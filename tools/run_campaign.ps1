# Godot HeadlessPulse - run a balance campaign from the shell (Windows wrapper).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_campaign.ps1 -Runs 50 -Seed 1000
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_campaign.ps1 -Runs 30 -Set "res://.../smg.tres|damage=10" -Baseline res://reports/campaign/report.json
#
# Prints the aggregated metrics and the path of the generated report.md.
param(
    [string]$Godot = $env:GODOT_BIN,
    [int]$Runs = 50,
    [int]$Seed = 1000,
    [int]$Repeat = 1,
    [int]$Jobs = 0,
    [int]$Batch = 0,
    [double]$MaxTime = 60.0,
    [string]$Out = 'res://reports/campaign',
    [string]$Config = '',
    [string]$Bot = '',
    [string]$Baseline = '',
    [string[]]$Set = @(),
    [switch]$SkipImport
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Godot) {
    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($command) { $Godot = $command.Source }
}
if (-not $Godot -or -not (Test-Path $Godot)) {
    Write-Host "godot binary not found. Pass -Godot <path> or set `$env:GODOT_BIN." -ForegroundColor Red
    exit 2
}

$log = Join-Path $root 'reports\_last_campaign.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null

if (-not $SkipImport) {
    cmd /c ('"' + $Godot + '" --headless --import --path "' + $root + '" > "' + $log + '" 2>&1')
}

$arguments = '--headless --path "' + $root + '" -s res://addons/headless_pulse/cli/run_sim.gd -- --sim-mode' +
    ' --sim-runs=' + $Runs + ' --sim-seed=' + $Seed + ' --sim-repeat=' + $Repeat +
    ' --sim-max-time=' + $MaxTime + ' --sim-out=' + $Out
if ($Jobs -gt 0) { $arguments += ' --sim-jobs=' + $Jobs }
if ($Batch -gt 0) { $arguments += ' --sim-batch=' + $Batch }
if ($Config) { $arguments += ' --sim-config=' + $Config }
if ($Bot) { $arguments += ' --sim-bot=' + $Bot }
if ($Baseline) { $arguments += ' --sim-baseline=' + $Baseline }
foreach ($override in $Set) {
    $arguments += ' --sim-set="' + $override + '"'
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
cmd /c ('"' + $Godot + '" ' + $arguments + ' >> "' + $log + '" 2>&1')
$code = $LASTEXITCODE
$sw.Stop()

Write-Host "campaign exit=$code wall=$([math]::Round($sw.Elapsed.TotalSeconds,2))s log=$log"
Get-Content $log | Select-String -Pattern 'campaign done|campaign failed|worker failed' | Select-Object -Last 3

$relative = $Out -replace '^res://', ''
$directory = Join-Path $root $relative
if (Test-Path $directory) {
    $markdown = Get-ChildItem $directory -Filter '*.md' | Select-Object -First 1
    if ($markdown) {
        Write-Host ""
        Write-Host "report: $($markdown.FullName)"
        Get-Content $markdown.FullName | Select-Object -First 12
    }
}
exit $code
