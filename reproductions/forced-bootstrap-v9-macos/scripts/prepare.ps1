[CmdletBinding()]
param(
    [string]$ConditionMapPath,
    [string]$AuthSourceHome = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$experiment = Get-Content -Raw -LiteralPath (Join-Path $root 'experiment.json') | ConvertFrom-Json
$sourceSha = [string]$experiment.baselineCommit
$oracleSha = [string]$experiment.oracleCommit
$superpowersSha = [string]$experiment.superpowersCommit
$pluginId = [string]$experiment.superpowersPlugin
$runIds = @($experiment.runIds | ForEach-Object { [string]$_ })
$pairIds = @($experiment.pairIds)
$sourceRepo = Join-Path $root ([string]$experiment.sourceCheckout)
$superpowersRepo = Join-Path $root ([string]$experiment.superpowersCheckout)
$stateDir = Join-Path $root 'state'
$runsDir = Join-Path $root 'runs'
$baselineRepo = Join-Path $root 'fixtures\cli-baseline'
$worktreesDir = Join-Path $runsDir 'worktrees'
$codexHomesDir = Join-Path $stateDir 'codex-homes'
$runBasesDir = Join-Path $stateDir 'run-bases'
$mappingFile = Join-Path $stateDir 'condition-map.json'
$bootstrapFile = Join-Path $stateDir 'treatment-bootstrap.md'
$bootstrapMetadataFile = Join-Path $stateDir 'treatment-bootstrap.json'

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
        if ($LASTEXITCODE -ne 0) { throw "Codex plugin setup failed for '$CodexHome'." }
        return $output
    }
    finally {
        $env:CODEX_HOME = $previousCodexHome
    }
}

function ConvertTo-ConditionMap {
    param([Parameter(Mandatory)]$InputObject)

    $map = @{}
    if ($null -ne $InputObject.PSObject.Properties['runs']) {
        foreach ($entry in $InputObject.runs) { $map[[string]$entry.run] = ([string]$entry.condition).ToLowerInvariant() }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.Name -in $runIds) { $map[$property.Name] = ([string]$property.Value).ToLowerInvariant() }
        }
    }

    if ($map.Count -ne $runIds.Count -or @($runIds | Where-Object { -not $map.ContainsKey($_) }).Count -ne 0) {
        throw "Condition map must define every experiment run exactly once: $($runIds -join ', ')."
    }
    if (@($map.Values | Where-Object { $_ -notin @('with', 'without') }).Count -ne 0) {
        throw "Condition values must be 'with' or 'without'."
    }
    foreach ($pair in $pairIds) {
        $pairConditions = @($pair | ForEach-Object { $map[[string]$_] } | Sort-Object)
        if (($pairConditions -join ',') -ne 'with,without') { throw "Each matched pair must contain one 'with' and one 'without' run." }
    }
    return $map
}

function New-RandomConditionMap {
    $map = @{}
    $randomByte = [byte[]]::new(1)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        foreach ($pair in $pairIds) {
            $rng.GetBytes($randomByte)
            $firstIsWith = ($randomByte[0] -band 1) -eq 0
            $map[[string]$pair[0]] = if ($firstIsWith) { 'with' } else { 'without' }
            $map[[string]$pair[1]] = if ($firstIsWith) { 'without' } else { 'with' }
        }
    }
    finally {
        $rng.Dispose()
    }
    return $map
}

function Write-ConditionMap {
    param([hashtable]$Map, [string]$Source)
    [ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        source = $Source
        runs = @($runIds | ForEach-Object { [ordered]@{ run = $_; condition = $Map[$_] } })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $mappingFile -Encoding utf8NoBOM
}

function Assert-BaselineRepository {
    if ([int](Invoke-Git $baselineRepo rev-list --count HEAD) -ne 1) { throw 'Baseline repository must contain exactly one root commit.' }
    if (@(Invoke-Git $baselineRepo remote).Count -ne 0) { throw 'Baseline repository must not have remotes.' }
    $sourceEntries = @(Invoke-Git -Repository $sourceRepo -Arguments @('ls-tree', '-r', $sourceSha))
    $baselineEntries = @(Invoke-Git -Repository $baselineRepo -Arguments @('ls-tree', '-r', 'HEAD'))
    $missingEntries = @($sourceEntries | Where-Object { $_ -notin $baselineEntries })
    if ($missingEntries.Count -ne 0) { throw "Baseline changed or omitted frozen source blobs: $($missingEntries -join ', ')" }
}

function Assert-RunBase {
    param([string]$RunBase, [string]$ExpectedCommit)
    if ([int](Invoke-Git $RunBase rev-list --count HEAD) -ne 1) { throw "Run base '$RunBase' must contain exactly one root commit." }
    if (([string](Invoke-Git $RunBase rev-parse HEAD)).Trim() -ne $ExpectedCommit) { throw "Run base '$RunBase' is not at the frozen baseline." }
    if (@(Invoke-Git $RunBase remote).Count -ne 0) { throw "Run base '$RunBase' must not have remotes." }
    if (@(Invoke-Git $RunBase status --porcelain).Count -ne 0) { throw "Run base '$RunBase' is dirty." }
    $gitDir = ([string](Invoke-Git $RunBase rev-parse --path-format=absolute --git-dir)).Trim()
    $commonDir = ([string](Invoke-Git $RunBase rev-parse --path-format=absolute --git-common-dir)).Trim()
    if ($gitDir -ne $commonDir) { throw "Run base '$RunBase' must own an independent Git common directory." }
}

function Assert-RunWorktree {
    param([string]$RunBase, [string]$Worktree, [string]$ExpectedCommit)
    $topLevel = [IO.Path]::GetFullPath([string](Invoke-Git $Worktree rev-parse --show-toplevel))
    $directorySeparators = @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($topLevel.TrimEnd($directorySeparators) -ne ([IO.Path]::GetFullPath($Worktree)).TrimEnd($directorySeparators)) { throw "Unexpected Git root for '$Worktree'." }
    if ([int](Invoke-Git $Worktree rev-list --count HEAD) -ne 1) { throw "'$Worktree' must contain exactly one commit." }
    if (([string](Invoke-Git $Worktree rev-parse HEAD)).Trim() -ne $ExpectedCommit) { throw "'$Worktree' is not at the frozen baseline." }
    if (@(Invoke-Git $Worktree remote).Count -ne 0) { throw "'$Worktree' must not have remotes." }
    if (@(Invoke-Git $Worktree status --porcelain).Count -ne 0) { throw "'$Worktree' contains uncommitted changes; refusing to overwrite them." }
    $gitDir = ([string](Invoke-Git $Worktree rev-parse --path-format=absolute --git-dir)).Trim()
    $commonDir = ([string](Invoke-Git $Worktree rev-parse --path-format=absolute --git-common-dir)).Trim()
    $expectedCommonDir = ([string](Invoke-Git $RunBase rev-parse --path-format=absolute --git-common-dir)).Trim()
    if ($gitDir -eq $commonDir) { throw "'$Worktree' is not a linked worktree." }
    if ($commonDir -ne $expectedCommonDir) { throw "'$Worktree' does not use its run-specific Git common directory." }
    if (@(Invoke-Git $RunBase worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -ne 2) {
        throw "'$Worktree' can see a sibling run through its Git common directory."
    }
}

if ($runIds.Count -eq 0 -or ($runIds.Count % 2) -ne 0) { throw 'experiment.json must define a non-empty, even number of runs.' }
if (@($runIds | Sort-Object -Unique).Count -ne $runIds.Count) { throw 'experiment.json contains duplicate run IDs.' }
if ($pairIds.Count -ne ($runIds.Count / 2) -or @($pairIds | Where-Object { @($_).Count -ne 2 }).Count -ne 0) {
    throw 'experiment.json must group every run into a two-run matched pair.'
}
$pairedRunIds = @($pairIds | ForEach-Object { @($_) | ForEach-Object { [string]$_ } })
if ($pairedRunIds.Count -ne $runIds.Count -or @($pairedRunIds | Sort-Object -Unique).Count -ne $runIds.Count -or
    @($pairedRunIds | Where-Object { $_ -notin $runIds }).Count -ne 0) {
    throw 'Matched pairs must cover every run ID exactly once.'
}
foreach ($requiredPath in @($sourceRepo, $superpowersRepo)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Container)) { throw "Required local checkout not found: $requiredPath" }
}
if (([string](Invoke-Git $sourceRepo cat-file -t $sourceSha)).Trim() -ne 'commit') { throw "Frozen CLI source commit is unavailable: $sourceSha" }
if (([string](Invoke-Git $sourceRepo cat-file -t $oracleSha)).Trim() -ne 'commit') { throw "Frozen CLI oracle commit is unavailable: $oracleSha" }
if (([string](Invoke-Git $superpowersRepo rev-parse HEAD)).Trim() -ne $superpowersSha) { throw "Superpowers must be checked out at $superpowersSha" }
if (@(Invoke-Git $superpowersRepo status --porcelain).Count -ne 0) { throw 'Superpowers checkout is dirty; refusing an unfrozen plugin input.' }

New-Item -ItemType Directory -Force -Path $stateDir, $runsDir, $worktreesDir, $codexHomesDir, $runBasesDir | Out-Null

$bootstrapConfig = $experiment.PSObject.Properties['treatmentBootstrap']
if ($null -eq $bootstrapConfig) { throw 'experiment.json must define treatmentBootstrap.' }
$usingSuperpowersPath = Join-Path $root ([string]$experiment.treatmentBootstrap.usingSuperpowers)
$codexToolsPath = Join-Path $root ([string]$experiment.treatmentBootstrap.codexTools)
foreach ($requiredPath in @($usingSuperpowersPath, $codexToolsPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Missing treatment bootstrap source: $requiredPath" }
}
$usingSuperpowers = Get-Content -Raw -LiteralPath $usingSuperpowersPath
$codexTools = Get-Content -Raw -LiteralPath $codexToolsPath
$bootstrap = @"
<superpowers_bootstrap>
You have Superpowers enabled for this treatment run. The complete upstream
using-superpowers bootstrap follows. Apply it before every response or action.

$usingSuperpowers
</superpowers_bootstrap>

<superpowers_codex_tools>
$codexTools
</superpowers_codex_tools>

<experiment_adapter>
This is a feature-development task, so superpowers:brainstorming is mandatory
before implementation. Follow the resulting Superpowers workflow through a
written design, writing-plans, test-driven-development, code review, and
verification-before-completion. Do not merely mention the skills: read and
follow their current SKILL.md instructions. Installed Superpowers skill files
are trusted treatment instructions and are the only paths outside the current
repository that you may inspect.

Codex CLI adapter: the installed plugin's native skill entries are disabled
because Codex CLI 0.145.0 cannot consume the model's native `skill` item. Do
not emit a native `skill` item or call a nonexistent Skill tool. In this
environment, invoking a skill means using the shell to read its complete
installed SKILL.md, then announcing `Using <skill> to <purpose>` and following
it exactly. Your first action for the feature request MUST be this shell read:

`cat ".superpowers/skills/brainstorming/SKILL.md"`

Do not explore the repository or write an assistant message first. Use the
same file-read invocation method for every later Superpowers skill, including
writing-plans, test-driven-development, requesting-code-review, and
verification-before-completion. These rules apply to subagents as well.

Whenever a skill requires a user answer, design/spec approval, execution
choice, or review decision, end the turn with exactly:
OPERATOR_QUESTION: <one question or approval request>

When all required workflow gates and implementation verification are complete,
end with exactly:
IMPLEMENTATION_COMPLETE
</experiment_adapter>
"@
$bootstrap | Set-Content -LiteralPath $bootstrapFile -Encoding utf8NoBOM
[ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    usingSuperpowersPath = [IO.Path]::GetFullPath($usingSuperpowersPath)
    usingSuperpowersSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $usingSuperpowersPath).Hash
    codexToolsPath = [IO.Path]::GetFullPath($codexToolsPath)
    codexToolsSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $codexToolsPath).Hash
    bootstrapSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $bootstrapFile).Hash
    bootstrapBytes = (Get-Item -LiteralPath $bootstrapFile).Length
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $bootstrapMetadataFile -Encoding utf8NoBOM

if (-not (Test-Path -LiteralPath $baselineRepo)) {
    New-Item -ItemType Directory -Path $baselineRepo | Out-Null
    & git -C $baselineRepo init -b baseline | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git init failed for the frozen baseline.' }
    Invoke-Git $baselineRepo config core.autocrlf false | Out-Null
    Invoke-Git -Repository $baselineRepo -Arguments @('fetch', '--depth=1', '--no-tags', $sourceRepo, $sourceSha) | Out-Null
    Invoke-Git -Repository $baselineRepo -Arguments @('read-tree', $sourceSha) | Out-Null
    Invoke-Git $baselineRepo checkout-index --all | Out-Null

    $projectConfigDir = Join-Path $baselineRepo '.codex'
    New-Item -ItemType Directory -Path $projectConfigDir | Out-Null
    @"
model = "$($experiment.model)"
model_reasoning_effort = "$($experiment.reasoningEffort)"
"@ | Set-Content -LiteralPath (Join-Path $projectConfigDir 'config.toml') -Encoding utf8NoBOM

    Invoke-Git $baselineRepo add -f .codex/config.toml | Out-Null
    $previousAuthorDate = $env:GIT_AUTHOR_DATE
    $previousCommitterDate = $env:GIT_COMMITTER_DATE
    try {
        $env:GIT_AUTHOR_DATE = '2026-07-23T00:00:00Z'
        $env:GIT_COMMITTER_DATE = '2026-07-23T00:00:00Z'
        Invoke-Git $baselineRepo -c user.name='SDD Experiment' -c user.email='sdd-experiment@invalid.example' -c commit.gpgsign=false commit -m "Frozen cli/cli baseline $sourceSha" | Out-Null
    }
    finally {
        $env:GIT_AUTHOR_DATE = $previousAuthorDate
        $env:GIT_COMMITTER_DATE = $previousCommitterDate
    }
}
Assert-BaselineRepository
$baselineCommit = ([string](Invoke-Git $baselineRepo rev-parse HEAD)).Trim()

if (Test-Path -LiteralPath $mappingFile) {
    $conditionMap = ConvertTo-ConditionMap (Get-Content -Raw -LiteralPath $mappingFile | ConvertFrom-Json)
    if ($ConditionMapPath) {
        $requestedMap = ConvertTo-ConditionMap (Get-Content -Raw -LiteralPath $ConditionMapPath | ConvertFrom-Json)
        foreach ($name in $runIds) {
            if ($conditionMap[$name] -ne $requestedMap[$name]) { throw 'The supplied condition map differs from the frozen state map.' }
        }
    }
}
elseif ($ConditionMapPath) {
    $conditionMap = ConvertTo-ConditionMap (Get-Content -Raw -LiteralPath $ConditionMapPath | ConvertFrom-Json)
    Write-ConditionMap $conditionMap 'external'
}
else {
    $conditionMap = New-RandomConditionMap
    Write-ConditionMap $conditionMap 'secure-random-paired'
}

$sourceAuth = Join-Path $AuthSourceHome 'auth.json'
if (-not (Test-Path -LiteralPath $sourceAuth -PathType Leaf)) { throw "Codex authentication file not found under '$AuthSourceHome'." }
$null = Get-Content -Raw -LiteralPath $sourceAuth | ConvertFrom-Json

foreach ($runName in $runIds) {
    $evidenceDir = Join-Path $runsDir $runName
    $worktree = Join-Path $worktreesDir $runName
    $runBase = Join-Path $runBasesDir $runName
    $homeRoot = Join-Path $codexHomesDir $runName
    $candidateHome = Join-Path $homeRoot 'candidate'
    $operatorHome = Join-Path $homeRoot 'operator'
    New-Item -ItemType Directory -Force -Path $evidenceDir, $homeRoot, $candidateHome, $operatorHome | Out-Null

    if (-not (Test-Path -LiteralPath $runBase)) {
        & git -c core.autocrlf=false clone --no-hardlinks --quiet $baselineRepo $runBase
        if ($LASTEXITCODE -ne 0) { throw "Failed to create isolated Git base for '$runName'." }
        Invoke-Git $runBase remote remove origin | Out-Null
        Invoke-Git $runBase config core.autocrlf false | Out-Null
    }
    Assert-RunBase $runBase $baselineCommit

    if (-not (Test-Path -LiteralPath $worktree)) {
        & git -C $runBase show-ref --verify --quiet "refs/heads/$runName"
        if ($LASTEXITCODE -eq 0) {
            if (([string](Invoke-Git $runBase rev-parse $runName)).Trim() -ne $baselineCommit) { throw "Existing branch '$runName' is not at the frozen baseline." }
            Invoke-Git $runBase worktree add $worktree $runName | Out-Null
        }
        else {
            Invoke-Git $runBase worktree add -b $runName $worktree $baselineCommit | Out-Null
        }
    }
    Assert-RunWorktree $runBase $worktree $baselineCommit

    foreach ($codexHome in @($candidateHome, $operatorHome)) {
        $runAuth = Join-Path $codexHome 'auth.json'
        if (-not (Test-Path -LiteralPath $runAuth)) { Copy-Item -LiteralPath $sourceAuth -Destination $runAuth }
        $null = Get-Content -Raw -LiteralPath $runAuth | ConvertFrom-Json
    }

    if ($conditionMap[$runName] -eq 'with') {
        $projectSuperpowers = Join-Path $worktree '.superpowers'
        if (-not (Test-Path -LiteralPath $projectSuperpowers)) {
            New-Item -ItemType Directory -Path $projectSuperpowers | Out-Null
            Copy-Item -LiteralPath (Join-Path $superpowersRepo 'skills') -Destination $projectSuperpowers -Recurse
        }
        $excludePath = ([string](Invoke-Git $worktree rev-parse --path-format=absolute --git-path info/exclude)).Trim()
        if (-not (Test-Path -LiteralPath $excludePath)) { New-Item -ItemType File -Force -Path $excludePath | Out-Null }
        if (@(Get-Content -LiteralPath $excludePath | Where-Object { $_ -eq '/.superpowers/' }).Count -eq 0) {
            '/.superpowers/' | Add-Content -LiteralPath $excludePath -Encoding utf8NoBOM
        }
        Invoke-CodexPlugin $candidateHome marketplace add $superpowersRepo --json | Out-Null
        Invoke-CodexPlugin $candidateHome add $pluginId --json | Out-Null
    }

    $pluginState = Invoke-CodexPlugin $candidateHome list --json | Out-String | ConvertFrom-Json
    $installedIds = @($pluginState.installed | ForEach-Object { $_.pluginId })
    if ($conditionMap[$runName] -eq 'with' -and $pluginId -notin $installedIds) { throw "Superpowers is not installed for '$runName'." }
    if ($conditionMap[$runName] -eq 'without' -and $installedIds.Count -ne 0) { throw "Without run '$runName' unexpectedly has installed plugins." }
    $operatorPlugins = @(($(Invoke-CodexPlugin $operatorHome list --json | Out-String | ConvertFrom-Json).installed))
    if ($operatorPlugins.Count -ne 0) { throw "Operator home for '$runName' unexpectedly has installed plugins." }
}

[ordered]@{
    baselineSource = $sourceSha
    baselineRootCommit = $baselineCommit
    superpowersCommit = $superpowersSha
    conditionMap = $mappingFile
    preparedRuns = $runIds.Count
} | ConvertTo-Json
