class_name ArenaEnemy
extends Node2D
## Simple chaser enemy: manual integration (no physics body) so the only physics
## interaction in the demo is the player's CharacterBody2D against static walls.

var max_hp: float = 24.0
var hp: float = 24.0
var speed: float = 90.0
var touch_damage: float = 7.0
var touch_interval: float = 0.55
var gold_reward: int = 5
var hit_radius: float = 12.0

var _alive: bool = true
var _touch_cooldown: float = 0.0
var _player: ArenaPlayer = null
var _headless: bool = true


func setup(p_max_hp: float, p_speed: float, p_touch_damage: float, p_gold: int, player: ArenaPlayer) -> void:
	max_hp = p_max_hp
	hp = p_max_hp
	speed = p_speed
	touch_damage = p_touch_damage
	gold_reward = p_gold
	_player = player


func _ready() -> void:
	add_to_group("enemies")
	_headless = DisplayServer.get_name() == "headless"


func is_alive() -> bool:
	return _alive


func take_damage(amount: float) -> float:
	if not _alive:
		return 0.0
	var actual: float = minf(amount, hp)
	hp -= actual
	if hp <= 0.000001:
		hp = 0.0
		_die()
	return actual


func _die() -> void:
	_alive = false
	remove_from_group("enemies")
	SimTelemetry.record_event("enemy_death", {
		"pos": [snappedf(global_position.x, 0.1), snappedf(global_position.y, 0.1)],
		"gold": gold_reward,
	})
	queue_free()


func _physics_process(delta: float) -> void:
	if not _alive:
		return
	if _player == null or not is_instance_valid(_player):
		return
	_touch_cooldown = maxf(_touch_cooldown - delta, 0.0)

	var to_player: Vector2 = _player.global_position - global_position
	var distance: float = to_player.length()
	if distance > 0.001:
		global_position += to_player / distance * speed * delta

	if distance <= hit_radius + 11.0 and _touch_cooldown <= 0.0:
		_touch_cooldown = touch_interval
		_player.take_damage(touch_damage, "enemy_contact")

	if not _headless:
		queue_redraw()


func _draw() -> void:
	var tint: float = clampf(hp / maxf(max_hp, 0.001), 0.0, 1.0)
	draw_circle(Vector2.ZERO, hit_radius, Color(0.75 + 0.25 * (1.0 - tint), 0.25 + 0.45 * tint, 0.3))
	draw_arc(Vector2.ZERO, hit_radius, 0.0, TAU, 16, Color(0.1, 0.05, 0.05), 1.5)
