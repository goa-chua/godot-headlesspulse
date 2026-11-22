extends HpTestCase
## SimConfig: CLI parsing, unknown-option detection, validation, batch math.


func run() -> void:
	# parse_args: repeatable --sim-set collects into an array; bare flags are true.
	var opts: Dictionary = SimConfig.parse_args(PackedStringArray([
		"--sim-mode",
		"--sim-seed=42",
		"--sim-set=a.tres|x=1",
		"--sim-set=b.tres|y=two",
	]))
	assert_true(opts.has("sim-mode"), "bare flag is parsed")
	assert_eq(str(opts.get("sim-seed", "")), "42", "value flag is parsed")
	var sets: Array = opts.get("sim-set", [])
	assert_eq(sets.size(), 2, "repeatable --sim-set is collected")
	assert_eq(str(sets[0]), "a.tres|x=1", "first override kept")
	assert_eq(str(sets[1]), "b.tres|y=two", "second override kept")

	# unknown_options flags typos but accepts every KNOWN_OPTIONS entry.
	assert_eq(SimConfig.unknown_options({"sim-seed": "1"}).size(), 0, "known option accepted")
	var typos: PackedStringArray = SimConfig.unknown_options({"sim-sedd": "1"})
	assert_eq(typos.size(), 1, "typo flagged")
	assert_eq(typos[0], "--sim-sedd", "typo name reported")
	assert_eq(SimConfig.unknown_options({"sim-gate-win-drop": "0.1"}).size(), 0, "gate option accepted")

	# --sim-help documents every known option (single source of truth).
	var help: String = SimConfig.help_text()
	for option: String in SimConfig.KNOWN_OPTIONS:
		assert_true(help.contains("--" + option), "help mentions --%s" % option)

	# apply_opts writes fields; the default scene/bot exist so validation passes.
	var config := SimConfig.new()
	var errors: PackedStringArray = config.apply_opts({
		"sim-seed": "77",
		"sim-runs": "5",
		"sim-max-time": "12.5",
		"sim-terminate-on-stuck": true,
		"sim-grid": "10x8",
		"sim-stuck-window": "2.5",
		"sim-gate-win-drop": "0.2",
	})
	assert_eq(errors.size(), 0, "valid options produce no errors: %s" % "; ".join(errors))
	assert_eq(config.seed, 77, "seed applied")
	assert_eq(config.runs, 5, "runs applied")
	assert_almost_eq(config.max_sim_time, 12.5, 0.0001, "max_sim_time applied")
	assert_true(config.terminate_on_stuck, "flag applied")
	assert_eq(config.grid_cols, 10, "grid cols applied")
	assert_eq(config.grid_rows, 8, "grid rows applied")
	assert_almost_eq(config.gate_max_win_drop, 0.2, 0.0001, "gate threshold applied")

	# validate() collects multiple problems at once.
	var bad := SimConfig.new()
	bad.runs = 0
	bad.max_sim_time = 0.0
	bad.bounds_min = Vector2(10.0, 10.0)
	bad.bounds_max = Vector2(-10.0, -10.0)
	var bad_errors: PackedStringArray = bad.validate()
	assert_true(bad_errors.size() >= 3, "validation reports each problem")
	assert_true(_any_contains(bad_errors, "runs"), "runs error reported")
	assert_true(_any_contains(bad_errors, "max_sim_time"), "max_sim_time error reported")
	assert_true(_any_contains(bad_errors, "bounds_max"), "bounds error reported")

	# The regression gate requires a baseline.
	var gate := SimConfig.new()
	gate.fail_on_regression = true
	assert_true(_any_contains(gate.validate(), "--sim-baseline"), "gate requires a baseline")

	# Batch math: explicit size wins, auto = ceil(runs / workers).
	var batch := SimConfig.new()
	batch.runs = 10
	batch.max_concurrency = 4
	assert_eq(batch.resolved_concurrency(), 4, "explicit concurrency")
	assert_eq(batch.resolved_batch_size(), 3, "ceil(10 / 4)")
	batch.batch_size = 5
	assert_eq(batch.resolved_batch_size(), 5, "explicit batch size wins")
	batch.batch_size = 0
	batch.runs = 0
	assert_eq(batch.resolved_batch_size(), 1, "zero runs yields batch 1")

	# _to_* helpers are lenient for CLI input.
	assert_eq(SimConfig._to_int("12", 0), 12, "int parsed")
	assert_eq(SimConfig._to_int("oops", 7), 7, "int falls back")
	assert_almost_eq(SimConfig._to_float("1.5", 0.0), 1.5, 0.0001, "float parsed")
	assert_true(SimConfig._to_bool("yes"), "bool true parsed")
	assert_false(SimConfig._to_bool("no"), "bool false parsed")


func _any_contains(messages: PackedStringArray, needle: String) -> bool:
	for message: String in messages:
		if message.contains(needle):
			return true
	return false
