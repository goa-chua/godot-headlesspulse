@tool
extends EditorPlugin
## Editor entry point: registers the Godot HeadlessPulse dock.
##
## The addon is fully usable without the editor (CLI + CI), this is only the
## convenience UI for humans.

const SIM_DOCK_SCRIPT: Script = preload("res://addons/headless_pulse/ui/sim_dock.gd")

var _dock: Control = null


func _enter_tree() -> void:
	_dock = SIM_DOCK_SCRIPT.new() as Control
	if _dock == null:
		push_error("[headless_pulse] failed to create the simulation dock")
		return
	_dock.name = "Godot HeadlessPulse"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
