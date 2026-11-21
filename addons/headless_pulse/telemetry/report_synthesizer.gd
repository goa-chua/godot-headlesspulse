class_name ReportSynthesizer
extends RefCounted
## Aggregates per-run JSON results into the two agent-facing artifacts:
##   - `report.json`: precise numbers, hotspots, per-weapon stats, A/B diff
##   - `report.md`  : compact (target < 4 KB) ASCII heatmap + anomaly summary
##
## The markdown output is the artifact a coding agent reads; keep it dense.

const SCHEMA: String = "headless_pulse/report/1"
const BUCKET_SECONDS: float = 15.0


static func build(
		config: SimConfig,
		runs: Array[Dictionary],
		wall_seconds: float,
		baseline: Dictionary = {},
		failed: Array[Dictionary] = []
	) -> Dictionary:
	var ok_runs: Array[Dictionary] = []
	for run: Dictionary in runs:
		if str(run.get("status", "")) == "ok":
			ok_runs.append(run)

	var count: int = ok_runs.size()
	var wins: int = 0
	var stuck_runs: int = 0
	var total_sim: float = 0.0
	var end_reasons: Dictionary = {}
	var survival: Array[float] = []
	var kills: Array[float] = []
	var gold: Array[float] = []
	var damage: Array[float] = []
	var dps: Array[float] = []
	var hp_remain: Array[float] = []
	var accuracy: Array[float] = []
	var weapon_damage: Dictionary = {}
	var heatmap := SpatialHeatmap.new(config.grid_cols, config.grid_rows)
	heatmap.setup(config.grid_cols, config.grid_rows, config.bounds_min, config.bounds_max)
	var timeseries_runs: Array = []
	var death_total: int = 0
	var stuck_total: int = 0
	var max_sim: float = 0.0
	var seed_min: int = 2147483647
	var seed_max: int = -2147483648

	for run: Dictionary in ok_runs:
		var sim_time: float = float(run.get("sim_time", 0.0))
		total_sim += sim_time
		max_sim = maxf(max_sim, sim_time)
		survival.append(sim_time)
		if bool(run.get("survived", false)):
			wins += 1
		var seed_value: int = int(run.get("seed", 0))
		seed_min = mini(seed_min, seed_value)
		seed_max = maxi(seed_max, seed_value)
		var reason: String = str(run.get("end_reason", "unknown"))
		end_reasons[reason] = int(end_reasons.get(reason, 0)) + 1

		var player: Dictionary = run.get("player", {})
		var run_damage: float = float(player.get("damage_dealt", 0.0))
		kills.append(float(player.get("kills", 0)))
		gold.append(float(player.get("gold", 0)))
		damage.append(run_damage)
		dps.append(run_damage / sim_time if sim_time > 0.0001 else 0.0)
		hp_remain.append(float(player.get("hp", 0.0)) / maxf(float(player.get("max_hp", 100.0)), 0.001))
		accuracy.append(float(player.get("accuracy", 0.0)))

		var telemetry: Dictionary = run.get("telemetry", {})
		var stuck_block: Dictionary = telemetry.get("stuck", {})
		var run_stuck: int = int(stuck_block.get("count", 0))
		if run_stuck > 0:
			stuck_runs += 1
		stuck_total += run_stuck
		var death_block: Dictionary = telemetry.get("death", {})
		death_total += int(death_block.get("count", 0))

		var per_weapon: Dictionary = telemetry.get("per_weapon", {})
		for weapon_id: String in per_weapon.keys():
			var entry: Dictionary = per_weapon[weapon_id]
			weapon_damage[weapon_id] = float(weapon_damage.get(weapon_id, 0.0)) + float(entry.get("damage", 0.0))

		var grid_dict: Dictionary = telemetry.get("heatmap", {})
		if not grid_dict.is_empty():
			heatmap.merge(SpatialHeatmap.from_dict(grid_dict))

		var ts: Dictionary = telemetry.get("timeseries", {})
		timeseries_runs.append({"samples": ts.get("samples", []), "sim_time": sim_time})

	var win_rate: float = float(wins) / float(count) if count > 0 else 0.0
	var stuck_rate: float = float(stuck_runs) / float(count) if count > 0 else 0.0
	var avg_sim: float = total_sim / float(count) if count > 0 else 0.0
	var speedup: float = total_sim / wall_seconds if wall_seconds > 0.0001 else 0.0

	var weapons: Dictionary = {}
	var total_weapon_damage: float = 0.0
	for weapon_id: String in weapon_damage.keys():
		total_weapon_damage += float(weapon_damage[weapon_id])
	for weapon_id: String in weapon_damage.keys():
		var dealt: float = float(weapon_damage[weapon_id])
		weapons[weapon_id] = {
			"damage": snappedf(dealt, 0.01),
			"share": snappedf(dealt / total_weapon_damage, 0.0001) if total_weapon_damage > 0.0 else 0.0,
			"dps": snappedf(dealt / total_sim, 0.01) if total_sim > 0.0001 else 0.0,
		}

	var determinism: Dictionary = _compute_determinism(ok_runs, config)
	var buckets: Array[Dictionary] = _build_buckets(timeseries_runs, count, max_sim)
	var anomalies: Array[Dictionary] = _detect_anomalies(
		config, win_rate, stuck_rate, count, heatmap, death_total, weapons,
		_median(survival), max_sim, determinism
	)

	var report: Dictionary = {
		"schema": SCHEMA,
		"generated_at": Time.get_datetime_string_from_system(true),
		"engine": str(Engine.get_version_info().get("string", "")),
		"config": config.to_dict(),
		"campaign": {
			"seed_min": seed_min if count > 0 else config.seed,
			"seed_max": seed_max if count > 0 else config.seed,
			"runs_per_seed": config.repeat,
			"total_runs": count,
			"failed_runs": failed.size(),
		},
		"timing": {
			"wall_seconds": snappedf(wall_seconds, 0.001),
			"total_sim_seconds": snappedf(total_sim, 0.01),
			"avg_sim_seconds": snappedf(avg_sim, 0.01),
			"speedup": snappedf(speedup, 0.01),
			"workers": config.resolved_concurrency(),
		},
		"win_rate": snappedf(win_rate, 0.0001),
		"wins": wins,
		"stuck_rate": snappedf(stuck_rate, 0.0001),
		"stuck_runs": stuck_runs,
		"stuck_events": stuck_total,
		"deaths": death_total,
		"end_reasons": end_reasons,
		"survival": {
			"median": snappedf(_median(survival), 0.001),
			"p90": snappedf(_p90(survival), 0.001),
			"min": snappedf(_min(survival), 0.001),
			"max": snappedf(_max(survival), 0.001),
		},
		"player": {
			"kills_median": snappedf(_median(kills), 0.01),
			"kills_p90": snappedf(_p90(kills), 0.01),
			"gold_median": snappedf(_median(gold), 0.01),
			"gold_p90": snappedf(_p90(gold), 0.01),
			"damage_median": snappedf(_median(damage), 0.01),
			"dps_median": snappedf(_median(dps), 0.01),
			"dps_p90": snappedf(_p90(dps), 0.01),
			"hp_remaining_median": snappedf(_median(hp_remain), 0.0001),
			"accuracy_median": snappedf(_median(accuracy), 0.0001),
		},
		"weapons": weapons,
		"anomalies": anomalies,
		"heatmap": heatmap.to_dict(),
		"hotspots": {
			"deaths": heatmap.hotspots(heatmap.deaths, 5),
			"stucks": heatmap.hotspots(heatmap.stucks, 5),
			"traffic": heatmap.top_traffic(5),
		},
		"timeseries": {
			"bucket_seconds": BUCKET_SECONDS,
			"buckets": buckets,
		},
		"determinism": determinism,
		"failed": failed,
	}
	if not baseline.is_empty():
		report["ab_diff"] = _ab_diff(report, baseline)
	return report


# --- aggregation helpers ---------------------------------------------------

static func _compute_determinism(runs: Array[Dictionary], config: SimConfig) -> Dictionary:
	var by_seed: Dictionary = {}
	for run: Dictionary in runs:
		var seed_value: int = int(run.get("seed", 0))
		var digest: String = str(run.get("determinism", {}).get("digest", ""))
		if not by_seed.has(seed_value):
			by_seed[seed_value] = []
		(by_seed[seed_value] as Array).append(digest)

	var checked: bool = false
	var mismatches: Array[Dictionary] = []
	for seed_value: int in by_seed.keys():
		var digests: Array = by_seed[seed_value]
		if digests.size() < 2:
			continue
		checked = true
		var first: String = str(digests[0])
		for i: int in range(1, digests.size()):
			if str(digests[i]) != first:
				mismatches.append({"seed": seed_value, "digests": digests})
				break

	return {
		"checked": checked and config.determinism_check,
		"repeat": config.repeat,
		"seeds": by_seed.size(),
		"identical": mismatches.is_empty(),
		"mismatches": mismatches,
	}


static func _build_buckets(timeseries_runs: Array, run_count: int, max_sim: float) -> Array[Dictionary]:
	var buckets: Array[Dictionary] = []
	if run_count <= 0 or max_sim <= 0.0001:
		return buckets
	var bucket_count: int = int(ceil(max_sim / BUCKET_SECONDS))
	for bucket_index: int in range(bucket_count):
		var bucket_end: float = float(bucket_index + 1) * BUCKET_SECONDS
		var hp_values: Array[float] = []
		var gold_values: Array[float] = []
		var dps_values: Array[float] = []
		var enemy_values: Array[float] = []
		var alive_count: int = 0
		for entry: Dictionary in timeseries_runs:
			# Runs that already ended before this bucket count as dead: they must
			# not be reported as 100% alive in later buckets.
			if float(entry.get("sim_time", 0.0)) < bucket_end - 0.0001:
				continue
			var samples: Array = entry.get("samples", [])
			var chosen: Dictionary = {}
			for sample: Dictionary in samples:
				if float(sample.get("t", 0.0)) <= bucket_end + 0.0001:
					chosen = sample
				else:
					break
			if chosen.is_empty():
				continue
			if bool(chosen.get("alive", false)):
				alive_count += 1
			hp_values.append(float(chosen.get("hp_frac", 0.0)))
			gold_values.append(float(chosen.get("gold", 0.0)))
			dps_values.append(float(chosen.get("dps", 0.0)))
			enemy_values.append(float(chosen.get("enemies", 0.0)))

		if hp_values.is_empty():
			buckets.append({
				"t": bucket_end,
				"alive_frac": 0.0,
				"hp_median": 0.0,
				"hp_p90": 0.0,
				"gold_median": 0.0,
				"dps_median": 0.0,
				"enemies_median": 0.0,
			})
			continue
		buckets.append({
			"t": bucket_end,
			"alive_frac": snappedf(float(alive_count) / float(run_count), 0.0001),
			"hp_median": snappedf(_median(hp_values), 0.0001),
			"hp_p90": snappedf(_p90(hp_values), 0.0001),
			"gold_median": snappedf(_median(gold_values), 0.01),
			"dps_median": snappedf(_median(dps_values), 0.01),
			"enemies_median": snappedf(_median(enemy_values), 0.01),
		})
	return buckets


static func _detect_anomalies(
		config: SimConfig,
		win_rate: float,
		stuck_rate: float,
		run_count: int,
		heatmap: SpatialHeatmap,
		death_total: int,
		weapons: Dictionary,
		median_survival: float,
		max_sim: float,
		determinism: Dictionary
	) -> Array[Dictionary]:
	var anomalies: Array[Dictionary] = []
	if run_count <= 0:
		anomalies.append({
			"severity": "CRITICAL",
			"code": "no_runs",
			"message": "No successful simulation runs were produced.",
			"suggestion": "Run a single worker manually to see the error: godot --headless res://.../arena.tscn -- --sim-mode --sim-seed=1000",
		})
		return anomalies

	if bool(determinism.get("checked", false)) and not bool(determinism.get("identical", true)):
		anomalies.append({
			"severity": "CRITICAL",
			"code": "nondeterministic",
			"message": "Same seed produced different run digests: %s" % str(determinism.get("mismatches", [])),
			"suggestion": "Find unseeded randomness (global randf/RandomNumberGenerator) or wall-clock time in simulation logic.",
		})

	if stuck_rate > config.stuck_rate_warn:
		var top: Array[Dictionary] = heatmap.hotspots(heatmap.stucks, 1)
		var where: String = "unknown area"
		if not top.is_empty():
			where = "near (x: %.0f, y: %.0f)" % [float(top[0]["pos"][0]), float(top[0]["pos"][1])]
		anomalies.append({
			"severity": "CRITICAL",
			"code": "stuck_cluster",
			"message": "%.1f%% of runs got stuck (%d/%d), most stuck events %s." % [
				stuck_rate * 100.0, int(round(stuck_rate * run_count)), run_count, where],
			"data": {"hotspots": top},
			"suggestion": "Fix navigation at that spot (add avoidance/steering) or widen the corridor; the ASCII map marks it with '!'.",
		})

	if death_total >= 3:
		var death_top: Array[Dictionary] = heatmap.hotspots(heatmap.deaths, 1)
		if not death_top.is_empty():
			var share: float = float(death_top[0]["count"]) / float(death_total)
			if share > 0.3:
				anomalies.append({
					"severity": "WARNING",
					"code": "death_cluster",
					"message": "%.0f%% of deaths happened near (x: %.0f, y: %.0f)." % [
						share * 100.0, float(death_top[0]["pos"][0]), float(death_top[0]["pos"][1])],
					"data": {"hotspots": death_top, "deaths": death_total},
					"suggestion": "Playtest that encounter location; it may be an unavoidable damage source or an unfair spawn.",
				})

	if win_rate < config.win_rate_target_min:
		anomalies.append({
			"severity": "WARNING",
			"code": "too_hard",
			"message": "Win rate %.1f%% is below the %.1f%%..%.1f%% target band." % [
				win_rate * 100.0, config.win_rate_target_min * 100.0, config.win_rate_target_max * 100.0],
			"suggestion": "Reduce enemy damage/HP or wave size: res://addons/headless_pulse/examples/arena_2d/arena.gd exports.",
		})
	elif win_rate > config.win_rate_target_max:
		anomalies.append({
			"severity": "WARNING",
			"code": "too_easy",
			"message": "Win rate %.1f%% is above the %.1f%%..%.1f%% target band." % [
				win_rate * 100.0, config.win_rate_target_min * 100.0, config.win_rate_target_max * 100.0],
			"suggestion": "Increase enemy pressure (wave_scale / enemy_base_hp) in the arena config.",
		})

	if weapons.size() >= 2:
		var ids: Array = weapons.keys()
		var max_dps: float = 0.0
		var min_dps: float = INF
		var max_id: String = ""
		var min_id: String = ""
		for weapon_id: String in ids:
			var value: float = float(weapons[weapon_id].get("dps", 0.0))
			if value > max_dps:
				max_dps = value
				max_id = weapon_id
			if value < min_dps:
				min_dps = value
				min_id = weapon_id
		if min_dps > 0.0001 and max_dps / min_dps > config.weapon_dps_ratio_warn:
			anomalies.append({
				"severity": "WARNING",
				"code": "weapon_imbalance",
				"message": "Weapon imbalance: '%s' deals %.1fx the DPS of '%s'." % [
					max_id, max_dps / min_dps, min_id],
				"data": {"weapons": weapons},
				"suggestion": "Adjust .tres balance (damage/fire_interval/pellets) for '%s' vs '%s'."
						% [max_id, min_id],
			})

	if run_count >= 3 and median_survival < max_sim * 0.35:
		anomalies.append({
			"severity": "WARNING",
			"code": "runs_end_early",
			"message": "Median survival is %.1fs of a %.0fs budget (%.0f%%)." % [
				median_survival, max_sim, median_survival / max_sim * 100.0],
			"suggestion": "Early deaths dominate the sample; check wave ramp-up and player sustain.",
		})

	return anomalies


static func _ab_diff(report: Dictionary, baseline: Dictionary) -> Dictionary:
	var diff: Dictionary = {}
	diff["baseline_generated_at"] = baseline.get("generated_at", "")
	var keys: Array[String] = [
		"win_rate", "stuck_rate", "stuck_events", "deaths",
	]
	for key: String in keys:
		var before: float = float(baseline.get(key, 0.0))
		var now: float = float(report.get(key, 0.0))
		diff[key] = {"baseline": before, "current": now, "delta": snappedf(now - before, 0.0001)}
	diff["survival_median"] = {
		"baseline": float(baseline.get("survival", {}).get("median", 0.0)),
		"current": float(report.get("survival", {}).get("median", 0.0)),
	}
	diff["survival_median"]["delta"] = snappedf(
		diff["survival_median"]["current"] - diff["survival_median"]["baseline"], 0.001)
	diff["dps_median"] = {
		"baseline": float(baseline.get("player", {}).get("dps_median", 0.0)),
		"current": float(report.get("player", {}).get("dps_median", 0.0)),
	}
	diff["dps_median"]["delta"] = snappedf(
		diff["dps_median"]["current"] - diff["dps_median"]["baseline"], 0.01)

	var weapon_diff: Dictionary = {}
	var before_weapons: Dictionary = baseline.get("weapons", {})
	var now_weapons: Dictionary = report.get("weapons", {})
	for weapon_id: String in now_weapons.keys():
		var now_share: float = float(now_weapons[weapon_id].get("share", 0.0))
		var before_share: float = float(before_weapons.get(weapon_id, {}).get("share", 0.0))
		weapon_diff[weapon_id] = {
			"share_baseline": before_share,
			"share_current": now_share,
			"share_delta": snappedf(now_share - before_share, 0.0001),
		}
	diff["weapons"] = weapon_diff
	return diff


# --- markdown --------------------------------------------------------------

static func render_markdown(report: Dictionary) -> String:
	var config: Dictionary = report.get("config", {})
	var campaign: Dictionary = report.get("campaign", {})
	var timing: Dictionary = report.get("timing", {})
	var survival: Dictionary = report.get("survival", {})
	var player: Dictionary = report.get("player", {})
	var heatmap_dict: Dictionary = report.get("heatmap", {})
	var heatmap: SpatialHeatmap = SpatialHeatmap.from_dict(heatmap_dict)
	var lines: PackedStringArray = PackedStringArray()

	lines.append("# Simulation Balance Report")
	lines.append("")
	lines.append("- **Config**: `%s` (%s)" % [str(config.get("scene_path", "?")), str(config.get("name", "?"))])
	lines.append("- **Runs**: %d (Seed: %d..%d) | **Real Wall Time**: %.2fs | **Avg Sim Time/Run**: %.1fs (%.0fx Speedup)" % [
		int(campaign.get("total_runs", 0)),
		int(campaign.get("seed_min", 0)),
		int(campaign.get("seed_max", 0)),
		float(timing.get("wall_seconds", 0.0)),
		float(timing.get("avg_sim_seconds", 0.0)),
		float(timing.get("speedup", 0.0)),
	])
	lines.append("- **Win Rate**: %.1f%% (%d/%d) | **Stuck Rate**: %.1f%% (%d/%d) | **Median Survival**: %.1fs" % [
		float(report.get("win_rate", 0.0)) * 100.0,
		int(report.get("wins", 0)),
		int(campaign.get("total_runs", 0)),
		float(report.get("stuck_rate", 0.0)) * 100.0,
		int(report.get("stuck_runs", 0)),
		int(campaign.get("total_runs", 0)),
		float(survival.get("median", 0.0)),
	])
	if int(campaign.get("failed_runs", 0)) > 0:
		lines.append("- **Failed runs**: %d (see `failed` in report.json)" % int(campaign.get("failed_runs", 0)))
	lines.append("")

	# 1. anomalies
	lines.append("## 1. Anomalies & Bottlenecks (Auto-Detected)")
	var anomalies: Array = report.get("anomalies", [])
	if anomalies.is_empty():
		lines.append("- None detected.")
	else:
		for anomaly: Dictionary in anomalies:
			var line: String = "- [%s] **%s**: %s" % [
				str(anomaly.get("severity", "INFO")),
				_code_title(str(anomaly.get("code", "issue"))),
				str(anomaly.get("message", "")),
			]
			lines.append(line)
			var suggestion: String = str(anomaly.get("suggestion", ""))
			if not suggestion.is_empty():
				lines.append("  - _Fix_: %s" % suggestion)
	lines.append("")

	# 2. heatmap
	var bounds_min: Array = heatmap_dict.get("bounds_min", [-480.0, -300.0])
	var bounds_max: Array = heatmap_dict.get("bounds_max", [480.0, 300.0])
	lines.append("## 2. Spatial Heatmap (World Bounds: X[%.0f, %.0f], Y[%.0f, %.0f], Grid: %dx%d)" % [
		float(bounds_min[0]), float(bounds_max[0]),
		float(bounds_min[1]), float(bounds_max[1]),
		int(heatmap_dict.get("cols", 0)), int(heatmap_dict.get("rows", 0)),
	])
	lines.append("Legend: `.` low | `:` medium | `+` high | `#` peak traffic | `X` death | `!` stuck")
	lines.append("```text")
	lines.append(heatmap.render_ascii())
	lines.append("```")
	lines.append("")

	# 3. time series
	lines.append("## 3. Time-Series Progression (Bucketed every %.0fs, Median / P90)" % BUCKET_SECONDS)
	lines.append("| Time | Alive% | Player HP% | Gold (Med) | DPS (Med) | Enemy Count |")
	lines.append("|------|--------|------------|------------|-----------|-------------|")
	for bucket: Dictionary in report.get("timeseries", {}).get("buckets", []):
		lines.append("| %02ds | %.0f%% | %.0f%% / %.0f%% | %.0f | %.0f | %.1f |" % [
			int(bucket.get("t", 0.0)),
			float(bucket.get("alive_frac", 0.0)) * 100.0,
			float(bucket.get("hp_median", 0.0)) * 100.0,
			float(bucket.get("hp_p90", 0.0)) * 100.0,
			float(bucket.get("gold_median", 0.0)),
			float(bucket.get("dps_median", 0.0)),
			float(bucket.get("enemies_median", 0.0)),
		])
	lines.append("")

	# 4. weapons
	var weapons: Dictionary = report.get("weapons", {})
	lines.append("## 4. Weapon Balance")
	if weapons.is_empty():
		lines.append("- No per-weapon damage recorded (call `SimTelemetry.record_metric(\"damage_dealt\", dmg, {\"weapon\": id})`).")
	else:
		lines.append("| Weapon | Damage | Share | DPS |")
		lines.append("|--------|--------|-------|-----|")
		var ids: Array = weapons.keys()
		ids.sort()
		for weapon_id: String in ids:
			var entry: Dictionary = weapons[weapon_id]
			lines.append("| %s | %.0f | %.1f%% | %.1f |" % [
				weapon_id,
				float(entry.get("damage", 0.0)),
				float(entry.get("share", 0.0)) * 100.0,
				float(entry.get("dps", 0.0)),
			])
	lines.append("")

	# 5. determinism
	var determinism: Dictionary = report.get("determinism", {})
	lines.append("## 5. Determinism")
	if bool(determinism.get("checked", false)):
		if bool(determinism.get("identical", true)):
			lines.append("- repeat=%d: **identical SHA-256 digest** for every seed (bit-exact)." % int(determinism.get("repeat", 1)))
		else:
			lines.append("- repeat=%d: **MISMATCH** %s" % [
				int(determinism.get("repeat", 1)), str(determinism.get("mismatches", []))])
	else:
		lines.append("- Not checked (set `--sim-repeat=2` to verify).")
	lines.append("")

	# 6. hotspots
	lines.append("## 6. Hotspots")
	var hotspots: Dictionary = report.get("hotspots", {})
	lines.append("- Deaths: %s" % _hotspot_text(hotspots.get("deaths", []), report.get("deaths", 0)))
	lines.append("- Stuck: %s" % _hotspot_text(hotspots.get("stucks", []), report.get("stuck_events", 0)))
	lines.append("- Player stats: kills median %.0f / p90 %.0f | gold median %.0f | accuracy %.0f%% | DPS median %.0f" % [
		float(player.get("kills_median", 0.0)),
		float(player.get("kills_p90", 0.0)),
		float(player.get("gold_median", 0.0)),
		float(player.get("accuracy_median", 0.0)) * 100.0,
		float(player.get("dps_median", 0.0)),
	])
	lines.append("")

	# 7. A/B diff
	if report.has("ab_diff"):
		lines.append("## 7. A/B Diff vs Baseline")
		var diff: Dictionary = report["ab_diff"]
		lines.append("| Metric | Baseline | Current | Delta |")
		lines.append("|--------|----------|---------|-------|")
		for key: String in ["win_rate", "stuck_rate", "stuck_events", "deaths"]:
			if diff.has(key):
				var entry: Dictionary = diff[key]
				lines.append("| %s | %.3f | %.3f | %+.3f |" % [
					key, float(entry.get("baseline", 0.0)),
					float(entry.get("current", 0.0)), float(entry.get("delta", 0.0))])
		var sm: Dictionary = diff.get("survival_median", {})
		lines.append("| survival_median | %.1fs | %.1fs | %+.1fs |" % [
			float(sm.get("baseline", 0.0)), float(sm.get("current", 0.0)), float(sm.get("delta", 0.0))])
		var dm: Dictionary = diff.get("dps_median", {})
		lines.append("| dps_median | %.1f | %.1f | %+.1f |" % [
			float(dm.get("baseline", 0.0)), float(dm.get("current", 0.0)), float(dm.get("delta", 0.0))])
		lines.append("")

	return "\n".join(lines)


static func _code_title(code: String) -> String:
	var titles: Dictionary = {
		"stuck_cluster": "Stuck Cluster",
		"death_cluster": "Death Hotspot",
		"weapon_imbalance": "Weapon Imbalance",
		"too_hard": "Difficulty Too High",
		"too_easy": "Difficulty Too Low",
		"runs_end_early": "Runs End Early",
		"nondeterministic": "NON-DETERMINISTIC",
		"no_runs": "No Runs",
	}
	return str(titles.get(code, code))


static func _hotspot_text(entries: Array, total: int) -> String:
	if entries.is_empty():
		return "none (0 events)"
	var parts: PackedStringArray = PackedStringArray()
	for entry: Dictionary in entries:
		var pos: Array = entry.get("pos", [0.0, 0.0])
		parts.append("(%.0f, %.0f)x%d" % [float(pos[0]), float(pos[1]), int(entry.get("count", 0))])
	return "%d total | top: %s" % [total, ", ".join(parts)]


# --- statistics ------------------------------------------------------------

static func _sorted(values: Array[float]) -> Array[float]:
	var copy: Array[float] = values.duplicate()
	copy.sort()
	return copy


static func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var arr: Array[float] = _sorted(values)
	var mid: int = arr.size() / 2
	if arr.size() % 2 == 1:
		return arr[mid]
	return (arr[mid - 1] + arr[mid]) * 0.5


static func _p90(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var arr: Array[float] = _sorted(values)
	var rank: int = int(ceil(0.9 * float(arr.size()))) - 1
	return arr[clampi(rank, 0, arr.size() - 1)]


static func _min(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var result: float = values[0]
	for value: float in values:
		result = minf(result, value)
	return result


static func _max(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var result: float = values[0]
	for value: float in values:
		result = maxf(result, value)
	return result
