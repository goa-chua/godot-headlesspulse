class_name ArenaRunner
extends Node2D
## Self-contained demo arena: bounded play field, a U-shaped trap used by the
## stuck-detection acceptance test, wave spawning through SimRNG, and a small HUD
## that is only created when a window is available (1x replay mode).

const WALL_THICKNESS: float = 20.0

const TUNING_PATH: String = "res://addons/headless_pulse/examples/arena_2d/arena_tuning.tres"

@export var arena_half_extent: Vector2 = Vector2(480.0, 300.0)
@export_group("Waves")
@export var wave_interval: float = 5.0
@export var first_wave_delay: float = 1.0
@export var wave_base_count: int = 2
@export var wave_scale: int = 2
@export var enemy_cap: int = 60
@export_group("Enemies")
@export var enemy_base_hp: float = 24.0
@export var enemy_hp_per_wave: float = 4.0
@export var enemy_base_speed: float = 88.0
@export var enemy_speed_per_wave: float = 4.0
@export var enemy_touch_damage: float = 7.0
@export var gold_per_kill: int = 5
@export var spawn_radius_min: float = 360.0
@export var spawn_radius_max: float = 450.0

var wave: int = 0

var _bounds: Rect2 = Rect2(Vector2(-480.0, -300.0), Vector2(960.0, 600.0))
var _walls_root: Node2D = null
var _enemy_root: Node2D = null
var _bullet_root: Node2D = null
var _player: ArenaPlayer = null
var _hud_label: Label = null
var _hud_timer: float = 0.0
var _wave_timer: float = 0.0
var _headless: bool = true
var _rng: SimRNG = null
var _wall_rects: Array[Rect2] = []
var _enemy_cache: Array[ArenaEnemy] = []
var _tuning: ArenaTuning = null


func _ready() -> void:
	add_to_group("arena")
	_headless = DisplayServer.get_name() == "headless"
	_bounds = Rect2(-arena_half_extent, arena_half_extent * 2.0)

	var runtime: Node = get_node_or_null("/root/SimRuntime")
	if runtime != null and runtime.is_active():
		_bounds = runtime.get_bounds()
		_rng = runtime.get_rng() as SimRNG

	_apply_tuning()

	_walls_root = Node2D.new()
	_walls_root.name = "Walls"
	add_child(_walls_root)
	_enemy_root = Node2D.new()
	_enemy_root.name = "Enemies"
	add_child(_enemy_root)
	_bullet_root = Node2D.new()
	_bullet_root.name = "Bullets"
	add_child(_bullet_root)

	_build_outer_walls()
	_build_obstacles()
	_spawn_player()
	if not _headless:
		_build_hud()

	_wave_timer = maxf(wave_interval - first_wave_delay, 0.0)


## Load data-driven balance knobs. `--sim-set=...arena_tuning.tres|prop=value`
## mutates this cached resource before the scene loads, which is how A/B tests run.
func _apply_tuning() -> void:
	if not ResourceLoader.exists(TUNING_PATH):
		return
	var runtime: Node = get_node_or_null("/root/SimRuntime")
	var res: Resource = null
	if runtime != null and runtime.is_active():
		res = runtime.get_resource(TUNING_PATH)
	else:
		res = load(TUNING_PATH)
	if not (res is ArenaTuning):
		return
	_tuning = res as ArenaTuning
	wave_interval = _tuning.wave_interval
	first_wave_delay = _tuning.first_wave_delay
	wave_base_count = _tuning.wave_base_count
	wave_scale = _tuning.wave_scale
	enemy_cap = _tuning.enemy_cap
	enemy_base_hp = _tuning.enemy_base_hp
	enemy_hp_per_wave = _tuning.enemy_hp_per_wave
	enemy_base_speed = _tuning.enemy_base_speed
	enemy_speed_per_wave = _tuning.enemy_speed_per_wave
	enemy_touch_damage = _tuning.enemy_touch_damage
	gold_per_kill = _tuning.gold_per_kill
	spawn_radius_min = _tuning.spawn_radius_min
	spawn_radius_max = _tuning.spawn_radius_max


func _physics_process(delta: float) -> void:
	_refresh_enemy_cache()
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as ArenaPlayer
	_wave_timer += delta
	if _wave_timer >= wave_interval - 0.000001:
		_wave_timer = 0.0
		spawn_wave()


## One group query per tick instead of one group query per bullet per tick.
func _refresh_enemy_cache() -> void:
	_enemy_cache.clear()
	for node: Node in get_tree().get_nodes_in_group("enemies"):
		if node is ArenaEnemy:
			_enemy_cache.append(node as ArenaEnemy)


func get_enemies() -> Array[ArenaEnemy]:
	return _enemy_cache


func get_enemy_count() -> int:
	return _enemy_cache.size()


func get_bullet_count() -> int:
	return _bullet_root.get_child_count() if _bullet_root != null else 0


func _process(delta: float) -> void:
	if _headless or _hud_label == null:
		return
	_hud_timer += delta
	if _hud_timer < 0.1:
		return
	_hud_timer = 0.0
	_update_hud()


# --- public API used by the demo game code --------------------------------

func spawn_bullet(bullet: ArenaBullet) -> void:
	_bullet_root.add_child(bullet)


func is_outside_bounds(world_pos: Vector2) -> bool:
	return not _bounds.grow(48.0).has_point(world_pos)


func get_bounds_rect() -> Rect2:
	return _bounds


func wave_index() -> int:
	return wave


func spawn_wave() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	wave += 1
	var count: int = wave_base_count + wave * wave_scale
	var room: int = maxi(enemy_cap - _enemy_root.get_child_count(), 0)
	count = mini(count, room)
	for _i: int in range(count):
		_spawn_enemy()
	SimTelemetry.record_event("wave_start", {"wave": wave, "count": count})


func _spawn_enemy() -> void:
	var angle: float = _randf_range(0.0, TAU)
	var radius: float = _randf_range(spawn_radius_min, spawn_radius_max)
	var pos: Vector2 = _player.global_position + Vector2(cos(angle), sin(angle)) * radius
	pos.x = clampf(pos.x, _bounds.position.x + 40.0, _bounds.end.x - 40.0)
	pos.y = clampf(pos.y, _bounds.position.y + 40.0, _bounds.end.y - 40.0)

	var enemy := ArenaEnemy.new()
	enemy.setup(
		enemy_base_hp + enemy_hp_per_wave * float(wave - 1),
		enemy_base_speed + enemy_speed_per_wave * float(wave - 1),
		enemy_touch_damage,
		gold_per_kill,
		_player
	)
	enemy.position = pos
	_enemy_root.add_child(enemy)


func _randf_range(from: float, to: float) -> float:
	if _rng != null:
		return _rng.randf_range(from, to)
	return randf_range(from, to)


# --- construction ---------------------------------------------------------

func _build_outer_walls() -> void:
	var b: Rect2 = _bounds
	var t: float = WALL_THICKNESS
	_add_wall(Rect2(b.position.x - t, b.position.y - t, b.size.x + 2.0 * t, t))
	_add_wall(Rect2(b.position.x - t, b.end.y, b.size.x + 2.0 * t, t))
	_add_wall(Rect2(b.position.x - t, b.position.y, t, b.size.y))
	_add_wall(Rect2(b.end.x, b.position.y, t, b.size.y))


func _build_obstacles() -> void:
	# U-shaped trap opening towards +X, used by examples/bots/wall_pusher_bot.gd.
	_add_wall(Rect2(-300.0, -40.0, 20.0, 160.0))
	_add_wall(Rect2(-300.0, 100.0, 80.0, 20.0))
	_add_wall(Rect2(-300.0, -40.0, 80.0, 20.0))
	# Scattered cover blocks.
	_add_wall(Rect2(150.0, 60.0, 90.0, 30.0))
	_add_wall(Rect2(-80.0, -180.0, 40.0, 90.0))
	_add_wall(Rect2(240.0, -160.0, 120.0, 24.0))
	_add_wall(Rect2(-20.0, 150.0, 160.0, 24.0))


func _add_wall(rect: Rect2) -> void:
	var body := StaticBody2D.new()
	body.position = rect.get_center()
	body.collision_layer = 1
	body.collision_mask = 1

	var shape := CollisionShape2D.new()
	var rect_shape := RectangleShape2D.new()
	rect_shape.size = rect.size
	shape.shape = rect_shape
	body.add_child(shape)

	_walls_root.add_child(body)
	_wall_rects.append(rect)


func _spawn_player() -> void:
	_player = ArenaPlayer.new()
	_player.position = Vector2.ZERO
	_player.name = "Player"
	if _tuning != null:
		_player.max_hp = _tuning.player_hp
		_player.move_speed = _tuning.player_speed
		_player.heal_per_kill = _tuning.heal_per_kill

	var collider := CollisionShape2D.new()
	var body_shape := RectangleShape2D.new()
	body_shape.size = Vector2(22.0, 22.0)
	collider.shape = body_shape
	collider.name = "Collision"
	_player.add_child(collider)

	add_child(_player)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	var label := Label.new()
	label.position = Vector2(16.0, 12.0)
	label.add_theme_font_size_override("font_size", 18)
	layer.add_child(label)
	add_child(layer)
	_hud_label = label
	_update_hud()


func _update_hud() -> void:
	if _hud_label == null or _player == null or not is_instance_valid(_player):
		return
	var runtime: Node = get_node_or_null("/root/SimRuntime")
	var sim_time: float = runtime.get_sim_time() if runtime != null and runtime.is_active() else 0.0
	_hud_label.text = "seed=%d  t=%.1fs  wave=%d  hp=%.0f  kills=%d  gold=%d  weapon=%s" % [
		_seed_display(),
		sim_time,
		wave,
		_player.hp,
		_player.kills,
		_player.gold,
		_player.weapon_id,
	]


func _seed_display() -> int:
	var runtime: Node = get_node_or_null("/root/SimRuntime")
	if runtime != null and runtime.is_active():
		var cfg: SimConfig = runtime.get_config()
		if cfg != null:
			return cfg.seed
	return 0


func _draw() -> void:
	var b: Rect2 = _bounds
	draw_rect(b, Color(0.1, 0.12, 0.16), false, 2.0)
	for rect: Rect2 in _wall_rects:
		draw_rect(rect, Color(0.32, 0.38, 0.48))
		draw_rect(rect, Color(0.55, 0.62, 0.72), false, 1.0)
	# Spawn marker for the replay window.
	draw_circle(Vector2.ZERO, 4.0, Color(0.3, 0.85, 1.0))
