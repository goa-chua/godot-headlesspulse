class_name SimInputProxy
extends RefCounted
## Virtual input device used by bots.
##
## It writes into the real `Input` singleton so the game under test does not need
## any knowledge of the simulation, and it exposes a virtual aim position because
## a headless project has no OS mouse to warp.
##
## Held actions are re-applied every tick and released as soon as the bot stops
## holding them, so no input state can leak between runs.

var _held: Dictionary = {}
var _once: Dictionary = {}
var _applied_last: Dictionary = {}
var _aim_world: Vector2 = Vector2.ZERO
var _has_aim: bool = false
var _mouse_screen: Vector2 = Vector2.ZERO
var _missing_actions: Dictionary = {}


func set_axis(negative_action: String, positive_action: String, value: float) -> void:
	var clamped: float = clampf(value, -1.0, 1.0)
	_set_held(positive_action, maxf(clamped, 0.0))
	_set_held(negative_action, maxf(-clamped, 0.0))


func hold_action(action: String, strength: float = 1.0) -> void:
	_set_held(action, clampf(strength, 0.0, 1.0))


func release_action(action: String) -> void:
	_held.erase(action)
	_once.erase(action)


func press_once(action: String) -> void:
	_once[action] = true


func set_aim_world_pos(world_pos: Vector2) -> void:
	_aim_world = world_pos
	_has_aim = true


func set_mouse_screen_pos(screen_pos: Vector2) -> void:
	_mouse_screen = screen_pos


func get_mouse_screen_pos() -> Vector2:
	return _mouse_screen


func get_aim_world_pos() -> Vector2:
	return _aim_world


func has_aim() -> bool:
	return _has_aim


## Push the accumulated virtual input into the engine Input singleton.
## Must be called at the end of the bot tick, before gameplay nodes read input.
func flush() -> void:
	for action: String in _applied_last.keys():
		if not _held.has(action) and not _once.has(action):
			Input.action_release(action)

	for action: String in _held.keys():
		_ensure_action(action)
		Input.action_press(action, float(_held[action]))

	for action: String in _once.keys():
		_ensure_action(action)
		Input.action_press(action, 1.0)

	_applied_last = _held.duplicate()
	for action: String in _once.keys():
		_applied_last[action] = true
	_once.clear()


## Release everything; used when a run ends or the bot is disabled.
func reset() -> void:
	for action: String in _applied_last.keys():
		Input.action_release(action)
	_held.clear()
	_once.clear()
	_applied_last.clear()
	_has_aim = false


func get_action_strength(action: String) -> float:
	return float(_held.get(action, 1.0 if _once.has(action) else 0.0))


## Names of every action currently driven by this proxy (for diagnostics).
func active_actions() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for action: String in _held.keys():
		names.append(action)
	for action: String in _once.keys():
		if not names.has(action):
			names.append(action)
	return names


func _set_held(action: String, strength: float) -> void:
	if strength <= 0.0:
		_held.erase(action)
	else:
		_held[action] = strength


func _ensure_action(action: String) -> void:
	if InputMap.has_action(action):
		return
	if _missing_actions.has(action):
		return
	_missing_actions[action] = true
	push_error("[headless_pulse] InputMap action '%s' does not exist; injected input is ignored. "
			% action + "Add it in Project Settings > Input Map or register it at startup.")
