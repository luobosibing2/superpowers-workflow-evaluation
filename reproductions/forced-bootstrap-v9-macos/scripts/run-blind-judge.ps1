[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$MaxParallel = 2,
    [int]$TimeoutMinutes = 60,
    [ValidateRange(1, 99)][int]$Replicate = 1,
    [switch]$PrepareOnly,
    [switch]$SkipPrepare,
    [switch]$Resume,
    [switch]$SelfTest,
    [string]$InternalCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-BlindMap {
    param([string]$Path)
    $map = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $labels = @($map.candidates | ForEach-Object { [string]$_.candidate })
    $runs = @($map.candidates | ForEach-Object { [string]$_.run })
    if (($labels | Sort-Object) -join ',' -ne 'Candidate-A,Candidate-B,Candidate-C,Candidate-D,Candidate-E,Candidate-F' -or
        ($runs | Sort-Object) -join ',' -ne 'run-01,run-02,run-03,run-04,run-05,run-06') {
        throw 'blind-map.json must map Candidate-A..F bijectively to run-01..06.'
    }
    return $map
}

function New-AnonymousPackages {
    param([string]$ExperimentRoot, [object]$BlindMap)
    $candidateRoot = Join-Path $ExperimentRoot 'evaluation\candidates'
    New-Item -ItemType Directory -Force -Path $candidateRoot | Out-Null
    foreach ($entry in $BlindMap.candidates) {
        $label = [string]$entry.candidate
        $run = [string]$entry.run
        $sourceDiff = Join-Path $ExperimentRoot "runs\$run\product-code.diff"
        if (-not (Test-Path -LiteralPath $sourceDiff -PathType Leaf)) { throw "Missing frozen product diff for $run." }
        $package = Join-Path $candidateRoot $label
        New-Item -ItemType Directory -Force -Path $package | Out-Null
        $copies = [ordered]@{
            'task.md' = Join-Path $ExperimentRoot 'task.md'
            'contract.md' = Join-Path $ExperimentRoot 'ground-truth\contract.md'
            'rubric.md' = Join-Path $ExperimentRoot 'ground-truth\rubric.md'
            'product.diff' = $sourceDiff
            'tests.log' = Join-Path $ExperimentRoot "runs\$run\tests.log"
            'judge-prompt.md' = Join-Path $ExperimentRoot 'evaluation\judge-prompt.md'
        }
        foreach ($copy in $copies.GetEnumerator()) {
            if (-not (Test-Path -LiteralPath $copy.Value -PathType Leaf)) { throw "Missing judge input: $($copy.Value)" }
            Copy-Item -LiteralPath $copy.Value -Destination (Join-Path $package $copy.Key) -Force
        }
        foreach ($relativePath in @(
            'pkg\cmd\project\item-list\item_list.go',
            'pkg\cmd\project\shared\queries\resolve_fields.go',
            'pkg\cmd\project\shared\queries\queries.go'
        )) {
            $baselineSource = Join-Path $ExperimentRoot "fixtures\cli-baseline\$relativePath"
            if (-not (Test-Path -LiteralPath $baselineSource -PathType Leaf)) { throw "Missing baseline judge context: $baselineSource" }
            $baselineTarget = Join-Path $package "baseline\$relativePath"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $baselineTarget) | Out-Null
            Copy-Item -LiteralPath $baselineSource -Destination $baselineTarget -Force
        }
        $files = Get-ChildItem -LiteralPath $package -File -Recurse | Where-Object Name -ne 'manifest.json' | Sort-Object FullName
        [ordered]@{
            schemaVersion = 2
            candidate = $label
            files = @($files | ForEach-Object {
                [ordered]@{
                    name = $_.FullName.Substring($package.Length).TrimStart('\', '/').Replace('\', '/')
                    bytes = $_.Length
                    sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
                }
            })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $package 'manifest.json') -Encoding utf8NoBOM
    }
}

function Assert-JudgeResult {
    param([string]$Path, [string]$Candidate)
    $result = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($result.candidate -ne $Candidate) { throw "Judge returned the wrong anonymous label for $Candidate." }
    if (@($result.dimensions).Count -ne 6) { throw "Judge must return six rubric dimensions for $Candidate." }
    $maxima = @($result.dimensions | ForEach-Object { [int]$_.maxScore })
    if (($maxima | Measure-Object -Sum).Sum -ne 100) { throw "Rubric maxima do not sum to 100 for $Candidate." }
    $score = ($result.dimensions | Measure-Object score -Sum).Sum
    if ($score -ne [int]$result.totalScore) { throw "Dimension scores do not match totalScore for $Candidate." }
}

function Get-JudgeUsage {
    param([string]$JsonlPath)
    $usage = [ordered]@{ inputTokens = 0L; cachedInputTokens = 0L; outputTokens = 0L; totalTokens = 0L }
    if (-not (Test-Path -LiteralPath $JsonlPath)) { return $usage }
    foreach ($line in Get-Content -LiteralPath $JsonlPath) {
        if ($line -notmatch '"type"\s*:\s*"turn\.completed"') { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        $usageValue = $event.usage
        $usage.inputTokens += [long]$usageValue.input_tokens
        $usage.cachedInputTokens += [long]$usageValue.cached_input_tokens
        $usage.outputTokens += [long]$usageValue.output_tokens
    }
    $usage.totalTokens = $usage.inputTokens + $usage.outputTokens
    return $usage
}

function Assert-PluginFreeHome {
    param([string]$JudgeHome)
    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $JudgeHome
        $pluginState = (& codex plugin list --json 2>&1 | Out-String) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or @($pluginState.installed).Count -ne 0) { throw "Judge CODEX_HOME has installed plugins: $JudgeHome" }
    }
    finally { $env:CODEX_HOME = $previousCodexHome }
}

function Invoke-Judge {
    param([string]$ExperimentRoot, [string]$Candidate, [int]$LimitMinutes, [bool]$Continue, [int]$JudgeReplicate)
    $package = Join-Path $ExperimentRoot "evaluation\candidates\$Candidate"
    $resultRoot = Join-Path $ExperimentRoot "evaluation\results\judge-$('{0:d2}' -f $JudgeReplicate)\$Candidate"
    $judgeHome = Join-Path $ExperimentRoot "evaluation\.judge-homes\judge-$('{0:d2}' -f $JudgeReplicate)\$Candidate"
    $finalPath = Join-Path $resultRoot 'judge.final.json'
    $statePath = Join-Path $resultRoot 'metadata.json'
    New-Item -ItemType Directory -Force -Path $resultRoot, $judgeHome | Out-Null
    if (Test-Path -LiteralPath $finalPath) {
        if (-not $Continue) { throw "$Candidate already has a result; pass -Resume to reuse it." }
        Assert-JudgeResult $finalPath $Candidate
        if (-not (Test-Path -LiteralPath $statePath)) {
            $existingJsonl = Join-Path $resultRoot 'judge.jsonl'
            if (-not (Test-Path -LiteralPath $existingJsonl)) { throw "$Candidate has a final result but no raw JSONL; archive it and rerun to restore complete evidence." }
            Write-JsonAtomic $statePath ([ordered]@{
                schemaVersion = 2; candidate = $Candidate; replicate = $JudgeReplicate; model = 'gpt-5.6-terra'; reasoningEffort = 'high'
                sandbox = 'read-only'; recoveredAfterHarnessInterruption = $true; usage = Get-JudgeUsage $existingJsonl
            })
        }
        return
    }

    $sourceAuth = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex/auth.json'
    if (-not (Test-Path -LiteralPath $sourceAuth)) { throw "Codex auth is missing: $sourceAuth" }
    Copy-Item -LiteralPath $sourceAuth -Destination (Join-Path $judgeHome 'auth.json') -Force
    Assert-PluginFreeHome $judgeHome

    $prompt = (Get-Content -Raw -LiteralPath (Join-Path $package 'judge-prompt.md')) + "`n`nAnonymous candidate label: $Candidate"
    $promptPath = Join-Path $resultRoot 'prompt.txt'
    $prompt | Set-Content -LiteralPath $promptPath -Encoding utf8NoBOM
    $stdoutPath = Join-Path $resultRoot 'judge.jsonl'
    $stderrPath = Join-Path $resultRoot 'judge.stderr.txt'
    $schema = Join-Path $ExperimentRoot 'evaluation\judge-output.schema.json'
    $codex = (Get-Command codex -ErrorAction Stop).Source
    $arguments = @(
        'exec', '--json', '--ignore-user-config', '-m', 'gpt-5.6-terra',
        '-c', 'model_reasoning_effort="high"',
        '-c', 'approval_policy="never"',
        '-c', 'web_search="disabled"',
        '-c', 'features.multi_agent=false',
        '-c', 'sandbox_workspace_write.network_access=false',
        '-s', 'read-only', '-C', $package,
        '--output-schema', $schema, '-o', $finalPath, '-'
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $codex
    $info.WorkingDirectory = $package
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['CODEX_HOME'] = $judgeHome
    foreach ($argument in $arguments) { $null = $info.ArgumentList.Add($argument) }

    $started = [DateTime]::UtcNow
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Failed to start blind judge for $Candidate." }
    $process.StandardInput.Write($prompt)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($LimitMinutes * 60 * 1000)) {
        $process.Kill($true)
        throw "Blind judge timed out for $Candidate."
    }
    $stdoutTask.Result | Set-Content -LiteralPath $stdoutPath -Encoding utf8NoBOM
    $stderrTask.Result | Set-Content -LiteralPath $stderrPath -Encoding utf8NoBOM
    if ($process.ExitCode -ne 0) { throw "Blind judge exited with $($process.ExitCode) for $Candidate; see $stderrPath" }
    Assert-JudgeResult $finalPath $Candidate

    $usage = Get-JudgeUsage $stdoutPath
    Write-JsonAtomic $statePath ([ordered]@{
        schemaVersion = 2
        candidate = $Candidate
        replicate = $JudgeReplicate
        model = 'gpt-5.6-terra'
        reasoningEffort = 'high'
        sandbox = 'read-only'
        startedAtUtc = $started.ToString('o')
        endedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
        usage = $usage
    })
}

function Invoke-SelfTest {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("blind-map-selftest-$([guid]::NewGuid().ToString('n')).json")
    try {
        [ordered]@{
            schemaVersion = 1
            candidates = @(
                [ordered]@{ candidate = 'Candidate-A'; run = 'run-01' },
                [ordered]@{ candidate = 'Candidate-B'; run = 'run-02' },
                [ordered]@{ candidate = 'Candidate-C'; run = 'run-03' },
                [ordered]@{ candidate = 'Candidate-D'; run = 'run-04' },
                [ordered]@{ candidate = 'Candidate-E'; run = 'run-05' },
                [ordered]@{ candidate = 'Candidate-F'; run = 'run-06' }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
        $map = Get-BlindMap $temp
        if (@($map.candidates).Count -ne 6) { throw 'Blind map self-test failed.' }
        $schema = Get-Content -Raw -LiteralPath (Join-Path $Root 'evaluation/judge-output.schema.json') | ConvertFrom-Json
        if ($schema.properties.totalScore.maximum -ne 100) { throw 'Judge schema self-test failed.' }
        'blind judge self-test passed'
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
$blindMap = Get-BlindMap (Join-Path $Root 'state\blind-map.json')

if ($InternalCandidate) {
    Invoke-Judge $Root $InternalCandidate $TimeoutMinutes $Resume.IsPresent $Replicate
    exit
}

if (-not $SkipPrepare) { New-AnonymousPackages $Root $blindMap }
if ($PrepareOnly) {
    "Prepared $(@($blindMap.candidates).Count) anonymous candidate packages."
    exit
}
if ($MaxParallel -lt 1) { throw 'MaxParallel must be positive.' }

$scriptPath = $MyInvocation.MyCommand.Path
$rootValue = $Root
$timeoutValue = $TimeoutMinutes
$resumeValue = $Resume.IsPresent
$replicateValue = $Replicate
$outcomes = @($blindMap.candidates | ForEach-Object { [string]$_.candidate }) | ForEach-Object -Parallel {
    try {
        & $using:scriptPath -Root $using:rootValue -TimeoutMinutes $using:timeoutValue -Replicate $using:replicateValue -Resume:$using:resumeValue -InternalCandidate $_
        [pscustomobject]@{ candidate = $_; ok = $true; error = $null }
    }
    catch { [pscustomobject]@{ candidate = $_; ok = $false; error = $_.Exception.Message } }
} -ThrottleLimit $MaxParallel
$failures = @($outcomes | Where-Object { -not $_.ok })
if ($failures.Count -gt 0) { throw "Blind judge failures: $(($failures | ForEach-Object { "$($_.candidate): $($_.error)" }) -join '; ')" }

'Blind judging complete.'
