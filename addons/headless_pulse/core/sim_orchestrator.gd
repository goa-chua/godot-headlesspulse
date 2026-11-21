class_name SimOrchestrator
extends RefCounted
## Multi-process campaign scheduler: N seeds split into batched worker processes.
##
## Used by both the CLI entry point (`cli/run_sim.gd`) and the editor dock, so the
## scheduling logic exists exactly once.
##
## Each worker is one Godot process that runs a *contiguous batch* of seeds
## sequentially (scene reload between runs). Batching is what keeps campaigns
## fast: engine start-up and the per-process worker-thread pool are paid once per
## batch instead of once per run, while still isolating every batch from the rest.
##
## Lifecycle: setup() -> start() -> poll() until status is not "running".

const STATUS_IDLE: String = "idle"
const STATUS_RUNNING: String = "running"
const STATUS_DONE: String = "done"
const STATUS_FAILED: String = "failed"

const RUN_SCHEMA: String = "headless_pulse/run/1"

var config: SimConfig = null
var status: String = STATUS_IDLE
var errors: PackedStringArray = PackedStringArray()

var _project_dir: String = ""
var _runs_dir: String = ""
var _jobs_pending: Array[Dictionary] = []
var _jobs_running: Array[Dictionary] = []
var _results: Array[Dictionary] = []
var _failed: Array[Dictionary] = []
var _total: int = 0
var _done: int = 0
var _max_workers: int = 1
var _batch_size: int = 1
var _start_usec: int = 0
var _spawn_usec: int = 0
var _wall_seconds: float = 0.0
var _baseline: Dictionary = {}
var _report_json: Dictionary = {}
var _report_markdown: String = ""
var _report_json_path: String = ""
var _report_md_path: String = ""


func setup(p_config: SimConfig, _opts: Dictionary) -> PackedStringArray:
	config = p_config
	errors = PackedStringArray()
	if config == null:
		errors.append("configuration is null")
		status = STATUS_FAILED
		return errors

	var project: String = ProjectSettings.globalize_path("res://").trim_suffix("/")
	if project.is_empty() or not DirAccess.dir_exists_absolute(project):
		errors.append("cannot resolve project directory")
	_project_dir = project
	_runs_dir = "%s/_runs" % config.resolved_output_dir()
	_max_workers = config.resolved_concurrency()
	_batch_size = config.resolved_batch_size()

	if not config.baseline_path.is_empty():
		var baseline: Dictionary = _read_json(config.baseline_path)
		if baseline.is_empty():
			errors.append("baseline report is not readable: %s" % config.baseline_path)
		else:
			_baseline = baseline

	status = STATUS_IDLE
	return errors


func start() -> PackedStringArray:
	errors = PackedStringArray()
	if config == null:
		errors.append("setup() was not called")
		status = STATUS_FAILED
		return errors
	if status == STATUS_RUNNING:
		errors.append("campaign already running")
		return errors

	_jobs_pending.clear()
	_jobs_running.clear()
	_results.clear()
	_failed.clear()
	_done = 0
	_total = 0
	_report_json = {}
	_report_markdown = ""

	# Chunk every repeat group into contiguous seed ranges; a worker runs its
	# whole range sequentially inside one process.
	for repeat_index: int in range(config.repeat):
		var offset: int = 0
		while offset < config.runs:
			var count: int = mini(_batch_size, config.runs - offset)
			var first_seed: int = config.seed + offset
			var job_id: String = "s%d_n%d" % [first_seed, count]
			if config.repeat > 1:
				job_id = "r%d_%s" % [repeat_index, job_id]
			_jobs_pending.append({
				"id": job_id,
				"seed": first_seed,
				"count": count,
				"repeat_index": repeat_index,
				"dir": "%s/%s" % [_runs_dir, job_id],
				"pid": -1,
				"started_usec": 0,
			})
			_total += count
			offset += count

	if _total <= 0:
		errors.append("no runs to execute")
		status = STATUS_FAILED
		return errors

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_runs_dir))
	_start_usec = Time.get_ticks_usec()
	status = STATUS_RUNNING
	return errors


## Advance the campaign: launch workers, reap finished ones, finalize when done.
## Returns the (possibly updated) status.
func poll() -> String:
	if status != STATUS_RUNNING:
		return status
	_launch_pending()
	_reap_finished()
	if _jobs_pending.is_empty() and _jobs_running.is_empty():
		_finalize()
	return status


func progress() -> Dictionary:
	var percent: float = float(_done) / float(_total) * 100.0 if _total > 0 else 0.0
	return {
		"done": _done,
		"total": _total,
		"running": _jobs_running.size(),
		"workers": _max_workers,
		"batch_size": _batch_size,
		"percent": snappedf(percent, 0.1),
		"elapsed_seconds": snappedf(float(Time.get_ticks_usec() - _start_usec) / 1000000.0, 0.01) if _start_usec > 0 else 0.0,
	}


func stop() -> void:
	for job: Dictionary in _jobs_running:
		var pid: int = int(job.get("pid", -1))
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
	_jobs_running.clear()
	_jobs_pending.clear()
	status = STATUS_FAILED
	errors.append("campaign stopped by user")


func get_report() -> Dictionary:
	return _report_json


func get_report_markdown() -> String:
	return _report_markdown


func report_paths() -> Dictionary:
	return {"json": _report_json_path, "markdown": _report_md_path}


func get_results() -> Array[Dictionary]:
	return _results


func get_failed() -> Array[Dictionary]:
	return _failed


# --- internals -------------------------------------------------------------

func _launch_pending() -> void:
	while _jobs_running.size() < _max_workers and not _jobs_pending.is_empty():
		var job: Dictionary = _jobs_pending.pop_front()
		_spawn(job)


func _spawn(job: Dictionary) -> void:
	_purge_dir(str(job["dir"]))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(str(job["dir"])))

	var args: PackedStringArray = _worker_args(job)
	var spawn_start: int = Time.get_ticks_usec()
	var pid: int = OS.create_process(OS.get_executable_path(), args)
	_spawn_usec += Time.get_ticks_usec() - spawn_start
	if pid <= 0:
		job["error"] = "failed to spawn worker process"
		job["exit_code"] = -1
		_failed.append(job)
		_done += int(job.get("count", 1))
		return
	job["pid"] = pid
	job["started_usec"] = Time.get_ticks_usec()
	_jobs_running.append(job)


func _worker_args(job: Dictionary) -> PackedStringArray:
	var args: PackedStringArray = PackedStringArray([
		"--headless",
		"--fixed-fps", "60",
		"--disable-render-loop",
		"--disable-vsync",
		"--quiet",
		"--path", _project_dir,
		config.scene_path,
		"--",
		"--sim-mode",
		"--sim-seed=%d" % int(job["seed"]),
		"--sim-batch=%d" % int(job["count"]),
		"--sim-tag=%s" % str(job["id"]),
		"--sim-out=%s" % str(job["dir"]),
		"--sim-scene=%s" % config.scene_path,
		"--sim-bot=%s" % config.bot_script_path,
		"--sim-max-time=%.6f" % config.max_sim_time,
		"--sim-grid=%dx%d" % [config.grid_cols, config.grid_rows],
		"--sim-bounds=%.4f,%.4f,%.4f,%.4f" % [
			config.bounds_min.x, config.bounds_min.y, config.bounds_max.x, config.bounds_max.y],
		"--sim-sample-interval=%.6f" % config.sample_interval,
		"--sim-stuck-window=%.6f" % config.stuck_window_seconds,
		"--sim-stuck-threshold=%.6f" % config.stuck_move_threshold,
		"--sim-player-group=%s" % config.player_group,
		"--sim-enemy-group=%s" % config.enemy_group,
	])
	if config.terminate_on_stuck:
		args.append("--sim-terminate-on-stuck=true")
	if config.verbose:
		args.append("--sim-verbose")
	for res_path: String in config.overrides.keys():
		var props: Dictionary = config.overrides[res_path]
		for prop: String in props.keys():
			args.append("--sim-set=%s|%s=%s" % [res_path, prop, var_to_str(props[prop])])
	return args


func _reap_finished() -> void:
	var now: int = Time.get_ticks_usec()
	for index: int in range(_jobs_running.size() - 1, -1, -1):
		var job: Dictionary = _jobs_running[index]
		var pid: int = int(job.get("pid", -1))
		var batch: int = int(job.get("count", 1))
		# A run is expected to take well under 60 s wall; keep a generous cap so a
		# hung worker cannot stall the campaign forever.
		var timeout: float = 120.0 + float(batch) * 60.0
		var alive: bool = pid > 0 and OS.is_process_running(pid)
		if alive:
			var elapsed: float = float(now - int(job.get("started_usec", now))) / 1000000.0
			if elapsed > timeout:
				OS.kill(pid)
				_jobs_running.remove_at(index)
				job["error"] = "worker timed out after %.0fs" % timeout
				_failed.append(job)
				_done += batch
			continue

		var exit_code: int = OS.get_process_exit_code(pid)
		_jobs_running.remove_at(index)
		_done += batch

		var results: Array[Dictionary] = _read_dir_results(str(job["dir"]))
		_results.append_array(results)
		if results.size() < batch:
			job["exit_code"] = exit_code
			job["received"] = results.size()
			job["expected"] = batch
			job["error"] = "worker returned %d/%d run results (check that 'godot --headless --import --path \"%s\"' succeeded)" % [
				results.size(), batch, _project_dir]
			_failed.append(job)


func _finalize() -> void:
	_wall_seconds = float(Time.get_ticks_usec() - _start_usec) / 1000000.0
	_results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var seed_a: int = int(a.get("seed", 0))
		var seed_b: int = int(b.get("seed", 0))
		if seed_a != seed_b:
			return seed_a < seed_b
		return str(a.get("run_id", "")) < str(b.get("run_id", "")))
	_report_json = ReportSynthesizer.build(config, _results, _wall_seconds, _baseline, _failed)
	# Report the *actually used* worker/batch layout (config.resolved_concurrency()
	# is only the concurrency cap; batching usually spawns fewer workers).
	_report_json["timing"]["batch_size"] = _batch_size
	_report_json["timing"]["workers"] = ceili(float(_total) / float(_batch_size)) if _batch_size > 0 else 1
	_report_markdown = ReportSynthesizer.render_markdown(_report_json)
	_write_reports()
	if config.verbose:
		print("[headless_pulse] timing: batch=%d workers=%d spawn_total=%.3fs wall=%.3fs"
				% [_batch_size, _max_workers, float(_spawn_usec) / 1000000.0, _wall_seconds])
	var ok: int = int(_report_json.get("campaign", {}).get("total_runs", 0))
	status = STATUS_DONE if ok > 0 else STATUS_FAILED


func _write_reports() -> void:
	_report_json_path = config.report_path("json")
	_report_md_path = config.report_path("md")
	var json_absolute: String = ProjectSettings.globalize_path(_report_json_path)
	var md_absolute: String = ProjectSettings.globalize_path(_report_md_path)
	DirAccess.make_dir_recursive_absolute(json_absolute.get_base_dir())

	var json_file: FileAccess = FileAccess.open(json_absolute, FileAccess.WRITE)
	if json_file != null:
		json_file.store_string(JSON.stringify(_report_json, "  ", true, true))
		json_file.close()
	else:
		errors.append("cannot write %s" % _report_json_path)

	var md_file: FileAccess = FileAccess.open(md_absolute, FileAccess.WRITE)
	if md_file != null:
		md_file.store_string(_report_markdown)
		md_file.close()
	else:
		errors.append("cannot write %s" % _report_md_path)


static func _purge_dir(res_dir: String) -> void:
	var absolute: String = ProjectSettings.globalize_path(res_dir)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir():
			dir.remove(name)
		name = dir.get_next()
	dir.list_dir_end()


static func _read_dir_results(res_dir: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var absolute: String = ProjectSettings.globalize_path(res_dir)
	if not DirAccess.dir_exists_absolute(absolute):
		return results
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		return results
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.ends_with(".json"):
			var data: Dictionary = _read_json("%s/%s" % [res_dir.rstrip("/"), name])
			if str(data.get("schema", "")) == RUN_SCHEMA:
				results.append(data)
		name = dir.get_next()
	dir.list_dir_end()
	return results


static func _read_json(path: String) -> Dictionary:
	var absolute: String = ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	if not FileAccess.file_exists(absolute):
		return {}
	var file: FileAccess = FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}
