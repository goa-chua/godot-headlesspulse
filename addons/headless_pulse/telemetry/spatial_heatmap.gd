class_name SpatialHeatmap
extends RefCounted
## Fixed-resolution world-to-grid rasterizer with a compact ASCII renderer.
##
## The renderer is deliberately token-cheap: a 40x20 map is ~1 KB of ASCII and
## still shows traffic density, death clusters ('X') and stuck hotspots ('!').

const TRAFFIC_CHARS: Array = [".", ":", "+", "#"]
const DEATH_CHAR: String = "X"
const STUCK_CHAR: String = "!"

var cols: int = 40
var rows: int = 20
var bounds_min: Vector2 = Vector2(-480.0, -300.0)
var bounds_max: Vector2 = Vector2(480.0, 300.0)

var traffic: PackedInt32Array = PackedInt32Array()
var deaths: PackedInt32Array = PackedInt32Array()
var stucks: PackedInt32Array = PackedInt32Array()
var max_traffic: int = 0
var total_samples: int = 0


func _init(p_cols: int = 40, p_rows: int = 20) -> void:
	setup(p_cols, p_rows, Vector2(-480.0, -300.0), Vector2(480.0, 300.0))


func setup(p_cols: int, p_rows: int, p_min: Vector2, p_max: Vector2) -> void:
	cols = maxi(p_cols, 1)
	rows = maxi(p_rows, 1)
	bounds_min = p_min
	bounds_max = p_max
	var size: int = cols * rows
	traffic = PackedInt32Array()
	traffic.resize(size)
	traffic.fill(0)
	deaths = traffic.duplicate()
	stucks = traffic.duplicate()
	max_traffic = 0
	total_samples = 0


func cell_index(world_pos: Vector2) -> int:
	if cols <= 0 or rows <= 0:
		return -1
	var span := bounds_max - bounds_min
	if span.x <= 0.0 or span.y <= 0.0:
		return -1
	var fx: float = clampf((world_pos.x - bounds_min.x) / span.x, 0.0, 0.999999)
	# Row 0 is the top of the map (largest world Y), matching a world-up view.
	var fy: float = clampf((bounds_max.y - world_pos.y) / span.y, 0.0, 0.999999)
	var col: int = clampi(int(fx * cols), 0, cols - 1)
	var row: int = clampi(int(fy * rows), 0, rows - 1)
	return row * cols + col


func add_traffic(world_pos: Vector2) -> void:
	var idx: int = cell_index(world_pos)
	if idx < 0:
		return
	traffic[idx] += 1
	max_traffic = maxi(max_traffic, traffic[idx])
	total_samples += 1


func add_death(world_pos: Vector2) -> void:
	var idx: int = cell_index(world_pos)
	if idx >= 0:
		deaths[idx] += 1


func add_stuck(world_pos: Vector2) -> void:
	var idx: int = cell_index(world_pos)
	if idx >= 0:
		stucks[idx] += 1


func is_compatible(other: SpatialHeatmap) -> bool:
	return cols == other.cols and rows == other.rows \
		and bounds_min.is_equal_approx(other.bounds_min) \
		and bounds_max.is_equal_approx(other.bounds_max)


func merge(other: SpatialHeatmap) -> void:
	if not is_compatible(other):
		push_warning("[headless_pulse] heatmap merge skipped: grid mismatch")
		return
	for i: int in range(traffic.size()):
		traffic[i] += other.traffic[i]
		deaths[i] += other.deaths[i]
		stucks[i] += other.stucks[i]
		max_traffic = maxi(max_traffic, traffic[i])
	total_samples += other.total_samples


## Highest-traffic cells, sorted descending: [{pos:[x,y], count:int, cell:int}]
func top_traffic(limit: int = 5) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for i: int in range(traffic.size()):
		if traffic[i] > 0:
			entries.append({"cell": i, "count": traffic[i], "pos": cell_center(i)})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["count"]) > int(b["count"]))
	if entries.size() > limit:
		entries.resize(limit)
	return entries


## Hotspots (cell -> world center), sorted descending: [{pos:[x,y], count:int}]
func hotspots(counts: PackedInt32Array, limit: int = 5) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for i: int in range(counts.size()):
		if counts[i] > 0:
			entries.append({"cell": i, "count": counts[i], "pos": cell_center(i)})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["count"]) > int(b["count"]))
	if entries.size() > limit:
		entries.resize(limit)
	return entries


func cell_center(idx: int) -> Array:
	var col: int = idx % cols
	var row: int = int(floor(float(idx) / float(cols)))
	var span := bounds_max - bounds_min
	var x: float = bounds_min.x + (float(col) + 0.5) / float(cols) * span.x
	var y: float = bounds_max.y - (float(row) + 0.5) / float(rows) * span.y
	return [snappedf(x, 0.1), snappedf(y, 0.1)]


func render_ascii() -> String:
	var lines: PackedStringArray = PackedStringArray()
	var border: String = "+" + "-".repeat(cols) + "+"
	lines.append(border)
	for row: int in range(rows):
		var line: String = "|"
		for col: int in range(cols):
			var idx: int = row * cols + col
			line += _cell_char(idx)
		line += "|"
		lines.append(line)
	lines.append(border)
	return "\n".join(lines)


func _cell_char(idx: int) -> String:
	if deaths[idx] > 0:
		return DEATH_CHAR
	if stucks[idx] > 0:
		return STUCK_CHAR
	var value: int = traffic[idx]
	if value <= 0 or max_traffic <= 0:
		return TRAFFIC_CHARS[0]
	if max_traffic == 1:
		return TRAFFIC_CHARS[3]
	var norm: float = float(value) / float(max_traffic)
	var level: int = 1 + int(norm * float(TRAFFIC_CHARS.size() - 1))
	return str(TRAFFIC_CHARS[clampi(level, 1, TRAFFIC_CHARS.size() - 1)])


func to_dict() -> Dictionary:
	return {
		"cols": cols,
		"rows": rows,
		"bounds_min": [snappedf(bounds_min.x, 0.01), snappedf(bounds_min.y, 0.01)],
		"bounds_max": [snappedf(bounds_max.x, 0.01), snappedf(bounds_max.y, 0.01)],
		"traffic": Array(traffic),
		"deaths": Array(deaths),
		"stucks": Array(stucks),
		"max_traffic": max_traffic,
		"total_samples": total_samples,
	}


static func from_dict(data: Dictionary) -> SpatialHeatmap:
	var grid := SpatialHeatmap.new(int(data.get("cols", 40)), int(data.get("rows", 20)))
	var bmin: Array = data.get("bounds_min", [-480.0, -300.0])
	var bmax: Array = data.get("bounds_max", [480.0, 300.0])
	grid.setup(
		int(data.get("cols", 40)),
		int(data.get("rows", 20)),
		Vector2(float(bmin[0]), float(bmin[1])),
		Vector2(float(bmax[0]), float(bmax[1]))
	)
	grid.total_samples = int(data.get("total_samples", 0))
	grid.max_traffic = int(data.get("max_traffic", 0))
	grid.traffic = _load_packed(Array(data.get("traffic", [])), grid.traffic)
	grid.deaths = _load_packed(Array(data.get("deaths", [])), grid.deaths)
	grid.stucks = _load_packed(Array(data.get("stucks", [])), grid.stucks)
	return grid


static func _load_packed(source: Array, target: PackedInt32Array) -> PackedInt32Array:
	for i: int in range(mini(source.size(), target.size())):
		target[i] = int(source[i])
	return target
