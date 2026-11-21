# Godot HeadlessPulse - reproducible acceptance verification (Windows).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
#
# Re-imports the project, then asserts determinism, stuck detection, campaign
# throughput/report budget and repeat-determinism. Exit code 0 = all pass.
param(
    [string]$Godot = $env:GODOT_BIN,
    [int]$Runs = 50,
    [double]$CampaignBudgetSeconds = 5.0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$verifyDir = Join-Path $root 'reports\_verify'
New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null

if (-not $Godot) {
    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($command) { $Godot = $command.Source }
}
if (-not $Godot -or -not (Test-Path $Godot)) {
    Write-Host "godot binary not found. Pass -Godot <path> or set `$env:GODOT_BIN." -ForegroundColor Red
    exit 2
}

$script:Failures = 0
$scene = 'res://addons/headless_pulse/examples/arena_2d/arena.tscn'
$campaignScript = 'res://addons/headless_pulse/cli/run_sim.gd'

function Invoke-Godot([string]$Name, [string]$Arguments) {
    $log = Join-Path $verifyDir "$Name.log"
    # cmd waits for the (GUI-subsystem) Godot process, PowerShell's & does not.
    cmd /c ('"' + $Godot + '" ' + $Arguments + ' > "' + $log + '" 2>&1')
    $code = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $code; Log = $log }
}

function Check([string]$Label, [bool]$Ok, [string]$Detail) {
    if ($Ok) {
        Write-Host ("[PASS] {0,-34} {1}" -f $Label, $Detail) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0,-34} {1}" -f $Label, $Detail) -ForegroundColor Red
        $script:Failures++
    }
}

function Read-Json([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

# Workers write one JSON per run into a per-batch subdirectory; find any of them.
function Find-RunResult([string]$Directory) {
    if (-not (Test-Path $Directory)) { return $null }
    $file = Get-ChildItem $Directory -Recurse -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'report*' } | Select-Object -First 1
    if (-not $file) { return $null }
    return Read-Json $file.FullName
}

Write-Host "Godot HeadlessPulse verification" -ForegroundColor Cyan
Write-Host "  project : $root"
Write-Host "  godot   : $Godot"
Write-Host ""

# --- 0. import (refresh script class cache) ---------------------------------
$import = Invoke-Godot 'import' ('--headless --import --path "' + $root + '"')
Check 'import project' ($import.ExitCode -eq 0) "exit=$($import.ExitCode)"

# --- 1. single-run determinism ---------------------------------------------
$runA = Join-Path $verifyDir 'det_a.json'
$runB = Join-Path $verifyDir 'det_b.json'
Remove-Item $runA, $runB -ErrorAction SilentlyContinue
$singleArgs = '--headless --fixed-fps 60 --disable-render-loop --disable-vsync --path "' + $root + '" ' + $scene +
    ' -- --sim-mode --sim-seed=4242 --sim-max-time=60'
$null = Invoke-Godot 'det_a' ($singleArgs + ' --sim-out=res://reports/_verify/det_a.json')
$null = Invoke-Godot 'det_b' ($singleArgs + ' --sim-out=res://reports/_verify/det_b.json')
$a = Read-Json $runA
$b = Read-Json $runB
$sameDigest = $a -and $b -and ($a.determinism.digest -eq $b.determinism.digest)
$sameState = $a -and $b -and ($a.player.final_pos_str -eq $b.player.final_pos_str) -and
    ($a.player.kills -eq $b.player.kills) -and ($a.player.hp -eq $b.player.hp)
if ($a) {
    Check 'determinism (same seed)' ($sameDigest -and $sameState) (
        "digest=$($a.determinism.digest.Substring(0,16))... pos=$($a.player.final_pos_str) kills=$($a.player.kills)")
} else {
    Check 'determinism (same seed)' $false 'run result missing'
}

# --- 1b. batch-size independence -------------------------------------------
$batchSeeds = @(4242, 4243, 4244)
foreach ($batchSeed in $batchSeeds) {
    $null = Invoke-Godot "single_$batchSeed" ($singleArgs.Replace('--sim-seed=4242', "--sim-seed=$batchSeed") +
        " --sim-batch=1 --sim-out=res://reports/_verify/single_$batchSeed.json")
}
$null = Invoke-Godot 'batch3' ($singleArgs.Replace('--sim-seed=4242', '--sim-seed=4242') +
    ' --sim-batch=3 --sim-out=res://reports/_verify/batch3')
$batchOk = $true
$batchDetail = 'batch=1 vs batch=3 digests match for 3 seeds'
foreach ($batchSeed in $batchSeeds) {
    $singleRun = Read-Json (Join-Path $verifyDir "single_$batchSeed.json")
    $batchedRun = Read-Json (Join-Path $verifyDir "batch3\seed$batchSeed.json")
    if (-not $singleRun -or -not $batchedRun) {
        $batchOk = $false
        $batchDetail = "missing result for seed $batchSeed"
        continue
    }
    if ($singleRun.determinism.digest -ne $batchedRun.determinism.digest) {
        $batchOk = $false
        $batchDetail = "seed $batchSeed differs (batch1=$($singleRun.determinism.digest) batch3=$($batchedRun.determinism.digest))"
    }
}
Check 'batch-size independence' $batchOk $batchDetail
# --- 2. stuck detection acceptance -----------------------------------------
$stuckDir = Join-Path $root 'reports\_verify\stuck'
Remove-Item $stuckDir -Recurse -Force -ErrorAction SilentlyContinue
$stuck = Invoke-Godot 'stuck' ('--headless --path "' + $root + '" -s ' + $campaignScript +
    ' -- --sim-mode --sim-config=res://sim_configs/stuck_test.tres --sim-out=res://reports/_verify/stuck')
$stuckReport = Read-Json (Join-Path $stuckDir 'stuck_test.json')
$stuckRun = Find-RunResult (Join-Path $stuckDir '_runs')
$stuckMarkdown = Join-Path $stuckDir 'stuck_test.md'
$stuckRateOk = $false
if ($stuckReport) { $stuckRateOk = [math]::Abs([double]$stuckReport.stuck_rate - 1.0) -lt 0.0001 }
$endReasonOk = $stuckRun -and ($stuckRun.end_reason -eq 'stuck')
$posOk = $false
if ($stuckRun -and $stuckRun.telemetry.stuck.count -gt 0) {
    $position = $stuckRun.telemetry.stuck.records[0].pos
    $posOk = ($position[0] -gt -300) -and ($position[0] -lt -250) -and ($position[1] -gt 20) -and ($position[1] -lt 60)
}
$markdownOk = (Test-Path $stuckMarkdown) -and ((Get-Content $stuckMarkdown -Raw) -match '!')
$stuckDetail = 'run or report missing'
if ($stuckRun) {
    $stuckDetail = "end_reason=$($stuckRun.end_reason) pos=$($stuckRun.telemetry.stuck.records[0].pos) ascii_mark=$markdownOk"
}
Check 'stuck detection' ($stuck.ExitCode -eq 0 -and $stuckRateOk -and $endReasonOk -and $posOk -and $markdownOk) $stuckDetail
$stuckAnomalies = 0
if ($stuckReport) { $stuckAnomalies = @($stuckReport.anomalies).Count }
Check 'anomaly detection' ($stuckAnomalies -ge 1) ("$stuckAnomalies anomaly entry(ies) in the stuck campaign")

# --- 3. campaign throughput + report budget --------------------------------
$campaignDir = Join-Path $root 'reports\_verify\campaign'
Remove-Item $campaignDir -Recurse -Force -ErrorAction SilentlyContinue
$campaignArgs = '--headless --path "' + $root + '" -s ' + $campaignScript +
    ' -- --sim-mode --sim-runs=' + $Runs + ' --sim-seed=1000 --sim-max-time=60 --sim-out=res://reports/_verify/campaign'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$campaign = Invoke-Godot 'campaign' $campaignArgs
$sw.Stop()
$report = Read-Json (Join-Path $campaignDir 'report.json')
$reportMd = Join-Path $campaignDir 'report.md'
$wallSeconds = if ($report) { [double]$report.timing.wall_seconds } else { 999.0 }
$reportBytes = if (Test-Path $reportMd) { (Get-Item $reportMd).Length } else { 0 }
$winOk = $report -and ([double]$report.win_rate -ge 0.25) -and ([double]$report.win_rate -le 0.80)
Check 'campaign throughput' ($campaign.ExitCode -eq 0 -and $wallSeconds -lt $CampaignBudgetSeconds) (
    "$Runs runs in $([math]::Round($wallSeconds,2))s (budget ${CampaignBudgetSeconds}s, external $([math]::Round($sw.Elapsed.TotalSeconds,2))s)")
Check 'report.md size budget' (($reportBytes -gt 0) -and ($reportBytes -lt 4096)) ("$reportBytes bytes")
$balanceDetail = 'report missing'
if ($report) {
    $balanceDetail = "win_rate=$([math]::Round([double]$report.win_rate*100,1))% stuck_rate=$([math]::Round([double]$report.stuck_rate*100,1))%"
}
Check 'balance within target band' ([bool]$winOk) $balanceDetail

# --- 4. repeat determinism campaign ----------------------------------------
$repeatDir = Join-Path $root 'reports\_verify\repeat'
Remove-Item $repeatDir -Recurse -Force -ErrorAction SilentlyContinue
$repeat = Invoke-Godot 'repeat' ('--headless --path "' + $root + '" -s ' + $campaignScript +
    ' -- --sim-mode --sim-runs=10 --sim-repeat=2 --sim-seed=3000 --sim-max-time=60 --sim-out=res://reports/_verify/repeat')
$repeatReport = Read-Json (Join-Path $repeatDir 'report.json')
$repeatOk = $repeatReport -and [bool]$repeatReport.determinism.checked -and
    [bool]$repeatReport.determinism.identical -and ($repeatReport.determinism.mismatches.Count -eq 0)
$repeatDetail = 'report missing'
if ($repeatReport) {
    $repeatDetail = "identical=$($repeatReport.determinism.identical) seeds=$($repeatReport.determinism.seeds)"
}
Check 'repeat determinism (x2)' ([bool]$repeatOk) $repeatDetail

# --- summary ---------------------------------------------------------------
Write-Host ""
if ($script:Failures -eq 0) {
    Write-Host "ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Failures) CHECK(S) FAILED - see logs in reports\_verify" -ForegroundColor Red
exit 1
