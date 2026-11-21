@tool
extends VBoxContainer
## Godot HeadlessPulse dock: configure a campaign, run it concurrently, preview the
## ASCII report, copy it for an AI agent, or replay one seed at 1x.

const SIM_CONFIG_SCRIPT: Script = preload("res://addons/headless_pulse/core/sim_config.gd")
const SIM_ORCHESTRATOR_SCRIPT: Script = preload("res://addons/headless_pulse/core/sim_orchestrator.gd")

var _config_path: LineEdit
var _seed: SpinBox
var _runs: SpinBox
var _workers: SpinBox
var _max_time: SpinBox
var _determinism: CheckBox
var _run_button: Button
var _stop_button: Button
var _progress: ProgressBar
var _status: Label
var _report_view: TextEdit
var _copy_button: Button
var _replay_button: Button
var _open_button: Button

var _orchestrator: RefCounted = null
var _last_markdown: String = ""
var _last_seed: int = 0
var _last_report_markdown_path: String = ""


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	name = "Godot HeadlessPulse"
	custom_minimum_size = Vector2(430.0, 620.0)
	set_process(false)
	_build_ui()


func _process(_delta: float) -> void:
	if _orchestrator == null:
		set_process(false)
		return
	var state: String = _orchestrator.poll()
	var progress: Dictionary = _orchestrator.progress()
	_progress.value = float(progress.get("percent", 0.0))
	_status.text = "%d/%d runs (%.1fs elapsed)" % [
		int(progress.get("done", 0)), int(progress.get("total", 0)),
		float(progress.get("elapsed_seconds", 0.0)),
	]
	if state != SimOrchestrator.STATUS_RUNNING:
		_finish_campaign(state)


# --- UI --------------------------------------------------------------------

func _build_ui() -> void:
	var title := Label.new()
	title.text = "Godot HeadlessPulse - headless balance telemetry"
	title.add_theme_font_size_override("font_size", 16)
	add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(grid)

	grid.add_child(_make_label("SimConfig"))
	_config_path = LineEdit.new()
	_config_path.text = "res://sim_configs/arena_2d.tres"
	_config_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_config_path)

	grid.add_child(_make_label("Start seed"))
	_seed = _make_spin(0, 10000000, 1000)
	grid.add_child(_seed)

	grid.add_child(_make_label("Runs"))
	_runs = _make_spin(1, 1000, 50)
	grid.add_child(_runs)

	grid.add_child(_make_label("Workers (0=auto)"))
	_workers = _make_spin(0, 64, 0)
	grid.add_child(_workers)

	grid.add_child(_make_label("Max sim seconds"))
	_max_time = _make_spin(1, 600, 60)
	grid.add_child(_max_time)

	grid.add_child(_make_label("Determinism check"))
	_determinism = CheckBox.new()
	_determinism.button_pressed = false
	grid.add_child(_determinism)

	var buttons := HBoxContainer.new()
	add_child(buttons)
	_run_button = Button.new()
	_run_button.text = "Run campaign"
	_run_button.pressed.connect(_on_run_pressed)
	buttons.add_child(_run_button)
	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.disabled = true
	_stop_button.pressed.connect(_on_stop_pressed)
	buttons.add_child(_stop_button)

	_progress = ProgressBar.new()
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.max_value = 100.0
	add_child(_progress)

	_status = Label.new()
	_status.text = "idle"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	_report_view = TextEdit.new()
	_report_view.editable = false
	_report_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_report_view.custom_minimum_size = Vector2(0.0, 300.0)
	add_child(_report_view)

	var actions := HBoxContainer.new()
	add_child(actions)
	_copy_button = Button.new()
	_copy_button.text = "Copy report for AI agent"
	_copy_button.disabled = true
	_copy_button.pressed.connect(_on_copy_pressed)
	actions.add_child(_copy_button)
	_replay_button = Button.new()
	_replay_button.text = "Replay seed (1x)"
	_replay_button.disabled = true
	_replay_button.pressed.connect(_on_replay_pressed)
	actions.add_child(_replay_button)
	_open_button = Button.new()
	_open_button.text = "Open report folder"
	_open_button.disabled = true
	_open_button.pressed.connect(_on_open_pressed)
	actions.add_child(_open_button)


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _make_spin(minimum: int, maximum: int, value: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = float(minimum)
	spin.max_value = float(maximum)
	spin.value = float(value)
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin


# --- actions ---------------------------------------------------------------

func _on_run_pressed() -> void:
	var config := _build_config()
	if config == null:
		return
	var errors: PackedStringArray = config.validate()
	if not errors.is_empty():
		_report_view.text = "Cannot run:\n- %s" % "\n- ".join(errors)
		return

	_orchestrator = SIM_ORCHESTRATOR_SCRIPT.new() as RefCounted
	var setup_errors: PackedStringArray = _orchestrator.setup(config, {})
	if not setup_errors.is_empty():
		_report_view.text = "Setup failed:\n- %s" % "\n- ".join(setup_errors)
		_orchestrator = null
		return
	var start_errors: PackedStringArray = _orchestrator.start()
	if not start_errors.is_empty():
		_report_view.text = "Start failed:\n- %s" % "\n- ".join(start_errors)
		_orchestrator = null
		return

	_last_seed = config.seed
	_run_button.disabled = true
	_stop_button.disabled = false
	_copy_button.disabled = true
	_replay_button.disabled = true
	_open_button.disabled = true
	_status.text = "starting %d workers..." % config.resolved_concurrency()
	set_process(true)


func _on_stop_pressed() -> void:
	if _orchestrator != null:
		_orchestrator.stop()
		_status.text = "stopped"


func _finish_campaign(state: String) -> void:
	_run_button.disabled = false
	_stop_button.disabled = true
	if state != SimOrchestrator.STATUS_DONE:
		_status.text = "campaign failed - see report view"
		_report_view.text = "\n".join(_orchestrator.errors)
		_orchestrator = null
		set_process(false)
		return

	var report: Dictionary = _orchestrator.get_report()
	var paths: Dictionary = _orchestrator.report_paths()
	_last_markdown = _orchestrator.get_report_markdown()
	_last_report_markdown_path = str(paths.get("markdown", ""))
	_report_view.text = _last_markdown
	var timing: Dictionary = report.get("timing", {})
	_status.text = "done: %d runs in %.2fs (%.0fx) | win %.1f%% | stuck %.1f%%" % [
		int(report.get("campaign", {}).get("total_runs", 0)),
		float(timing.get("wall_seconds", 0.0)),
		float(timing.get("speedup", 0.0)),
		float(report.get("win_rate", 0.0)) * 100.0,
		float(report.get("stuck_rate", 0.0)) * 100.0,
	]
	_copy_button.disabled = false
	_replay_button.disabled = false
	_open_button.disabled = false
	_orchestrator = null
	set_process(false)


func _on_copy_pressed() -> void:
	if _last_markdown.is_empty():
		return
	DisplayServer.clipboard_set(_last_markdown)
	_status.text = "report copied to clipboard (%d bytes)" % _last_markdown.length()


func _on_replay_pressed() -> void:
	var config := _build_config()
	if config == null:
		return
	var project_dir: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	var args: PackedStringArray = PackedStringArray([
		"--path", project_dir,
		config.scene_path,
		"--",
		"--sim-mode",
		"--sim-replay",
		"--sim-seed=%d" % _last_seed,
		"--sim-bot=%s" % config.bot_script_path,
		"--sim-max-time=%.1f" % config.max_sim_time,
		"--sim-tag=replay_seed%d" % _last_seed,
	])
	OS.create_process(OS.get_executable_path(), args)
	_status.text = "replaying seed %d at 1x in a new window" % _last_seed


func _on_open_pressed() -> void:
	var config := _build_config()
	if config == null:
		return
	var directory: String = ProjectSettings.globalize_path(config.resolved_output_dir())
	OS.shell_open(directory)


func _build_config() -> RefCounted:
	var config: RefCounted = SIM_CONFIG_SCRIPT.new()
	var path: String = _config_path.text.strip_edges()
	if not path.is_empty():
		if not ResourceLoader.exists(path):
			_report_view.text = "SimConfig not found: %s" % path
			return null
		var resource: Resource = load(path)
		if not (resource is SimConfig):
			_report_view.text = "Not a SimConfig resource: %s" % path
			return null
		config = (resource as SimConfig).duplicate(true)

	config.seed = int(_seed.value)
	config.runs = int(_runs.value)
	config.max_concurrency = int(_workers.value)
	config.max_sim_time = _max_time.value
	if _determinism.button_pressed:
		config.repeat = 2
		config.determinism_check = true
	return config
