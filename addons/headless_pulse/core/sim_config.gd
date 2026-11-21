class_name SimConfig
extends Resource
## Configuration for one simulation campaign (N runs, one scene, one bot).
##
## A campaign can be described either by a `.tres` resource or entirely by CLI
## arguments. Every field can be overridden from the command line, which lets an
## agent run A/B experiments without editing project files.
##
## CLI arguments (everything after `--`):
##   --sim-mode                     enable simulation (required)
##   --sim-config=<path.tres>       load a SimConfig resource as the base
##   --sim-scene=<res://...tscn>    scene to simulate
##   --sim-bot=<res://...gd>        SimBotBase script that drives the scene
##   --sim-seed=<int>               first seed of the campaign
##   --sim-runs=<int>               number of runs
##   --sim-repeat=<int>             run every seed N times (determinism check)
##   --sim-jobs=<int>               worker processes (0 = auto)
##   --sim-batch=<int>              runs per worker process (0 = auto: runs/workers)
##   --sim-max-time=<float>         simulated seconds per run
##   --sim-out=<path>               output file (worker) or directory (orchestrator)
##   --sim-tag=<string>             run id suffix used by the orchestrator
##   --sim-grid=<cols>x<rows>       ASCII heatmap resolution
##   --sim-bounds=<x0,y0,x1,y1>     world bounds used by the heatmap
##   --sim-sample-interval=<float>  time-series sampling period (sim seconds)
##   --sim-stuck-window=<float>     stuck detection window (sim seconds)
##   --sim-stuck-threshold=<float>  minimum displacement inside the window (world units)
##   --sim-terminate-on-stuck       end a run as soon as it is stuck
##   --sim-set=<res>|<prop>=<val>   override a .tres property for this campaign (repeatable)
##   --sim-report-name=<string>     base name of the aggregated report
##   --sim-baseline=<path.json>     baseline report used for A/B diffing
##   --sim-replay                   windowed 1x replay instead of a headless batch worker
##   --sim-verbose                  print extra diagnostics

const SCHEMA: String = "headless_pulse/config/1"

@export var name: String = "arena_2d"
@export_file("*.tscn") var scene_path: String = "res://addons/headless_pulse/examples/arena_2d/arena.tscn"
@export_file("*.gd") var bot_script_path: String = "res://addons/headless_pulse/examples/bots/kiting_shooter_bot.gd"

@export_group("Campaign")
@export var seed: int = 1000
@export var runs: int = 50
@export var repeat: int = 1
@export var max_concurrency: int = 0
@export var batch_size: int = 0
@export var max_sim_time: float = 60.0

@export_group("Scene Hooks")
@export var player_group: String = "player"
@export var enemy_group: String = "enemies"

@export_group("Output")
@export var output_dir: String = "res://reports"
@export var report_name: String = "report"
@export var baseline_path: String = ""
@export var verbose: bool = false
@export var determinism_check: bool = true

@export_group("Telemetry")
@export var grid_cols: int = 40
@export var grid_rows: int = 20
@export var auto_bounds: bool = false
@export var bounds_min: Vector2 = Vector2(-480.0, -300.0)
@export var bounds_max: Vector2 = Vector2(480.0, 300.0)
@export var sample_interval: float = 0.5
@export var stuck_window_seconds: float = 3.0
@export var stuck_move_threshold: float = 6.0
@export var terminate_on_stuck: bool = false

@export_group("Balance Thresholds")
@export var overrides: Dictionary = {}
@export var win_rate_target_min: float = 0.25
@export var win_rate_target_max: float = 0.80
@export var stuck_rate_warn: float = 0.05
@export var weapon_dps_ratio_warn: float = 2.0


## Parse `--key=value` user arguments into a dictionary.
## Repeatable keys are collected into an Array.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var opts: Dictionary = {}
	var sets: Array[String] = []
	for raw: String in args:
		if not raw.begins_with("--"):
			continue
		var key: String = raw.substr(2)
		var value: Variant = true
		var eq: int = key.find("=")
		if eq >= 0:
			value = key.substr(eq + 1)
			key = key.substr(0, eq)
		if key == "sim-set":
			sets.append(str(value))
			continue
		opts[key] = value
	if not sets.is_empty():
		opts["sim-set"] = sets
	return opts


## Build a SimConfig from parsed CLI options. Returns null when a fatal option
## is invalid (the error is printed, so a worker fails loudly instead of running
## with a silently different configuration).
static func from_opts(opts: Dictionary) -> SimConfig:
	var config: SimConfig = null
	if opts.has("sim-config"):
		var path: String = str(opts["sim-config"])
		if not ResourceLoader.exists(path):
			push_error("[headless_pulse] config not found: %s" % path)
			return null
		var res: Resource = load(path)
		if res is SimConfig:
			config = (res as SimConfig).duplicate(true) as SimConfig
		else:
			push_error("[headless_pulse] not a SimConfig resource: %s" % path)
			return null
	if config == null:
		config = SimConfig.new()
	var errors: PackedStringArray = config.apply_opts(opts)
	if not errors.is_empty():
		for err: String in errors:
			push_error("[headless_pulse] %s" % err)
		return null
	return config


## Apply parsed CLI options on top of this config. Returns a list of errors.
func apply_opts(opts: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if opts.has("sim-scene"):
		scene_path = str(opts["sim-scene"])
	if opts.has("sim-bot"):
		bot_script_path = str(opts["sim-bot"])
	if opts.has("sim-name"):
		name = str(opts["sim-name"])
	if opts.has("sim-seed"):
		seed = _to_int(opts["sim-seed"], seed)
	if opts.has("sim-runs"):
		runs = _to_int(opts["sim-runs"], runs)
	if opts.has("sim-repeat"):
		repeat = _to_int(opts["sim-repeat"], repeat)
	if opts.has("sim-jobs"):
		max_concurrency = _to_int(opts["sim-jobs"], max_concurrency)
	if opts.has("sim-batch"):
		batch_size = _to_int(opts["sim-batch"], batch_size)
	if opts.has("sim-max-time"):
		max_sim_time = _to_float(opts["sim-max-time"], max_sim_time)
	if opts.has("sim-tag"):
		pass # consumed by SimRuntime
	if opts.has("sim-out"):
		var raw_out: String = str(opts["sim-out"])
		# A worker receives an exact result file; the orchestrator receives a
		# directory. Both map onto `output_dir`.
		output_dir = _dir_of(raw_out) if raw_out.ends_with(".json") else raw_out
	if opts.has("sim-report-name"):
		report_name = str(opts["sim-report-name"])
	if opts.has("sim-baseline"):
		baseline_path = str(opts["sim-baseline"])
	if opts.has("sim-verbose"):
		verbose = _to_bool(opts["sim-verbose"])
	if opts.has("sim-no-determinism-check"):
		determinism_check = false
	if opts.has("sim-player-group"):
		player_group = str(opts["sim-player-group"])
	if opts.has("sim-enemy-group"):
		enemy_group = str(opts["sim-enemy-group"])
	if opts.has("sim-grid"):
		var grid: PackedStringArray = str(opts["sim-grid"]).to_lower().split("x")
		if grid.size() == 2:
			grid_cols = _to_int(grid[0], grid_cols)
			grid_rows = _to_int(grid[1], grid_rows)
		else:
			errors.append("--sim-grid expects <cols>x<rows>, got '%s'" % str(opts["sim-grid"]))
	if opts.has("sim-bounds"):
		var parts: PackedStringArray = str(opts["sim-bounds"]).split(",")
		if parts.size() == 4:
			bounds_min = Vector2(_to_float(parts[0], bounds_min.x), _to_float(parts[1], bounds_min.y))
			bounds_max = Vector2(_to_float(parts[2], bounds_max.x), _to_float(parts[3], bounds_max.y))
		else:
			errors.append("--sim-bounds expects <x0,y0,x1,y1>, got '%s'" % str(opts["sim-bounds"]))
	if opts.has("sim-sample-interval"):
		sample_interval = _to_float(opts["sim-sample-interval"], sample_interval)
	if opts.has("sim-stuck-window"):
		stuck_window_seconds = _to_float(opts["sim-stuck-window"], stuck_window_seconds)
	if opts.has("sim-stuck-threshold"):
		stuck_move_threshold = _to_float(opts["sim-stuck-threshold"], stuck_move_threshold)
	if opts.has("sim-terminate-on-stuck"):
		terminate_on_stuck = _to_bool(opts["sim-terminate-on-stuck"])
	if opts.has("sim-win-rate-min"):
		win_rate_target_min = _to_float(opts["sim-win-rate-min"], win_rate_target_min)
	if opts.has("sim-win-rate-max"):
		win_rate_target_max = _to_float(opts["sim-win-rate-max"], win_rate_target_max)
	if opts.has("sim-set"):
		var set_list: Array = opts["sim-set"]
		var extra: PackedStringArray = _apply_overrides(set_list)
		errors.append_array(extra)
	errors.append_array(validate())
	return errors


func _apply_overrides(set_list: Array) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	for entry: Variant in set_list:
		var text: String = str(entry)
		var split: int = text.find("|")
		if split < 0:
			errors.append("--sim-set expects <res>|<prop>=<value>, got '%s'" % text)
			continue
		var res_path: String = text.substr(0, split)
		var assign: String = text.substr(split + 1)
		var eq: int = assign.find("=")
		if eq <= 0:
			errors.append("--sim-set expects <res>|<prop>=<value>, got '%s'" % text)
			continue
		var prop: String = assign.substr(0, eq)
		var value: Variant = str_to_var(assign.substr(eq + 1))
		if not overrides.has(res_path):
			overrides[res_path] = {}
		(overrides[res_path] as Dictionary)[prop] = value
	return errors


func validate() -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()
	if not ResourceLoader.exists(scene_path):
		errors.append("scene not found: %s" % scene_path)
	if not ResourceLoader.exists(bot_script_path):
		errors.append("bot script not found: %s" % bot_script_path)
	if max_sim_time <= 0.0:
		errors.append("max_sim_time must be > 0 (got %f)" % max_sim_time)
	if runs < 1:
		errors.append("runs must be >= 1 (got %d)" % runs)
	if repeat < 1:
		errors.append("repeat must be >= 1 (got %d)" % repeat)
	if batch_size < 0:
		errors.append("batch_size must be >= 0 (got %d)" % batch_size)
	if grid_cols < 4 or grid_cols > 400 or grid_rows < 4 or grid_rows > 400:
		errors.append("grid must be within 4..400 cells per axis (got %dx%d)" % [grid_cols, grid_rows])
	if sample_interval <= 0.0:
		errors.append("sample_interval must be > 0 (got %f)" % sample_interval)
	if stuck_window_seconds <= 0.0:
		errors.append("stuck_window_seconds must be > 0 (got %f)" % stuck_window_seconds)
	if stuck_move_threshold < 0.0:
		errors.append("stuck_move_threshold must be >= 0 (got %f)" % stuck_move_threshold)
	if not auto_bounds and (bounds_max.x <= bounds_min.x or bounds_max.y <= bounds_min.y):
		errors.append("bounds_max must be greater than bounds_min")
	return errors


func to_dict() -> Dictionary:
	return {
		"schema": SCHEMA,
		"name": name,
		"scene_path": scene_path,
		"bot_script_path": bot_script_path,
		"seed": seed,
		"runs": runs,
		"repeat": repeat,
		"max_concurrency": max_concurrency,
		"batch_size": batch_size,
		"max_sim_time": max_sim_time,
		"output_dir": output_dir,
		"report_name": report_name,
		"grid_cols": grid_cols,
		"grid_rows": grid_rows,
		"auto_bounds": auto_bounds,
		"bounds_min": [bounds_min.x, bounds_min.y],
		"bounds_max": [bounds_max.x, bounds_max.y],
		"sample_interval": sample_interval,
		"stuck_window_seconds": stuck_window_seconds,
		"stuck_move_threshold": stuck_move_threshold,
		"terminate_on_stuck": terminate_on_stuck,
		"overrides": overrides,
		"determinism_check": determinism_check,
	}


## Number of worker processes that should be used for this campaign.
func resolved_concurrency() -> int:
	var cores: int = OS.get_processor_count()
	if max_concurrency > 0:
		return clampi(max_concurrency, 1, 64)
	# One worker per core minus one leaves headroom for the orchestrator; the cap
	# keeps a 64-core CI box from spawning 60 Godot processes at once.
	return clampi(cores - 1, 1, 32)


## Directory that receives the aggregated report files.
func resolved_output_dir() -> String:
	return output_dir.rstrip("/")


## Runs executed sequentially inside one worker process (0 = auto).
## Batching amortises engine start-up; each run still gets a fresh scene reload.
func resolved_batch_size() -> int:
	if batch_size > 0:
		return clampi(batch_size, 1, 64)
	if runs <= 0:
		return 1
	return maxi(1, ceili(float(runs) / float(resolved_concurrency())))


## Absolute path for a report file inside the output directory.
func report_path(extension: String) -> String:
	return "%s/%s.%s" % [resolved_output_dir(), report_name, extension]


static func _dir_of(path: String) -> String:
	var slash: int = path.rfind("/")
	if slash <= 0:
		return path
	return path.substr(0, slash)


static func _to_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is bool:
		return 1 if value else 0
	var text: String = str(value).strip_edges()
	if text.is_valid_int():
		return text.to_int()
	return fallback


static func _to_float(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		return float(value)
	var text: String = str(value).strip_edges()
	if text.is_valid_float():
		return text.to_float()
	return fallback


static func _to_bool(value: Variant) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return int(value) != 0
	var text: String = str(value).strip_edges().to_lower()
	return text in ["1", "true", "yes", "on"]
