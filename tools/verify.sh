#!/usr/bin/env bash
# HeadlessPulse - cross-platform acceptance verification (Linux / macOS / Git Bash).
#
#   bash tools/verify.sh /path/to/godot
#   CAMPAIGN_BUDGET=120 bash tools/verify.sh /path/to/godot   # slow/shared CI runners
#   GODOT_BIN=/path/to/godot bash tools/verify.sh
#
# This file is only a launcher: every check lives in res://tools/verify_checks.gd,
# the same code tools/verify.ps1 runs on Windows, so the two platforms cannot
# drift apart. `CAMPAIGN_BUDGET` is the allowed wall time for the 50-run campaign.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT_BIN="${1:-${GODOT_BIN:-godot}}"

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

cd "$ROOT"
exec "$GODOT_BIN" --headless --path . -s res://tools/verify_checks.gd -- --budget="${CAMPAIGN_BUDGET:-5}"
