[CmdletBinding()]
param(
    [ValidateSet('Bootstrap','Validate','Prepare','Preflight','Run','Judge','Summarize','All')]
    [string]$Action = 'Validate',
    [switch]$Resume,
    [ValidateRange(1, 6)][int]$JudgeMaxParallel = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $root '../..'))
$sourceCampaign = Join-Path $repositoryRoot 'campaigns/forced-bootstrap-v9'
$runtimeRoot = Join-Path $root '.runtime'
$codexRuntime = Join-Path $runtimeRoot 'codex-0.145.0'
$codexWrapper = Join-Path $codexRuntime 'node_modules/.bin/codex'
$codexCommand = Join-Path $codexRuntime 'node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex'
$sourceCheckout = Join-Path $repositoryRoot 'candidates/cli'
$oracleCheckout = Join-Path $repositoryRoot 'candidates/cli-oracle'
$superpowersCheckout = Join-Path $repositoryRoot 'tools/superpowers'
$referencePath = Join-Path $root 'ground-truth/reference'
$stateRoot = Join-Path $root 'state'
$reportsRoot = Join-Path $root 'reports'
$experiment = Get-Content -Raw -LiteralPath (Join-Path $root 'experiment.json') | ConvertFrom-Json

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = $repositoryRoot
    )
    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
        }
    }
    finally { Pop-Location }
}

function Get-ExternalOutput {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = $repositoryRoot
    )
    Push-Location $WorkingDirectory
    try {
        $output = @(& $Command @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
        }
        return ($output -join [Environment]::NewLine).Trim()
    }
    finally { Pop-Location }
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is missing: $Name"
    }
}

function Assert-CleanCheckout {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { return }
    $status = Get-ExternalOutput git @('-C', $Path, 'status', '--porcelain')
    if ($status) { throw "Refusing to replace dirty pinned checkout: $Path" }
}

function Set-PinnedCheckout {
    param(
        [string]$Repository,
        [string]$Path,
        [string[]]$Commits,
        [string]$CheckoutCommit
    )
    Assert-CleanCheckout $Path
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
        $repositoryConfig = Get-ExternalOutput git @('-C', $Path, 'config', '--list')
        if ($repositoryConfig -match '(?m)^remote\..+\.promisor=true$' -or
            $repositoryConfig -match '(?m)^remote\..+\.partialclonefilter=') {
            throw "Pinned checkout must be a complete clone for offline use: $Path"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        Invoke-External git @('clone', '--no-checkout', $Repository, $Path)
    }
    foreach ($commit in $Commits) {
        Invoke-External git @('-C', $Path, 'fetch', '--quiet', '--no-tags', '--depth', '1', 'origin', $commit)
    }
    Invoke-External git @('-C', $Path, 'checkout', '--detach', '--force', $CheckoutCommit)
    $actual = Get-ExternalOutput git @('-C', $Path, 'rev-parse', 'HEAD')
    if ($actual -ne $CheckoutCommit) { throw "Pinned checkout mismatch for ${Path}: $actual" }
}

function Set-OracleCheckout {
    Assert-CleanCheckout $oracleCheckout
    if (-not (Test-Path -LiteralPath (Join-Path $oracleCheckout '.git'))) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $oracleCheckout)) | Out-Null
        Invoke-External git @('clone', '--no-hardlinks', '--no-checkout', $sourceCheckout, $oracleCheckout)
        Invoke-External git @('-C', $oracleCheckout, 'remote', 'remove', 'origin')
    }
    Invoke-External git @('-C', $oracleCheckout, 'checkout', '--detach', '--force', ([string]$experiment.oracleCommit))
    $tree = Get-ExternalOutput git @('-C', $oracleCheckout, 'rev-parse', 'HEAD^{tree}')
    if ($tree -ne 'b4539ca014121861158af022e743c494436f1b1f') {
        throw "Oracle tree mismatch: $tree"
    }
    if (-not (Test-Path -LiteralPath $referencePath)) {
        New-Item -ItemType SymbolicLink -Path $referencePath -Target $oracleCheckout | Out-Null
    }
    $referenceItem = Get-Item -LiteralPath $referencePath -Force
    if ($referenceItem.LinkType -ne 'SymbolicLink') {
        throw "Ground Truth reference must be a symbolic link: $referencePath"
    }
    $resolvedReference = [IO.Path]::GetFullPath([string]$referenceItem.Target)
    if ($resolvedReference -ne [IO.Path]::GetFullPath($oracleCheckout)) {
        throw "Ground Truth reference points to the wrong checkout: $resolvedReference"
    }
}

function Install-PinnedCodex {
    [IO.Directory]::CreateDirectory($codexRuntime) | Out-Null
    if (-not (Test-Path -LiteralPath $codexCommand -PathType Leaf) -or
        -not (Test-Path -LiteralPath $codexWrapper -PathType Leaf)) {
        $previousCache = $env:npm_config_cache
        try {
            $env:npm_config_cache = Join-Path $codexRuntime 'npm-cache'
            Invoke-External npm @(
                'install', '--prefix', $codexRuntime, '--ignore-scripts',
                '--include=optional', '--no-save', '--package-lock=false',
                '--no-audit', '--no-fund', '@openai/codex@0.145.0'
            )
        }
        finally {
            if ($null -eq $previousCache) { Remove-Item -LiteralPath 'env:npm_config_cache' -ErrorAction SilentlyContinue }
            else { $env:npm_config_cache = $previousCache }
        }
    }
    $mainPackage = Get-Content -Raw -LiteralPath (Join-Path $codexRuntime 'node_modules/@openai/codex/package.json') | ConvertFrom-Json
    $platformPackage = Get-Content -Raw -LiteralPath (Join-Path $codexRuntime 'node_modules/@openai/codex-darwin-arm64/package.json') | ConvertFrom-Json
    if ($mainPackage.version -ne '0.145.0' -or $platformPackage.version -ne '0.145.0-darwin-arm64') {
        throw "Codex npm package pin mismatch: main=$($mainPackage.version) platform=$($platformPackage.version)"
    }
    $version = Get-ExternalOutput $codexCommand @('--version')
    if ($version -notmatch '0\.145\.0') {
        throw "Codex CLI pin mismatch: $version"
    }
    $runtimeBin = Split-Path -Parent $codexWrapper
    if (($env:PATH -split [IO.Path]::PathSeparator) -notcontains $runtimeBin) {
        $env:PATH = $runtimeBin + [IO.Path]::PathSeparator + $env:PATH
    }
    return $version
}

function Assert-FrozenAssets {
    $relativeAssets = @(
        'experiment.json',
        'pricing.json',
        'protocol.md',
        'task.md',
        'ground-truth/contract.md',
        'ground-truth/operator-guide.md',
        'ground-truth/rubric.md',
        'ground-truth/evidence/issue-13816.json',
        'ground-truth/evidence/manifest.json',
        'ground-truth/evidence/oracle.diff',
        'ground-truth/evidence/pr-13823.json',
        'ground-truth/evidence/review-comments.json',
        'evaluation/judge-output.schema.json',
        'evaluation/judge-prompt.md'
    )
    foreach ($relative in $relativeAssets) {
        $source = Join-Path $sourceCampaign $relative
        $copy = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $copy -PathType Leaf)) {
            throw "Missing frozen asset: $relative"
        }
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
        $copyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $copy).Hash
        if ($sourceHash -ne $copyHash) { throw "Frozen asset changed in macOS capsule: $relative" }
    }
}

function Write-PortManifest {
    param([string]$CodexVersion)
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $bootstrapManifestPath = Join-Path $stateRoot 'treatment-bootstrap.json'
    $bootstrapManifest = if (Test-Path -LiteralPath $bootstrapManifestPath -PathType Leaf) {
        Get-Content -Raw -LiteralPath $bootstrapManifestPath | ConvertFrom-Json
    } else { $null }
    $bootstrapHashes = $null
    if ($null -ne $bootstrapManifest) {
        $adaptedBootstrapPath = Join-Path $stateRoot 'treatment-bootstrap.md'
        $adaptedBootstrap = Get-Content -Raw -LiteralPath $adaptedBootstrapPath
        $originalCommand = 'Get-Content -Raw ".superpowers\skills\brainstorming\SKILL.md"'
        $adaptedCommand = 'cat ".superpowers/skills/brainstorming/SKILL.md"'
        $originalBootstrap = $adaptedBootstrap.Replace($adaptedCommand, $originalCommand)
        if ($originalBootstrap -eq $adaptedBootstrap) {
            throw 'Unable to reconstruct the frozen v9 bootstrap for manifest hashing.'
        }
        $originalBytes = [Text.Encoding]::UTF8.GetBytes($originalBootstrap)
        $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
        $bootstrapHashes = [ordered]@{
            source = 'reconstructed frozen v9 bootstrap with the original PowerShell skill-read command'
            originalSha256 = $originalHash.ToLowerInvariant()
            adaptedSha256 = ([string]$bootstrapManifest.bootstrapSha256).ToLowerInvariant()
            originalCommand = $originalCommand
            adaptedCommand = $adaptedCommand
        }
    }
    $scriptNames = @(
        'prepare.ps1',
        'preflight.ps1',
        'orchestrate.ps1',
        'run-blind-judge.ps1',
        'freeze-product-code-diffs.ps1',
        'summarize.ps1'
    )
    $scriptHashes = foreach ($name in $scriptNames) {
        $source = Join-Path $sourceCampaign "scripts/$name"
        $adapted = Join-Path $root "scripts/$name"
        [ordered]@{
            path = "scripts/$name"
            sourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.ToLowerInvariant()
            adaptedSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $adapted).Hash.ToLowerInvariant()
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        upstream = [ordered]@{
            repository = 'kvenux/workflow-arena'
            commit = (Get-ExternalOutput git @('-C', $repositoryRoot, 'rev-parse', 'HEAD'))
            sourceCampaign = 'campaigns/forced-bootstrap-v9'
        }
        experiment = [ordered]@{
            model = [string]$experiment.model
            reasoningEffort = [string]$experiment.reasoningEffort
            candidateSoftTokenCap = [long]$experiment.softTokenCap
            wallClockMinutes = [int]$experiment.wallClockMinutes
            runCount = @($experiment.runIds).Count
        }
        pins = [ordered]@{
            baselineCommit = [string]$experiment.baselineCommit
            oracleCommit = [string]$experiment.oracleCommit
            oracleTree = 'b4539ca014121861158af022e743c494436f1b1f'
            superpowersCommit = [string]$experiment.superpowersCommit
            superpowersVersion = [string]$experiment.superpowersVersion
            codexVersion = $CodexVersion
        }
        host = [ordered]@{
            os = [Environment]::OSVersion.VersionString
            architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            powershell = $PSVersionTable.PSVersion.ToString()
            go = (Get-ExternalOutput go @('version'))
            node = (Get-ExternalOutput node @('--version'))
            npm = (Get-ExternalOutput npm @('--version'))
        }
        platformDeltas = @(
            'POSIX path and user-home resolution',
            'Darwin ARM64 Codex executable resolution',
            'focused tests launched by /bin/zsh -lc',
            'project-local skills read with cat',
            'Ground Truth reference linked with a POSIX symbolic link'
        )
        treatmentBootstrap = $bootstrapHashes
        scripts = $scriptHashes
    }
    $manifestPath = Join-Path $stateRoot 'port-manifest.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
    return $manifestPath
}

function Invoke-Bootstrap {
    foreach ($command in @('git','node','npm','go','pwsh')) { Assert-Command $command }
    Assert-FrozenAssets
    $codexVersion = Install-PinnedCodex
    Set-PinnedCheckout 'https://github.com/cli/cli.git' $sourceCheckout @(
        [string]$experiment.baselineCommit,
        [string]$experiment.oracleCommit
    ) ([string]$experiment.baselineCommit)
    Set-OracleCheckout
    Set-PinnedCheckout 'https://github.com/obra/superpowers.git' $superpowersCheckout @(
        [string]$experiment.superpowersCommit
    ) ([string]$experiment.superpowersCommit)
    if (Get-ExternalOutput git @('-C', $superpowersCheckout, 'status', '--porcelain')) {
        throw 'Pinned Superpowers checkout is dirty.'
    }
    Invoke-External go @('mod', 'download') $sourceCheckout
    $manifestPath = Write-PortManifest $codexVersion
    Write-Output "Bootstrap passed: $manifestPath"
}

function Invoke-Validate {
    Assert-FrozenAssets
    $codexVersion = Install-PinnedCodex
    $repositoryCommit = Get-ExternalOutput git @('-C', $repositoryRoot, 'rev-parse', 'HEAD')
    if ($repositoryCommit -ne '0b87a36de85494b15b9fe9991c55fdeeb1dcf713') {
        throw "Workflow Arena checkout moved from the frozen upstream commit: $repositoryCommit"
    }
    $frozenDiff = Get-ExternalOutput git @('-C', $repositoryRoot, 'diff', '--', 'campaigns/forced-bootstrap-v9')
    if ($frozenDiff) { throw 'The frozen forced-bootstrap-v9 campaign was modified.' }
    $shellCheck = Get-ExternalOutput /bin/zsh @('-lc', 'printf macos-adapter-ok')
    if ($shellCheck -ne 'macos-adapter-ok') { throw 'POSIX shell adapter self-test failed.' }
    & (Join-Path $root 'scripts/orchestrate.ps1') -Root $root -SelfTest
    & (Join-Path $root 'scripts/run-blind-judge.ps1') -Root $root -SelfTest
    & (Join-Path $root 'scripts/summarize-selftest.ps1')
    Write-PortManifest $codexVersion | Out-Null
    Write-Output 'macOS adapter validation passed.'
}

function Invoke-Prepare {
    Install-PinnedCodex | Out-Null
    & (Join-Path $root 'scripts/prepare.ps1')
    if (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'condition-map.json'))) {
        throw 'Prepare did not freeze a condition map.'
    }
}

function Invoke-OfflineBaselineTest {
    $logPath = Join-Path $stateRoot 'offline-baseline-test.log'
    $previous = @{
        GOPROXY = $env:GOPROXY
        HTTP_PROXY = $env:HTTP_PROXY
        HTTPS_PROXY = $env:HTTPS_PROXY
        NO_PROXY = $env:NO_PROXY
    }
    try {
        $env:GOPROXY = 'off'
        $env:HTTP_PROXY = 'http://127.0.0.1:9'
        $env:HTTPS_PROXY = 'http://127.0.0.1:9'
        $env:NO_PROXY = ''
        Push-Location (Join-Path $root 'fixtures/cli-baseline')
        try {
            $lines = @(& /bin/zsh -lc ([string]@($experiment.focusedTests)[0]) 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally { Pop-Location }
        @(
            "COMMAND: $([string]@($experiment.focusedTests)[0])",
            $lines,
            "EXIT_CODE: $exitCode"
        ) | Set-Content -LiteralPath $logPath -Encoding utf8NoBOM
        if ($exitCode -ne 0) { throw "Offline baseline test failed; see $logPath" }
    }
    finally {
        foreach ($key in $previous.Keys) {
            if ($null -eq $previous[$key]) { Remove-Item -LiteralPath "env:$key" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "env:$key" -Value $previous[$key] }
        }
    }
    Write-Output "Offline baseline test passed: $logPath"
}

function Invoke-Preflight {
    Install-PinnedCodex | Out-Null
    & (Join-Path $root 'scripts/preflight.ps1')
    Invoke-OfflineBaselineTest
}

function Invoke-Runs {
    Install-PinnedCodex | Out-Null
    $preflight = Join-Path $stateRoot 'preflight.json'
    if (-not (Test-Path -LiteralPath $preflight -PathType Leaf)) {
        throw 'Preflight evidence is missing; run -Action Preflight before spending model quota.'
    }
    & (Join-Path $root 'scripts/orchestrate.ps1') -Root $root -CodexCommand $codexCommand -Resume:$Resume
}

function New-BlindMap {
    $path = Join-Path $stateRoot 'blind-map.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $runs = @($experiment.runIds | ForEach-Object { [string]$_ })
    $shuffled = @($runs | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
    $labels = 'Candidate-A','Candidate-B','Candidate-C','Candidate-D','Candidate-E','Candidate-F'
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
        if ($state.status -notin @('completed', 'token_cap')) {
            throw "Run is not valid for judging: $run status=$($state.status)"
        }
    }
}

function Invoke-Judges {
    Install-PinnedCodex | Out-Null
    Assert-JudgeableRuns
    [IO.Directory]::CreateDirectory($reportsRoot) | Out-Null
    New-BlindMap | Out-Null
    & (Join-Path $root 'scripts/freeze-product-code-diffs.ps1') -Root $root
    & (Join-Path $root 'scripts/run-blind-judge.ps1') -Root $root -Replicate 1 -MaxParallel $JudgeMaxParallel -Resume:$Resume
    & (Join-Path $root 'scripts/run-blind-judge.ps1') -Root $root -Replicate 2 -MaxParallel $JudgeMaxParallel -SkipPrepare -Resume:$Resume
}

function Invoke-Summarize {
    [IO.Directory]::CreateDirectory($reportsRoot) | Out-Null
    & (Join-Path $root 'scripts/summarize.ps1') -RunsPath (Join-Path $root 'runs') -ReportsPath $reportsRoot
    & (Join-Path $root 'scripts/summarize-reproduction.ps1') -Root $root
    Copy-Item -LiteralPath (Join-Path $stateRoot 'port-manifest.json') -Destination (Join-Path $reportsRoot 'port-manifest.json') -Force
}

switch ($Action) {
    'Bootstrap' { Invoke-Bootstrap }
    'Validate' { Invoke-Validate }
    'Prepare' { Invoke-Prepare }
    'Preflight' { Invoke-Preflight }
    'Run' { Invoke-Runs }
    'Judge' { Invoke-Judges }
    'Summarize' { Invoke-Summarize }
    'All' {
        Invoke-Bootstrap
        Invoke-Validate
        Invoke-Prepare
        Invoke-Preflight
        Invoke-Runs
        Invoke-Judges
        Invoke-Summarize
    }
}
