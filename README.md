# Godot HeadlessPulse

**简体中文** | [English](README.en.md)

[![GitHub](https://img.shields.io/badge/GitHub-goa--chua%2Fgodot--headlesspulse-181717?logo=github)](https://github.com/goa-chua/godot-headlesspulse)
[![CI](https://github.com/goa-chua/godot-headlesspulse/actions/workflows/ci.yml/badge.svg)](https://github.com/goa-chua/godot-headlesspulse/actions/workflows/ci.yml)
[![Godot](https://img.shields.io/badge/Godot-4.7-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Status](https://img.shields.io/badge/status-M1--M4%20verified-brightgreen)](#路线图)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey)](#已知限制)

> Godot 4.7 的**无头、确定性、高速仿真与平衡性遥测**插件。
> 用廉价启发式 Bot 跑量，用高密度结构化遥测喂给大模型。

把"100 局 × 60 秒"的游戏逻辑压缩成 **几秒钟** 的真实时间和 **一个 2.5 KB 的 ASCII/JSON 报告**，
让 Coding Agent 直接定位卡死点、数值膨胀点、武器平衡偏差；改完 `.tres` 再做 A/B 回归。

**仓库**：<https://github.com/goa-chua/godot-headlesspulse>

---

## 目录

- [核心亮点](#核心亮点)
- [实测数据](#实测数据)
- [适用场景](#适用场景)
- [快速开始](#快速开始)
- [报告示例](#报告示例)
- [常用工作流](#常用工作流)
- [CLI 参数](#cli-参数)
- [接入自己的游戏](#接入自己的游戏)
- [数据契约](#数据契约)
- [架构与目录](#架构与目录)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [路线图](#路线图)
- [贡献](#贡献)
- [许可证](#许可证)

---

## 核心亮点

| 能力 | 说明 |
|---|---|
| **确定性快进** | `--fixed-fps 60` 关闭真实时间同步，固定步长让 delta 恒为 `1/60`；1 帧 = 1 物理步。同种子逐 tick SHA-256 **bit-exact** 可复现。 |
| **真正的高速** | 不依赖 `Engine.time_scale`（会丢物理步、穿模、仍受墙钟限制）。纯 CPU 全速推进，单局 ~195x，campaign 聚合 ~1400–1450x。 |
| **批量多进程** | 一进程顺序跑一批种子（自动分片），引擎启动与线程开销摊薄到多局；`SimOrchestrator` 用 `OS.create_process` 派发、`is_process_running` 回收，worker 只落盘不依赖 stdout。 |
| **零侵入接入** | 非 `--sim-mode` 时 `SimRuntime` 关闭自身处理、`SimTelemetry` 每个方法立即 return，**游戏本体零开销**。 |
| **虚拟输入与瞄准** | `SimInputProxy` 走真实 `Input` 单例注入，无需改输入系统；无头环境没有光标，用 `SimRuntime.get_aim_world_position()` 暴露虚拟瞄准。 |
| **Agent 友好的报告** | 2.5 KB ASCII 空间热力图 + 结构化 JSON；异常自带 `_Fix_` 修复建议和世界坐标，可直接指导改 `.tres`。 |
| **A/B 测试** | `--sim-set=<res>\|<prop>=<val>` 免改文件覆写数值资源，配合 `--sim-baseline` 输出前后差异表。 |
| **编辑器 Dock** | 面板内配置、并发跑、进度条、ASCII 预览、一键复制给 AI、按 Seed 1x 复现。 |
| **可复现验收** | `tools/verify.ps1` 一条命令跑完确定性、卡死检测、吞吐、报告体积、重复确定性。 |

---

## 实测数据

> 测量环境：Windows 11，24 逻辑核，Godot **4.7.2.stable.steam**，示例靶场 `arena_2d`，
> 单局预算 60 秒仿真（3600 tick），种子 1000..1049。数字随 CPU 与场景复杂度变化；
> 共享/省电模式的机器上吞吐会有波动（下表给出实测区间）。

| 指标 | 实测结果 |
|---|---|
| 单局 60s 逻辑（3600 tick） | 内部 **~0.28 s → ~195x**；进程总耗时 ~0.56 s（含引擎启动） |
| 50 局 × 60s campaign | **1.9–2.0 s**（内部）→ **~1400–1450x 聚合加速** |
| 批量 worker | 50 局自动切成 17 个 worker（每进程顺序跑 3 局），避免 50 次引擎启动 |
| worker 线程配置的影响 | 默认每进程按核数预留 worker 线程（24 核 = 23 线程/进程），20+ 并发时互相争抢；`threading/worker_pool/max_threads=1` 让 50 局 6.5 s → 3.4 s，叠加批量后 ≈ 1.9 s |
| 确定性（同 seed 两次） | digest / 终局坐标 / 击杀 / HP **完全一致** |
| 确定性回归（20 seed × 2） | 40 局 **0 mismatch**（且 batch=1/3/5 的 digest 逐局一致） |
| 卡死检测 | 撞 U 形陷阱的 Bot 在 **t = 4.03 s**、坐标 `(-269, 33)` 精确判定 |
| 空场景极限 | 3600 tick / 0.0055 s ≈ **10860x** |
| 报告体积 | `report.md` **2.5 KB**（40×20 网格，预算 < 4 KB） |
| 示例平衡结果 | 胜率 48%、卡死率 4%、中位存活 59.7s |

复现方法见 [常用工作流](#常用工作流) 的「一键验收」。

---

## 适用场景

**适合：**

- 动作 / Roguelike / 塔防 / 策略等**回合或 tick 驱动**的玩法平衡验证；
- 数值改动前后的 **A/B 回归**（胜率、存活时间、DPS、经济曲线）；
- 关卡几何导致的**卡死 / 卡角 / 导航问题**定位；
- 让 Coding Agent 在 CI 或本地自主完成「跑量 → 看报告 → 改数值 → 回归」。

**不适合：**

- 纯视觉 / 动画 / UI 问题（本工具不渲染、不截图）；
- 需要真实玩家手感、网络同步或非确定性外部依赖的验证；
- 只关心实时帧率表现的性能测试（仿真刻意脱离墙钟）。

---

## 快速开始

要求：**Godot 4.7+**（标准版或 Steam 版均可）。CLI 跨平台；本文脚本以 Windows PowerShell 为例。

### 0. 获取代码

```powershell
git clone https://github.com/goa-chua/godot-headlesspulse.git
cd godot-headlesspulse
```

### 1. 接入插件

把 `addons/headless_pulse/` 拷进你的工程，二选一：

- 编辑器：项目设置 → 插件 → 启用 **Godot HeadlessPulse**（获得 Dock）；
- 纯 CLI/CI：只加两个 Autoload（**顺序不能反**，`SimRuntime` 依赖先注册的遥测单例）：

```ini
[autoload]
SimTelemetry="*res://addons/headless_pulse/telemetry/telemetry_collector.gd"
SimRuntime="*res://addons/headless_pulse/core/sim_runtime.gd"
```

> 新增 / 重命名任何 `class_name` 后，必须先重新导入刷新脚本类缓存：
> `godot --headless --import --path .`

> **批量仿真建议**：
> 1. 在用于跑量的工程里设置 `threading/worker_pool/max_threads=1`。每个 Godot 进程默认按
>    CPU 核数预留 worker 线程（24 核 = 23 线程/进程），20+ 并发会变成 500+ 线程互相抢 CPU；
>    实测该设置让 50 局 campaign 从 6.5 s 降到 3.4 s。
> 2. 让 worker 批量跑种子（默认自动，约 `runs / workers` 局/进程；也可 `--sim-batch=<n>` 手动指定），
>    把引擎启动开销摊薄。两项叠加后 50 局 ≈ **1.9 s**。
> 3. 若你的游戏逻辑本身重度依赖 WorkerThreadPool，请保留线程并适当降低 `--sim-jobs`，
>    或用 `--sim-batch=1` 回到一局一进程。

### 2. 跑一局（单进程，输出 `reports/_runs/seed1001.json`）

```powershell
godot --headless --fixed-fps 60 --disable-render-loop --disable-vsync --path . `
  res://addons/headless_pulse/examples/arena_2d/arena.tscn -- `
  --sim-mode --sim-seed=1001 --sim-max-time=60
```

### 3. 跑 50 局并生成报告

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=50 --sim-seed=1000 --sim-max-time=60 `
  --sim-out=res://reports/campaign
```

产物结构（批量模式下每批一个子目录，内含该批每局结果）：

```text
reports/campaign/
├── report.md                     # 给 Agent 读：ASCII 热力图 + 异常 + 时间序列
├── report.json                   # 给程序读：精确数值、分位数、武器统计、hotspots、A/B diff
└── _runs/
    └── s1000_n3/seed1000.json    # 一批 3 局的逐局明细（含逐 tick digest）
    └── ...
```

> 默认自动批量：50 局会切成 17 个 worker（每进程 3 局）。需要一局一进程调试时加 `--sim-batch=1`。

---

## 报告示例

真实输出（一次 50 局 campaign 在本地生成 `reports/accept50/report.md`，此处精简空白）：

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
|::::..::::.:::::::!!::::::::::.::.::.::.|   <- '!' = 卡死热点
|::.::::::::::::::::.......:::::.:::.::::|
|:::::.:::::::::::::++:::::::::::::::::::|   <- '+' = 较高流量
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

内置异常检测规则（阈值均可在 `SimConfig` 调整）：

| 规则 | 触发条件 | 报告内容 |
|---|---|---|
| `stuck_cluster` | 卡死局占比 > `stuck_rate_warn`（默认 5%） | 卡死比例 + 最热坐标 + 导航修复建议 |
| `death_cluster` | 单一网格死亡占比 > 30% 且死亡 ≥ 3 | 死亡热点坐标 + 场地/伤害源排查建议 |
| `weapon_imbalance` | 武器 DPS 比值 > `weapon_dps_ratio_warn`（默认 2.0） | 失衡武器对 + 建议调整的 `.tres` 字段 |
| `too_hard` / `too_easy` | 胜率落在目标区间外 | 胜率与目标区间 + 增减敌人数值建议 |
| `runs_end_early` | 中位存活 < 预算 35% | 过早死亡提示 |
| `nondeterministic` | 同 seed 的 digest 不一致 | **CRITICAL**：未播种随机 / 时间依赖排查建议 |

---

## 常用工作流

### 验证确定性（bit-exact）

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=20 --sim-repeat=2 --sim-seed=2000 --sim-out=res://reports/determinism
```

`report.json` 中会得到：

```json
"determinism": { "checked": true, "identical": true, "repeat": 2, "seeds": 20, "mismatches": [] }
```

### A/B 测试（改数值不碰文件）

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-runs=30 --sim-seed=1000 `
  --sim-out=res://reports/ab_smg `
  --sim-baseline=res://reports/campaign/report.json `
  --sim-set="res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres|damage=10"
```

`report.md` 末尾追加 A/B 差异表：

```markdown
## 7. A/B Diff vs Baseline
| Metric          | Baseline | Current | Delta  |
|-----------------|----------|---------|--------|
| win_rate        | 0.480    | 0.467   | -0.013 |
| survival_median | 59.7s    | 58.8s   | -0.9s  |
| dps_median      | 52.0     | 57.9    | +5.8   |
```

`--sim-set` 可重复，格式 `<res://资源.tres>|<属性>=<值>`，所有 worker 在场景加载前生效。

### 验证卡死检测（U 形陷阱 + 顶墙 Bot）

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-config=res://sim_configs/stuck_test.tres --sim-out=reports/stuck
```

期望：`end_reason=stuck`、坐标落在陷阱内、ASCII 图出现 `!`、报告输出 `CRITICAL Stuck Cluster`。

### 编辑器 Dock

打开编辑器 → 右侧 **Godot HeadlessPulse** 面板 → 配置 SimConfig / 局数 / 并发 / 时长 →
**Run campaign** → 进度条 → ASCII 报告预览 → **Copy report for AI agent** →
**Replay seed (1x)** 以正常速度开窗口复现某局。

### 一键验收（推荐每次改完代码执行）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
# PowerShell 7+ 环境可用：pwsh -File tools/verify.ps1 -Godot ...
```

依次校验：重新导入 → 同 seed 双跑确定性 → 卡死检测 → 50 局吞吐（< 5s）与报告体积（< 4 KB）
→ 胜率目标区间 → repeat=2 确定性。全部 PASS 返回 0，失败打印 `FAIL` 并返回 1。

Linux / macOS / Git Bash：`bash tools/verify.sh /path/to/godot`（CI 环境用宽松吞吐预算 `CAMPAIGN_BUDGET=120`）。

仓库内置 GitHub Actions（`.github/workflows/ci.yml`）：ubuntu-latest 自动下载 Godot 4.7.2 → 跑同一套验收 → 上传 `reports/` 报告产物。

### 给 Coding Agent 的提示词模板

```text
读取 reports/campaign/report.md，按严重度从高到低处理异常：
1. 只修改每条异常 _Fix_ 指向的 .tres 数值（不要改逻辑代码）；
2. 用 --sim-runs=30 --sim-seed=1000 重跑，并加 --sim-baseline 对比 win_rate / median survival / dps；
3. 若目标指标改善且没有新增 CRITICAL，输出新的 report.md 摘要；否则回滚该改动并说明原因。
只引用报告中的数字，不要编造。
```

---

## CLI 参数

| 参数 | 说明 |
|---|---|
| `--sim-mode` | 必填，开启仿真（放在 `--` 之后） |
| `--sim-config=<path.tres>` | 载入 `SimConfig` 作为基线 |
| `--sim-scene=<path.tscn>` / `--sim-bot=<path.gd>` | 被测场景 / 驱动 Bot |
| `--sim-seed` / `--sim-runs` / `--sim-repeat` | 起始种子 / 局数 / 每种子重复次数（确定性校验） |
| `--sim-jobs=<n>` | worker 进程并发上限；0 = 自动（核数 − 1，上限 32） |
| `--sim-batch=<n>` | 每个 worker 顺序跑多少局；0 = 自动（约 `runs / workers`，摊薄引擎启动开销） |
| `--sim-max-time=<秒>` | 单局仿真时长 |
| `--sim-out=<path>` | 单局 = 输出文件；campaign = 输出目录 |
| `--sim-grid=40x20` / `--sim-bounds=x0,y0,x1,y1` | 热力图分辨率 / 世界边界 |
| `--sim-sample-interval=<秒>` | 时序采样周期 |
| `--sim-stuck-window=<秒>` / `--sim-stuck-threshold=<单位>` | 卡死窗口 / 窗口内最小累计路程 |
| `--sim-terminate-on-stuck` | 判定卡死立即结束该局 |
| `--sim-set=<res>\|<prop>=<val>` | 覆写 `.tres` 属性（可重复，A/B 用） |
| `--sim-baseline=<report.json>` | A/B 对比基线 |
| `--sim-report-name=<名称>` | 聚合报告文件名（默认 `report`） |
| `--sim-replay` | 1x 窗口复现模式（不关渲染 / 音频） |
| `--sim-verbose` | 额外诊断输出 |

---

## 接入自己的游戏

1. 玩家节点加入 group `player`，敌人加入 group `enemies`（可用 `--sim-player-group` / `--sim-enemy-group` 覆盖）。
2. 移动 / 开火必须读 `Input` action（Bot 通过 `Input.action_press` 注入；`SimBotBase` 优先级 `-100`，保证同 tick 先注入）。
3. 若游戏用**鼠标位置**瞄准：`SimRuntime.is_active()` 时改读 `SimRuntime.get_aim_world_position()`。
   这是无头环境通常唯一需要的代码改动（没有真实光标可 warp）。
4. 写一个 Bot（继承 `SimBotBase`，只重写 `_bot_tick`）：

```gdscript
class_name MyBot
extends SimBotBase

func _bot_tick(delta: float) -> void:
    var player := get_target_node()                    # group "player"
    var enemy := find_nearest_enemy(player.global_position)
    if enemy == null:
        return
    set_move_vector(player.global_position - enemy.global_position)  # 后退风筝
    aim_at(enemy.global_position)
    hold_action("fire")
```

5. 业务埋点（可选；非仿真模式全部 no-op）：

```gdscript
SimTelemetry.record_event("player_death", {"cause": "contact", "wave": 3})
SimTelemetry.record_metric("damage_dealt", 12.0, {"weapon": "smg"})
SimTelemetry.record_metric("gold", player.gold)
```

6. 用 `SimConfig` `.tres` 固化一套 campaign（参考 `sim_configs/arena_2d.tres`），然后：

```powershell
godot --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- `
  --sim-mode --sim-config=res://sim_configs/arena_2d.tres --sim-out=res://reports/my_game
```

---

## 数据契约

### 单局 `reports/<campaign>/_runs/<batch>/seed1000.json`

> 批量模式下一批种子共用一个子目录；每局 JSON 内的 `run_id` 与 `seed` 可唯一定位。

```text
schema, status, run_id, seed, engine, config_name, config, scene_path, bot_script_path,
sim_time, ticks, frames, wall_ms, speedup,
end_reason (timeout|death|stuck|player_lost|scripted),
survived (= end_reason==timeout 且玩家存活),
player { alive, hp, max_hp, final_pos[x,y] (全精度), final_pos_str, kills, gold,
         damage_dealt, weapon_damage, hits, shots_fired, accuracy, weapon, move_intent },
telemetry { events, event_log, metrics, metrics_by_tag, per_weapon {id:{damage,share}},
            damage_dealt, death {count, positions, records}, stuck {count, positions, records},
            heatmap {cols, rows, bounds_min, bounds_max, traffic[], deaths[], stucks[], max_traffic},
            timeseries {interval, samples[{t, hp, hp_frac, alive, kills, gold, damage, dps,
                                           enemies, bullets, weapon}]},
            observed_bounds },
determinism { digest (逐 tick SHA-256), samples, rng_draws, rng_seed },
overrides, replay
```

### 聚合报告 `reports/<campaign>/report.json`

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
failed, ab_diff (仅 --sim-baseline 时)
```

---

## 架构与目录

```text
            Agent / CI / 编辑器 Dock
                      │  CLI 参数 / SimConfig.tres / --sim-set 覆写
                      ▼
        SimOrchestrator（种子自动分片 · 一批 = 一个 headless 进程 · 回收子进程）
                      │
        ┌─────────────┴──────────────┐
        ▼                            ▼
  Worker #0（headless）        Worker #N（headless）
        │ --fixed-fps 60 / --disable-render-loop / --headless
        ▼
  SimRuntime（Autoload）—— 种子 RNG · 虚拟输入 · 终止判定 · 逐 tick digest
        │
        ├── SimBotBase ──► SimInputProxy ──► Input.action_press（真实输入单例）
        └── SimTelemetry ── 事件 / 指标 / 轨迹 / 卡死 / 时序
                      │
                      ▼
        report.json（精确数值） + report.md（2.5KB ASCII，喂给 LLM）
```

```text
addons/headless_pulse/
├── plugin.cfg / plugin.gd          # EditorPlugin：注册 Dock
├── core/
│   ├── sim_runtime.gd              # Autoload：运行生命周期、RNG、digest、资源覆写
│   ├── sim_config.gd               # SimConfig 资源 + CLI 解析/校验
│   ├── sim_rng.gd                  # 确定性 RNG（记录抽取次数）
│   ├── sim_checksum.gd             # 逐 tick SHA-256 digest（bit-exact 证据）
│   └── sim_orchestrator.gd         # 多进程并发调度（poll 驱动，Dock 复用）
├── bot/
│   ├── sim_bot_base.gd             # Bot 基类（重写 _bot_tick）
│   ├── sim_input_proxy.gd          # 虚拟输入 + 虚拟瞄准
│   └── stuck_detector.gd           # 滑动窗口「累计路程」卡死检测
├── telemetry/
│   ├── telemetry_collector.gd      # Autoload SimTelemetry（非仿真零开销）
│   ├── spatial_heatmap.gd          # 栅格化 + ASCII 渲染
│   └── report_synthesizer.gd       # 聚合/分位数/异常检测/A-B diff/markdown
├── cli/run_sim.gd                  # `godot -s` campaign 入口
├── ui/sim_dock.gd                  # 编辑器 Dock
└── examples/
    ├── arena_2d/                   # 自包含靶场 + 平衡数值 .tres + 武器 .tres
    └── bots/                       # kiting_shooter_bot.gd / wall_pusher_bot.gd
sim_configs/                        # arena_2d.tres / stuck_test.tres
tools/                              # verify.ps1 / run_campaign.ps1
```

### 关键设计决策

1. **不用 `Engine.time_scale` 快进。** 正确做法是 `--fixed-fps 60` 关闭真实时间同步 + 固定步长，
   让引擎「能跑多快跑多快」，同时保证 delta 恒为 `1/60`。实测 1 帧 = 1 物理步。
2. **一进程一批（默认自动 1–3 局）。** 批次内顺序执行：暂停场景 → 重载 → 换种子 → 继续跑，引擎启动开销摊薄到多局；
   批次之间用独立进程隔离，worker 只写 JSON 文件，避免 stdout 管道依赖。
3. **确定性三件套**：固定步长 + 单一种子 RNG（记录每次抽取）+ 逐 tick 状态 SHA-256，报告直接给出证据。
4. **卡死判据是「窗口内累计路程」而非净位移。** 绕圈风筝净位移≈0 但没卡死；
   只有「有移动意图却推不动（路程≈0）」才算卡死。
5. **报告为 Agent 设计**：< 4 KB、ASCII 可直读、异常带修复建议、坐标可直接对应世界位置。
6. **多进程必须限制 worker 线程池**：每进程默认预留「核数−1」个 worker 线程，20+ 并发的
   campaign 会产生 500+ 线程互相抢占；`threading/worker_pool/max_threads=1` 是实测最有效的吞吐开关。

---

## 常见问题

**Q：为什么报告写 `res://` 而不是 `user://`？**
`user://` 在部分受管 / 沙箱环境不可写（本机就复现过 `Could not open 'user://' directory`）。
项目内的 `res://reports/` 在开发 / CI 场景可写，且方便直接对报告做 diff。

**Q：新增 `class_name` 后运行报 `Identifier ... not declared`？**
Godot 4 的全局类名缓存在 `.godot/global_script_class_cache.cfg`，新增 / 改名后必须重新导入：
`godot --headless --import --path .`（`tools/verify.ps1` 每次都会先做这一步）。

**Q：PowerShell 里 `godot ...` 立刻返回、`$LASTEXITCODE` 为空、日志乱序？**
Windows / Steam 版 Godot 是 GUI 子系统程序，PowerShell 不会等待。用
`cmd /c "godot ... > log 2>&1"` 等待（`tools/*.ps1` 已封装），或改用 PowerShell 7 的进程对象等待。

**Q：`--sim-set` 覆写了但游戏里还是旧值？**
资源必须通过 `SimRuntime.get_resource(path)` 加载（`SimRuntime` 统一「加载 + 覆写 + 强引用」），
不要直接 `load()`——否则可能拿到未被覆写的第二个实例。示例代码已全部按此实现。

**Q：卡死率异常高 / Bot 被误判卡死？**
卡死 = 滑动窗口内**累计路程** < 阈值且**有移动意图**。若 Bot 会「原地对枪」，请让 Bot 保持
移动意图或调小 `--sim-stuck-window`；若确实顶住障碍物，报告中的 `!` 与坐标就是真实卡点。

**Q：仿真结果不确定（digest 不一致）？**
检查：未播种的全局 `randf()/randi()/Array.shuffle()`、`Time.get_ticks_msec()` 参与逻辑、
物理多线程、外部文件 / 网络依赖。`SimRNG` 记录抽取次数，可用于二分定位。

**Q：50 局吞吐忽快忽慢，怎么稳定提速？**
两个旋钮（见「快速开始」的批量仿真建议）：`threading/worker_pool/max_threads=1`
限制每进程的线程池，`--sim-batch` 让一个进程跑多局以摊薄启动开销。默认两者都生效：
本机实测 50 局 **≈1.9 s**（未优化时 6.5 s）。共享机器上的其他负载（浏览器、杀软扫描、编辑器）
仍会影响墙钟，可通过 `--sim-jobs` 适配物理核数。

**Q：非仿真模式下插件有性能开销吗？**
没有实际开销：`SimRuntime` 在非 `--sim-mode` 时 `set_process(false)/set_physics_process(false)`，
`SimTelemetry` 每个公开方法首行 `if not _active: return`。

**Q：能在 CI 里跑吗？**
可以。CI 安装 Godot 4.7 后用 `--headless` 执行 CLI 即可；Windows runner 上直接调用
`tools/verify.ps1`，Linux / macOS 用同样的 `godot ... -s ...` 命令（脚本仅作等待封装）。

---

## 已知限制

- **跨引擎版本 / 平台不承诺 bit-exact**：2D 物理在同一构建内确定；升级引擎后需重新验证。
- 热力图基于固定世界矩形（`bounds_min/bounds_max`）；`auto_bounds` 仅建议单局使用（跨局网格不可合并）。
- 报告只覆盖「数值 / 空间 / 时序」维度，不含渲染、动画、UI、音频问题。
- 编辑器 Dock 已验证可注册 / 实例化，交互按钮需真实编辑器会话人工验证。
- 示例靶场是**自包含演示**，用于验证框架与验收标准，不代表真实项目复杂度。

---

## 路线图

| 阶段 | 内容 | 状态 |
|---|---|---|
| M1 | 无头确定性快进内核、虚拟输入、示例靶场 | ✅ 已实现并验证 |
| M2 | 遥测采集、卡死检测、ASCII 热力图、`report.json/md` | ✅ 已实现并验证 |
| M3 | 批量多进程调度、统计聚合、`.tres` 覆写 A/B | ✅ 已实现并验证 |
| M4 | 编辑器 Dock（运行 / 进度 / 预览 / 复制 / 复现 Seed） | ✅ 已实现并验证 |
| CI | GitHub Actions：Linux 自动下载 Godot 4.7.2、跑验收、上传报告 | ✅ 已实现并验证 |
| 后续 | 2D/3D 多场景示例、报告 diff 可视化、长时仿真 Streaming | 💡 计划中 |

---

## 贡献

1. 改完代码先跑 `tools/verify.ps1`，确保全部检查 PASS；
2. 新增 `class_name` 后记得 `--import` 刷新类缓存，并同步 `AGENTS.md` 的目录树与数据契约；
3. 保持 `report.md` < 4 KB，新增报告内容需说明体积影响；
4. 提交信息建议：`feat(core): ...` / `fix(telemetry): ...` / `docs(readme): ...`。

更多实现约束与验证要求见 [AGENTS.md](AGENTS.md)。

---

## 许可证

[MIT](LICENSE) © Godot HeadlessPulse contributors
