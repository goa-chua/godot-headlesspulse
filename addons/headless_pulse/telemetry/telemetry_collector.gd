extends Node
## SimTelemetry autoload: zero-cost run recorder.
##
## In a normal (non-simulation) game run every method below returns immediately,
## so gameplay code can call it without a single branch or allocation. In
## simulation mode it records:
##   - structured events (death / kill / stuck / custom),
##   - metrics (optionally tagged, e.g. per weapon),
##   - sampled positions for the spatial heatmap,
##   - a fixed-interval time series (HP / DPS / gold / enemy count),
##   - stuck episodes from [StuckDetector].
##
## Game code only needs the two public entry points:
## [codeblock]
## SimTelemetry.record_event("player_death", {"cause": "contact", "wave": 3})
## SimTelemetry.record_metric("damage_dealt", 12.0, {"weapon": "smg"})
## [/codeblock]

const DPS_WINDOW_SECONDS: float = 3.0
const MAX_EVENT_DETAILS: int = 4000
const MAX_STUCK_RECORDS: int = 200

var _active: bool = false
var _config: SimConfig = null
var _runtime: Node = null
var _rng: SimRNG = null

var _events: Dictionary = {}
var _event_details: Array[Dictionary] = []
var _metrics: Dictionary = {}
var _metrics_by_tag: Dictionary = {}
var _positions: PackedVector2Array = PackedVector2Array()
var _death_positions: PackedVector2Array = PackedVector2Array()
var _stuck_positions: PackedVector2Array = PackedVector2Array()
var _death_records: Array[Dictionary] = []
var _stuck_records: Array[Dictionary] = []
var _timeseries: Array[Dictionary] = []
var _dps_history: Array[Dictionary] = []
var _stuck_detector: StuckDetector = null
var _sample_accum: float = 0.0
var _total_damage: float = 0.0
var _observed_min: Vector2 = Vector2(INF, INF)
var _observed_max: Vector2 = Vector2(-INF, -INF)
var _has_last_pos: bool = false


func is_active() -> bool:
	return _active


## Called once by SimRuntime when a simulated run starts.
func begin(runtime: Node, config: SimConfig, rng: SimRNG) -> void:
	_runtime = runtime
	_config = config
	_rng = rng
	_events.clear()
	_event_details.clear()
	_metrics.clear()
	_metrics_by_tag.clear()
	_positions = PackedVector2Array()
	_death_positions = PackedVector2Array()
	_stuck_positions = PackedVector2Array()
	_death_records.clear()
	_stuck_records.clear()
	_timeseries.clear()
	_dps_history.clear()
	_sample_accum = 0.0
	_total_damage = 0.0
	_observed_min = Vector2(INF, INF)
	_observed_max = Vector2(-INF, -INF)
	_has_last_pos = false
	_stuck_detector = StuckDetector.new(config.stuck_window_seconds, config.stuck_move_threshold)
	_active = true


# --- public API used by gameplay code --------------------------------------

func record_event(name: String, data: Dictionary = {}) -> void:
	if not _active:
		return
	_events[name] = int(_events.get(name, 0)) + 1
	if name == "player_death":
		var pos: Array = data.get("pos", [0.0, 0.0])
		record_death(Vector2(float(pos[0]), float(pos[1])), str(data.get("cause", "unknown")), int(data.get("wave", 0)))
	if _event_details.size() < MAX_EVENT_DETAILS:
		var entry: Dictionary = {
			"name": name,
			"t": snappedf(_sim_time(), 0.001),
		}
		if not data.is_empty():
			entry["data"] = data.duplicate(true)
		_event_details.append(entry)


func record_metric(name: String, value: float, tags: Dictionary = {}) -> void:
	if not _active:
		return
	_metrics[name] = float(_metrics.get(name, 0.0)) + value
	if name == "damage_dealt":
		_total_damage += value
	if not tags.is_empty():
		if not _metrics_by_tag.has(name):
			_metrics_by_tag[name] = {}
		var bucket: Dictionary = _metrics_by_tag[name]
		for tag_key: String in tags.keys():
			var key: String = "%s=%s" % [tag_key, str(tags[tag_key])]
			bucket[key] = float(bucket.get(key, 0.0)) + value


func record_death(world_pos: Vector2, cause: String, wave: int = 0) -> void:
	if not _active:
		return
	_death_positions.append(world_pos)
	_death_records.append({
		"pos": [snappedf(world_pos.x, 0.1), snappedf(world_pos.y, 0.1)],
		"t": snappedf(_sim_time(), 0.001),
		"cause": cause,
		"wave": wave,
	})


func record_stuck(world_pos: Vector2, sim_time: float) -> void:
	if not _active:
		return
	_stuck_positions.append(world_pos)
	if _stuck_records.size() < MAX_STUCK_RECORDS:
		_stuck_records.append({
			"pos": [snappedf(world_pos.x, 0.1), snappedf(world_pos.y, 0.1)],
			"t": snappedf(sim_time, 0.001),
		})


func death_count() -> int:
	return _death_positions.size()


func stuck_count() -> int:
	return _stuck_positions.size()


func event_count(name: String) -> int:
	return int(_events.get(name, 0))


func total_damage() -> float:
	return _total_damage


## Advance sampling / stuck detection; called every fixed physics tick by SimRuntime.
func tick(delta: float, player: Node, enemy_count: int, bullet_count: int) -> void:
	if not _active:
		return

	var pos: Vector2 = Vector2.ZERO
	var has_player: bool = player != null and is_instance_valid(player)
	var intent: float = 1.0
	if has_player:
		pos = (player as Node2D).global_position
		intent = float(_prop(player, "move_intent", 1.0))
		_observed_min = Vector2(minf(_observed_min.x, pos.x), minf(_observed_min.y, pos.y))
		_observed_max = Vector2(maxf(_observed_max.x, pos.x), maxf(_observed_max.y, pos.y))
		_has_last_pos = true
		if _stuck_detector != null and _stuck_detector.tick(_sim_time(), pos, intent):
			record_stuck(pos, _sim_time())

	_sample_accum += delta
	if _sample_accum + 0.000001 < _config.sample_interval:
		return
	_sample_accum = 0.0
	if has_player:
		_positions.append(pos)
	_sample(_sim_time(), player, enemy_count, bullet_count)


func _sample(time: float, player: Node, enemy_count: int, bullet_count: int) -> void:
	var hp: float = 0.0
	var max_hp: float = 100.0
	var alive: bool = false
	var kills: int = 0
	var gold: int = 0
	var weapon: String = ""
	if player != null and is_instance_valid(player):
		hp = float(_prop(player, "hp", 0.0))
		max_hp = maxf(float(_prop(player, "max_hp", 100.0)), 0.0001)
		alive = bool(_prop(player, "is_alive", true)) and hp > 0.0
		kills = int(_prop(player, "kills", 0))
		gold = int(_prop(player, "gold", 0))
		weapon = str(_prop(player, "weapon_id", ""))

	var damage: float = float(_metrics.get("damage_dealt", 0.0))
	_dps_history.append({"t": time, "damage": damage})
	while _dps_history.size() > 2 and time - float(_dps_history[0]["t"]) > DPS_WINDOW_SECONDS:
		_dps_history.pop_front()
	var dps: float = 0.0
	if _dps_history.size() >= 2:
		var first: Dictionary = _dps_history[0]
		var span: float = time - float(first["t"])
		if span > 0.0001:
			dps = (damage - float(first["damage"])) / span

	_timeseries.append({
		"t": snappedf(time, 0.001),
		"hp": snappedf(hp, 0.01),
		"hp_frac": snappedf(clampf(hp / max_hp, 0.0, 1.0), 0.0001),
		"alive": alive,
		"kills": kills,
		"gold": gold,
		"damage": snappedf(damage, 0.01),
		"dps": snappedf(dps, 0.01),
		"enemies": enemy_count,
		"bullets": bullet_count,
		"weapon": weapon,
	})


## Build the telemetry block of the run result (called once at end of run).
func finish() -> Dictionary:
	if not _active:
		return {}
	var bounds_min: Vector2 = _config.bounds_min
	var bounds_max: Vector2 = _config.bounds_max
	if _config.auto_bounds and _has_last_pos:
		bounds_min = _observed_min
		bounds_max = _observed_max
		var pad: Vector2 = (bounds_max - bounds_min) * 0.08
		pad.x = maxf(pad.x, 8.0)
		pad.y = maxf(pad.y, 8.0)
		bounds_min -= pad
		bounds_max += pad

	var grid := SpatialHeatmap.new(_config.grid_cols, _config.grid_rows)
	grid.setup(_config.grid_cols, _config.grid_rows, bounds_min, bounds_max)
	for pos: Vector2 in _positions:
		grid.add_traffic(pos)
	for pos: Vector2 in _death_positions:
		grid.add_death(pos)
	for pos: Vector2 in _stuck_positions:
		grid.add_stuck(pos)

	var weapon_totals: Dictionary = _metrics_by_tag.get("damage_dealt", {})
	var total: float = float(_metrics.get("damage_dealt", 0.0))
	var per_weapon: Dictionary = {}
	for key: String in weapon_totals.keys():
		var parts: PackedStringArray = key.split("=", true, 1)
		var weapon: String = parts[1] if parts.size() > 1 else key
		var value: float = float(weapon_totals[key])
		per_weapon[weapon] = {
			"damage": snappedf(value, 0.01),
			"share": snappedf(value / total, 0.0001) if total > 0.0 else 0.0,
		}

	return {
		"events": _events.duplicate(),
		"event_log": _event_details.duplicate(true),
		"metrics": _metrics.duplicate(),
		"metrics_by_tag": _metrics_by_tag.duplicate(true),
		"per_weapon": per_weapon,
		"damage_dealt": snappedf(total, 0.01),
		"death": {
			"count": _death_positions.size(),
			"positions": _pos_array(_death_positions),
			"records": _death_records.duplicate(true),
		},
		"stuck": {
			"count": _stuck_positions.size(),
			"positions": _pos_array(_stuck_positions),
			"records": _stuck_records.duplicate(true),
		},
		"heatmap": grid.to_dict(),
		"timeseries": {
			"interval": _config.sample_interval,
			"samples": _timeseries.duplicate(true),
		},
		"observed_bounds": {
			"min": [snappedf(_observed_min.x, 0.1), snappedf(_observed_min.y, 0.1)] if _has_last_pos else [0.0, 0.0],
			"max": [snappedf(_observed_max.x, 0.1), snappedf(_observed_max.y, 0.1)] if _has_last_pos else [0.0, 0.0],
		},
		"samples": _timeseries.size(),
	}


func _sim_time() -> float:
	if _runtime != null and _runtime.has_method("get_sim_time"):
		return _runtime.get_sim_time()
	return 0.0


static func _prop(node: Object, name: String, fallback: Variant) -> Variant:
	if node == null:
		return fallback
	var value: Variant = node.get(name)
	return fallback if value == null else value


static func _pos_array(points: PackedVector2Array) -> Array:
	var out: Array = []
	for p: Vector2 in points:
		out.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	return out
