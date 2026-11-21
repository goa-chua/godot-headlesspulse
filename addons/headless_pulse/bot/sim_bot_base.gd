class_name SimBotBase
extends Node
## Base class for heuristic bots.
##
## A bot runs in `_physics_process` with `process_physics_priority = -100`, so it
## injects input before player/entity scripts are processed on the same fixed
## tick. Subclasses only override `_bot_tick()`; helpers below cover the common
## "find something, steer, shoot" loop.
##
## [codeblock]
## class_name MyBot
## extends SimBotBase
##
## func _bot_tick(_delta: float) -> void:
##     var player := get_target_node()
##     var enemy := find_nearest_enemy(player.global_position)
##     if enemy == null:
##         return
##     var away := (player.global_position - enemy.global_position).normalized()
##     set_move_vector(away)
##     aim_at(enemy.global_position)
##     hold_action("fire")
## [/codeblock]

const GROUP_ARENA: String = "arena"

var input_proxy: SimInputProxy = SimInputProxy.new()
var runtime: Node = null
var config: SimConfig = null

var _initialized: bool = false
var _tick: int = 0


func _init() -> void:
	process_physics_priority = -100
	process_priority = -100


func _ready() -> void:
	_boot()


func _physics_process(delta: float) -> void:
	if not _initialized:
		_boot()
	if runtime == null or not runtime.is_active():
		return
	_tick += 1
	_bot_tick(delta)
	input_proxy.flush()


## Override this in your bot.
func _bot_tick(_delta: float) -> void:
	pass


## Optional hook called once when the bot is attached to a live simulation.
func _on_bot_ready() -> void:
	pass


func _boot() -> void:
	if _initialized:
		return
	_initialized = true
	runtime = get_node_or_null("/root/SimRuntime")
	if runtime != null:
		if runtime.has_method("get_config"):
			config = runtime.get_config() as SimConfig
		if runtime.has_method("bind_input_proxy"):
			runtime.bind_input_proxy(input_proxy)
	_on_bot_ready()


# --- queries ---------------------------------------------------------------

func is_simulating() -> bool:
	return runtime != null and runtime.is_active()


func get_target_node() -> Node2D:
	var group: String = config.player_group if config != null else "player"
	return get_first_in_group(group)


func get_first_in_group(group: String) -> Node2D:
	for node: Node in get_tree().get_nodes_in_group(group):
		if node is Node2D and is_instance_valid(node):
			return node as Node2D
	return null


func find_nearest_in_group(group: String, from: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist: float = INF
	for node: Node in get_tree().get_nodes_in_group(group):
		if not (node is Node2D) or not is_instance_valid(node):
			continue
		if node.has_method("is_alive") and not node.is_alive():
			continue
		var dist: float = from.distance_squared_to((node as Node2D).global_position)
		if dist < best_dist:
			best_dist = dist
			best = node as Node2D
	return best


func find_nearest_enemy(from: Vector2) -> Node2D:
	var group: String = config.enemy_group if config != null else "enemies"
	return find_nearest_in_group(group, from)


func find_enemies(radius: float, from: Vector2) -> Array[Node2D]:
	var result: Array[Node2D] = []
	var group: String = config.enemy_group if config != null else "enemies"
	var radius_sq: float = radius * radius
	for node: Node in get_tree().get_nodes_in_group(group):
		if not (node is Node2D) or not is_instance_valid(node):
			continue
		var enemy := node as Node2D
		if enemy.has_method("is_alive") and not enemy.is_alive():
			continue
		if from.distance_squared_to(enemy.global_position) <= radius_sq:
			result.append(enemy)
	return result


func get_arena() -> Node2D:
	return get_first_in_group(GROUP_ARENA)


func get_arena_rect() -> Rect2:
	if config != null:
		return Rect2(config.bounds_min, config.bounds_max - config.bounds_min)
	return Rect2(Vector2(-480.0, -300.0), Vector2(960.0, 600.0))


func sim_time() -> float:
	if runtime != null and runtime.has_method("get_sim_time"):
		return runtime.get_sim_time()
	return 0.0


func sim_rng() -> SimRNG:
	if runtime != null and runtime.has_method("get_rng"):
		return runtime.get_rng() as SimRNG
	return null


func tick_count() -> int:
	return _tick


# --- actions ---------------------------------------------------------------

func set_move_vector(direction: Vector2) -> void:
	var dir: Vector2 = direction.normalized() if direction.length_squared() > 0.000001 else Vector2.ZERO
	input_proxy.set_axis("move_left", "move_right", dir.x)
	input_proxy.set_axis("move_up", "move_down", dir.y)


func hold_action(action: String) -> void:
	input_proxy.hold_action(action)


func press_once(action: String) -> void:
	input_proxy.press_once(action)


func release_action(action: String) -> void:
	input_proxy.release_action(action)


func aim_at(world_pos: Vector2) -> void:
	input_proxy.set_aim_world_pos(world_pos)


func clear_aim() -> void:
	input_proxy.reset()


## Steer away from world bounds so simple bots rarely pin themselves to a wall.
func steer_away_from_bounds(position: Vector2, margin: float = 64.0, weight: float = 1.0) -> Vector2:
	var rect: Rect2 = get_arena_rect()
	var push: Vector2 = Vector2.ZERO
	if position.x < rect.position.x + margin:
		push.x += weight * (1.0 - (position.x - rect.position.x) / margin)
	elif position.x > rect.end.x - margin:
		push.x -= weight * (1.0 - (rect.end.x - position.x) / margin)
	if position.y < rect.position.y + margin:
		push.y += weight * (1.0 - (position.y - rect.position.y) / margin)
	elif position.y > rect.end.y - margin:
		push.y -= weight * (1.0 - (rect.end.y - position.y) / margin)
	return push
