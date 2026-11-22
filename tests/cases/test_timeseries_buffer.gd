extends HpTestCase
## SimTimeseriesBuffer: bounded memory, deterministic decimation, last sample kept.


func run() -> void:
	# max_samples = 0 keeps everything (legacy behaviour).
	var unlimited := SimTimeseriesBuffer.new(0)
	for index: int in range(100):
		unlimited.append(_sample(index * 0.5))
	assert_eq(unlimited.size(), 100, "unlimited buffer keeps every sample")
	assert_eq(unlimited.snapshot().size(), 100, "unlimited snapshot keeps every sample")
	assert_eq(unlimited.stride, 1, "unlimited buffer never decimates")

	# Input under the cap is untouched and ordered.
	var small := SimTimeseriesBuffer.new(100)
	for index: int in range(50):
		small.append(_sample(index * 0.5))
	var small_snapshot: Array[Dictionary] = small.snapshot()
	assert_eq(small_snapshot.size(), 50, "input under the cap is untouched")
	assert_almost_eq(float(small_snapshot[0]["t"]), 0.0, 0.0001, "first sample time")
	assert_almost_eq(float(small_snapshot[49]["t"]), 24.5, 0.0001, "last sample time")

	# Long input is bounded during collection (memory <= 2x cap) and decimated.
	var bounded := SimTimeseriesBuffer.new(50)
	for index: int in range(1000):
		bounded.append(_sample(index * 0.5))
	assert_true(bounded.size() <= 100, "collection memory bounded by 2x cap (got %d)" % bounded.size())
	assert_gt(float(bounded.stride), 1.0, "decimation happened")
	var snapshot: Array[Dictionary] = bounded.snapshot()
	assert_true(snapshot.size() <= 50, "snapshot respects the cap (got %d)" % snapshot.size())
	assert_true(snapshot.size() >= 2, "snapshot keeps several samples")
	assert_almost_eq(float(snapshot[0]["t"]), 0.0, 0.0001, "first sample kept")
	assert_almost_eq(float(snapshot[snapshot.size() - 1]["t"]), 499.5, 0.0001, "last sample always kept")
	var increasing: bool = true
	for index: int in range(1, snapshot.size()):
		if float(snapshot[index]["t"]) <= float(snapshot[index - 1]["t"]):
			increasing = false
	assert_true(increasing, "snapshot times stay increasing")

	# Two identical runs produce identical snapshots (decimation is deterministic).
	var run_a := SimTimeseriesBuffer.new(50)
	var run_b := SimTimeseriesBuffer.new(50)
	for index: int in range(1000):
		run_a.append(_sample(index * 0.5))
		run_b.append(_sample(index * 0.5))
	assert_eq(run_a.snapshot(), run_b.snapshot(), "decimation is deterministic")
	assert_eq(run_a.stride, run_b.stride, "stride is deterministic")

	# snapshots are deep copies: mutating one must not touch the buffer.
	var copy_snapshot: Array[Dictionary] = bounded.snapshot()
	copy_snapshot[0]["hp"] = 999.0
	var again: Array[Dictionary] = bounded.snapshot()
	assert_ne(float(again[0]["hp"]), 999.0, "snapshot returns deep copies")

	# clear() resets size and stride.
	bounded.clear()
	assert_eq(bounded.size(), 0, "clear empties the buffer")
	assert_eq(bounded.stride, 1, "clear resets stride")
	assert_eq(bounded.snapshot().size(), 0, "empty snapshot")

	# Exactly at the cap: untouched. One over the doubling point: decimated.
	var exact := SimTimeseriesBuffer.new(10)
	for index: int in range(10):
		exact.append(_sample(index * 0.5))
	assert_eq(exact.snapshot().size(), 10, "exactly-cap input untouched")
	assert_eq(exact.stride, 1, "exactly-cap input not decimated")

	var edge := SimTimeseriesBuffer.new(10)
	for index: int in range(21):
		edge.append(_sample(index * 0.5))
	var edge_snapshot: Array[Dictionary] = edge.snapshot()
	assert_true(edge_snapshot.size() <= 10, "over-cap input capped")
	assert_almost_eq(float(edge_snapshot[edge_snapshot.size() - 1]["t"]), 10.0, 0.0001,
			"over-cap input keeps the last sample")
	assert_gt(float(edge.stride), 1.0, "over-cap input decimated")


func _sample(time: float) -> Dictionary:
	return {"t": time, "hp": 100.0 - time, "alive": true}
