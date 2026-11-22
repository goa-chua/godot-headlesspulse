# Changelog

All notable changes to **Godot HeadlessPulse** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-22

First public release: a Godot 4.7 addon that runs N headless, deterministic,
fixed-timestep simulations of a game scene with a heuristic bot and turns the
result into an agent-friendly `report.json` + `report.md`.

### Added

- **Deterministic fast-forward kernel** — `--fixed-fps 60 --disable-render-loop`
  batch flags, `SimRuntime` lifecycle, `SimRNG` (draw counter), per-tick
  `SimChecksum` SHA-256 digest, `SimInputProxy` + `SimBotBase` input injection
  (physics priority -100) and a self-contained 2D arena demo (~195x per run).
- **Telemetry** — events, per-weapon damage, sampled positions, stuck episodes,
  time series, ASCII spatial heatmap, percentile aggregates and JSON/markdown
  reports (~2.5 KB `report.md`) with auto-detected anomalies and `_Fix_` hints.
- **Batch campaign orchestrator** — multi-process scheduler that batches seeds per
  worker (`--sim-batch`), auto worker count (`--sim-jobs`), per-run result files,
  and A/B diffing against a baseline report (`--sim-baseline`).
- **Balance workflow** — `--sim-set="<res.tres>|<prop>=<value>"` overrides tuned
  resources without editing files; `--sim-win-rate-min/max` target band.
- **A/B regression gate** — `--sim-fail-on-regression` exits 4 when the win rate
  or median survival drop beyond `--sim-gate-win-drop` / `--sim-gate-survival-drop`
  or new CRITICAL anomalies appear (per-rule `gate PASS/FAIL` output).
- **CLI self-check** — `--sim-help` (authoritative option list + defaults),
  `--sim-dry-run` (validate the config and print the plan), warnings for unknown
  `--sim-*` options, documented exit codes 0/1/2/3/4.
- **Editor dock** — run campaigns, progress bar, ASCII preview, copy for an agent,
  replay a seed at 1x.
- **Verification** — `tools/verify.ps1` (Windows) and `tools/verify.sh`
  (Linux/macOS/Git Bash) run 14 acceptance checks: project-settings invariants,
  editor-only script parse, headless editor plugin load, same-seed determinism,
  batch-size independence, stuck detection, throughput/report budget, balance
  band, both directions of the regression gate, repeat determinism.
- **CI** — GitHub Actions matrix (ubuntu-latest + windows-latest on pinned Godot
  4.7.2, plus a non-blocking advisory leg on the latest stable release), Godot
  binary cache, per-leg `reports/` artifacts, `workflow_dispatch` with a
  `pinned_version` input.
- `CHANGELOG.md`, `.github/dependabot.yml`, `v0.1.0` tag and GitHub release.

### Fixed

- Results no longer depend on `--sim-batch` / CPU core count: the SceneTree is
  paused before the first scene is instantiated, so every run (including run 0)
  starts with zero pre-run gameplay ticks. Both verify scripts assert this.
- `--sim-set` overrides resolve through `SimRuntime.get_resource()`, so shared
  tuned resources observe the overridden values instead of a second instance.
- CI jobs are grouped by trigger + ref, so a manual `workflow_dispatch` no longer
  cancels the validation of a pushed commit.

### Verified

- 50 runs × 60 simulated seconds in **1.9–2.0 s** locally (~1400–1450x aggregate),
  `report.md` **2.5 KB**, win rate 48 %, stuck rate 4 %.
- Bit-exact digest (`d89cfb85…`) is identical across Linux (CI), Windows (CI) and
  local Windows; `--sim-batch=1/3/17` and `--sim-repeat=2` match too.
- CI: ubuntu-latest 14/14 checks (~6 s campaign), windows-latest 14/14 (~12 s)
  with `CAMPAIGN_BUDGET=120`.
- Engine: Godot 4.7.2 (4.7.x supported; the advisory CI leg tracks the latest
  stable release).

### Known limitations

- 2D physics is deterministic within an engine build; cross-version/cross-platform
  bit-exactness is not promised.
- The editor dock's interactive widgets need a real editor session — headless CI
  verifies plugin/dock registration only.
- The heatmap assumes fixed world bounds; `auto_bounds` is intended for single runs.
- Games with state that survives a scene reload should use `--sim-batch=1`.

[Unreleased]: https://github.com/goa-chua/godot-headlesspulse/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/goa-chua/godot-headlesspulse/releases/tag/v0.1.0
