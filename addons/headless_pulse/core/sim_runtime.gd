extends Node
## SimRuntime autoload: headless simulation host and per-run result writer.
##
## Activated only when `--sim-mode` is present after `--` on the command line.
## Without it the node disables its own processing and every public method is a
## cheap no-op, so shipping the addon cannot affect normal gameplay.
##
## One process can host a *batch* of runs (`--sim-batch=N`, seeds
## `--sim-seed .. +N-1`): between runs it pauses the tree, reloads the scene and
## re-seeds everything, which amortises engine start-up across runs. A batch of 1
## is the plain single-run mode used for debugging.
##
## Responsibilities per run:
##   1. configure the engine for deterministic fast-forward,
##   2. own the seeded RNG + determinism digest,
##   3. attach the configured SimBotBase and hand it the virtual input proxy,
##   4. stop the run on death / timeout / stuck and write `_runs/*.json`.

const RESULT_SCHEMA: String = "headless_pulse/run/1"

signal run_finished

var _active: bool = false
var _config: SimConfig = null
var _rng: SimRNG = null
var _checksum: SimChecksum = null
var _input_proxy: SimInputProxy = null
var _telemetry: Node = null
var _bot: Node = null
var _player: Node = null
var _seed_start: int = 0
var _seed: int = 0
var _batch_count: int = 1
var _run_index: int = 0
var _tag: String = ""
var _out_path: String = ""
var _replay: bool = false
var _running: bool = false
var _finished: bool = false
var _sim_time: float = 0.0
var _ticks: int = 0
var _frames: int = 0
var _run_start_usec: int = 0
var _tuned_resources: Dictionary = {}
var _arena_ref: Node = null


func _init() -> void:
	# Run after gameplay nodes so termination checks see the final state of a tick.
	process_physics_priority = 1000
	process_priority = 1000
	# Keep ticking while the tree is paused during a between-runs scene reload.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	var opts: Dictionary = SimConfig.parse_args(OS.get_cmdline_user_args())
	# `-s`/`--script` mode is the orchestrator itself: autoloads do run there, but
	# that process has no game scene and must never start a simulation run.
	if not opts.has("sim-mode") or _is_script_mode():
		_active = false
		set_process(false)
		set_physics_process(false)
		return

	_active = true
	_replay = opts.has("sim-replay")
	_out_path = str(opts.get("sim-out", ""))
	_tag = str(opts.get("sim-tag", ""))
	_batch_count = maxi(1, str(opts.get("sim-batch", "1")).to_int())

	_config = SimConfig.from_opts(opts)
	if _config == null:
		push_error("[headless_pulse] invalid simulation configuration, aborting")
		get_tree().quit(1)
		return

	_seed_start = _config.seed
	_seed = _seed_start
	_configure_engine()
	_apply_overrides()

	# Created in _ready (before the main scene's _ready) so gameplay code can fetch
	# the seeded RNG during scene construction; _start_run() resets them per run.
	_rng = SimRNG.new(_seed_start)
	_checksum = SimChecksum.new()
	_input_proxy = SimInputProxy.new()

	# Spawn the first bot after the main scene is instantiated.
	call_deferred("_run_batch")

	if _config.verbose:
		print("[headless_pulse] runtime active seeds=%d..%d scene=%s bot=%s replay=%s"
				% [_seed_start, _seed_start + _batch_count - 1,
				_config.scene_path, _config.bot_script_path, _replay])


func _configure_engine() -> void:
	Engine.time_scale = 1.0
	if _replay:
		# 1x windowed replay: leave rendering / audio alone.
		return

	# Rendering and audio must be out of the way for a batch worker. The CLI
	# already passes --headless --fixed-fps 60; these are belt-and-braces.
	RenderingServer.render_loop_enabled = false
	if AudioServer.get_bus_index("Master") >= 0:
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)

	var ticks: int = Engine.physics_ticks_per_second
	if ticks != 60:
		push_warning("[headless_pulse] physics_ticks_per_second=%d, forcing 60 for deterministic 1 frame = 1 tick" % ticks)
		Engine.physics_ticks_per_second = 60
	if Engine.max_physics_steps_per_frame < 1:
		Engine.max_physics_steps_per_frame = 8


func _apply_overrides() -> void:
	if _config.overrides.is_empty():
		return
	for res_path: String in _config.overrides.keys():
		var res: Resource = get_resource(res_path)
		if res == null:
			push_error("[headless_pulse] override target not found: %s" % res_path)
			continue
		if _config.verbose:
			print("[headless_pulse] override %s -> %s" % [res_path, str(_config.overrides[res_path])])


## Load a resource and apply this campaign's `--sim-set` overrides to it.
## The instance is retained here, so every consumer in the run shares exactly the
## same mutated resource (weapon/balance `.tres` A/B testing relies on this).
func get_resource(path: String) -> Resource:
	if _tuned_resources.has(path):
		return _tuned_resources[path] as Resource
	var res: Resource = load(path)
	if res == null:
		return null
	var props: Dictionary = _config.overrides.get(path, {})
	for prop: String in props.keys():
		res.set(prop, props[prop])
	_tuned_resources[path] = res
	return res


# --- batch loop ------------------------------------------------------------

func _run_batch() -> void:
	_telemetry = get_node_or_null("/root/SimTelemetry")
	for index: int in range(_batch_count):
		_run_index = index
		if index > 0:
			await _reload_for_next_run()
		_start_run()
		await run_finished
		if _replay:
			break
	_finished = true
	if get_tree() != null:
		get_tree().quit(0)


## Pause gameplay, reload the scene, then resume. Pausing is what keeps the new
## scene from ticking before we hand it a fresh seed/bot, so every run starts from
## exactly the same state regardless of how many frames the reload takes.
func _reload_for_next_run() -> void:
	var tree: SceneTree = get_tree()
	tree.paused = true
	_player = null
	_arena_ref = null
	_bot = null
	if _input_proxy != null:
		_input_proxy.reset()
	_input_proxy = null

	var error: int = tree.change_scene_to_file(_config.scene_path)
	if error != OK:
		push_error("[headless_pulse] cannot reload scene %s (error %d)" % [_config.scene_path, error])
		tree.paused = false
		return

	var guard: int = 0
	while guard < 240:
		await tree.process_frame
		guard += 1
		var scene: Node = tree.current_scene
		if scene != null and scene.scene_file_path == _config.scene_path:
			break
	tree.paused = false


func _start_run() -> void:
	_seed = _seed_start + _run_index
	_rng.reset(_seed)
	_checksum.reset()
	if _input_proxy == null:
		_input_proxy = SimInputProxy.new()
	else:
		_input_proxy.reset()
	_sim_time = 0.0
	_ticks = 0
	_frames = 0
	if _telemetry != null and _telemetry.has_method("begin"):
		_telemetry.begin(self, _config, _rng)
	_spawn_bot()
	_run_start_usec = Time.get_ticks_usec()
	_running = true
	if _config.verbose:
		print("[headless_pulse] run %d/%d seed=%d started" % [_run_index + 1, _batch_count, _seed])


func _spawn_bot() -> void:
	if not ResourceLoader.exists(_config.bot_script_path):
		push_error("[headless_pulse] bot script not found: %s" % _config.bot_script_path)
		return
	var script: Script = load(_config.bot_script_path)
	if script == null:
		push_error("[headless_pulse] failed to load bot script: %s" % _config.bot_script_path)
		return
	var bot: Node = script.new() as Node
	if bot == null:
		push_error("[headless_pulse] bot script did not create a Node: %s" % _config.bot_script_path)
		return
	bot.name = "SimBot"
	var host: Node = get_tree().current_scene
	if host == null:
		host = get_tree().root
	host.add_child(bot)
	_bot = bot
	if _config.verbose:
		print("[headless_pulse] bot attached: %s" % _config.bot_script_path)


func _process(_delta: float) -> void:
	if not _active or not _running:
		return
	_frames += 1


func _physics_process(delta: float) -> void:
	if not _active or not _running:
		return
	_ticks += 1
	_sim_time += delta
	_ensure_player()

	var enemies: int = 0
	var bullets: int = 0
	if get_tree() != null:
		if _arena_ref == null or not is_instance_valid(_arena_ref):
			_arena_ref = get_tree().get_first_node_in_group("arena")
		if _arena_ref != null and _arena_ref.has_method("get_enemy_count"):
			enemies = int(_arena_ref.get_enemy_count())
			bullets = int(_arena_ref.get_bullet_count())
		else:
			enemies = get_tree().get_nodes_in_group(_config.enemy_group).size()
			bullets = get_tree().get_nodes_in_group("bullets").size()

	_feed_digest(enemies, bullets)
	if _telemetry != null and _telemetry.has_method("tick"):
		_telemetry.tick(delta, _player, enemies, bullets)
	_check_termination()


func _feed_digest(enemies: int, bullets: int) -> void:
	var px: float = 0.0
	var py: float = 0.0
	var hp: float = -1.0
	var kills: int = 0
	var gold: int = 0
	if _player != null and is_instance_valid(_player):
		var pos: Vector2 = (_player as Node2D).global_position
		px = pos.x
		py = pos.y
		hp = float(_prop(_player, "hp", -1.0))
		kills = int(_prop(_player, "kills", 0))
		gold = int(_prop(_player, "gold", 0))
	_checksum.feed([_sim_time, px, py, hp, kills, gold, enemies, bullets, _rng.draws])


func _check_termination() -> void:
	if _telemetry != null and _telemetry.has_method("death_count"):
		if _telemetry.death_count() > 0:
			_finish("death")
			return
		if _config.terminate_on_stuck and _telemetry.stuck_count() > 0:
			_finish("stuck")
			return
	if _sim_time >= _config.max_sim_time - 0.000001:
		_finish("timeout")
		return
	if _sim_time > 1.0 and (_player == null or not is_instance_valid(_player)):
		_finish("player_lost")


func _ensure_player() -> void:
	if _player != null and is_instance_valid(_player):
		return
	_player = get_tree().get_first_node_in_group(_config.player_group)


func _finish(reason: String) -> void:
	if not _running:
		return
	_running = false

	var wall_ms: float = (Time.get_ticks_usec() - _run_start_usec) / 1000.0
	var speedup: float = _sim_time / (wall_ms / 1000.0) if wall_ms > 0.0 else 0.0

	if _input_proxy != null:
		_input_proxy.reset()

	var telemetry: Dictionary = {}
	if _telemetry != null and _telemetry.has_method("finish"):
		telemetry = _telemetry.finish()

	var player_stats: Dictionary = {}
	if _player != null and is_instance_valid(_player) and _player.has_method("get_run_stats"):
		player_stats = _player.get_run_stats()

	# A "win" is surviving the full time budget; death / stuck / lost-player runs
	# are not wins even if the entity happened to still be alive.
	var survived: bool = reason == "timeout" and bool(player_stats.get("alive", false))

	var result: Dictionary = {
		"schema": RESULT_SCHEMA,
		"status": "ok",
		"run_id": _run_tag(),
		"seed": _seed,
		"engine": str(Engine.get_version_info().get("string", "")),
		"config_name": _config.name,
		"config": _config.to_dict(),
		"scene_path": _config.scene_path,
		"bot_script_path": _config.bot_script_path,
		"sim_time": snappedf(_sim_time, 0.000001),
		"ticks": _ticks,
		"frames": _frames,
		"wall_ms": snappedf(wall_ms, 0.001),
		"speedup": snappedf(speedup, 0.01),
		"end_reason": reason,
		"survived": survived,
		"player": player_stats,
		"telemetry": telemetry,
		"determinism": {
			"digest": _checksum.digest(),
			"samples": _checksum.samples,
			"rng_draws": _rng.draws,
			"rng_seed": _rng.get_seed(),
		},
		"overrides": _config.overrides,
		"replay": _replay,
	}

	var path: String = _run_output_path()
	_write_json(path, result)

	print("SIM_RESULT seed=%d reason=%s sim_time=%.3f ticks=%d wall_ms=%.1f speedup=%.0fx kills=%d digest=%s out=%s"
			% [_seed, reason, _sim_time, _ticks, wall_ms, speedup,
			int(player_stats.get("kills", 0)), _checksum.digest(), path])

	run_finished.emit()


func _run_tag() -> String:
	if _batch_count > 1:
		return "seed%d" % _seed
	if not _tag.is_empty():
		return _tag
	return "seed%d" % _seed


func _run_output_path() -> String:
	if _batch_count == 1 and _out_path.ends_with(".json"):
		return _out_path
	var directory: String = _out_path
	if directory.is_empty():
		directory = "%s/_runs" % _config.resolved_output_dir()
	return "%s/%s.json" % [directory.rstrip("/"), _run_tag()]


## Write a JSON file, creating parent directories when needed.
static func _write_json(path: String, data: Dictionary) -> bool:
	var absolute: String = ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	var dir: String = absolute.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		push_error("[headless_pulse] cannot write run result: %s (error %d)" % [absolute, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(data, "  ", true, true))
	file.close()
	return true


# --- public API ------------------------------------------------------------

func is_active() -> bool:
	return _active


func is_replay() -> bool:
	return _replay


func get_sim_time() -> float:
	return _sim_time


func get_ticks() -> int:
	return _ticks


func get_rng() -> SimRNG:
	return _rng


func get_config() -> SimConfig:
	return _config


func get_player() -> Node:
	return _player


func get_bot() -> Node:
	return _bot


func get_input_proxy() -> SimInputProxy:
	return _input_proxy


func bind_input_proxy(proxy: SimInputProxy) -> void:
	_input_proxy = proxy


func get_bounds() -> Rect2:
	if _config == null:
		return Rect2(Vector2(-480.0, -300.0), Vector2(960.0, 600.0))
	return Rect2(_config.bounds_min, _config.bounds_max - _config.bounds_min)


func set_aim_world_position(world_pos: Vector2) -> void:
	if _input_proxy != null:
		_input_proxy.set_aim_world_pos(world_pos)


func get_aim_world_position() -> Vector2:
	return _input_proxy.get_aim_world_pos() if _input_proxy != null else Vector2.ZERO


func has_aim() -> bool:
	return _input_proxy != null and _input_proxy.has_aim()


## Game code can end a run early (e.g. a "level cleared" condition).
func finish_run(reason: String = "scripted") -> void:
	if _active and _running:
		_finish(reason)


static func _prop(node: Object, name: String, fallback: Variant) -> Variant:
	if node == null:
		return fallback
	var value: Variant = node.get(name)
	if value == null:
		return fallback
	return value


## True when this process runs a MainLoop script (`godot -s ...`) instead of a
## game scene - e.g. the campaign orchestrator in cli/run_sim.gd.
static func _is_script_mode() -> bool:
	for argument: String in OS.get_cmdline_args():
		if argument == "-s" or argument == "--script" or argument.begins_with("--script="):
			return true
	return false
