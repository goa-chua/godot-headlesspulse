extends HpTestCase
## SpatialHeatmap: world -> cell mapping, aggregation, ASCII markers, roundtrip.


func run() -> void:
	var grid := SpatialHeatmap.new(10, 4)
	assert_eq(grid.traffic.size(), 40, "10x4 grid allocated")
	assert_eq(grid.cell_index(Vector2(-480.0, 300.0)), 0, "top-left corner")
	assert_eq(grid.cell_index(Vector2(480.0, -300.0)), 39, "bottom-right corner")
	assert_eq(grid.cell_index(Vector2(0.0, 0.0)), 2 * 10 + 5, "centre cell")
	assert_eq(grid.cell_index(Vector2(-10000.0, 10000.0)), 0, "out-of-bounds clamps top-left")
	assert_eq(grid.cell_index(Vector2(10000.0, -10000.0)), 39, "out-of-bounds clamps bottom-right")

	grid.add_traffic(Vector2(0.0, 0.0))
	grid.add_traffic(Vector2(0.0, 0.0))
	grid.add_traffic(Vector2(-400.0, 200.0))
	grid.add_death(Vector2(0.0, 0.0))
	grid.add_stuck(Vector2(300.0, -200.0))
	assert_eq(grid.total_samples, 3, "traffic samples counted")
	assert_eq(grid.max_traffic, 2, "peak traffic tracked")
	assert_eq(grid.traffic[2 * 10 + 5], 2, "centre traffic accumulated")
	assert_eq(grid.deaths[2 * 10 + 5], 1, "death recorded")

	var ascii: String = grid.render_ascii()
	assert_eq(ascii.split("\n").size(), 4 + 2, "ASCII adds a border row on each side")
	assert_true(ascii.contains("X"), "death marker rendered")
	assert_true(ascii.contains("!"), "stuck marker rendered")

	var top: Array[Dictionary] = grid.top_traffic(1)
	assert_eq(top.size(), 1, "top_traffic limit respected")
	assert_eq(int(top[0]["count"]), 2, "top_traffic sorted by count")
	var stuck_spots: Array[Dictionary] = grid.hotspots(grid.stucks, 1)
	assert_eq(stuck_spots.size(), 1, "hotspot found")
	assert_eq(int(stuck_spots[0]["count"]), 1, "hotspot count")
	assert_gt(float(stuck_spots[0]["pos"][0]), 0.0, "stuck hotspot is on the right half")

	# merge() aggregates compatible grids and ignores mismatched ones.
	var other := SpatialHeatmap.new(10, 4)
	other.add_traffic(Vector2(0.0, 0.0))
	grid.merge(other)
	assert_eq(grid.traffic[2 * 10 + 5], 3, "merge sums traffic")
	assert_eq(grid.total_samples, 4, "merge sums samples")
	var incompatible := SpatialHeatmap.new(20, 8)
	grid.merge(incompatible)
	assert_eq(grid.total_samples, 4, "incompatible grid is ignored")

	# to_dict/from_dict roundtrip preserves the grid.
	var restored := SpatialHeatmap.from_dict(grid.to_dict())
	assert_true(restored.is_compatible(grid), "roundtrip keeps the grid bounds")
	assert_eq(restored.traffic[2 * 10 + 5], 3, "roundtrip keeps traffic")
	assert_eq(restored.deaths[2 * 10 + 5], 1, "roundtrip keeps deaths")
	assert_eq(restored.total_samples, 4, "roundtrip keeps samples")
	assert_eq(restored.max_traffic, 3, "roundtrip keeps the peak")
