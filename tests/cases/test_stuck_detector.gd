extends HpTestCase
## StuckDetector: edge-triggered wall-push detection, no false positives.

const DT: float = 1.0 / 60.0


func run() -> void:
	# Fast movement never triggers.
	var moving := StuckDetector.new(3.0, 6.0)
	var time: float = 0.0
	var position := Vector2.ZERO
	var fired_while_moving: bool = false
	for i: int in range(300):
		time += DT
		position.x += 5.0 * DT
		if moving.tick(time, position, 1.0):
			fired_while_moving = true
	assert_false(fired_while_moving, "moving entity is never stuck")
	assert_eq(moving.count(), 0, "no events while moving")

	# Pushing a wall fires exactly one edge-triggered event per episode.
	var pushing := StuckDetector.new(3.0, 6.0)
	time = 0.0
	position = Vector2(100.0, 0.0)
	var events: int = 0
	for i: int in range(300):
		time += DT
		if pushing.tick(time, position, 1.0):
			events += 1
	assert_eq(events, 1, "one event per stuck episode")
	assert_eq(pushing.count(), 1, "event recorded")
	assert_true(pushing.is_stuck(), "detector is stuck")
	var event: Dictionary = pushing.events[0]
	assert_almost_eq(float(event["pos"][0]), 100.0, 0.0001, "event position x")
	assert_almost_eq(float(event["time"]), 3.0, 0.15, "event fires after roughly one window")
	assert_almost_eq(float(event["traveled"]), 0.0, 0.0001, "no path travelled")

	# Escaping clears the state, so a second episode fires again.
	time += DT
	pushing.tick(time, position + Vector2(50.0, 0.0), 1.0)
	assert_false(pushing.is_stuck(), "unstuck after escaping the wall")
	for i: int in range(300):
		time += DT
		pushing.tick(time, position + Vector2(50.0, 0.0), 1.0)
	assert_eq(pushing.count(), 2, "second episode is counted")

	# Idle entities (no movement intent) are not "stuck".
	var idle := StuckDetector.new(3.0, 6.0)
	time = 0.0
	for i: int in range(300):
		time += DT
		idle.tick(time, Vector2.ZERO, 0.0)
	assert_eq(idle.count(), 0, "idle is not stuck")

	# clear() resets history and state.
	pushing.clear()
	assert_eq(pushing.count(), 0, "clear removes events")
	assert_false(pushing.is_stuck(), "clear resets stuck state")
