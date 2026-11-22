extends SceneTree
## Standalone CLI entry point for a whole campaign.
##
## Run it from a shell (script mode does not load autoloads, which is why this
## file only uses preloaded classes):
##
## [codeblock]
## godot --headless -s res://addons/headless_pulse/cli/run_sim.gd -- \
##     --sim-mode --sim-runs=50 --sim-jobs=12 --sim-seed=1000 \
##     --sim-max-time=60 --sim-out=res://reports
## [/codeblock]
##
## The workers themselves run the game scene normally, so they obey the same
## determinism rules as a single run. Exit code: 0 = campaign produced results,
## 1 = campaign failed, 2 = bad arguments, 3 = worker start failure,
## 4 = regression gate failed (`--sim-fail-on-regression`).
##
## Pass `--sim-help` after `--` to print the full option list.

var _orchestrator: SimOrchestrator = null
var _config: SimConfig = null
var _last_printed_step: int = -1
var _finished: bool = false


func _initialize() -> void:
	var opts: Dictionary = SimConfig.parse_args(OS.get_cmdline_user_args())
	if opts.has("sim-help"):
		print(SimConfig.help_text())
		quit(0)
		return
	if not opts.has("sim-mode"):
		printerr("[headless_pulse] missing --sim-mode; pass it after '--' (see --sim-help)")
		quit(2)
		return
	for unknown: String in SimConfig.unknown_options(opts):
		printerr("[headless_pulse] warning: unknown option %s (see --sim-help)" % unknown)

	_config = SimConfig.from_opts(opts)
	if _config == null:
		printerr("[headless_pulse] invalid configuration (see errors above)")
		quit(2)
		return

	if opts.has("sim-dry-run"):
		_print_plan(_config)
		quit(0)
		return

	_orchestrator = SimOrchestrator.new()
	var setup_errors: PackedStringArray = _orchestrator.setup(_config, opts)
	if not setup_errors.is_empty():
		for message: String in setup_errors:
			printerr("[headless_pulse] %s" % message)
		quit(2)
		return

	var start_errors: PackedStringArray = _orchestrator.start()
	if not start_errors.is_empty():
		for message: String in start_errors:
			printerr("[headless_pulse] %s" % message)
		quit(3)
		return

	print("[headless_pulse] campaign started: scene=%s" % _config.scene_path)
	print("[headless_pulse] runs=%d repeat=%d workers=%d batch=%d seed=%d..%d max_sim_time=%.0fs"
			% [_config.runs, _config.repeat, _config.resolved_concurrency(),
			_config.resolved_batch_size(), _config.seed,
			_config.seed + _config.runs - 1, _config.max_sim_time])


func _print_plan(config: SimConfig) -> void:
	print("[headless_pulse] dry run: no simulation executed")
	print("[headless_pulse]   scene    : %s" % config.scene_path)
	print("[headless_pulse]   bot      : %s" % config.bot_script_path)
	print("[headless_pulse]   runs=%d repeat=%d seed=%d..%d workers=%d batch=%d max_sim_time=%.1fs"
			% [config.runs, config.repeat, config.seed, config.seed + config.runs - 1,
			config.resolved_concurrency(), config.resolved_batch_size(), config.max_sim_time])
	print("[headless_pulse]   output   : %s/%s.{json,md}" % [
			config.resolved_output_dir(), config.report_name])
	print("[headless_pulse]   telemetry: grid=%dx%d sample_interval=%.2fs stuck_window=%.2fs"
			% [config.grid_cols, config.grid_rows, config.sample_interval,
			config.stuck_window_seconds])
	print("[headless_pulse]   baseline : %s" % (
			"(none)" if config.baseline_path.is_empty() else config.baseline_path))
	print("[headless_pulse]   gate     : %s (win drop %.2f, survival drop %.1fs, new critical=%s)"
			% ["on" if config.fail_on_regression else "off", config.gate_max_win_drop,
			config.gate_max_survival_drop, str(config.gate_fail_on_new_critical)])
	if not config.overrides.is_empty():
		print("[headless_pulse]   overrides: %d resource(s)" % config.overrides.size())


func _process(_delta: float) -> bool:
	if _orchestrator == null:
		return true
	var state: String = _orchestrator.poll()

	if state == SimOrchestrator.STATUS_RUNNING:
		var progress: Dictionary = _orchestrator.progress()
		var step: int = int(progress.get("done", 0) / 10) * 10
		if step != _last_printed_step:
			_last_printed_step = step
			print("[headless_pulse] progress %d/%d runs (%.0f%%) elapsed=%.2fs"
					% [int(progress.get("done", 0)), int(progress.get("total", 0)),
					float(progress.get("percent", 0.0)), float(progress.get("elapsed_seconds", 0.0))])
		OS.delay_msec(2)
		return false

	if not _finished:
		_finished = true
		_finish(state)
	return true


func _finish(state: String) -> void:
	var report: Dictionary = _orchestrator.get_report()
	var paths: Dictionary = _orchestrator.report_paths()
	var failed: Array[Dictionary] = _orchestrator.get_failed()
	for job: Dictionary in failed:
		printerr("[headless_pulse] worker failed: %s (%s)" % [str(job.get("id", "?")), str(job.get("error", "unknown"))])

	if report.is_empty():
		printerr("[headless_pulse] campaign failed, no report generated")
		quit(1)
		return

	var campaign: Dictionary = report.get("campaign", {})
	var timing: Dictionary = report.get("timing", {})
	print("[headless_pulse] campaign done: runs=%d failed=%d wall=%.2fs speedup=%.0fx win_rate=%.1f%% stuck_rate=%.1f%%"
			% [int(campaign.get("total_runs", 0)), int(campaign.get("failed_runs", 0)),
			float(timing.get("wall_seconds", 0.0)), float(timing.get("speedup", 0.0)),
			float(report.get("win_rate", 0.0)) * 100.0, float(report.get("stuck_rate", 0.0)) * 100.0])
	print("[headless_pulse] report: %s" % str(paths.get("markdown", "")))
	print("[headless_pulse] report: %s" % str(paths.get("json", "")))

	var exit_code: int = 0 if state == SimOrchestrator.STATUS_DONE else 1
	if _config != null and _config.fail_on_regression:
		var gate: Dictionary = ReportSynthesizer.evaluate_regression_gate(
				report, _config.gate_max_win_drop, _config.gate_max_survival_drop,
				_config.gate_fail_on_new_critical)
		for check: Dictionary in gate.get("checks", []):
			print("[headless_pulse] gate %s: %-24s %s" % [
					"PASS" if bool(check.get("passed", false)) else "FAIL",
					str(check.get("name", "")), str(check.get("detail", ""))])
		if bool(gate.get("passed", false)):
			print("[headless_pulse] regression gate passed")
		else:
			printerr("[headless_pulse] regression gate FAILED (exit 4)")
			exit_code = 4
	quit(exit_code)
