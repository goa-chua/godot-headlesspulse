class_name KitingShooterBot
extends SimBotBase
## Reference heuristic bot: kite the nearest enemy, strafe in the comfort band,
## switch to the shotgun at close range, and keep firing.
##
## It is intentionally cheap (no pathfinding, no lookahead) - the goal is to
## exercise game logic, not to play well.

const KITE_RADIUS: float = 170.0
const COMFORT_RADIUS: float = 260.0
const SHOTGUN_RADIUS: float = 130.0

var _strafe_timer: float = 0.0
var _strafe_sign: float = 1.0
var _weapon_index: int = 0


func _bot_tick(delta: float) -> void:
	var player: Node2D = get_target_node()
	if player == null:
		return

	var nearest: Node2D = find_nearest_enemy(player.global_position)
	if nearest == null:
		var center: Vector2 = get_arena_rect().get_center()
		set_move_vector((center - player.global_position).normalized())
		return

	var to_enemy: Vector2 = nearest.global_position - player.global_position
	var distance: float = to_enemy.length()
	var dir: Vector2 = Vector2.ZERO

	if distance < KITE_RADIUS:
		dir = -to_enemy.normalized()
	elif distance > COMFORT_RADIUS:
		dir = to_enemy.normalized()
	else:
		_strafe_timer -= delta
		if _strafe_timer <= 0.0:
			_strafe_sign *= -1.0
			_strafe_timer = 1.2
		var tangent := Vector2(-to_enemy.normalized().y, to_enemy.normalized().x)
		dir = tangent * _strafe_sign

	dir += steer_away_from_bounds(player.global_position, 80.0, 1.6)
	for enemy: Node2D in find_enemies(90.0, player.global_position):
		var away: Vector2 = player.global_position - enemy.global_position
		if away.length_squared() > 0.0001:
			dir += away.normalized() * 0.8

	# Never stand perfectly still (that would look like a stuck run to telemetry
	# and makes the bot trivially easy to surround).
	if dir.length_squared() < 0.04:
		dir = Vector2(cos(sim_time() * 0.7), sin(sim_time() * 0.7))

	set_move_vector(dir)
	aim_at(nearest.global_position)
	hold_action("fire")

	var want: int = 1 if distance < SHOTGUN_RADIUS else 0
	if want != _weapon_index:
		_weapon_index = want
		press_once("weapon_%d" % (want + 1))
