extends SceneTree
## Headless unit-test runner (no framework, no addon runtime needed).
##
##   godot --headless --path . -s res://tests/run_tests.gd
##
## The acceptance scripts (tools/verify.ps1, tools/verify.sh) run this after
## `--import`, because the suites use `class_name`s from the project (the global
## class cache has to be fresh). Exit code 0 = all suites passed, 1 = failure.

const SUITES: Array = [
	"res://tests/cases/test_sim_rng.gd",
	"res://tests/cases/test_sim_checksum.gd",
	"res://tests/cases/test_sim_config.gd",
	"res://tests/cases/test_stuck_detector.gd",
	"res://tests/cases/test_spatial_heatmap.gd",
	"res://tests/cases/test_timeseries_buffer.gd",
	"res://tests/cases/test_report_synthesizer.gd",
]


func _initialize() -> void:
	var failed_suites: int = 0
	var total_assertions: int = 0
	print("HeadlessPulse unit tests")
	for path: String in SUITES:
		var script: GDScript = load(path) as GDScript
		if script == null:
			printerr("[FAIL] suite missing: %s (run --import first)" % path)
			failed_suites += 1
			continue
		var suite: HpTestCase = script.new() as HpTestCase
		suite.suite_name = path.get_file().get_basename()
		suite.run()
		total_assertions += suite.assertions
		if suite.failure_count() == 0:
			print("[PASS] %-28s %d assertion(s)" % [suite.suite_name, suite.assertions])
		else:
			failed_suites += 1
			print("[FAIL] %-28s %s" % [suite.suite_name, suite.failure_text()])

	print("")
	if failed_suites == 0:
		print("unit tests: %d suites, %d assertions, 0 failures" % [SUITES.size(), total_assertions])
		quit(0)
		return
	print("unit tests: %d/%d suites FAILED" % [failed_suites, SUITES.size()])
	quit(1)
