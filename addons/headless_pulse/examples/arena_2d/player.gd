class_name ArenaPlayer
extends CharacterBody2D
## Demo player: CharacterBody2D movement against static walls, data-driven
## weapons, and a virtual-aim adapter so headless bots can shoot without a mouse.

const DEFAULT_WEAPONS: Array = [
	"res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres",
	"res://addons/headless_pulse/examples/arena_2d/weapons/shotgun.tres",
]

@export var max_hp: float = 100.0
@export var move_speed: float = 260.0
@export var heal_per_kill: float = 0.0
@export var weapon_paths: PackedStringArray = DEFAULT_WEAPONS

var hp: float = 100.0
var is_alive: bool = true
var kills: int = 0
var gold: int = 0
var damage_dealt: float = 0.0
var hits: int = 0
var shots_fired: int = 0
var move_intent: float = 0.0
var weapon_id: String = ""
var weapon_damage: Dictionary = {}

var _weapons: Array[WeaponStats] = []
var _weapon_index: int = 0
var _fire_cooldown: float = 0.0
var _aim_dir: Vector2 = Vector2.RIGHT
var _arena: Node = null
var _runtime: Node = null
var _rng: SimRNG = null
var _headless: bool = true


func _ready() -> void:
	add_to_group("player")
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	hp = max_hp
	_headless = DisplayServer.get_name() == "headless"
	_runtime = get_node_or_null("/root/SimRuntime")
	_arena = get_tree().get_first_node_in_group("arena")
	_load_weapons()
	_equip(0)
	if _runtime != null and _runtime.is_active():
		_rng = _runtime.get_rng() as SimRNG
		if not _headless:
			queue_redraw()


func _load_weapons() -> void:
	var paths: PackedStringArray = weapon_paths
	if paths.is_empty():
		paths = DEFAULT_WEAPONS
	for path: String in paths:
		if not ResourceLoader.exists(path):
			push_error("[headless_pulse] weapon resource not found: %s" % path)
			continue
		var res: Resource = null
		if _runtime != null and _runtime.is_active():
			# Shared, override-aware instance: weapon balance A/B via --sim-set.
			res = _runtime.get_resource(path)
		else:
			res = load(path)
		if res is WeaponStats:
			_weapons.append(res as WeaponStats)


func _equip(index: int) -> void:
	if _weapons.is_empty():
		return
	_weapon_index = clampi(index, 0, _weapons.size() - 1)
	weapon_id = _weapons[_weapon_index].id
	_fire_cooldown = 0.0


func _physics_process(delta: float) -> void:
	if not is_alive:
		return

	if Input.is_action_just_pressed("weapon_1"):
		_equip(0)
	if Input.is_action_just_pressed("weapon_2"):
		_equip(1)

	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	move_intent = input_dir.length()
	velocity = input_dir * move_speed
	move_and_slide()

	_update_aim()
	_fire_cooldown = maxf(_fire_cooldown - delta, 0.0)
	if Input.is_action_pressed("fire") and _fire_cooldown <= 0.0:
		_shoot()

	if not _headless:
		queue_redraw()


func _update_aim() -> void:
	if _runtime != null and _runtime.is_active() and _runtime.has_aim():
		var to_aim: Vector2 = _runtime.get_aim_world_position() - global_position
		if to_aim.length_squared() > 0.0001:
			_aim_dir = to_aim.normalized()
		return
	var to_mouse: Vector2 = get_global_mouse_position() - global_position
	if to_mouse.length_squared() > 0.0001:
		_aim_dir = to_mouse.normalized()


func _shoot() -> void:
	if _weapons.is_empty() or _arena == null:
		return
	var weapon: WeaponStats = _weapons[_weapon_index]
	_fire_cooldown = weapon.fire_interval
	var muzzle: Vector2 = global_position + _aim_dir * 16.0
	for _pellet: int in range(maxi(weapon.pellets, 1)):
		shots_fired += 1
		var dir: Vector2 = _aim_dir
		if weapon.pellets > 1 and weapon.spread_radians > 0.0:
			dir = _aim_dir.rotated(_randf_range(-weapon.spread_radians, weapon.spread_radians))
		var bullet := ArenaBullet.new()
		bullet.setup(muzzle, dir * weapon.bullet_speed, weapon.damage, weapon.id,
				weapon.bullet_lifetime, weapon.bullet_radius, self)
		if _arena.has_method("spawn_bullet"):
			_arena.spawn_bullet(bullet)
		else:
			get_parent().add_child(bullet)


func take_damage(amount: float, cause: String = "unknown") -> void:
	if not is_alive:
		return
	hp = maxf(hp - amount, 0.0)
	SimTelemetry.record_metric("damage_taken", amount)
	if hp <= 0.0:
		_die(cause)
	elif not _headless:
		queue_redraw()


func _die(cause: String) -> void:
	is_alive = false
	velocity = Vector2.ZERO
	set_physics_process(false)
	SimTelemetry.record_event("player_death", {
		"cause": cause,
		"wave": _arena.wave_index() if _arena != null and _arena.has_method("wave_index") else 0,
		"pos": [snappedf(global_position.x, 0.1), snappedf(global_position.y, 0.1)],
		"gold": gold,
		"kills": kills,
	})
	if not _headless:
		queue_redraw()


func note_hit(amount: float, p_weapon_id: String) -> void:
	hits += 1
	damage_dealt += amount
	weapon_damage[p_weapon_id] = float(weapon_damage.get(p_weapon_id, 0.0)) + amount
	SimTelemetry.record_metric("damage_dealt", amount, {"weapon": p_weapon_id})


func note_kill(gold_reward: int) -> void:
	kills += 1
	gold += gold_reward
	if heal_per_kill > 0.0 and is_alive:
		hp = minf(hp + heal_per_kill, max_hp)
	SimTelemetry.record_metric("gold_earned", float(gold_reward))
	SimTelemetry.record_event("enemy_kill", {"reward": gold_reward, "wave": 0})


func get_run_stats() -> Dictionary:
	return {
		"alive": is_alive,
		"hp": snappedf(hp, 0.01),
		"max_hp": max_hp,
		"move_intent": move_intent,
		"final_pos": [global_position.x, global_position.y],
		"final_pos_str": var_to_str(global_position),
		"kills": kills,
		"gold": gold,
		"damage_dealt": snappedf(damage_dealt, 0.01),
		"weapon_damage": weapon_damage.duplicate(),
		"hits": hits,
		"shots_fired": shots_fired,
		"accuracy": snappedf(float(hits) / float(shots_fired), 0.0001) if shots_fired > 0 else 0.0,
		"weapon": weapon_id,
	}


func _randf_range(from: float, to: float) -> float:
	if _rng != null:
		return _rng.randf_range(from, to)
	return randf_range(from, to)


func _draw() -> void:
	var body_color: Color = Color(0.3, 0.85, 1.0) if is_alive else Color(0.35, 0.35, 0.4)
	draw_rect(Rect2(-11.0, -11.0, 22.0, 22.0), body_color)
	draw_rect(Rect2(-11.0, -11.0, 22.0, 22.0), Color(0.05, 0.1, 0.15), false, 2.0)
	draw_line(Vector2.ZERO, _aim_dir * 26.0, Color(1.0, 1.0, 1.0), 2.0)
	# HP bar above the player.
	var frac: float = clampf(hp / maxf(max_hp, 0.001), 0.0, 1.0)
	draw_rect(Rect2(-14.0, -22.0, 28.0, 4.0), Color(0.12, 0.12, 0.12))
	draw_rect(Rect2(-14.0, -22.0, 28.0 * frac, 4.0), Color(0.2, 0.9, 0.35))
