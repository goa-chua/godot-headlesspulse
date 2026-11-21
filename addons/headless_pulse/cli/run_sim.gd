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
## 1 = campaign failed, 2 = bad arguments.

var _orchestrator: SimOrchestrator = null
var _last_printed_step: int = -1
var _finished: bool = false


func _initialize() -> void:
	var opts: Dictionary = SimConfig.parse_args(OS.get_cmdline_user_args())
	if not opts.has("sim-mode"):
		printerr("[headless_pulse] missing --sim-mode; pass it after '--'")
		quit(2)
		return

	var config: SimConfig = SimConfig.from_opts(opts)
	if config == null:
		printerr("[headless_pulse] invalid configuration (see errors above)")
		quit(2)
		return

	_orchestrator = SimOrchestrator.new()
	var setup_errors: PackedStringArray = _orchestrator.setup(config, opts)
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

	print("[headless_pulse] campaign started: scene=%s" % config.scene_path)
	print("[headless_pulse] runs=%d repeat=%d workers=%d batch=%d seed=%d..%d max_sim_time=%.0fs"
			% [config.runs, config.repeat, config.resolved_concurrency(),
			config.resolved_batch_size(), config.seed,
			config.seed + config.runs - 1, config.max_sim_time])


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
	quit(0 if state == SimOrchestrator.STATUS_DONE else 1)
