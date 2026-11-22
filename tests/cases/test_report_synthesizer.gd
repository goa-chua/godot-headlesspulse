extends HpTestCase
## ReportSynthesizer: percentile math, critical counting, A/B diff, regression gate.


func run() -> void:
	# Percentile helpers.
	var values: Array[float] = [10.0, 20.0, 30.0, 40.0]
	assert_almost_eq(ReportSynthesizer._median(values), 25.0, 0.0001, "median of even count")
	assert_almost_eq(ReportSynthesizer._min(values), 10.0, 0.0001, "min")
	assert_almost_eq(ReportSynthesizer._max(values), 40.0, 0.0001, "max")
	assert_almost_eq(ReportSynthesizer._p90(values), 40.0, 0.0001, "p90 rank")
	var single: Array[float] = [7.5]
	assert_almost_eq(ReportSynthesizer._median(single), 7.5, 0.0001, "median of one value")
	var empty: Array[float] = []
	assert_almost_eq(ReportSynthesizer._median(empty), 0.0, 0.0001, "median of empty list")
	assert_almost_eq(ReportSynthesizer._p90(empty), 0.0, 0.0001, "p90 of empty list")

	# CRITICAL anomaly counting is case-insensitive and tolerant of bad input.
	var report: Dictionary = {
		"anomalies": [
			{"severity": "CRITICAL", "code": "a"},
			{"severity": "critical", "code": "b"},
			{"severity": "WARN", "code": "c"},
		],
	}
	assert_eq(ReportSynthesizer._count_critical(report), 2, "critical anomalies counted")
	assert_eq(ReportSynthesizer._count_critical({}), 0, "missing list counts zero")

	# Gate without a baseline diff fails with a dedicated rule.
	var no_baseline: Dictionary = ReportSynthesizer.evaluate_regression_gate({"anomalies": []}, 0.05, 5.0, true)
	assert_false(bool(no_baseline.get("passed", true)), "gate needs a baseline")
	var no_baseline_checks: Array = no_baseline.get("checks", [])
	assert_eq(no_baseline_checks.size(), 1, "one rule for the missing baseline")
	assert_eq(str(no_baseline_checks[0]["name"]), "baseline diff", "rule name")

	# Within-limits report passes all three rules.
	var within: Dictionary = {
		"ab_diff": {
			"win_rate": {"baseline": 0.5, "current": 0.47, "delta": -0.03},
			"survival_median": {"baseline": 60.0, "current": 58.0, "delta": -2.0},
			"critical_anomalies": {"baseline": 0, "current": 0, "delta": 0},
		},
		"anomalies": [],
	}
	var passed_gate: Dictionary = ReportSynthesizer.evaluate_regression_gate(within, 0.05, 5.0, true)
	assert_true(bool(passed_gate.get("passed", false)), "within limits passes the gate")
	assert_eq((passed_gate.get("checks", []) as Array).size(), 3, "three gate rules")

	# A regressed report fails the relevant rules (and names them).
	var regressed: Dictionary = {
		"ab_diff": {
			"win_rate": {"baseline": 0.5, "current": 0.2, "delta": -0.3},
			"survival_median": {"baseline": 60.0, "current": 60.0, "delta": 0.0},
			"critical_anomalies": {"baseline": 0, "current": 1, "delta": 1},
		},
		"anomalies": [{"severity": "CRITICAL", "code": "x"}],
	}
	var failed_gate: Dictionary = ReportSynthesizer.evaluate_regression_gate(regressed, 0.05, 5.0, true)
	assert_false(bool(failed_gate.get("passed", true)), "regression fails the gate")
	var failed_names: PackedStringArray = PackedStringArray()
	for check: Dictionary in failed_gate.get("checks", []):
		if not bool(check.get("passed", true)):
			failed_names.append(str(check.get("name", "")))
	assert_true(failed_names.has("win_rate drop"), "win-rate rule failed")
	assert_true(failed_names.has("new CRITICAL anomalies"), "critical rule failed")

	# The critical rule can be switched off; relaxed limits pass.
	var relaxed: Dictionary = ReportSynthesizer.evaluate_regression_gate(regressed, 1.0, 60.0, false)
	assert_true(bool(relaxed.get("passed", false)), "relaxed thresholds pass")

	# _ab_diff adds the critical-anomaly delta the gate compares on.
	var baseline: Dictionary = {
		"generated_at": "base",
		"win_rate": 0.5,
		"stuck_rate": 0.0,
		"stuck_events": 0,
		"deaths": 0,
		"survival": {"median": 60.0},
		"player": {"dps_median": 50.0},
		"weapons": {"smg": {"share": 1.0}},
		"anomalies": [{"severity": "CRITICAL"}],
	}
	var current: Dictionary = baseline.duplicate(true)
	current["anomalies"] = []
	var diff: Dictionary = ReportSynthesizer._ab_diff(current, baseline)
	var critical: Dictionary = diff.get("critical_anomalies", {})
	assert_eq(int(critical.get("baseline", -1)), 1, "baseline critical counted")
	assert_eq(int(critical.get("current", -1)), 0, "current critical counted")
	assert_eq(int(critical.get("delta", -1)), -1, "critical delta computed")
