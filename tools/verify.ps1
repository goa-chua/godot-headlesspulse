# Godot HeadlessPulse - reproducible acceptance verification (Windows).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot "C:\path\to\godot.exe"
#   CAMPAIGN_BUDGET=120 powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify.ps1 -Godot ...
#
# Re-imports the project, then runs the unit-test suites, asserts project-settings
# invariants, parses the editor-only scripts, loads the editor plugin headless,
# checks determinism, batch-size independence, stuck detection, campaign
# throughput/report budget, balance band, the A/B regression gate and
# repeat-determinism. Exit code 0 = all pass. Mirrors tools/verify.sh
# (Linux/macOS/Git Bash); CI runs both.
param(
    [string]$Godot = $env:GODOT_BIN,
    [int]$Runs = 50,
    # Shared/CI runners are slower than a local workstation: allow a relaxed budget.
    [double]$CampaignBudgetSeconds = $(if ($env:CAMPAIGN_BUDGET) { [double]$env:CAMPAIGN_BUDGET } else { 5.0 })
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
$versionLog = Join-Path $verifyDir 'version.log'
cmd /c ('"' + $Godot + '" --version > "' + $versionLog + '" 2>&1') | Out-Null
$engineLine = ''
if (Test-Path $versionLog) {
    $engineLine = ((Get-Content $versionLog -Raw) -split "`r?`n")[0]
}
Write-Host "  engine  : $engineLine"
Write-Host "  budget  : $CampaignBudgetSeconds s (CAMPAIGN_BUDGET)"
Write-Host ""

# --- 0. import (refresh script class cache) ---------------------------------
$import = Invoke-Godot 'import' ('--headless --import --path "' + $root + '"')
Check 'import project' ($import.ExitCode -eq 0) "exit=$($import.ExitCode)"

# --- 0a. unit tests --------------------------------------------------------
# Fast engine-native suites (no framework): RNG, checksum, config parsing,
# stuck detection, heatmap rasterizer, report statistics and the regression gate.
$unit = Invoke-Godot 'unit_tests' ('--headless --path "' + $root + '" -s res://tests/run_tests.gd')
$unitLog = if (Test-Path $unit.Log) { Get-Content $unit.Log -Raw } else { '' }
$unitSummary = ''
$unitMatch = [regex]::Match($unitLog, '(?m)^unit tests:.*$')
if ($unitMatch.Success) { $unitSummary = $unitMatch.Value }
if ($unit.ExitCode -ne 0) {
    $unitFail = [regex]::Match($unitLog, '(?m)^\[FAIL\].*$')
    if ($unitFail.Success) { $unitSummary = $unitFail.Value }
}
Check 'unit tests' ($unit.ExitCode -eq 0) $unitSummary

# --- 0b. project settings invariants ---------------------------------------
# Hard rules from AGENTS.md: campaigns need a capped worker pool, and the editor
# plugin has to stay enabled for the dock (also checked by the editor smoke test).
$projectSettings = Get-Content (Join-Path $root 'project.godot') -Raw
$threadPoolOk = [bool]($projectSettings -match '(?m)^worker_pool/max_threads=1$')
$pluginEnabledOk = [bool]($projectSettings -match 'headless_pulse/plugin\.cfg')
Check 'project settings invariants' ($threadPoolOk -and $pluginEnabledOk) `
    "worker_pool/max_threads=1=$threadPoolOk editor_plugin=$pluginEnabledOk"

# --- 0c. uncovered script parse check --------------------------------------
# plugin.gd and sim_dock.gd only load in the editor, so the gameplay runs below
# never parse them; check them explicitly or a syntax error can ship green.
$uncoveredScripts = @(
    'res://addons/headless_pulse/plugin.gd',
    'res://addons/headless_pulse/ui/sim_dock.gd'
)
$parseOk = $true
$parseDetail = 'plugin.gd + sim_dock.gd parse cleanly'
foreach ($scriptPath in $uncoveredScripts) {
    $parseName = 'parse_' + [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)
    $parsed = Invoke-Godot $parseName ('--headless --check-only --path "' + $root + '" --script ' + $scriptPath)
    if ($parsed.ExitCode -ne 0) {
        $parseOk = $false
        $parseDetail = "failed: $scriptPath"
    }
}
Check 'uncovered script parse' $parseOk $parseDetail

# --- 0d. editor plugin load smoke ------------------------------------------
# Editor mode is the only mode that instantiates plugin.gd and the dock.
$editor = Invoke-Godot 'editor_load' ('--headless --editor --quit --path "' + $root + '"')
$editorLog = if (Test-Path $editor.Log) { Get-Content $editor.Log -Raw } else { '' }
$editorScriptError = [bool]($editorLog -match 'SCRIPT ERROR|Failed to load script')
Check 'editor plugin load' (($editor.ExitCode -eq 0) -and -not $editorScriptError) `
    "exit=$($editor.ExitCode) script_errors=$editorScriptError"

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

# --- 3b. A/B regression gate ----------------------------------------------
# A clearly-worse variant must make the CLI exit 4 with a failing gate, while
# relaxed limits let the same variant pass. The campaign above is the baseline.
$gateOverride = 'res://addons/headless_pulse/examples/arena_2d/weapons/smg.tres|damage=1'
$gateBaseline = 'res://reports/_verify/campaign/report.json'
$gateFail = Invoke-Godot 'gate_fail' ('--headless --path "' + $root + '" -s ' + $campaignScript +
    ' -- --sim-mode --sim-runs=20 --sim-seed=5000 --sim-max-time=60 --sim-out=reports/_verify/gate_fail' +
    ' --sim-baseline=' + $gateBaseline + ' --sim-fail-on-regression --sim-set="' + $gateOverride + '"')
$gateFailLog = if (Test-Path $gateFail.Log) { Get-Content $gateFail.Log -Raw } else { '' }
Check 'regression gate rejects drop' (($gateFail.ExitCode -eq 4) -and [bool]($gateFailLog -match 'regression gate FAILED')) `
    "exit=$($gateFail.ExitCode) (expected 4)"

$gatePass = Invoke-Godot 'gate_pass' ('--headless --path "' + $root + '" -s ' + $campaignScript +
    ' -- --sim-mode --sim-runs=20 --sim-seed=5000 --sim-max-time=60 --sim-out=reports/_verify/gate_pass' +
    ' --sim-baseline=' + $gateBaseline + ' --sim-fail-on-regression' +
    ' --sim-gate-win-drop=1.0 --sim-gate-survival-drop=60 --sim-gate-fail-on-new-critical=false' +
    ' --sim-set="' + $gateOverride + '"')
$gatePassLog = if (Test-Path $gatePass.Log) { Get-Content $gatePass.Log -Raw } else { '' }
Check 'regression gate allows limit' (($gatePass.ExitCode -eq 0) -and [bool]($gatePassLog -match 'regression gate passed')) `
    "exit=$($gatePass.ExitCode) (expected 0)"

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
