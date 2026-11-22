extends SceneTree
## Single-source acceptance checks for Godot HeadlessPulse.
##
## The platform scripts are only thin launchers:
##
##   bash tools/verify.sh /path/to/godot
##   powershell -NoProfile -File tools/verify.ps1 -Godot C:\path\to\godot.exe
##
## Both end up here, so Linux, macOS, Git Bash and Windows run exactly the same
## check code (no duplicated shell/PowerShell logic):
##
##   godot --headless --path . -s res://tools/verify_checks.gd -- [--budget=<seconds>]
##
## `--budget` is the allowed wall time for the 50-run campaign (default 5 s locally,
## CI passes CAMPAIGN_BUDGET=120). Exit code 0 = all checks passed, 1 = failure.

const OUT_DIR: String = "res://reports/_verify"
const CAMPAIGN_SCRIPT: String = "res://addons/headless_pulse/cli/run_sim.gd"
const SCENE: String = "res://addons/headless_pulse/examples/arena_2d/arena.tscn"
const STUCK_CONFIG: String = "res://sim_configs/stuck_test.tres"
const SMG: String = "res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres"
const BATCH_FLAGS: Array = ["--fixed-fps", "60", "--disable-render-loop", "--disable-vsync"]

var _godot: String = ""
var _root: String = ""
var _budget: float = 5.0
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_godot = OS.get_executable_path()
	_root = ProjectSettings.globalize_path("res://").trim_suffix("/")
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--budget="):
			_budget = float(arg.trim_prefix("--budget="))
	_reset_out_dir()

	var version: Dictionary = _run("version", PackedStringArray(["--version"]))
	print("HeadlessPulse verification")
	print("  project : %s" % _root)
	print("  godot   : %s" % _godot)
	print("  engine  : %s" % _first_line(str(version["text"])))
	print("  system  : %s / %d cores / campaign budget %ds" % [
			OS.get_name(), OS.get_processor_count(), int(_budget)])
	print("")

	_check_import()
	_check_unit_tests()
	_check_project_settings()
	_check_uncovered_scripts()
	_check_editor_plugin()
	_check_determinism()
	_check_batch_independence()
	_check_timeseries_cap()
	var stuck_campaign: Dictionary = _check_stuck_detection()
	_check_anomalies(stuck_campaign)
	var campaign: Dictionary = _check_campaign()
	_check_regression_gate()
	_check_repeat_determinism()

	print("")
	if _failures == 0:
		print("ALL CHECKS PASSED (%d checks)" % _checks)
		quit(0)
		return
	print("%d/%d CHECK(S) FAILED - logs in reports/_verify" % [_failures, _checks])
	quit(1)


# --- checks ---------------------------------------------------------------

func _check_import() -> void:
	var result: Dictionary = _run("import", PackedStringArray(["--import", "--path", _root]))
	_check("import project", int(result["exit"]) == 0, "exit=%d" % int(result["exit"]), result)


func _check_unit_tests() -> void:
	var result: Dictionary = _run("unit_tests", PackedStringArray([
		"--path", _root, "-s", "res://tests/run_tests.gd"]))
	var text: String = str(result["text"])
	var summary: String = _line_starting_with(text, "unit tests:")
	if summary.is_empty():
		summary = _first_line_starting_with(text, "[FAIL]")
	_check("unit tests", int(result["exit"]) == 0, summary, result)


func _check_project_settings() -> void:
	var project: String = _read_text("res://project.godot")
	var thread_pool_ok: bool = project.contains("worker_pool/max_threads=1")
	var plugin_ok: bool = project.contains("headless_pulse/plugin.cfg")
	_check("project settings invariants", thread_pool_ok and plugin_ok,
			"worker_pool/max_threads=1=%s editor_plugin=%s" % [thread_pool_ok, plugin_ok])


func _check_uncovered_scripts() -> void:
	var scripts: Array = [
		"res://addons/headless_pulse/plugin.gd",
		"res://addons/headless_pulse/ui/sim_dock.gd",
	]
	var failed: int = 0
	var detail: String = "plugin.gd + sim_dock.gd parse cleanly"
	var last: Dictionary = {}
	for script_path: String in scripts:
		var name: String = "parse_" + script_path.get_file().get_basename()
		last = _run(name, PackedStringArray([
			"--check-only", "--path", _root, "--script", script_path]))
		if int(last["exit"]) != 0:
			failed += 1
			detail = "failed: %s" % script_path
	_check("uncovered script parse", failed == 0, detail, last)


func _check_editor_plugin() -> void:
	var result: Dictionary = _run("editor_load", PackedStringArray([
		"--editor", "--quit", "--path", _root]))
	var text: String = str(result["text"])
	var script_error: bool = text.contains("SCRIPT ERROR") or text.contains("Failed to load script")
	var detail: String = "exit=%d script_errors=%s" % [int(result["exit"]), script_error]
	_check("editor plugin load", int(result["exit"]) == 0 and not script_error, detail, result)


func _check_determinism() -> void:
	var run_a: Dictionary = _run("det_a", _single_run_args(4242, "res://reports/_verify/det_a.json"))
	var run_b: Dictionary = _run("det_b", _single_run_args(4242, "res://reports/_verify/det_b.json"))
	var a: Dictionary = _read_json("res://reports/_verify/det_a.json")
	var b: Dictionary = _read_json("res://reports/_verify/det_b.json")
	if a.is_empty() or b.is_empty():
		_check("determinism (same seed)", false, "run result missing", run_a if a.is_empty() else run_b)
		return
	var digest_a: String = _str_at(a, ["determinism", "digest"])
	var digest_b: String = _str_at(b, ["determinism", "digest"])
	var pos_a: String = _str_at(a, ["player", "final_pos_str"])
	var pos_b: String = _str_at(b, ["player", "final_pos_str"])
	var state_equal: bool = pos_a == pos_b \
			and _int_at(a, ["player", "kills"]) == _int_at(b, ["player", "kills"]) \
			and is_equal_approx(_float_at(a, ["player", "hp"]), _float_at(b, ["player", "hp"]))
	var ok: bool = digest_a == digest_b and state_equal and not digest_a.is_empty()
	var detail: String = "digest=%s... pos=%s kills=%d" % [
			digest_a.substr(0, mini(16, digest_a.length())), pos_a, _int_at(a, ["player", "kills"])]
	_check("determinism (same seed)", ok, detail, run_a if not ok else {})


func _check_batch_independence() -> void:
	var seeds: Array = [4242, 4243, 4244]
	var details: PackedStringArray = PackedStringArray()
	var ok: bool = true
	var last: Dictionary = {}
	for seed_value: int in seeds:
		last = _run("single_%d" % seed_value,
				_single_run_args(seed_value, "res://reports/_verify/single_%d.json" % seed_value, 1))
	var batched: Dictionary = _run("batch3",
			_single_run_args(4242, "res://reports/_verify/batch3", 3))
	if int(batched["exit"]) != 0:
		last = batched
	for seed_value: int in seeds:
		var single_json: Dictionary = _read_json("res://reports/_verify/single_%d.json" % seed_value)
		var batch_json: Dictionary = _read_json(
				"res://reports/_verify/batch3/seed%d.json" % seed_value)
		var single_digest: String = _str_at(single_json, ["determinism", "digest"])
		var batch_digest: String = _str_at(batch_json, ["determinism", "digest"])
		if single_digest.is_empty() or batch_digest.is_empty() or single_digest != batch_digest:
			ok = false
			details.append("seed %d differs" % seed_value)
	if ok:
		details.append("batch=1 vs batch=3 digests match for 3 seeds")
	_check("batch-size independence", ok, " ".join(details), last if not ok else {})


func _check_stuck_detection() -> Dictionary:
	var result: Dictionary = _run("stuck",
			_campaign_args(0, 1000, "res://reports/_verify/stuck", ["--sim-config=" + STUCK_CONFIG]))
	var report: Dictionary = _read_json("res://reports/_verify/stuck/stuck_test.json")
	var run_json_path: String = _find_run_json("res://reports/_verify/stuck/_runs")
	var run_data: Dictionary = _read_json(run_json_path) if not run_json_path.is_empty() else {}
	var detail: String = "run or report missing"
	var ok: bool = false
	if not report.is_empty() and not run_data.is_empty():
		var end_reason: String = _str_at(run_data, ["end_reason"])
		var records: Array = _array_at(run_data, ["telemetry", "stuck", "records"])
		var pos_x: float = 0.0
		var pos_y: float = 0.0
		if not records.is_empty():
			var pos: Array = _array_at(records[0], ["pos"])
			if pos.size() >= 2:
				pos_x = float(pos[0])
				pos_y = float(pos[1])
		var markdown: String = _read_text("res://reports/_verify/stuck/stuck_test.md")
		var rate: float = _float_at(report, ["stuck_rate"])
		var ascii_mark: bool = markdown.contains("!")
		ok = end_reason == "stuck" and not records.is_empty() and absf(rate - 1.0) < 0.0001 \
				and pos_x > -300.0 and pos_x < -250.0 and pos_y > 20.0 and pos_y < 60.0 \
				and ascii_mark
		detail = "end_reason=%s pos=(%.1f, %.1f) ascii_mark=%s" % [end_reason, pos_x, pos_y, ascii_mark]
	_check("stuck detection", ok, detail, result if not ok else {})
	return report


func _check_anomalies(report: Dictionary) -> void:
	var count: int = _array_at(report, ["anomalies"]).size()
	_check("anomaly detection", count >= 1,
			"%d anomaly entry(ies) in the stuck campaign" % count)


func _check_timeseries_cap() -> void:
	var result: Dictionary = _run("timeseries_cap", _single_run_args(4242,
			"res://reports/_verify/timeseries_cap.json", 0, ["--sim-timeseries-max=20"]))
	var run_data: Dictionary = _read_json("res://reports/_verify/timeseries_cap.json")
	var samples: Array = _array_at(run_data, ["telemetry", "timeseries", "samples"])
	var reported_count: int = _int_at(run_data, ["telemetry", "samples"])
	var sim_time: float = _float_at(run_data, ["sim_time"])
	var last_t: float = 0.0
	if not samples.is_empty():
		var last: Variant = samples[samples.size() - 1]
		if last is Dictionary:
			last_t = float((last as Dictionary).get("t", 0.0))
	var ok: bool = int(result["exit"]) == 0 and samples.size() >= 2 \
			and samples.size() <= 20 and reported_count == samples.size() \
			and last_t > 0.0 and sim_time - last_t <= 2.0
	_check("timeseries cap", ok,
			"%d samples (cap 20), last t=%.1fs of %.1fs" % [samples.size(), last_t, sim_time],
			result if not ok else {})


func _check_campaign() -> Dictionary:
	var result: Dictionary = _run("campaign",
			_campaign_args(50, 1000, "res://reports/_verify/campaign"))
	var report: Dictionary = _read_json("res://reports/_verify/campaign/report.json")
	var markdown_bytes: int = _file_size("res://reports/_verify/campaign/report.md")
	if report.is_empty():
		_check("campaign throughput", false, "campaign report missing", result)
		_check("report.md size budget", false, "%d bytes" % markdown_bytes)
		_check("balance within target band", false, "report missing")
		return report
	var wall: float = _float_at(report, ["timing", "wall_seconds"])
	var speedup: float = _float_at(report, ["timing", "speedup"])
	var win: float = _float_at(report, ["win_rate"])
	var stuck: float = _float_at(report, ["stuck_rate"])
	var throughput_ok: bool = int(result["exit"]) == 0 and wall <= _budget
	var throughput_detail: String = "50 runs in %.2fs (budget %.0fs, %.0fx)" % [wall, _budget, speedup]
	_check("campaign throughput", throughput_ok, throughput_detail, result if not throughput_ok else {})
	_check("report.md size budget", markdown_bytes > 0 and markdown_bytes < 4096,
			"%d bytes" % markdown_bytes)
	var balance_ok: bool = win >= 0.25 and win <= 0.80
	_check("balance within target band", balance_ok,
			"win_rate=%.1f%% stuck_rate=%.1f%%" % [win * 100.0, stuck * 100.0])
	return report


func _check_regression_gate() -> void:
	var baseline: String = "res://reports/_verify/campaign/report.json"
	var override: String = SMG + "|damage=1"
	var rejected: Dictionary = _run("gate_fail", _campaign_args(20, 5000,
			"res://reports/_verify/gate_fail", [
				"--sim-baseline=" + baseline,
				"--sim-fail-on-regression",
				"--sim-set=" + override,
			]))
	var rejected_ok: bool = int(rejected["exit"]) == 4 \
			and str(rejected["text"]).contains("regression gate FAILED")
	_check("regression gate rejects drop", rejected_ok,
			"exit=%d (expected 4)" % int(rejected["exit"]), rejected if not rejected_ok else {})

	var allowed: Dictionary = _run("gate_pass", _campaign_args(20, 5000,
			"res://reports/_verify/gate_pass", [
				"--sim-baseline=" + baseline,
				"--sim-fail-on-regression",
				"--sim-gate-win-drop=1.0",
				"--sim-gate-survival-drop=60",
				"--sim-gate-fail-on-new-critical=false",
				"--sim-set=" + override,
			]))
	var allowed_ok: bool = int(allowed["exit"]) == 0 \
			and str(allowed["text"]).contains("regression gate passed")
	_check("regression gate allows limit", allowed_ok,
			"exit=%d (expected 0)" % int(allowed["exit"]), allowed if not allowed_ok else {})


func _check_repeat_determinism() -> void:
	var result: Dictionary = _run("repeat", _campaign_args(10, 3000,
			"res://reports/_verify/repeat", ["--sim-repeat=2"]))
	var report: Dictionary = _read_json("res://reports/_verify/repeat/report.json")
	if report.is_empty():
		_check("repeat determinism (x2)", false, "report missing", result)
		return
	var checked: bool = bool(_dig(report, ["determinism", "checked"]))
	var identical: bool = bool(_dig(report, ["determinism", "identical"]))
	var mismatches: int = _array_at(report, ["determinism", "mismatches"]).size()
	var ok: bool = checked and identical and mismatches == 0
	_check("repeat determinism (x2)", ok,
			"identical=%s mismatches=%d" % [identical, mismatches], result if not ok else {})


# --- process helpers ------------------------------------------------------

## Run the same Godot binary headless and capture its combined output.
func _run(name: String, args: PackedStringArray) -> Dictionary:
	var full: PackedStringArray = PackedStringArray(["--headless"])
	full.append_array(args)
	var output: Array = []
	var started: int = Time.get_ticks_msec()
	var exit_code: int = OS.execute(_godot, full, output, true)
	var elapsed: float = float(Time.get_ticks_msec() - started) / 1000.0
	var text: String = ""
	for part: Variant in output:
		text += str(part)
	var log_path: String = OUT_DIR.path_join(name + ".log")
	_write_text(log_path, text)
	return {"exit": exit_code, "text": text, "log": log_path, "seconds": elapsed}


func _single_run_args(seed_value: int, out_path: String, batch_size: int = 0,
		extra: Array = []) -> PackedStringArray:
	var args: PackedStringArray = PackedStringArray(["--path", _root])
	args.append_array(BATCH_FLAGS)
	args.append(SCENE)
	args.append("--")
	args.append("--sim-mode")
	args.append("--sim-seed=%d" % seed_value)
	args.append("--sim-max-time=60")
	args.append("--sim-out=" + out_path)
	if batch_size > 0:
		args.append("--sim-batch=%d" % batch_size)
	args.append_array(extra)
	return args


## Campaign CLI args; `runs <= 0` leaves the run count to the config resource.
func _campaign_args(runs: int, seed_value: int, out_path: String, extra: Array = []) -> PackedStringArray:
	var args: PackedStringArray = PackedStringArray(["--path", _root, "-s", CAMPAIGN_SCRIPT, "--"])
	args.append("--sim-mode")
	if runs > 0:
		args.append("--sim-runs=%d" % runs)
	args.append("--sim-seed=%d" % seed_value)
	args.append("--sim-max-time=60")
	args.append("--sim-out=" + out_path)
	args.append_array(extra)
	return args


# --- filesystem / JSON helpers --------------------------------------------

func _reset_out_dir() -> void:
	_remove_tree(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))


func _remove_tree(res_path: String) -> void:
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	var dir: DirAccess = DirAccess.open(abs_path)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute(abs_path.path_join(file_name))
	for sub_dir: String in dir.get_directories():
		_remove_tree(res_path.path_join(sub_dir))
	DirAccess.remove_absolute(abs_path)


func _find_run_json(res_dir: String) -> String:
	var abs_path: String = ProjectSettings.globalize_path(res_dir)
	var dir: DirAccess = DirAccess.open(abs_path)
	if dir == null:
		return ""
	for file_name: String in dir.get_files():
		if file_name.ends_with(".json") and not file_name.begins_with("report"):
			return res_dir.path_join(file_name)
	for sub_dir: String in dir.get_directories():
		var found: String = _find_run_json(res_dir.path_join(sub_dir))
		if not found.is_empty():
			return found
	return ""


func _read_text(res_path: String) -> String:
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	if not FileAccess.file_exists(abs_path):
		return ""
	var file: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _write_text(res_path: String, text: String) -> void:
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	var dir: String = abs_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(abs_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _read_json(res_path: String) -> Dictionary:
	if res_path.is_empty():
		return {}
	var text: String = _read_text(res_path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _file_size(res_path: String) -> int:
	var abs_path: String = ProjectSettings.globalize_path(res_path)
	if not FileAccess.file_exists(abs_path):
		return 0
	var file: FileAccess = FileAccess.open(abs_path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size


# --- dictionary / string helpers ------------------------------------------

func _dig(data: Dictionary, keys: Array) -> Variant:
	var cursor: Variant = data
	for key: Variant in keys:
		if cursor is Dictionary:
			cursor = (cursor as Dictionary).get(key)
		elif cursor is Array:
			var list: Array = cursor as Array
			var index: int = int(key)
			cursor = list[index] if index >= 0 and index < list.size() else null
		else:
			return null
	return cursor


func _str_at(data: Dictionary, keys: Array) -> String:
	var value: Variant = _dig(data, keys)
	return "" if value == null else str(value)


func _float_at(data: Dictionary, keys: Array) -> float:
	var value: Variant = _dig(data, keys)
	return 0.0 if value == null else float(value)


func _int_at(data: Dictionary, keys: Array) -> int:
	var value: Variant = _dig(data, keys)
	return 0 if value == null else int(value)


func _array_at(data: Dictionary, keys: Array) -> Array:
	var value: Variant = _dig(data, keys)
	return value if value is Array else []


func _first_line(text: String) -> String:
	for line: String in text.replace("\r", "").split("\n"):
		if not line.strip_edges().is_empty():
			return line.strip_edges()
	return ""


func _line_starting_with(text: String, prefix: String) -> String:
	for line: String in text.replace("\r", "").split("\n"):
		if line.strip_edges().begins_with(prefix):
			return line.strip_edges()
	return ""


func _first_line_starting_with(text: String, prefix: String) -> String:
	return _line_starting_with(text, prefix)


# --- reporting ------------------------------------------------------------

func _check(name: String, ok: bool, detail: String, log_result: Dictionary = {}) -> void:
	_checks += 1
	if ok:
		print("[PASS] %-34s %s" % [name, detail])
		return
	_failures += 1
	print("[FAIL] %-34s %s" % [name, detail])
	if log_result.is_empty():
		return
	var lines: PackedStringArray = str(log_result.get("text", "")).replace("\r", "").split("\n")
	for index: int in range(maxi(0, lines.size() - 12), lines.size()):
		var line: String = lines[index]
		if not line.strip_edges().is_empty():
			print("        | " + line)
