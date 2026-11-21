#!/usr/bin/env bash
# HeadlessPulse - cross-platform acceptance verification (Linux / macOS / Git Bash).
#
#   bash tools/verify.sh /path/to/godot
#   CAMPAIGN_BUDGET=120 bash tools/verify.sh /path/to/godot   # slow/shared CI runners
#   GODOT_BIN=/path/to/godot bash tools/verify.sh
#
# Mirrors tools/verify.ps1: re-import the project, then assert same-seed
# determinism, stuck detection, campaign throughput/report budget, balance band
# and repeat determinism. Exit code 0 = all checks passed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${1:-${GODOT_BIN:-godot}}"
CAMPAIGN_BUDGET="${CAMPAIGN_BUDGET:-60}"
cd "$ROOT"

if [ -f "$GODOT_BIN" ]; then
    :
elif command -v "$GODOT_BIN" >/dev/null 2>&1; then
    GODOT_BIN="$(command -v "$GODOT_BIN")"
else
    echo "godot binary not found: '$GODOT_BIN' (pass it as the first argument or set GODOT_BIN)" >&2
    exit 2
fi
if [ ! -x "$GODOT_BIN" ]; then
    chmod +x "$GODOT_BIN" 2>/dev/null || true
fi

if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "python3 is required to parse the JSON reports" >&2
    exit 2
fi

OUT="reports/_ci"
rm -rf "$OUT"
mkdir -p "$OUT"

FAILED=0
LAST_LOG=""

pass() { printf '[PASS] %-34s %s\n' "$1" "$2"; }
fail() { printf '[FAIL] %-34s %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

# json <file> <dotted.key.path>  -> raw value on stdout
json() {
    "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2].split("."):
    value = value[int(key)] if isinstance(value, list) else value[key]
print("true" if value is True else "false" if value is False else value)
PYEOF
}

run_godot() {
    local name="$1"
    shift
    LAST_LOG="$OUT/$name.log"
    "$GODOT_BIN" "$@" >"$LAST_LOG" 2>&1
    return $?
}

show_log_tail() {
    if [ -n "$LAST_LOG" ] && [ -f "$LAST_LOG" ]; then
        tail -n 20 "$LAST_LOG"
    fi
}

echo "HeadlessPulse verification"
echo "  project : $ROOT"
echo "  godot   : $GODOT_BIN"
echo "  system  : $(uname -srm 2>/dev/null || echo unknown) / python=$PY / budget=${CAMPAIGN_BUDGET}s"
"$GODOT_BIN" --version >"$OUT/version.log" 2>&1 || true
printf '  engine  : %s\n' "$(head -n 1 "$OUT/version.log")"
echo ""

# --- 0. import (refresh script class cache) --------------------------------
if run_godot import --headless --import --path .; then
    pass "import project" "exit=0"
else
    fail "import project" "exit=$?"
    show_log_tail
fi

# --- 1. single-run determinism ---------------------------------------------
run_godot det_a --headless --fixed-fps 60 --disable-render-loop --disable-vsync --path . \
    res://addons/headless_pulse/examples/arena_2d/arena.tscn -- \
    --sim-mode --sim-seed=4242 --sim-max-time=60 --sim-out=reports/_ci/det_a.json
run_godot det_b --headless --fixed-fps 60 --disable-render-loop --disable-vsync --path . \
    res://addons/headless_pulse/examples/arena_2d/arena.tscn -- \
    --sim-mode --sim-seed=4242 --sim-max-time=60 --sim-out=reports/_ci/det_b.json
if [ -f "$OUT/det_a.json" ] && [ -f "$OUT/det_b.json" ]; then
    digest_a="$(json "$OUT/det_a.json" determinism.digest)"
    digest_b="$(json "$OUT/det_b.json" determinism.digest)"
    pos_a="$(json "$OUT/det_a.json" player.final_pos_str)"
    pos_b="$(json "$OUT/det_b.json" player.final_pos_str)"
    kills_a="$(json "$OUT/det_a.json" player.kills)"
    kills_b="$(json "$OUT/det_b.json" player.kills)"
    hp_a="$(json "$OUT/det_a.json" player.hp)"
    hp_b="$(json "$OUT/det_b.json" player.hp)"
    if [ "$digest_a" = "$digest_b" ] && [ "$pos_a" = "$pos_b" ] && [ "$kills_a" = "$kills_b" ] && [ "$hp_a" = "$hp_b" ]; then
        pass "determinism (same seed)" "digest=${digest_a:0:16}... pos=$pos_a kills=$kills_a"
    else
        fail "determinism (same seed)" "digest_a=$digest_a digest_b=$digest_b pos_a=$pos_a pos_b=$pos_b"
        show_log_tail
    fi
else
    fail "determinism (same seed)" "run result missing"
    show_log_tail
fi

# --- 2. stuck detection acceptance -----------------------------------------
run_godot stuck --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- \
    --sim-mode --sim-config=res://sim_configs/stuck_test.tres --sim-out=reports/_ci/stuck
stuck_report="$OUT/stuck/stuck_test.json"
stuck_markdown="$OUT/stuck/stuck_test.md"
stuck_rate=""
stuck_run=""
if [ -f "$stuck_report" ]; then
    stuck_rate="$(json "$stuck_report" stuck_rate)"
    stuck_run="$(find "$OUT/stuck/_runs" -name '*.json' 2>/dev/null | head -n 1)"
fi
stuck_ok=0
stuck_detail="run or report missing"
if [ -n "$stuck_run" ] && [ -f "$stuck_run" ]; then
    end_reason="$(json "$stuck_run" end_reason)"
    stuck_count="$(json "$stuck_run" telemetry.stuck.count)"
    pos_x="$(json "$stuck_run" telemetry.stuck.records.0.pos.0)"
    pos_y="$(json "$stuck_run" telemetry.stuck.records.0.pos.1)"
    mark_ok=0
    if [ -f "$stuck_markdown" ] && grep -q '!' "$stuck_markdown"; then mark_ok=1; fi
    rate_ok="$("$PY" -c 'import sys; print(1 if abs(float(sys.argv[1]) - 1.0) < 1e-4 else 0)' "${stuck_rate:-0}")"
    pos_ok="$("$PY" -c 'import sys; x, y = float(sys.argv[1]), float(sys.argv[2]); print(1 if -300 < x < -250 and 20 < y < 60 else 0)' "$pos_x" "$pos_y")"
    if [ "$end_reason" = "stuck" ] && [ "$stuck_count" -gt 0 ] && [ "$rate_ok" = "1" ] && [ "$pos_ok" = "1" ] && [ "$mark_ok" = "1" ]; then
        stuck_ok=1
    fi
    stuck_detail="end_reason=$end_reason pos=($pos_x, $pos_y) ascii_mark=$mark_ok"
fi
if [ "$stuck_ok" = "1" ]; then
    pass "stuck detection" "$stuck_detail"
else
    fail "stuck detection" "$stuck_detail"
    show_log_tail
fi

# --- anomaly detection (the stuck campaign must emit a CRITICAL anomaly) ---
anomalies=""
if [ -f "$stuck_report" ]; then
    anomalies="$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("anomalies", [])))' "$stuck_report")"
fi
if [ "${anomalies:-0}" -ge 1 ]; then
    pass "anomaly detection" "$anomalies anomaly entry(ies) in the stuck campaign"
else
    fail "anomaly detection" "no anomalies reported"
fi

# --- 3. campaign throughput + report budget --------------------------------
campaign_start=$(date +%s)
run_godot campaign --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- \
    --sim-mode --sim-runs=50 --sim-seed=1000 --sim-max-time=60 --sim-out=reports/_ci/campaign
campaign_exit=$?
campaign_elapsed=$(( $(date +%s) - campaign_start ))
campaign_report="$OUT/campaign/report.json"
campaign_markdown="$OUT/campaign/report.md"
if [ -f "$campaign_report" ] && [ -f "$campaign_markdown" ]; then
    wall="$(json "$campaign_report" timing.wall_seconds)"
    speedup="$(json "$campaign_report" timing.speedup)"
    win="$(json "$campaign_report" win_rate)"
    stuck="$(json "$campaign_report" stuck_rate)"
    md_bytes=$(wc -c <"$campaign_markdown" | tr -d ' ')
    within_budget="$("$PY" -c 'import sys; print(1 if float(sys.argv[1]) <= float(sys.argv[2]) else 0)' "$wall" "$CAMPAIGN_BUDGET")"
    balance_ok="$("$PY" -c 'import sys; w = float(sys.argv[1]); print(1 if 0.25 <= w <= 0.80 else 0)' "$win")"
    if [ "$campaign_exit" -eq 0 ] && [ "$within_budget" = "1" ]; then
        pass "campaign throughput" "50 runs in ${wall}s (budget ${CAMPAIGN_BUDGET}s, external ${campaign_elapsed}s, ${speedup}x)"
    else
        fail "campaign throughput" "50 runs in ${wall}s (budget ${CAMPAIGN_BUDGET}s, external ${campaign_elapsed}s)"
        show_log_tail
    fi
    if [ "$md_bytes" -gt 0 ] && [ "$md_bytes" -lt 4096 ]; then
        pass "report.md size budget" "$md_bytes bytes"
    else
        fail "report.md size budget" "$md_bytes bytes"
    fi
    if [ "$balance_ok" = "1" ]; then
        pass "balance within target band" "win_rate=$("$PY" -c 'import sys; print(round(float(sys.argv[1])*100,1))' "$win")% stuck_rate=$("$PY" -c 'import sys; print(round(float(sys.argv[1])*100,1))' "$stuck")%"
    else
        fail "balance within target band" "win_rate=$win"
    fi
else
    fail "campaign throughput" "campaign report missing (exit=$campaign_exit)"
    show_log_tail
fi

# --- 4. repeat determinism campaign ---------------------------------------
run_godot repeat --headless --path . -s res://addons/headless_pulse/cli/run_sim.gd -- \
    --sim-mode --sim-runs=10 --sim-repeat=2 --sim-seed=3000 --sim-max-time=60 --sim-out=reports/_ci/repeat
repeat_report="$OUT/repeat/report.json"
if [ -f "$repeat_report" ]; then
    checked="$(json "$repeat_report" determinism.checked)"
    identical="$(json "$repeat_report" determinism.identical)"
    mismatches="$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))["determinism"]["mismatches"]))' "$repeat_report")"
    seeds="$(json "$repeat_report" determinism.seeds)"
    if [ "$checked" = "true" ] && [ "$identical" = "true" ] && [ "$mismatches" -eq 0 ]; then
        pass "repeat determinism (x2)" "identical=true seeds=$seeds mismatches=0"
    else
        fail "repeat determinism (x2)" "identical=$identical mismatches=$mismatches"
        show_log_tail
    fi
else
    fail "repeat determinism (x2)" "report missing"
    show_log_tail
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
fi
echo "$FAILED CHECK(S) FAILED - logs in $OUT"
exit 1
