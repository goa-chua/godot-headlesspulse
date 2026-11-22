# Godot HeadlessPulse

[简体中文](README.md) | **English**

[![GitHub](https://img.shields.io/badge/GitHub-goa--chua%2Fgodot--headlesspulse-181717?logo=github)](https://github.com/goa-chua/godot-headlesspulse)
[![CI](https://github.com/goa-chua/godot-headlesspulse/actions/workflows/ci.yml/badge.svg)](https://github.com/goa-chua/godot-headlesspulse/actions/workflows/ci.yml)
[![Godot](https://img.shields.io/badge/Godot-4.7-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Status](https://img.shields.io/badge/status-M1--M6%20verified-brightgreen)](#roadmap)
[![Release](https://img.shields.io/github/v/release/goa-chua/godot-headlesspulse?display_name=tag&sort=semver)](https://github.com/goa-chua/godot-headlesspulse/releases)
[![Changelog](https://img.shields.io/badge/changelog-v0.1.0-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)](#known-limitations)

> A **headless, deterministic, high-speed simulation and balance-telemetry** addon for Godot 4.7.
> Cheap heuristic bots do the grinding; dense structured telemetry feeds the LLM.

It compresses "100 runs × 60 seconds" of game logic into **a few seconds** of wall time and
**one 2.5 KB ASCII/JSON report**, so a coding agent can spot stuck points, balance skew and
weapon imbalances, edit the `.tres`, and re-run an A/B regression.

**Repository**: <https://github.com/goa-chua/godot-headlesspulse>

---

## Table of contents

- [Highlights](#highlights)
- [Measured results](#measured-results)
- [When to use it](#when-to-use-it)
- [Quick start](#quick-start)
- [Sample report](#sample-report)
- [Common workflows](#common-workflows)
- [CLI reference](#cli-reference)
- [Onboarding a real game](#onboarding-a-real-game)
- [Data contracts](#data-contracts)
- [Architecture and layout](#architecture-and-layout)
- [FAQ](#faq)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Highlights

| Capability | What it gives you |
|---|---|
| **Deterministic fast-forward** | `--fixed-fps 60` disables real-time sync, so `delta` is exactly `1/60`; 1 frame = 1 physics step. Per-tick SHA-256 proves **bit-exact** reproducibility for a seed. |
| **Actually fast** | No `Engine.time_scale` hacks (which drop physics steps, tunnel through geometry and stay wall-clock bound). ~195x per run, ~1400-1450x aggregate for a campaign. |
| **Batched multi-process** | Each process runs a batch of seeds sequentially (auto-chunked), amortising engine start-up and thread-pool cost; `SimOrchestrator` spawns via `OS.create_process` and reaps via `is_process_running`. Workers only write files, never rely on stdout pipes. |
| **Zero intrusion** | Without `--sim-mode`, `SimRuntime` disables its own processing and every `SimTelemetry` method returns immediately — **zero cost** in the shipping game. |
| **Virtual input and aim** | `SimInputProxy` injects through the real `Input` singleton; headless has no cursor, so `SimRuntime.get_aim_world_position()` provides virtual aiming. |
| **Agent-friendly output** | A 2.5 KB ASCII spatial heatmap plus structured JSON; every anomaly carries a `_Fix_` suggestion and world coordinates that map back to `.tres` fields. |
| **A/B testing** | `--sim-set=<res>\|<prop>=<val>` overrides balance resources without editing files; `--sim-baseline` renders a before/after diff table. |
| **Editor dock** | Configure, run concurrently, watch progress, preview ASCII, copy for an AI agent, replay a seed at 1x. |
| **Reproducible verification** | `tools/verify.ps1` checks determinism, stuck detection, throughput, report size and repeat-determinism in one command. |

---

## Measured results

> Environment: Windows 11, 24 logical cores, Godot **4.7.2.stable.steam**, demo arena `arena_2d`,
> 60 simulated seconds per run (3600 ticks), seeds 1000..1049. Numbers scale with CPU and scene
> complexity; on shared or power-limited machines the throughput varies (the table gives the measured range).

| Metric | Result |
|---|---|
| Single run, 60 s of logic (3600 ticks) | **~0.28 s internally → ~195x**; ~0.56 s process wall time incl. engine boot |
| 50 runs × 60 s campaign | **1.9-2.0 s** internal → **~1400-1450x aggregate speedup** |
| Batched workers | 50 runs auto-split into 17 workers (3 runs each sequentially) instead of 50 engine boots |
| Worker thread pool impact | each process reserves `cores-1` worker threads by default (24 cores = 23 threads/process), so 20+ concurrent workers compete; with `threading/worker_pool/max_threads=1` 50 runs went 6.5 s → 3.4 s, and batching takes it to **≈1.9 s** |
| Determinism (same seed twice) | digest, final position, kills and HP **identical** |
| Repeat-determinism (20 seeds × 2) | 40 runs, **0 mismatches** (and batch=1/3/5 produce identical per-seed digests) |
| Stuck detection | wall-pusher bot flagged at **t = 4.03 s**, position `(-269, 33)` |
| Empty-scene ceiling | 3600 ticks in 0.0055 s ≈ **10,860x** |
| Report size | `report.md` **2.5 KB** (40×20 grid, budget < 4 KB) |
| Demo balance | 48% win rate, 4% stuck rate, median survival 59.7 s |

How to reproduce: see "One-command verification" under [Common workflows](#common-workflows).

---

## When to use it

**Good fit:**

- Balance validation for **tick- or turn-driven** gameplay (action, roguelike, tower defense, strategy);
- **A/B regressions** after number changes (win rate, survival time, DPS, economy curves);
- Locating **stuck / wedged / navigation** problems caused by level geometry;
- Letting a coding agent autonomously loop "run → read report → tweak numbers → regress" locally or in CI.

**Poor fit:**

- Pure visual, animation or UI issues (this tool does not render or screenshot);
- Validating real player feel, network sync or other nondeterministic external dependencies;
- Real-time performance profiling (simulation deliberately detaches from wall-clock time).

---

## Quick start

Requires **Godot 4.7+** (standard or Steam build). The CLI is cross-platform; scripts below use Windows PowerShell.

### 0. Get the code

```powershell
git clone https://github.com/goa-chua/godot-headlesspulse.git
cd godot-headlesspulse
```

### 1. Install the addon

Copy `addons/headless_pulse/` into your project, then either:

- Editor: Project Settings → Plugins → enable **Godot HeadlessPulse** (gives you the dock), or
- CLI-only: add just the two autoloads (**order matters**, `SimRuntime` resolves the telemetry singleton):

```ini
[autoload]
SimTelemetry="*res://addons/headless_pulse/telemetry/telemetry_collector.gd"
SimRuntime="*res://addons/headless_pulse/core/sim_runtime.gd"
```

> After adding or renaming any `class_name`, re-import to refresh the script class cache:
> `godot --headless --import --path .`

> **Batch-simulation tips:**
> 1. Set `threading/worker_pool/max_threads=1` in the project used for campaigns. Every Godot
>    process reserves `cores-1` worker threads by default (23 per process on a 24-core box), so
>    20+ concurrent workers mean 500+ threads fighting for CPU; measured 50-run campaign 6.5 s → 3.4 s.
> 2. Let workers batch seeds (automatic by default, about `runs / workers` runs per process;
>    override with `--sim-batch=<n>`). Among both, 50 runs take **≈1.9 s**.
> 3. If your gameplay genuinely relies on `WorkerThreadPool`, keep the threads and lower
>    `--sim-jobs`, or use `--sim-batch=1` to go back to one process per run.

### 2. Run one seed (writes `reports/_runs/seed1001.json`)

```powershell
godot --headless --fixed-fps 60 --disable-render-loop --disable-vsync --path . `
  res://addons/headless_pulse/examples/arena_2d/arena.tscn -- `
  --sim-mode --sim-seed=1001 --sim-max-time=60
```

### 3. Run a 50-run campaign

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=50 --sim-seed=1000 --sim-max-time=60 `
  --sim-out=res://reports/campaign
```

Output layout (in batch mode each batch gets a subdirectory holding its per-run files):

```text
reports/campaign/
├── report.md                     # for the agent: ASCII heatmap + anomalies + time series
├── report.json                   # for programs: exact numbers, percentiles, weapons, hotspots, A/B diff
└── _runs/
    └── s1000_n3/seed1000.json    # per-run details for a 3-run batch (per-tick digest)
    └── ...
```

> Batching is automatic: 50 runs become 17 workers with 3 runs each. Use `--sim-batch=1` for one process per run when debugging.

---

## Sample report

Real output from a 50-run campaign (generated locally at `reports/accept50/report.md`, whitespace trimmed here):

```markdown
# Simulation Balance Report

- **Config**: `res://addons/headless_pulse/examples/arena_2d/arena.tscn` (arena_2d)
- **Runs**: 50 (Seed: 1000..1049) | **Real Wall Time**: 1.95s | **Avg Sim Time/Run**: 55.5s (1426x Speedup)
- **Win Rate**: 48.0% (24/50) | **Stuck Rate**: 4.0% (2/50) | **Median Survival**: 59.7s

## 1. Anomalies & Bottlenecks (Auto-Detected)
- [WARNING] **Death Hotspot**: 31% of deaths happened near (x: 468, y: -285).
  - _Fix_: Playtest that encounter location; it may be an unavoidable damage source or an unfair spawn.

## 2. Spatial Heatmap (World Bounds: X[-480, 480], Y[-300, 300], Grid: 40x20)
Legend: `.` low | `:` medium | `+` high | `#` peak traffic | `X` death | `!` stuck
+----------------------------------------+
|X::::.::::::::.::::::::::X:::::::::::X:X|
|::::..::::.:::::::!!::::::::::.::.::.::.|   <- '!' = stuck hotspot
|::.::::::::::::::::.......:::::.:::.::::|
|:::::.:::::::::::::++:::::::::::::::::::|   <- '+' = high traffic
|:::::.::X::::::::::+#:::::::::::::::::::|
|:::::.::::::::::::::::::::::::::::::::::|
|:::::::::::::::::::::::::::::::::::::.::|
|:::::.::::::XX::::::::::X::::::::::::::X|
+----------------------------------------+

## 3. Time-Series Progression (Bucketed every 15s, Median / P90)
| Time | Alive% | Player HP% | Gold (Med) | DPS (Med) | Enemy Count |
|------|--------|------------|------------|-----------|-------------|
| 15s  | 100%   | 100% / 100% | 60        | 46        | 6.0         |
| 30s  | 100%   | 100% / 100% | 160       | 58        | 8.0         |
| 45s  | 92%    | 83% / 100%  | 230       | 66        | 42.0        |
| 60s  | 48%    | 74% / 97%   | 275       | 63        | 67.0        |

## 4. Weapon Balance
| Weapon  | Damage | Share | DPS  |
|---------|--------|-------|------|
| shotgun | 55534  | 38.6% | 20.0 |
| smg     | 88411  | 61.4% | 31.8 |

## 6. Hotspots
- Deaths: 26 total | top: (468, -285)x8, (-276, -15)x4, ...
- Stuck: 2 total | top: (-36, 195)x1, (-12, 195)x1
- Player stats: kills median 54 / p90 59 | gold median 270 | accuracy 80%
```

Built-in anomaly rules (all thresholds live on `SimConfig`):

| Rule | Trigger | Report content |
|---|---|---|
| `stuck_cluster` | stuck run share > `stuck_rate_warn` (5%) | share + hottest cell + navigation fix hint |
| `death_cluster` | a single cell holds > 30% of deaths, deaths ≥ 3 | hotspot coordinates + level/damage-source hint |
| `weapon_imbalance` | max/min weapon DPS ratio > `weapon_dps_ratio_warn` (2.0) | the imbalanced pair + `.tres` fields to tune |
| `too_hard` / `too_easy` | win rate outside the target band | win rate vs band + pressure-tuning hint |
| `runs_end_early` | median survival < 35% of the budget | early-death warning |
| `nondeterministic` | identical seeds produce different digests | **CRITICAL** with unseeded-RNG/time-dependency hints |

---

## Common workflows

### Prove determinism (bit-exact)

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=20 --sim-repeat=2 --sim-seed=2000 --sim-out=res://reports/determinism
```

`report.json` then contains:

```json
"determinism": { "checked": true, "identical": true, "repeat": 2, "seeds": 20, "mismatches": [] }
```

### A/B test (change numbers without touching files)

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=30 --sim-seed=1000 `
  --sim-out=res://reports/ab_smg `
  --sim-baseline=res://reports/campaign/report.json `
  --sim-set="res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres|damage=10"
```

`report.md` grows an A/B section:

```markdown
## 7. A/B Diff vs Baseline
| Metric          | Baseline | Current | Delta  |
|-----------------|----------|---------|--------|
| win_rate        | 0.480    | 0.467   | -0.013 |
| survival_median | 59.7s    | 58.8s   | -0.9s  |
| dps_median      | 52.0     | 57.9    | +5.8   |
```

`--sim-set` is repeatable; the format is `<res://resource.tres>|<property>=<value>` and every
worker applies it before loading the scene.

**Regression gate (for CI)**: with `--sim-fail-on-regression`, a campaign whose A/B diff exceeds the
allowed drops exits **4**, so a balance regression can fail CI directly:

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=50 --sim-seed=1000 --sim-out=res://reports/ab `
  --sim-baseline=res://reports/campaign/report.json --sim-fail-on-regression `
  --sim-gate-win-drop=0.05 --sim-gate-survival-drop=5 --sim-gate-fail-on-new-critical=true `
  --sim-set="res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres|damage=10"
```

Rules (one `gate PASS/FAIL` line each): win-rate drop within the limit, median-survival drop within
the limit, and no additional CRITICAL anomalies. Tune each rule with its `--sim-gate-*` option.

### Verify stuck detection (U-shaped trap + wall pusher)

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-config=res://sim_configs/stuck_test.tres --sim-out=reports/stuck
```

Expected: `end_reason=stuck`, the coordinate falls inside the trap, the ASCII map shows `!`,
and the report prints a `CRITICAL Stuck Cluster` anomaly.

### Editor dock

Open the editor → right side **Godot HeadlessPulse** panel → pick a SimConfig, runs, concurrency and max
simulation time → **Run campaign** → progress bar → ASCII preview → **Copy report for AI agent** →
**Replay seed (1x)** opens a windowed process to reproduce one run at normal speed.

### One-command verification (run after every change)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
# With PowerShell 7+: pwsh -File tools/verify.ps1 -Godot ...
```

It re-imports the project, then runs the **unit tests** (6 suites / 256 assertions: RNG, checksum,
config parsing, stuck detection, heatmap rasterizer, report statistics and the regression gate),
checks **project-settings invariants** (`worker_pool/max_threads=1` plus the editor plugin enabled),
**parses the editor-only scripts** (`plugin.gd` / `sim_dock.gd`, never loaded by gameplay runs),
**loads the editor plugin headless**, same-seed determinism, **batch=1 vs batch=3 digests**, stuck
detection, 50-run throughput (< 5 s) and report size (< 4 KB), the win-rate target band, the
**A/B regression gate** (a worse variant must exit 4, relaxed limits must exit 0) and
repeat-determinism. Exit code 0 means all checks passed; failures print `FAIL` and return 1.

The unit tests also run standalone (no framework):

```powershell
godot --headless --import --path .                                  # refresh the class cache once
godot --headless --path . -s res://tests/run_tests.gd               # 6 suites / 256 assertions
```

Linux / macOS / Git Bash: `bash tools/verify.sh /path/to/godot` (CI uses a relaxed `CAMPAIGN_BUDGET=120`; both scripts honour that variable).

The repository ships a matrix CI (`.github/workflows/ci.yml`):

- **Required legs**: `ubuntu-latest` runs `tools/verify.sh`, `windows-latest` runs `tools/verify.ps1`, both on the pinned Godot 4.7.2.
- **Advisory leg** (`continue-on-error`, never blocks a merge): `ubuntu-latest` tracks the latest stable Godot, so an engine upgrade regression shows up as a failure signal.
- Every leg downloads/caches Godot, runs the same acceptance checks and uploads the `reports/` artifacts; no duplicate leg is created while the latest stable release equals the pinned version.

### Prompt template for a coding agent

```text
Read reports/campaign/report.md and handle anomalies from highest to lowest severity:
1. Only change the .tres numbers that each anomaly's _Fix_ points to (no logic changes);
2. Re-run with --sim-runs=30 --sim-seed=1000 and add --sim-baseline to compare win_rate / median survival / dps;
3. If the target metric improved and no new CRITICAL appeared, summarize the new report;
   otherwise revert the change and explain why.
Quote only numbers from the report. Do not invent metrics.
```

---

## CLI reference

| Option | Meaning |
|---|---|
| `--sim-mode` | required, enables simulation (after `--`) |
| `--sim-config=<path.tres>` | load a `SimConfig` as the campaign baseline |
| `--sim-scene=<path.tscn>` / `--sim-bot=<path.gd>` | scene under test / driving bot |
| `--sim-seed` / `--sim-runs` / `--sim-repeat` | first seed / number of runs / runs per seed (determinism check) |
| `--sim-jobs=<n>` | worker concurrency cap; 0 = auto (cores − 1, capped at 32) |
| `--sim-batch=<n>` | runs executed sequentially per worker; 0 = auto (about `runs / workers`), amortising engine start-up |
| `--sim-max-time=<sec>` | simulated seconds per run |
| `--sim-out=<path>` | worker: exact result file; campaign: output directory |
| `--sim-grid=40x20` / `--sim-bounds=x0,y0,x1,y1` | heatmap resolution / world bounds |
| `--sim-sample-interval=<sec>` | time-series sampling period |
| `--sim-stuck-window=<sec>` / `--sim-stuck-threshold=<units>` | stuck window / minimum path length inside it |
| `--sim-terminate-on-stuck` | end a run as soon as it is stuck |
| `--sim-set=<res>\|<prop>=<val>` | override a `.tres` property (repeatable, for A/B) |
| `--sim-baseline=<report.json>` | baseline report for A/B diffing |
| `--sim-fail-on-regression` | enable the regression gate (needs `--sim-baseline`); exits 4 when exceeded |
| `--sim-gate-win-drop=<fraction>` / `--sim-gate-survival-drop=<sec>` | allowed win-rate / median-survival drop (default 0.05 / 5) |
| `--sim-gate-fail-on-new-critical=<bool>` | count additional CRITICAL anomalies as a failure (default true) |
| `--sim-report-name=<name>` | aggregated report file name (default `report`) |
| `--sim-replay` | 1x windowed replay (leaves rendering/audio on) |
| `--sim-verbose` | extra diagnostics |
| `--sim-help` / `--sim-dry-run` | print every option (with defaults) / validate the config and print the plan without simulating |
| `--sim-no-determinism-check` | skip the repeat-digest check (faster) |
| `--sim-player-group=<group>` / `--sim-enemy-group=<group>` | scene groups holding the player / enemies |
| `--sim-win-rate-min` / `--sim-win-rate-max` | win-rate target band used by the anomaly rules |

Unknown `--sim-*` options are reported as warnings instead of being silently ignored; campaign exit
codes: `0` ok, `1` campaign failed, `2` bad arguments, `3` worker start failure, `4` regression gate
failed.

---

## Onboarding a real game

1. Put the player node in group `player` and enemies in group `enemies` (overridable via
   `--sim-player-group` / `--sim-enemy-group`).
2. Movement and firing must read `Input` actions: bots inject through `Input.action_press` and
   `SimBotBase` runs at priority `-100`, so injection happens before gameplay on the same tick.
3. If the game aims with the **OS mouse**, read `SimRuntime.get_aim_world_position()` while
   `SimRuntime.is_active()`. That is usually the only code change needed, because headless has no
   cursor to warp.
4. Write a bot by extending `SimBotBase` and overriding `_bot_tick`:

```gdscript
class_name MyBot
extends SimBotBase

func _bot_tick(delta: float) -> void:
    var player := get_target_node()                    # group "player"
    var enemy := find_nearest_enemy(player.global_position)
    if enemy == null:
        return
    set_move_vector(player.global_position - enemy.global_position)  # kite away
    aim_at(enemy.global_position)
    hold_action("fire")
```

5. Optional business telemetry (all no-ops outside simulation):

```gdscript
SimTelemetry.record_event("player_death", {"cause": "contact", "wave": 3})
SimTelemetry.record_metric("damage_dealt", 12.0, {"weapon": "smg"})
SimTelemetry.record_metric("gold", player.gold)
```

6. Freeze a campaign into a `SimConfig` `.tres` (see `sim_configs/arena_2d.tres`) and run:

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-config=res://sim_configs/arena_2d.tres --sim-out=res://reports/my_game
```

---

## Data contracts

### Per-run result (`reports/<campaign>/_runs/<batch>/seed1000.json`)

> In batch mode one subdirectory holds all runs of that batch; `run_id` and `seed` identify each run.

```text
schema, status, run_id, seed, engine, config_name, config, scene_path, bot_script_path,
sim_time, ticks, frames, wall_ms, speedup,
end_reason (timeout|death|stuck|player_lost|scripted),
survived (true only when end_reason == timeout and the player is alive),
player { alive, hp, max_hp, final_pos[x,y] (full precision), final_pos_str, kills, gold,
         damage_dealt, weapon_damage, hits, shots_fired, accuracy, weapon, move_intent },
telemetry { events, event_log, metrics, metrics_by_tag, per_weapon {id:{damage,share}},
            damage_dealt, death {count, positions, records}, stuck {count, positions, records},
            heatmap {cols, rows, bounds_min, bounds_max, traffic[], deaths[], stucks[], max_traffic},
            timeseries {interval, samples[{t, hp, hp_frac, alive, kills, gold, damage, dps,
                                           enemies, bullets, weapon}]},
            observed_bounds },
determinism { digest (per-tick SHA-256), samples, rng_draws, rng_seed },
overrides, replay
```

### Campaign report (`reports/<campaign>/report.json`)

```text
schema, generated_at, engine, config,
campaign {seed_min, seed_max, runs_per_seed, total_runs, failed_runs},
timing {wall_seconds, total_sim_seconds, avg_sim_seconds, speedup, workers},
win_rate, wins, stuck_rate, stuck_runs, stuck_events, deaths, end_reasons,
survival {median, p90, min, max},
player {kills_median, kills_p90, gold_median, gold_p90, damage_median,
        dps_median, dps_p90, hp_remaining_median, accuracy_median},
weapons {id:{damage, share, dps}},
anomalies [{severity, code, message, data, suggestion}],
heatmap {cols, rows, bounds_min, bounds_max, traffic[], deaths[], stucks[]},
hotspots {deaths, stucks, traffic},
timeseries {bucket_seconds, buckets[{t, alive_frac, hp_median, hp_p90,
                                    gold_median, dps_median, enemies_median}]},
determinism {checked, repeat, seeds, identical, mismatches},
failed, ab_diff (only with --sim-baseline)
```

---

## Architecture and layout

```text
            Agent / CI / Editor dock
                      │  CLI args / SimConfig.tres / --sim-set overrides
                      ▼
        SimOrchestrator (seed auto-chunking · one batch = one headless process · reaping)
                      │
        ┌─────────────┴──────────────┐
        ▼                            ▼
  Worker #0 (headless)         Worker #N (headless)
        │ --fixed-fps 60 / --disable-render-loop / --headless
        ▼
  SimRuntime (autoload) — seeded RNG · virtual input · termination · per-tick digest
        │
        ├── SimBotBase ──► SimInputProxy ──► Input.action_press (real input singleton)
        └── SimTelemetry ── events / metrics / trajectory / stuck / time series
                      │
                      ▼
        report.json (exact numbers) + report.md (2.5 KB ASCII for the LLM)
```

```text
addons/headless_pulse/
├── plugin.cfg / plugin.gd          # EditorPlugin: registers the dock
├── core/
│   ├── sim_runtime.gd              # autoload: lifecycle, RNG, digest, resource overrides
│   ├── sim_config.gd               # SimConfig resource + CLI parsing/validation
│   ├── sim_rng.gd                  # deterministic RNG (counts draws)
│   ├── sim_checksum.gd             # per-tick SHA-256 digest (bit-exact evidence)
│   └── sim_orchestrator.gd         # multi-process scheduler (poll-driven, reused by the dock)
├── bot/
│   ├── sim_bot_base.gd             # bot base class (override _bot_tick)
│   ├── sim_input_proxy.gd          # virtual input + virtual aim
│   └── stuck_detector.gd           # sliding-window path-length stuck detection
├── telemetry/
│   ├── telemetry_collector.gd      # autoload SimTelemetry (zero-cost when inactive)
│   ├── spatial_heatmap.gd          # grid rasterizer + ASCII renderer
│   └── report_synthesizer.gd       # aggregation, percentiles, anomalies, A/B diff, markdown
├── cli/run_sim.gd                  # `godot -s` campaign entry point
├── ui/sim_dock.gd                  # editor dock
└── examples/
    ├── arena_2d/                   # self-contained arena + tuning .tres + weapon .tres
    └── bots/                       # kiting_shooter_bot.gd / wall_pusher_bot.gd
sim_configs/                        # arena_2d.tres / stuck_test.tres
tools/                              # verify.ps1 / run_campaign.ps1
```

### Key design decisions

1. **Never fast-forward with `Engine.time_scale`.** Use `--fixed-fps 60` to disable real-time sync
   plus a fixed timestep, so the engine runs as fast as the CPU allows while `delta` stays `1/60`.
   Measured: 1 frame = 1 physics step.
2. **One process per batch (auto 1-3 runs).** Inside a batch: pause scene → reload → new seed → continue,
   which amortises engine start-up; batches stay isolated in separate processes, and workers only write
   JSON files, avoiding stdout-pipe dependencies.
3. **Determinism in three parts:** fixed timestep + a single seeded RNG (with a draw counter) +
   per-tick state SHA-256. The report exposes the evidence as `identical: true`.
4. **Stuck means "intent but no distance", not net displacement.** A kiting bot circles back to its
   starting point, so net displacement is ~0 while it is perfectly healthy; only travel distance
   inside the window (≈0) with movement intent indicates being wedged.
5. **Reports are built for agents:** under 4 KB, directly readable ASCII, anomalies with fix hints,
   coordinates that map to world positions.
6. **Cap the worker thread pool for multi-process runs.** Each process reserves `cores-1` worker
   threads by default, so 20+ concurrent workers create 500+ competing threads;
   `threading/worker_pool/max_threads=1` is the single most effective throughput knob measured here.

---

## FAQ

**Why write reports to `res://` instead of `user://`?**
`user://` is not writable in some managed/sandboxed environments (we reproduced
`Could not open 'user://' directory` on this machine). `res://reports/` is writable during
development/CI and makes reports diffable.

**After adding a `class_name` I get `Identifier ... not declared`.**
Godot 4 caches global classes in `.godot/global_script_class_cache.cfg`; re-import after adding or
renaming one: `godot --headless --import --path .` (`tools/verify.ps1` always does this first).

**PowerShell returns immediately, `$LASTEXITCODE` is empty and logs are out of order.**
On Windows the Steam Godot build is a GUI-subsystem executable, so PowerShell does not wait.
Wrap it in `cmd /c "godot ... > log 2>&1"` (already handled by `tools/*.ps1`) or use a PowerShell 7
process object with `WaitForExit()`.

**`--sim-set` was applied but the game still sees the old value.**
Resources must be loaded through `SimRuntime.get_resource(path)`, which loads, applies overrides and
keeps a strong reference. A plain `load()` can hand out a second, unmodified instance. The examples
already do this everywhere.

**Stuck rate looks too high / a bot is falsely flagged.**
Stuck means accumulated path length inside the window is below the threshold **and** movement intent
is present. If your bot intentionally stands still while shooting, either keep some movement intent
or lower `--sim-stuck-window`. If it is genuinely wedged, the `!` and coordinate in the report are real.

**Simulation results are not deterministic (digest mismatch).**
Check for unseeded global `randf()/randi()/Array.shuffle()`, `Time.get_ticks_msec()` in gameplay
logic, threaded physics, or external file/network dependencies. `SimRNG` counts draws, which helps
bisecting the source.

**Campaign throughput is unstable — how do I make it faster and steadier?**
Two knobs (see the batch-simulation tips in Quick start): `threading/worker_pool/max_threads=1` caps
each process's thread pool, and `--sim-batch` lets one process run several seeds to amortise engine
boot. Both are on by default: measured 50 runs in **≈1.9 s** here (6.5 s unoptimised). Other workloads
on a shared machine (browser, antivirus scans, editor) still affect wall time; size `--sim-jobs` to
the physical core count.

**Does the addon cost anything in normal (non-simulation) runs?**
No meaningful cost: `SimRuntime` calls `set_process(false)/set_physics_process(false)` and every
public `SimTelemetry` method starts with `if not _active: return`.

**Can it run in CI?**
Yes. The repository ships a matrix CI: a Windows runner calls `tools/verify.ps1`, a Linux runner
calls `tools/verify.sh` — both run the same acceptance checks and upload the reports. An advisory leg
tracks the latest stable Godot (`continue-on-error`, non-blocking) to surface engine-upgrade
regressions early. On any CI system you can also run the CLI directly with
`godot --headless ... -s ...` (the scripts only wrap process waiting and assertions).

---

## Known limitations

- **No bit-exactness promise across engine versions/platforms:** 2D physics is deterministic within a
  build; re-verify after upgrading Godot.
- The heatmap assumes a fixed world rectangle (`bounds_min`/`bounds_max`); `auto_bounds` is intended
  for single runs only (grids are not mergeable across runs).
- Reports cover numbers/spatial/time-series only — not rendering, animation, UI or audio.
- The editor dock is verified to register and instantiate headless; its interactive widgets need a
  real editor session for manual validation.
- The demo arena is a **self-contained fixture** used to validate the framework and acceptance
  criteria; it is not representative of a production project's complexity.

---

## Roadmap

| Stage | Content | Status |
|---|---|---|
| M1 | Headless deterministic fast-forward kernel, virtual input, demo arena | ✅ implemented and verified |
| M2 | Telemetry, stuck detection, ASCII heatmap, `report.json/md` | ✅ implemented and verified |
| M3 | Batched multi-process scheduler, statistical aggregation, `.tres` override A/B | ✅ implemented and verified |
| M4 | Editor dock (run / progress / preview / copy / replay seed) | ✅ implemented and verified |
| M5 | CLI self-check (`--sim-help` / `--sim-dry-run` / unknown-option warnings), CI hardening (script parse, plugin load, settings invariants), A/B regression gate (exit 4) | ✅ implemented and verified |
| M6 | Unit tests (6 suites / 256 assertions, wired into both verify scripts; also fixed the latent `SimRNG` composite-helper bug that bypassed the seeded RNG) | ✅ implemented and verified |
| CI | GitHub Actions matrix: ubuntu + windows on Godot 4.7.2, plus an advisory latest-stable leg; runs acceptance checks and uploads reports | ✅ implemented and verified |
| Release | `v0.1.0` tag + GitHub Release + [CHANGELOG.md](CHANGELOG.md) + Dependabot for GitHub Actions | ✅ done |
| Next | 2D/3D multi-scene examples, report diff visualization, long-session streaming | 💡 planned |

---

## Contributing

1. Run `tools/verify.ps1` after changes and keep every check passing;
2. Re-import after adding a `class_name`, and update the directory tree/data contracts in `AGENTS.md`;
3. Keep `report.md` under 4 KB; explain the size impact when you add report content;
4. Record user-visible changes in [CHANGELOG.md](CHANGELOG.md) (under `Unreleased`);
5. Suggested commit prefixes: `feat(core): ...` / `fix(telemetry): ...` / `docs(readme): ...`.

Implementation constraints live in [AGENTS.md](AGENTS.md).

---

## License

[MIT](LICENSE) © Godot HeadlessPulse contributors
