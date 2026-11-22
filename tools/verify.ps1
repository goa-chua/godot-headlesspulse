# Godot HeadlessPulse - acceptance verification launcher (Windows).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
#   CAMPAIGN_BUDGET=120 powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot ...
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot ... -CampaignBudgetSeconds 120
#
# This file is only a launcher: every check lives in res://tools/verify_checks.gd,
# the same code tools/verify.sh runs on Linux/macOS/Git Bash, so the two platforms
# cannot drift apart. `-CampaignBudgetSeconds` / CAMPAIGN_BUDGET is the allowed wall
# time for the 50-run campaign.
param(
    [string]$Godot = $env:GODOT_BIN,
    [double]$CampaignBudgetSeconds = $(if ($env:CAMPAIGN_BUDGET) { [double]$env:CAMPAIGN_BUDGET } else { 5.0 })
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$reportsDir = Join-Path $root 'reports'
New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
$log = Join-Path $reportsDir '_launcher.log'

if (-not $Godot) {
    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($command) { $Godot = $command.Source }
}
if (-not $Godot -or -not (Test-Path $Godot)) {
    Write-Host "godot binary not found. Pass -Godot <path> or set `$env:GODOT_BIN." -ForegroundColor Red
    exit 2
}

# cmd waits for the (GUI-subsystem) Godot binary; Tee keeps the console output live
# and leaves a launcher log next to the per-check logs in reports/.
$arguments = '--headless --path "' + $root + '" -s res://tools/verify_checks.gd -- --budget=' + $CampaignBudgetSeconds
cmd /c ('"' + $Godot + '" ' + $arguments + ' 2>&1') | Tee-Object -FilePath $log
exit $LASTEXITCODE
