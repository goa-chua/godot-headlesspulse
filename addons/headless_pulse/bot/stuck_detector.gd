class_name StuckDetector
extends RefCounted
## Sliding-window movement detector based on **path length**, not net
## displacement.
##
## A kiting bot circles back to roughly its starting point every few seconds, so
## net displacement false-positives; summing per-tick movement does not. A run is
## "stuck" when the entity is *trying to move* (intent above MIN_INTENT) but has
## traveled less than `move_threshold` world units during the last
## `window_seconds` simulated seconds - i.e. it is pushing against geometry.
##
## Detection is edge-triggered: one event per stuck episode, and a new event can
## only fire after the entity got unstuck.

const MIN_INTENT: float = 0.25

var window_seconds: float = 3.0
var move_threshold: float = 6.0
var events: Array[Dictionary] = []

var _samples: Array[Dictionary] = []
var _is_stuck: bool = false
var _path_length: float = 0.0
var _intent_sum: float = 0.0


func _init(p_window_seconds: float = 3.0, p_move_threshold: float = 6.0) -> void:
	window_seconds = p_window_seconds
	move_threshold = p_move_threshold


## Advance the detector by one simulated tick.
## `intent` is the normalized movement request (0 = idle, 1 = full input).
## Returns true on a new stuck event.
func tick(sim_time: float, position: Vector2, intent: float = 1.0) -> bool:
	if not _samples.is_empty():
		var previous: Dictionary = _samples[_samples.size() - 1]
		_path_length += position.distance_to(previous["p"] as Vector2)
	var clamped_intent: float = clampf(intent, 0.0, 1.0)
	_intent_sum += clamped_intent
	_samples.append({
		"t": sim_time,
		"p": position,
		"i": clamped_intent,
		"d": _path_length,
	})

	# Drop samples older than the window, but keep at least two.
	while _samples.size() > 2 and sim_time - float(_samples[0]["t"]) > window_seconds:
		_intent_sum -= float(_samples[0]["i"])
		_samples.pop_front()

	var oldest: Dictionary = _samples[0]
	var window_covered: bool = sim_time - float(oldest["t"]) >= window_seconds - 0.0001
	var traveled: float = _path_length - float(oldest["d"])
	var average_intent: float = _intent_sum / float(_samples.size())

	if _is_stuck:
		if traveled > move_threshold * 2.0 or average_intent < MIN_INTENT * 0.5:
			_is_stuck = false
		return false

	if window_covered and traveled < move_threshold and average_intent >= MIN_INTENT:
		_is_stuck = true
		events.append({
			"pos": [position.x, position.y],
			"time": sim_time,
			"traveled": traveled,
			"window": window_seconds,
			"intent": average_intent,
		})
		return true
	return false


func is_stuck() -> bool:
	return _is_stuck


func count() -> int:
	return events.size()


func clear() -> void:
	_samples.clear()
	events.clear()
	_is_stuck = false
	_path_length = 0.0
	_intent_sum = 0.0
