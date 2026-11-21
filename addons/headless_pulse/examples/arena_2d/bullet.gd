class_name ArenaBullet
extends Node2D
## Straight-line projectile with deterministic manual integration.
##
## The hit loop is the hottest path of a campaign (bullets x enemies x ticks), so
## it avoids casts and virtual calls: candidates come from the arena's per-tick
## enemy cache, dead enemies are detected by a `hp` read (same condition as
## `is_alive()`, which sets `hp` to 0), and the exact test is a squared distance.
## Iteration order follows the enemy insertion order, which keeps hit resolution
## deterministic and stable across builds.

var velocity: Vector2 = Vector2.ZERO
var damage: float = 1.0
var weapon_id: String = ""
var lifetime: float = 1.0
var radius: float = 6.0
var shooter: ArenaPlayer = null

var _arena: Node = null
var _use_arena_cache: bool = false
var _headless: bool = true


func setup(
		spawn_position: Vector2,
		p_velocity: Vector2,
		p_damage: float,
		p_weapon_id: String,
		p_lifetime: float,
		p_radius: float,
		p_shooter: ArenaPlayer
	) -> void:
	position = spawn_position
	velocity = p_velocity
	damage = p_damage
	weapon_id = p_weapon_id
	lifetime = p_lifetime
	radius = p_radius
	shooter = p_shooter


func _ready() -> void:
	add_to_group("bullets")
	_arena = get_tree().get_first_node_in_group("arena")
	_use_arena_cache = _arena != null and _arena.has_method("get_enemies")
	_headless = DisplayServer.get_name() == "headless"


func _physics_process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()
		return
	global_position += velocity * delta

	if _arena != null and _arena.is_outside_bounds(global_position):
		queue_free()
		return

	var enemies: Array[ArenaEnemy] = _arena.get_enemies() if _use_arena_cache else _collect_enemies()
	var px: float = global_position.x
	var py: float = global_position.y
	for enemy: ArenaEnemy in enemies:
		if enemy.hp <= 0.0:
			continue
		var ep: Vector2 = enemy.global_position
		var reach: float = enemy.hit_radius + radius
		var dx: float = ep.x - px
		if dx > reach or dx < -reach:
			continue
		var dy: float = ep.y - py
		if dy > reach or dy < -reach:
			continue
		if dx * dx + dy * dy > reach * reach:
			continue
		var actual: float = enemy.take_damage(damage)
		if actual > 0.0 and shooter != null and is_instance_valid(shooter):
			shooter.note_hit(actual, weapon_id)
			if enemy.hp <= 0.0:
				shooter.note_kill(enemy.gold_reward)
		queue_free()
		return

	if not _headless:
		queue_redraw()


func _collect_enemies() -> Array[ArenaEnemy]:
	var result: Array[ArenaEnemy] = []
	for node: Node in get_tree().get_nodes_in_group("enemies"):
		if node is ArenaEnemy:
			result.append(node as ArenaEnemy)
	return result


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, Color(1.0, 0.85, 0.25))
