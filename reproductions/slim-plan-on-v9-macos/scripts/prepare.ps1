[CmdletBinding()]
param(
    [string]$AuthSourceHome = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$experiment = Get-Content -Raw -LiteralPath (Join-Path $root 'experiment.json') | ConvertFrom-Json
$sourceRepo = Join-Path $root ([string]$experiment.sourceCheckout)
$pluginInput = Join-Path $root ([string]$experiment.slimPluginInput)
$inputManifestPath = Join-Path $root 'inputs/slim-input-manifest.json'
$stateDir = Join-Path $root 'state'
$runsDir = Join-Path $root 'runs'
$baselineRepo = Join-Path $root 'fixtures/cli-baseline'
$worktreesDir = Join-Path $runsDir 'worktrees'
$codexHomesDir = Join-Path $stateDir 'codex-homes'
$runBasesDir = Join-Path $stateDir 'run-bases'
$adapterPath = Join-Path $stateDir 'slim-adapter.md'
$adapterManifestPath = Join-Path $stateDir 'slim-adapter.json'
$conditionMapPath = Join-Path $stateDir 'condition-map.json'
$runIds = @($experiment.runIds | ForEach-Object { [string]$_ })

function Invoke-Git {
    param([string]$Repository, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git failed in '$Repository': $($output -join [Environment]::NewLine)" }
    return $output
}

function Invoke-CodexPlugin {
    param([string]$CodexHome, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $CodexHome
        $output = & codex plugin @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Codex plugin setup failed for '$CodexHome': $($output -join [Environment]::NewLine)" }
        return $output
    }
    finally { $env:CODEX_HOME = $previousCodexHome }
}

function Assert-SlimInput {
    $manifest = Get-Content -Raw -LiteralPath $inputManifestPath | ConvertFrom-Json
    if ([string]$manifest.sourceCommit -ne [string]$experiment.slimPluginCommit) { throw 'Slim source commit manifest mismatch.' }
    if ([string]$manifest.version -ne [string]$experiment.slimPluginVersion) { throw 'Slim version manifest mismatch.' }
    foreach ($property in $manifest.files.PSObject.Properties) {
        $path = Join-Path $pluginInput ([string]$property.Name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Slim input: $($property.Name)" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$property.Value).ToLowerInvariant()) { throw "Slim input hash mismatch: $($property.Name)" }
    }
    $actualSkills = @(Get-ChildItem -LiteralPath (Join-Path $pluginInput 'skills') -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
    } | Select-Object -ExpandProperty Name | Sort-Object)
    $expectedSkills = @($experiment.slimSkills | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actualSkills -join ',') -ne ($expectedSkills -join ',')) { throw "Slim skill whitelist mismatch: $($actualSkills -join ',')" }
}

function Assert-BaselineRepository {
    if (-not (Test-Path -LiteralPath (Join-Path $baselineRepo '.git'))) { throw 'Baseline repository is missing.' }
    if (@(Invoke-Git $baselineRepo rev-list --parents HEAD).Count -ne 1) { throw 'Baseline repository must contain one root commit.' }
    if (@(Invoke-Git $baselineRepo status --porcelain).Count -ne 0) { throw 'Baseline repository is dirty.' }
    if (@(Invoke-Git $baselineRepo remote).Count -ne 0) { throw 'Baseline repository has a remote.' }
    $subject = ([string](Invoke-Git $baselineRepo log -1 --format=%s)).Trim()
    if ($subject -ne "Frozen cli/cli baseline $($experiment.baselineCommit)") { throw "Unexpected baseline commit subject: $subject" }
}

function Assert-RunBase {
    param([string]$RunBase, [string]$BaselineCommit)
    if (([string](Invoke-Git $RunBase rev-parse HEAD)).Trim() -ne $BaselineCommit) { throw "Run base moved: $RunBase" }
    if (@(Invoke-Git $RunBase remote).Count -ne 0) { throw "Run base has a remote: $RunBase" }
    if (@(Invoke-Git $RunBase rev-list --count HEAD).Count -ne 1 -or ([int]([string](Invoke-Git $RunBase rev-list --count HEAD)).Trim()) -ne 1) {
        throw "Run base exposes history: $RunBase"
    }
}

function Assert-RunWorktree {
    param([string]$RunBase, [string]$Worktree, [string]$BaselineCommit)
    if (([string](Invoke-Git $Worktree rev-parse HEAD)).Trim() -ne $BaselineCommit) { throw "Run worktree moved: $Worktree" }
    if (@(Invoke-Git $Worktree remote).Count -ne 0) { throw "Run worktree has a remote: $Worktree" }
    if (@(Invoke-Git $Worktree status --porcelain).Count -ne 0) { throw "Run worktree is dirty before launch: $Worktree" }
    if (@(Invoke-Git $RunBase worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -ne 2) {
        throw "Run base exposes an unexpected sibling: $RunBase"
    }
}

if ($runIds.Count -ne 3 -or @($runIds | Sort-Object -Unique).Count -ne 3) { throw 'Slim experiment must define exactly three unique run IDs.' }
if ([string]$experiment.probeRun -notin $runIds) { throw 'probeRun must be one of runIds.' }
if (-not (Test-Path -LiteralPath $sourceRepo -PathType Container)) { throw "Missing source checkout: $sourceRepo" }
if (([string](Invoke-Git $sourceRepo cat-file -t ([string]$experiment.baselineCommit))).Trim() -ne 'commit') { throw 'Frozen baseline commit is unavailable.' }
Assert-SlimInput

New-Item -ItemType Directory -Force -Path $stateDir, $runsDir, $worktreesDir, $codexHomesDir, $runBasesDir | Out-Null

$adapter = Get-Content -Raw -LiteralPath (Join-Path $root 'inputs/slim-adapter.md')
$adapter | Set-Content -LiteralPath $adapterPath -Encoding utf8NoBOM
[ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceCommit = [string]$experiment.slimPluginCommit
    pluginVersion = [string]$experiment.slimPluginVersion
    adapterSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $adapterPath).Hash.ToLowerInvariant()
    skills = @($experiment.slimSkills | ForEach-Object {
        $relative = "skills/$_/SKILL.md"
        [ordered]@{ name = [string]$_; relativePath = $relative; sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $pluginInput $relative)).Hash.ToLowerInvariant() }
    })
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $adapterManifestPath -Encoding utf8NoBOM

if (-not (Test-Path -LiteralPath $baselineRepo)) {
    New-Item -ItemType Directory -Path $baselineRepo | Out-Null
    & git -C $baselineRepo init -b baseline | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init failed for the frozen baseline.' }
    Invoke-Git $baselineRepo config core.autocrlf false | Out-Null
    Invoke-Git -Repository $baselineRepo -Arguments @('fetch', '--depth=1', '--no-tags', $sourceRepo, [string]$experiment.baselineCommit) | Out-Null
    Invoke-Git -Repository $baselineRepo -Arguments @('read-tree', [string]$experiment.baselineCommit) | Out-Null
    Invoke-Git $baselineRepo checkout-index --all | Out-Null
    $projectConfigDir = Join-Path $baselineRepo '.codex'
    New-Item -ItemType Directory -Path $projectConfigDir | Out-Null
    "model = `"$($experiment.model)`"`nmodel_reasoning_effort = `"$($experiment.reasoningEffort)`"" |
        Set-Content -LiteralPath (Join-Path $projectConfigDir 'config.toml') -Encoding utf8NoBOM
    Invoke-Git $baselineRepo add -f .codex/config.toml | Out-Null
    $previousAuthorDate = $env:GIT_AUTHOR_DATE
    $previousCommitterDate = $env:GIT_COMMITTER_DATE
    try {
        $env:GIT_AUTHOR_DATE = '2026-07-31T00:00:00Z'
        $env:GIT_COMMITTER_DATE = '2026-07-31T00:00:00Z'
        Invoke-Git $baselineRepo -c user.name='Slim Experiment' -c user.email='slim-experiment@invalid.example' -c commit.gpgsign=false commit -m "Frozen cli/cli baseline $($experiment.baselineCommit)" | Out-Null
    }
    finally {
        $env:GIT_AUTHOR_DATE = $previousAuthorDate
        $env:GIT_COMMITTER_DATE = $previousCommitterDate
    }
}
Assert-BaselineRepository
$baselineCommit = ([string](Invoke-Git $baselineRepo rev-parse HEAD)).Trim()

[ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    source = 'fixed-slim-condition'
    runs = @($runIds | ForEach-Object { [ordered]@{ run = $_; condition = 'slim' } })
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $conditionMapPath -Encoding utf8NoBOM

$sourceAuth = Join-Path $AuthSourceHome 'auth.json'
if (-not (Test-Path -LiteralPath $sourceAuth -PathType Leaf)) { throw "Codex authentication file not found under '$AuthSourceHome'." }
$null = Get-Content -Raw -LiteralPath $sourceAuth | ConvertFrom-Json

foreach ($runName in $runIds) {
    $runDir = Join-Path $runsDir $runName
    $worktree = Join-Path $worktreesDir $runName
    $runBase = Join-Path $runBasesDir $runName
    $homeRoot = Join-Path $codexHomesDir $runName
    $candidateHome = Join-Path $homeRoot 'candidate'
    $operatorHome = Join-Path $homeRoot 'operator'
    New-Item -ItemType Directory -Force -Path $runDir, $candidateHome, $operatorHome | Out-Null

    if (-not (Test-Path -LiteralPath $runBase)) {
        & git -c core.autocrlf=false clone --no-hardlinks --quiet $baselineRepo $runBase
        if ($LASTEXITCODE -ne 0) { throw "Failed to create run base: $runName" }
        Invoke-Git $runBase remote remove origin | Out-Null
        Invoke-Git $runBase config core.autocrlf false | Out-Null
    }
    Assert-RunBase $runBase $baselineCommit
    if (-not (Test-Path -LiteralPath $worktree)) {
        Invoke-Git $runBase worktree add -b $runName $worktree $baselineCommit | Out-Null
    }
    Assert-RunWorktree $runBase $worktree $baselineCommit

    foreach ($codexHome in @($candidateHome, $operatorHome)) {
        $runAuth = Join-Path $codexHome 'auth.json'
        if (-not (Test-Path -LiteralPath $runAuth)) { Copy-Item -LiteralPath $sourceAuth -Destination $runAuth }
        $null = Get-Content -Raw -LiteralPath $runAuth | ConvertFrom-Json
    }

    $projectSlim = Join-Path $worktree '.slim-superpowers'
    if (-not (Test-Path -LiteralPath $projectSlim)) { Copy-Item -LiteralPath $pluginInput -Destination $projectSlim -Recurse }
    $excludePath = ([string](Invoke-Git $worktree rev-parse --path-format=absolute --git-path info/exclude)).Trim()
    if (-not (Test-Path -LiteralPath $excludePath)) { New-Item -ItemType File -Force -Path $excludePath | Out-Null }
    if (@(Get-Content -LiteralPath $excludePath | Where-Object { $_ -eq '/.slim-superpowers/' }).Count -eq 0) {
        '/.slim-superpowers/' | Add-Content -LiteralPath $excludePath -Encoding utf8NoBOM
    }
    Invoke-CodexPlugin $candidateHome marketplace add $pluginInput --json | Out-Null
    Invoke-CodexPlugin $candidateHome add ([string]$experiment.slimPlugin) --json | Out-Null
    $installed = @((Invoke-CodexPlugin $candidateHome list --json | Out-String | ConvertFrom-Json).installed | ForEach-Object { $_.pluginId })
    if ([string]$experiment.slimPlugin -notin $installed) { throw "Slim plugin is not installed for $runName." }
    if (@((Invoke-CodexPlugin $operatorHome list --json | Out-String | ConvertFrom-Json).installed).Count -ne 0) {
        throw "Operator unexpectedly has a plugin: $runName"
    }
}

[ordered]@{
    baselineSource = [string]$experiment.baselineCommit
    baselineRootCommit = $baselineCommit
    slimPluginCommit = [string]$experiment.slimPluginCommit
    adapter = $adapterPath
    preparedRuns = $runIds.Count
} | ConvertTo-Json
