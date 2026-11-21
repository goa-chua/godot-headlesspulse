class_name WallPusherBot
extends SimBotBase
## Acceptance-test bot for stuck detection: walk into the U-shaped trap of the
## demo arena and keep pushing against the back wall, so StuckDetector must
## report a hotspot.
##
## The target is *inside* the wall on purpose: a bot that merely walks to a point
## and hovers is not "stuck" (it still travels a little), while one that presses
## into geometry travels ~0 units and is.
##
## Usage:
##   --sim-bot=res://addons/headless_pulse/examples/bots/wall_pusher_bot.gd
##   --sim-max-time=12 --sim-terminate-on-stuck

var _target: Vector2 = Vector2(-340.0, 40.0)


func _bot_tick(_delta: float) -> void:
	var player: Node2D = get_target_node()
	if player == null:
		return

	var to_target: Vector2 = _target - player.global_position
	set_move_vector(to_target)

	# Still shoot back so the run is a realistic session, not a freeze-frame.
	var nearest: Node2D = find_nearest_enemy(player.global_position)
	if nearest != null:
		aim_at(nearest.global_position)
		hold_action("fire")
