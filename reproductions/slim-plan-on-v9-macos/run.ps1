[CmdletBinding()]
param(
    [ValidateSet('Bootstrap','Validate','Prepare','Preflight','Run','Judge','Summarize','All')]
    [string]$Action = 'Validate',
    [switch]$Resume,
    [ValidateRange(1, 3)][int]$JudgeMaxParallel = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $root '../..'))
$sourceCapsule = Join-Path $repositoryRoot 'reproductions/forced-bootstrap-v9-macos'
$sourceCheckout = Join-Path $repositoryRoot 'candidates/cli'
$oracleCheckout = Join-Path $repositoryRoot 'candidates/cli-oracle'
$referencePath = Join-Path $root 'ground-truth/reference'
$stateRoot = Join-Path $root 'state'
$reportsRoot = Join-Path $root 'reports'
$runtimeRoot = Join-Path $root '.runtime'
$codexRuntime = Join-Path $runtimeRoot 'codex-0.145.0'
$sourceCodexRuntime = Join-Path $sourceCapsule '.runtime/codex-0.145.0'
$codexWrapper = Join-Path $codexRuntime 'node_modules/.bin/codex'
$codexCommand = Join-Path $codexRuntime 'node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex'
$experiment = Get-Content -Raw -LiteralPath (Join-Path $root 'experiment.json') | ConvertFrom-Json

function Invoke-External {
    param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory = $repositoryRoot)
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command $($Arguments -join ' ')" }
    }
    finally { Pop-Location }
}

function Get-ExternalOutput {
    param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory = $repositoryRoot)
    Push-Location $WorkingDirectory
    try {
        $output = @(& $Command @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
        return ($output -join [Environment]::NewLine).Trim()
    }
    finally { Pop-Location }
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required command is missing: $Name" }
}

function Install-PinnedCodex {
    if (-not (Test-Path -LiteralPath $codexCommand -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
        if (Test-Path -LiteralPath $sourceCodexRuntime -PathType Container) {
            Copy-Item -LiteralPath $sourceCodexRuntime -Destination $codexRuntime -Recurse
        }
        else {
            New-Item -ItemType Directory -Force -Path $codexRuntime | Out-Null
            $previousCache = $env:npm_config_cache
            try {
                $env:npm_config_cache = Join-Path $codexRuntime 'npm-cache'
                Invoke-External npm @('install','--prefix',$codexRuntime,'--ignore-scripts','--include=optional','--no-save','--package-lock=false','--no-audit','--no-fund','@openai/codex@0.145.0')
            }
            finally {
                if ($null -eq $previousCache) { Remove-Item -LiteralPath 'env:npm_config_cache' -ErrorAction SilentlyContinue }
                else { $env:npm_config_cache = $previousCache }
            }
        }
    }
    $mainPackage = Get-Content -Raw -LiteralPath (Join-Path $codexRuntime 'node_modules/@openai/codex/package.json') | ConvertFrom-Json
    $platformPackage = Get-Content -Raw -LiteralPath (Join-Path $codexRuntime 'node_modules/@openai/codex-darwin-arm64/package.json') | ConvertFrom-Json
    if ($mainPackage.version -ne '0.145.0' -or $platformPackage.version -ne '0.145.0-darwin-arm64') { throw 'Codex package pin mismatch.' }
    $version = Get-ExternalOutput $codexCommand @('--version')
    if ($version -notmatch '0\.145\.0') { throw "Codex version mismatch: $version" }
    $runtimeBin = Split-Path -Parent $codexWrapper
    if (($env:PATH -split [IO.Path]::PathSeparator) -notcontains $runtimeBin) { $env:PATH = $runtimeBin + [IO.Path]::PathSeparator + $env:PATH }
    return $version
}

function Assert-FrozenInputs {
    $shared = @(
        'task.md','pricing.json','ground-truth/contract.md','ground-truth/operator-guide.md','ground-truth/rubric.md',
        'ground-truth/evidence/issue-13816.json','ground-truth/evidence/manifest.json','ground-truth/evidence/oracle.diff',
        'ground-truth/evidence/pr-13823.json','ground-truth/evidence/review-comments.json',
        'evaluation/judge-output.schema.json','evaluation/judge-prompt.md'
    )
    foreach ($relative in $shared) {
        $source = Join-Path $sourceCapsule $relative
        $copy = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $copy -PathType Leaf)) { throw "Missing frozen input: $relative" }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $copy).Hash) { throw "Frozen input changed: $relative" }
    }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'inputs/slim-input-manifest.json') | ConvertFrom-Json
    $pluginRoot = Join-Path $root ([string]$experiment.slimPluginInput)
    foreach ($property in $manifest.files.PSObject.Properties) {
        $file = Join-Path $pluginRoot ([string]$property.Name)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing Slim input: $($property.Name)" }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant() -ne ([string]$property.Value).ToLowerInvariant()) { throw "Slim input changed: $($property.Name)" }
    }
}

function Assert-SourcePins {
    $head = Get-ExternalOutput git @('-C',$sourceCheckout,'rev-parse','HEAD')
    if ($head -ne [string]$experiment.baselineCommit) { throw "Source checkout moved: $head" }
    if (Get-ExternalOutput git @('-C',$sourceCheckout,'status','--porcelain')) { throw 'Source checkout is dirty.' }
    if ((Get-ExternalOutput git @('-C',$sourceCheckout,'cat-file','-t',[string]$experiment.oracleCommit)) -ne 'commit') { throw 'Oracle commit is unavailable.' }
    $oracleHead = Get-ExternalOutput git @('-C',$oracleCheckout,'rev-parse','HEAD')
    $oracleTree = Get-ExternalOutput git @('-C',$oracleCheckout,'rev-parse','HEAD^{tree}')
    if ($oracleHead -ne [string]$experiment.oracleCommit -or $oracleTree -ne [string]$experiment.oracleTree) { throw 'Oracle checkout pin mismatch.' }
    if (-not (Test-Path -LiteralPath $referencePath)) { New-Item -ItemType SymbolicLink -Path $referencePath -Target $oracleCheckout | Out-Null }
    $reference = Get-Item -LiteralPath $referencePath -Force
    if ($reference.LinkType -ne 'SymbolicLink' -or [IO.Path]::GetFullPath([string]$reference.Target) -ne [IO.Path]::GetFullPath($oracleCheckout)) { throw 'Ground Truth reference link mismatch.' }
}

function Get-DirectoryAggregate([string]$Path) {
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName)
    $lines = foreach ($file in $files) {
        $relative = $file.FullName.Substring($Path.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant())  $relative"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    return [ordered]@{
        fileCount = $files.Count
        bytes = [long](($files | Measure-Object Length -Sum).Sum)
        aggregateSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Write-SourceIntegritySnapshot {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $sourceRuns = Join-Path $sourceCapsule 'runs'
    $runRows = foreach ($run in @('run-01','run-02','run-03','run-04','run-05','run-06')) {
        $state = Get-Content -Raw -LiteralPath (Join-Path $sourceRuns "$run/state.json") | ConvertFrom-Json
        $aggregate = Get-DirectoryAggregate (Join-Path $sourceRuns $run)
        [ordered]@{ runId = $run; condition = [string]$state.condition; status = [string]$state.status; fileCount = $aggregate.fileCount; bytes = $aggregate.bytes; aggregateSha256 = $aggregate.aggregateSha256 }
    }
    [ordered]@{
        schemaVersion = 1
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        repositoryCommit = Get-ExternalOutput git @('-C',$repositoryRoot,'rev-parse','HEAD')
        sourceCapsule = '../forced-bootstrap-v9-macos'
        keyFiles = @('state/condition-map.json','reports/metrics.json','reports/metrics.csv','reports/reproduction-report.md','evaluation/deblinded-summary.json') | ForEach-Object {
            $path = Join-Path $sourceCapsule $_
            [ordered]@{ path = $_; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $path).Length }
        }
        runs = $runRows
        slimInput = [ordered]@{ commit = [string]$experiment.slimPluginCommit; version = [string]$experiment.slimPluginVersion; manifestSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'inputs/slim-input-manifest.json')).Hash.ToLowerInvariant() }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stateRoot 'source-integrity-before.json') -Encoding utf8NoBOM
}

function Assert-SourceIntegrityUnchanged {
    $snapshotPath = Join-Path $stateRoot 'source-integrity-before.json'
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw 'Missing source integrity snapshot.' }
    $snapshot = Get-Content -Raw -LiteralPath $snapshotPath | ConvertFrom-Json
    foreach ($entry in @($snapshot.keyFiles)) {
        $path = Join-Path $sourceCapsule ([string]$entry.path)
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -ne [string]$entry.sha256) { throw "Frozen source file changed: $($entry.path)" }
    }
    foreach ($entry in @($snapshot.runs)) {
        $aggregate = Get-DirectoryAggregate (Join-Path $sourceCapsule "runs/$($entry.runId)")
        if ($aggregate.aggregateSha256 -ne [string]$entry.aggregateSha256 -or $aggregate.fileCount -ne [int]$entry.fileCount) { throw "Frozen source run changed: $($entry.runId)" }
    }
}

function Write-PortManifest([string]$CodexVersion) {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'inputs/slim-input-manifest.json') | ConvertFrom-Json
    [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        workflowArena = [ordered]@{ commit = Get-ExternalOutput git @('-C',$repositoryRoot,'rev-parse','HEAD'); sourceCapsule = '../forced-bootstrap-v9-macos' }
        pins = [ordered]@{ baselineCommit = [string]$experiment.baselineCommit; oracleCommit = [string]$experiment.oracleCommit; oracleTree = [string]$experiment.oracleTree; codexVersion = $CodexVersion; slimPluginCommit = [string]$experiment.slimPluginCommit; slimPluginVersion = [string]$experiment.slimPluginVersion }
        experiment = [ordered]@{ model = [string]$experiment.model; reasoningEffort = [string]$experiment.reasoningEffort; runCount = @($experiment.runIds).Count; softTokenCap = [long]$experiment.softTokenCap; wallClockMinutes = [int]$experiment.wallClockMinutes; maxSubagents = [int]$experiment.maxSubagentsPerRun; judges = 0 }
        slimInputs = @($manifest.files.PSObject.Properties | ForEach-Object { [ordered]@{ path = $_.Name; sha256 = [string]$_.Value } })
        adapter = [ordered]@{ path = 'inputs/slim-adapter.md'; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'inputs/slim-adapter.md')).Hash.ToLowerInvariant(); nativeSkillsDisabled = $true; delivery = 'project-local exact files plus shell-read compatibility adapter' }
        host = [ordered]@{ os = [Environment]::OSVersion.VersionString; architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); powershell = $PSVersionTable.PSVersion.ToString(); go = Get-ExternalOutput go @('version'); node = Get-ExternalOutput node @('--version'); npm = Get-ExternalOutput npm @('--version') }
        boundaries = @('Later non-contemporaneous add-on; no randomized three-arm contrast','No blind judging or product score','Codex 0.145.0 native skill-item compatibility adapter')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'port-manifest.json') -Encoding utf8NoBOM
}

function Invoke-Bootstrap {
    foreach ($command in @('git','node','npm','go','pwsh','python3')) { Assert-Command $command }
    Assert-FrozenInputs
    $codexVersion = Install-PinnedCodex
    Assert-SourcePins
    Invoke-External go @('mod','download') $sourceCheckout
    Write-SourceIntegritySnapshot
    Write-PortManifest $codexVersion
    Write-Output 'Bootstrap passed.'
}

function Invoke-Validate {
    Assert-FrozenInputs
    $codexVersion = Install-PinnedCodex
    Assert-SourcePins
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'source-integrity.json') -PathType Leaf) { Assert-SourceIntegrityUnchanged }
    else { Write-SourceIntegritySnapshot }
    Invoke-External python3 @('-m','unittest','discover','-s',(Join-Path $root 'inputs/slim-superpowers/tests'),'-p','test_slim_contract.py') $root
    & (Join-Path $root 'scripts/orchestrate.ps1') -Root $root -SelfTest
    & (Join-Path $root 'scripts/audit-adoption.ps1') -Root $root -SelfTest
    & (Join-Path $root 'scripts/freeze-product-code-diffs.ps1') -Root $root -SelfTest
    & (Join-Path $root 'scripts/run-blind-judge.ps1') -Root $root -SelfTest
    Write-PortManifest $codexVersion
    Write-Output 'Slim adapter validation passed.'
}

function Invoke-Prepare {
    Install-PinnedCodex | Out-Null
    & (Join-Path $root 'scripts/prepare.ps1')
}

function Invoke-OfflineBaselineTest {
    $logPath = Join-Path $stateRoot 'offline-baseline-test.log'
    $previous = @{ GOPROXY=$env:GOPROXY; HTTP_PROXY=$env:HTTP_PROXY; HTTPS_PROXY=$env:HTTPS_PROXY; NO_PROXY=$env:NO_PROXY }
    try {
        $env:GOPROXY='off'; $env:HTTP_PROXY='http://127.0.0.1:9'; $env:HTTPS_PROXY='http://127.0.0.1:9'; $env:NO_PROXY=''
        Push-Location (Join-Path $root 'fixtures/cli-baseline')
        try { $lines = @(& /bin/zsh -lc ([string]@($experiment.focusedTests)[0]) 2>&1); $exitCode = $LASTEXITCODE }
        finally { Pop-Location }
        @("COMMAND: $([string]@($experiment.focusedTests)[0])",$lines,"EXIT_CODE: $exitCode") | Set-Content -LiteralPath $logPath -Encoding utf8NoBOM
        if ($exitCode -ne 0) { throw "Offline baseline test failed; see $logPath" }
    }
    finally {
        foreach ($key in $previous.Keys) {
            if ($null -eq $previous[$key]) { Remove-Item -LiteralPath "env:$key" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "env:$key" -Value $previous[$key] }
        }
    }
}

function Invoke-Preflight {
    Install-PinnedCodex | Out-Null
    & (Join-Path $root 'scripts/preflight.ps1')
    Invoke-OfflineBaselineTest
}

function Invoke-Runs {
    Install-PinnedCodex | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'preflight.json') -PathType Leaf)) { throw 'Preflight evidence is missing.' }
    & (Join-Path $root 'scripts/orchestrate.ps1') -Root $root -CodexCommand $codexCommand -Resume:$Resume
}

function New-BlindMap {
    $path = Join-Path $stateRoot 'blind-map.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $runs = @($experiment.runIds | ForEach-Object { [string]$_ })
    $shuffled = @($runs | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
    $labels = 'Candidate-A','Candidate-B','Candidate-C'
    [ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        source = 'secure-random'
        candidates = @(for ($index = 0; $index -lt $labels.Count; $index++) {
            [ordered]@{ candidate = $labels[$index]; run = $shuffled[$index] }
        })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Assert-JudgeableRuns {
    foreach ($run in @($experiment.runIds | ForEach-Object { [string]$_ })) {
        $statePath = Join-Path $root "runs/$run/state.json"
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "Missing run state: $run" }
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ($state.status -notin @('completed','token_cap')) { throw "Run is not judgeable: $run status=$($state.status)" }
        if (-not (Test-Path -LiteralPath (Join-Path $root "runs/$run/tests.log") -PathType Leaf)) { throw "Missing focused-test evidence: $run" }
    }
}

function Invoke-Judges {
    Install-PinnedCodex | Out-Null
    Assert-JudgeableRuns
    New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
    New-BlindMap | Out-Null
    & (Join-Path $root 'scripts/freeze-product-code-diffs.ps1') -Root $root
    & (Join-Path $root 'scripts/run-blind-judge.ps1') -Root $root -CodexCommand $codexCommand -Replicate 1 -MaxParallel $JudgeMaxParallel -Resume:$Resume
    & (Join-Path $root 'scripts/run-blind-judge.ps1') -Root $root -CodexCommand $codexCommand -Replicate 2 -MaxParallel $JudgeMaxParallel -SkipPrepare -Resume:$Resume
}

function Invoke-Summarize {
    New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
    & (Join-Path $root 'scripts/freeze-product-code-diffs.ps1') -Root $root
    & (Join-Path $root 'scripts/summarize.ps1') -RunsPath (Join-Path $root 'runs') -ReportsPath $reportsRoot
    & (Join-Path $root 'scripts/audit-adoption.ps1') -Root $root
    & python3 (Join-Path $root 'scripts/audit_judges.py') --root $root
    if ($LASTEXITCODE -ne 0) { throw 'Slim judge audit failed.' }
    & python3 (Join-Path $root 'scripts/summarize_slim_judges.py') --root $root
    if ($LASTEXITCODE -ne 0) { throw 'Slim judge summarization failed.' }
    Copy-Item -LiteralPath (Join-Path $stateRoot 'port-manifest.json') -Destination (Join-Path $reportsRoot 'port-manifest.json') -Force
    Assert-SourceIntegrityUnchanged
}

switch ($Action) {
    'Bootstrap' { Invoke-Bootstrap }
    'Validate' { Invoke-Validate }
    'Prepare' { Invoke-Prepare }
    'Preflight' { Invoke-Preflight }
    'Run' { Invoke-Runs }
    'Judge' { Invoke-Judges }
    'Summarize' { Invoke-Summarize }
    'All' { Invoke-Bootstrap; Invoke-Validate; Invoke-Prepare; Invoke-Preflight; Invoke-Runs; Invoke-Judges; Invoke-Summarize }
}
