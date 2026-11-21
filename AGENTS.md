# AGENTS.md — Godot HeadlessPulse (headless simulation & balance telemetry)

This file is the entry point for any coding agent working on this repository.
Read it fully before changing code. Verified status and exact commands are below;
do not trust assumptions that contradict the "Verified engine facts" table — it
was measured on this machine with Godot 4.7.2.

Docs: [README.md](README.md) (简体中文) · [README.en.md](README.en.md) (English) · [LICENSE](LICENSE).
Repo: <https://github.com/goa-chua/godot-headlesspulse>

## What this project is

A Godot 4.7 addon (`addons/headless_pulse/`) that lets a coding agent or designer:

1. Run **N headless, deterministic, fixed-timestep simulations** of a game scene
   with a heuristic bot as fast as the CPU allows (measured **~1400-1500x aggregate**
   speedup: 50 runs of 60 simulated seconds in **1.8-2.0 s**).
2. Collect **structured telemetry** (events, per-weapon damage, sampled
   positions, stuck episodes, time series).
3. Emit two agent-friendly artifacts: `report.json` (exact numbers) and
   `report.md` (~2.3 KB ASCII heatmap + auto-detected anomalies + fix hints).
4. A/B test balance values by overriding `.tres` properties from the CLI, with
   a diff against a baseline report.

The value proposition: cheap heuristic bots run the game 100s of times; the LLM
only reads a compressed report. No screenshots, no per-step vision inference, no
wall-clock dependence.

## Verified engine facts (measured, Godot 4.7.2.stable.steam)

| Fact | Measurement |
|---|---|
| `--fixed-fps 60` gives fixed delta | `_process`/`_physics_process` delta = `1/60` exactly |
| physics : render ratio | 3600 ticks vs 3599 frames → exactly 1 physics step per iteration |
| Empty-scene throughput | 3600 ticks in 0.0055 s ≈ 10,860x |
| Demo arena throughput | 3600 ticks in ~0.35 s ≈ **170x** per run |
| Batch workers | a worker runs `--sim-batch=N` seeds sequentially (pause tree, reload scene, reset RNG/checksum/proxy); batch=1/3/5 produce identical per-seed digests |
| Campaign throughput | 50 runs auto-split into 17 workers × 3 runs: **1.8-2.0 s** (~1400-1500x aggregate) |
| Worker thread pool | each process reserves `cores-1` worker threads; capping to 1 took a 50-run campaign from 6.5 s to 3.4 s (batching then takes it to ~1.9 s) |
| `--disable-render-loop` | `RenderingServer.render_loop_enabled == false` |
| `--headless` | dummy display + dummy audio, no GPU work |
| `-s` script mode | **Autoloads DO load**; `MainLoop`/`SceneTree` `_process()` is driven |
| Batch flag set | `--headless --fixed-fps 60 --disable-render-loop --disable-vsync` |
| `OS.get_process_exit_code` / `OS.is_process_running` | available → orchestrator reaps workers |
| `user://` writes | can be blocked on locked-down machines; **write to `res://`** |

Three pitfalls that already caused bugs here — keep them in mind:

- **Steam/Windows Godot is a GUI-subsystem binary.** Plain PowerShell `& godot ...`
  returns immediately and `$LASTEXITCODE` is empty. Wrap calls in
  `cmd /c "godot ... > log 2>&1"` (cmd waits) or use a process object with
  `WaitForExit()`. All scripts in `tools/` do this.
- **Script class cache lives in `.godot/global_script_class_cache.cfg`.** Adding or
  renaming any `class_name` requires a re-import before game-mode runs can resolve
  it: `godot --headless --import --path <project>`.
- **Windows PowerShell 5.1 `Set-Content` defaults to ANSI/GBK.** Editing a UTF-8
  file with non-ASCII text (Chinese docs, `→`, `≈`) that way corrupts it. Use the
  agent's `write`/`edit` tools, or `Set-Content -Encoding utf8`, and re-check with
  a UTF-8 reader. The docs were once corrupted exactly like this.

## Hard rules for implementation

1. **Determinism.** All gameplay randomness goes through `SimRNG`. Never call the
   global `randf()/randi()/Array.shuffle()` inside simulated logic. Never use
   `Time.get_ticks_msec()`, `Engine.get_frames_drawn()`, or real time for gameplay;
   use accumulated fixed `delta`. Wall-clock time is allowed only for reporting
   (`wall_ms`, `speedup`), never inside the run digest.
2. **Fixed timestep.** Workers must be launched with the batch flag set above.
   `SimRuntime` forces `physics_ticks_per_second = 60` and disables the render loop.
3. **Input injection order.** `SimBotBase` runs in `_physics_process` with
   `process_physics_priority = -100`, so injected `Input` state is visible to
   player/entity scripts on the same tick.
4. **Zero intrusion.** Without `--sim-mode` (and not in `-s` script mode)
   `SimRuntime` disables its own processing and `SimTelemetry` methods return
   immediately. A shipping game pays nothing. Never break this.
5. **Shared tuned resources.** Anything overridable by `--sim-set` must be loaded
   via `SimRuntime.get_resource(path)` inside a run; `load()` alone can hand out a
   second instance whose properties were not overridden.
6. **Output paths.** Generated data goes under `res://reports/...` (writable in a
   normal project) — not `user://`.
7. **Strict typing.** `var x: float`, typed arrays, explicit `-> void` returns.
8. **Report size budget.** `report.md` must stay < 4 KB (currently ~2.3 KB for a
   40x20 grid). Adding verbose prose to it needs an explicit reason.
9. **Cap the worker thread pool for campaigns.** Every Godot process reserves
   `cores-1` worker threads; 20+ concurrent workers then create 500+ competing
   threads. Projects used for batch simulation must set
   `threading/worker_pool/max_threads=1` (this fixture does). Measured effect:
   50-run campaign 6.5 s → 3.4 s (then batching → ~1.9 s). If gameplay genuinely
   uses the worker pool, keep the threads and lower `--sim-jobs` instead.
10. **Batch runs must be isolated by a scene reload.** A batch worker pauses the
    tree, reloads the scene and resets RNG/checksum/input per run. Do not rely on
    state that survives a scene reload (autoloads, static vars, mutated global
    resources) for per-run state; games with such global state should use
    `--sim-batch=1` (one process per run).

## Directory layout

```
addons/headless_pulse/
├── plugin.cfg / plugin.gd          # EditorPlugin: registers the dock
├── core/
│   ├── sim_runtime.gd              # Autoload "SimRuntime": run lifecycle, RNG, digest, overrides
│   ├── sim_config.gd               # SimConfig resource + CLI parsing/validation
│   ├── sim_rng.gd                  # deterministic RNG wrapper (draw counter)
│   ├── sim_checksum.gd             # per-tick SHA-256 state digest (bit-exact proof)
│   └── sim_orchestrator.gd         # multi-process campaign scheduler (poll-based; batches seeds per process)
├── bot/
│   ├── sim_bot_base.gd             # class_name SimBotBase (override _bot_tick)
│   ├── sim_input_proxy.gd          # virtual input + virtual aim adapter
│   └── stuck_detector.gd           # path-length sliding-window stuck detection
├── telemetry/
│   ├── telemetry_collector.gd      # Autoload "SimTelemetry" (zero-cost when inactive)
│   ├── spatial_heatmap.gd          # grid rasterizer + ASCII renderer
│   └── report_synthesizer.gd       # aggregation, percentile stats, anomalies, A/B diff, markdown
├── cli/run_sim.gd                  # `godot -s ... run_sim.gd` campaign entry point
├── ui/sim_dock.gd                  # editor dock (run campaign, preview, copy, replay seed)
└── examples/
    ├── arena_2d/                   # self-contained demo scene, tuning .tres, weapons
    └── bots/                       # kiting_shooter_bot.gd, wall_pusher_bot.gd
sim_configs/                        # campaigns: arena_2d.tres, stuck_test.tres
tools/                              # verify.ps1 / verify.sh, run_campaign.ps1 (acceptance wrappers)
.github/workflows/ci.yml            # GitHub Actions: ubuntu-latest + Godot 4.7.2 + verify.sh
reports/                            # generated reports + samples (gitignored, reproducible)
README.md / README.en.md            # bilingual user docs (Chinese default, English mirror)
AGENTS.md / LICENSE
```

## Data contracts

### Per-run result (`reports/<campaign>/_runs/<batch>/seed1000.json`)

In batch mode one subdirectory holds all runs of that batch (`run_id` + `seed`
identify each run); single runs may write an exact file when `--sim-out` ends
with `.json`.

```
schema, status, run_id, seed, engine, config_name, config, scene_path, bot_script_path,
sim_time, ticks, frames, wall_ms, speedup, end_reason (timeout|death|stuck|player_lost|scripted),
survived (true only when end_reason == timeout and player alive),
player {alive, hp, max_hp, final_pos [x, y] (full float precision), final_pos_str, kills, gold,
        damage_dealt, weapon_damage, hits, shots_fired, accuracy, weapon, move_intent},
telemetry {events, event_log, metrics, metrics_by_tag, per_weapon {id: {damage, share}},
           damage_dealt, death {count, positions, records}, stuck {count, positions, records},
           heatmap {cols, rows, bounds_min, bounds_max, traffic[], deaths[], stucks[],
                    max_traffic, total_samples},
           timeseries {interval, samples [{t, hp, hp_frac, alive, kills, gold, damage, dps,
                                           enemies, bullets, weapon}]},
           observed_bounds, samples},
determinism {digest (SHA-256 of every tick's state), samples, rng_draws, rng_seed},
overrides, replay
```

### Campaign report (`reports/<campaign>/report.json`)

Top-level keys: `schema, generated_at, engine, config, campaign, timing, win_rate,
wins, stuck_rate, stuck_runs, stuck_events, deaths, end_reasons, survival
{median, p90, min, max}, player {kills_median, kills_p90, gold_median, gold_p90,
damage_median, dps_median, dps_p90, hp_remaining_median, accuracy_median},
weapons {id: {damage, share, dps}}, anomalies [{severity, code, message, data,
suggestion}], heatmap, hotspots {deaths, stucks, traffic}, timeseries {bucket_seconds,
buckets [...]}, determinism {checked, identical, mismatches}, failed, ab_diff (when
`--sim-baseline` given)`.

### `report.md` sections

1. header (config, runs, wall time, speedup, win/stuck rate, median survival)
2. Anomalies & Bottlenecks — each with `_Fix_:` suggestion
3. Spatial Heatmap — `.` low `:` medium `+` high `#` peak `X` death `!` stuck
4. Time-Series Progression — 15 s buckets, median/P90
5. Weapon Balance
6. Determinism
7. Hotspots
8. A/B Diff (only with a baseline)

## CLI cheat sheet

```powershell
# one worker, one seed (debugging; writes reports/_runs/seed1001.json)
godot --headless --fixed-fps 60 --disable-render-loop --path . res://addons/headless_pulse/examples/arena_2d/arena.tscn -- `
  --sim-mode --sim-seed=1001 --sim-max-time=60 --sim-verbose

# campaign: 50 runs, auto workers, auto report
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=50 --sim-seed=1000 --sim-max-time=60 --sim-out=res://reports/campaign

# bit-exact determinism proof (2 runs per seed)
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=20 --sim-repeat=2 --sim-seed=2000 --sim-out=res://reports/determinism

# stuck acceptance (wall_pusher bot in the U trap, ends early on stuck)
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-config=res://sim_configs/stuck_test.tres --sim-out=res://reports/stuck

# A/B: override a .tres value and diff against a baseline report
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=30 --sim-seed=1000 --sim-out=res://reports/ab --sim-baseline=res://reports/campaign/report.json `
  --sim-set="res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres|damage=10"
```

All worker-relevant options: `--sim-config --sim-scene --sim-bot --sim-seed --sim-runs
--sim-repeat --sim-jobs --sim-batch --sim-max-time --sim-out --sim-tag --sim-grid --sim-bounds
--sim-sample-interval --sim-stuck-window --sim-stuck-threshold --sim-terminate-on-stuck
--sim-set --sim-report-name --sim-baseline --sim-verbose --sim-replay`.

`--sim-batch` is the worker-side batch size (runs per process); the orchestrator
derives it automatically as `ceil(runs / workers)` unless overridden.

`--sim-set` format is `<res://path.tres>|<property>=<value>` (repeatable,
applied by every worker before the scene loads).

## Verification workflow (do this after any change)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
# PowerShell 7+: pwsh -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
```

On Linux/macOS (and Git Bash on Windows), the same checks run with bash; this is what CI uses:

```bash
bash tools/verify.sh /path/to/godot      # CAMPAIGN_BUDGET=120 on shared CI runners
```

GitHub Actions: `.github/workflows/ci.yml` runs on ubuntu-latest, downloads Godot 4.7.2, executes `tools/verify.sh` and uploads `reports/` as an artifact.

It re-imports the project and asserts:

1. **Determinism** — same seed twice → identical `digest`, `final_pos`, `kills`, `hp`.
2. **Stuck detection** — `wall_pusher_bot` ends with `end_reason=stuck` near the trap,
   and `report.md` contains a `!` hotspot.
3. **Throughput** — 50 runs of 60 simulated seconds complete in < 5 s (measured ~1.8-1.9 s),
   `report.md` < 4 KB, win rate inside the configured target band.
4. **Repeat determinism** — `--sim-repeat=2` campaign reports `identical = true`
   with zero mismatches.

Exit code 0 = all checks pass. Any failing check prints `FAIL` and returns 1.

## Milestones (all implemented and verified)

- **M1 — deterministic fast-forward kernel**: done. Batch flags, `SimRuntime`,
  `SimRNG`, `SimChecksum`, `SimInputProxy`, `SimBotBase`, arena demo. Verified
  bit-exact with identical digests; ~170x per run, ~1400x campaign aggregate.
- **M2 — telemetry, stuck detection, ASCII heatmap**: done. Verified with the
  wall-pusher bot: stuck event at t≈4.03 s at `(-269, 33)`, `!` hotspot rendered,
  CRITICAL stuck-cluster anomaly emitted.
- **M3 — batched multi-process orchestrator + statistical aggregation + A/B**: done.
  50 runs in 1.8-2.0 s, `report.json`/`report.md` written, `.tres` overrides work,
  baseline diff renders.
- **M4 — editor dock**: done. `plugin.gd` registers a dock that runs campaigns,
  shows progress and the ASCII report, copies it for an agent, and replays a seed
  at 1x in a windowed process.

## How to onboard a real game (5 minutes)

1. Copy `addons/headless_pulse/` into your project and enable the plugin
   (Project → Project Settings → Plugins) or add only the autoloads:
   ```
   [autoload]
   SimTelemetry="*res://addons/headless_pulse/telemetry/telemetry_collector.gd"
   SimRuntime="*res://addons/headless_pulse/core/sim_runtime.gd"
   ```
2. Your player must be in group `player` (configurable via `--sim-player-group`),
   enemies in group `enemies`, and your movement/fire must read `Input` actions.
3. If your game aims with the OS mouse, read the aim direction from
   `SimRuntime.get_aim_world_position()` while `SimRuntime.is_active()` (this is the
   only code change usually needed, because headless has no real cursor).
4. Write a bot extending `SimBotBase` and override `_bot_tick()`.
5. Create a `SimConfig` `.tres` (see `sim_configs/arena_2d.tres`) and run a
   campaign. Add `SimTelemetry.record_event/record_metric` calls for business
   metrics (damage per weapon, gold, deaths) to enrich the report.

## Known limitations

- Windows focus for the helper scripts: `tools/*.ps1` wrap process waiting; the CLI
  itself is cross-platform.
- 2D physics is deterministic per-engine-build; the demo's player uses
  `CharacterBody2D` + `move_and_slide` against static walls (manual integration for
  enemies/bullets). Cross-platform/cross-version bit-exactness is not promised.
- The heatmap assumes a fixed world rectangle (config `bounds_min/bounds_max`);
  `auto_bounds` exists but makes grids run-specific, so aggregation prefers fixed
  bounds.
- The editor dock is verified to instantiate/register headless; its interactive
  widgets need a real editor session.
- Batch workers reload the scene between runs; per-run state must not live in
  autoloads/statics/global resources that survive a reload. Use `--sim-batch=1`
  for games whose run state cannot be reset by a scene reload.
