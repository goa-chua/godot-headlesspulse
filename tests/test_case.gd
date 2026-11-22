class_name HpTestCase
extends RefCounted
## Minimal assertion base for the HeadlessPulse unit tests.
##
## Each suite in `tests/cases/` extends this class and implements `run()`,
## calling the `assert_*` helpers. `tests/run_tests.gd` instantiates every suite,
## calls `run()` and reports one PASS/FAIL line per suite (no external test
## framework, so it also works in a bare Godot install).

var suite_name: String = ""
var assertions: int = 0

var _failures: PackedStringArray = PackedStringArray()


## Overridden by every suite.
func run() -> void:
	push_error("HpTestCase.run() must be overridden")


func assert_true(condition: bool, message: String = "") -> void:
	assertions += 1
	if not condition:
		_failures.append(_prefix(message) + "expected true, got false")


func assert_false(condition: bool, message: String = "") -> void:
	assertions += 1
	if condition:
		_failures.append(_prefix(message) + "expected false, got true")


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	assertions += 1
	if actual != expected:
		_failures.append(_prefix(message) + "expected %s, got %s" % [str(expected), str(actual)])


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> void:
	assertions += 1
	if actual == unexpected:
		_failures.append(_prefix(message) + "did not expect %s" % str(unexpected))


func assert_almost_eq(actual: float, expected: float, epsilon: float = 0.0001, message: String = "") -> void:
	assertions += 1
	if absf(actual - expected) > epsilon:
		_failures.append(_prefix(message) + "expected %f (+/- %f), got %f" % [expected, epsilon, actual])


func assert_gt(actual: float, threshold: float, message: String = "") -> void:
	assertions += 1
	if actual <= threshold:
		_failures.append(_prefix(message) + "expected > %f, got %f" % [threshold, actual])


func fail(message: String) -> void:
	assertions += 1
	_failures.append(_prefix(message) + "explicit failure")


func failure_count() -> int:
	return _failures.size()


func failure_text() -> String:
	return "; ".join(_failures)


func _prefix(message: String) -> String:
	return "" if message.is_empty() else message + ": "
