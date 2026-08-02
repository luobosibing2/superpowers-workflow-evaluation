[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$experiment = Get-Content -Raw -LiteralPath (Join-Path $root 'experiment.json') | ConvertFrom-Json
$mapping = Get-Content -Raw -LiteralPath (Join-Path $root 'state/condition-map.json') | ConvertFrom-Json
$expectedRoot = ([string](& git -C (Join-Path $root 'fixtures/cli-baseline') rev-parse HEAD)).Trim()
$adapterPath = Join-Path $root 'state/slim-adapter.md'
$adapter = Get-Content -Raw -LiteralPath $adapterPath
$inputManifest = Get-Content -Raw -LiteralPath (Join-Path $root 'inputs/slim-input-manifest.json') | ConvertFrom-Json
$commonDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rows = @()

function Get-PluginState([string]$ActorHome) {
    $previousHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $ActorHome
        $value = (& codex plugin list --json 2>&1 | Out-String) | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect plugin state: $ActorHome" }
        return $value
    }
    finally { $env:CODEX_HOME = $previousHome }
}

function New-DisabledSlimSkillsArgument([string]$CandidateHome) {
    $state = Get-PluginState $CandidateHome
    $installed = @($state.installed | Where-Object { [string]$_.pluginId -eq [string]$experiment.slimPlugin })
    if ($installed.Count -ne 1) { throw 'Candidate does not have exactly one frozen Slim plugin.' }
    if ([string]$installed[0].version -ne [string]$experiment.slimPluginVersion) { throw 'Installed Slim version mismatch.' }
    $skillsRoot = Join-Path $CandidateHome "plugins/cache/$($installed[0].marketplaceName)/$($installed[0].name)/$($installed[0].version)/skills"
    $actual = @(Get-ChildItem -LiteralPath $skillsRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | Select-Object -ExpandProperty Name | Sort-Object)
    $expected = @($experiment.slimSkills | ForEach-Object { [string]$_ } | Sort-Object)
    if (($actual -join ',') -ne ($expected -join ',')) { throw "Installed skill whitelist mismatch: $($actual -join ',')" }
    $entries = foreach ($name in $actual) {
        $path = (Join-Path $skillsRoot "$name/SKILL.md").Replace('\', '/')
        $expectedHash = [string]$inputManifest.files.PSObject.Properties["skills/$name/SKILL.md"].Value
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) { throw "Installed skill hash mismatch: $name" }
        "{ path = `"$path`", enabled = false }"
    }
    return 'skills.config=[' + ($entries -join ',') + ']'
}

foreach ($entry in @($mapping.runs)) {
    $run = [string]$entry.run
    $condition = [string]$entry.condition
    if ($condition -notin @('slim-requirement-loop','slim-requirement-review-loops')) { throw "Unexpected condition for ${run}: $condition" }
    $worktree = Join-Path $root "runs/worktrees/$run"
    $runBase = Join-Path $root "state/run-bases/$run"
    $candidateHome = Join-Path $root "state/codex-homes/$run/candidate"
    $operatorHome = Join-Path $root "state/codex-homes/$run/operator"
    $reviewerHome = Join-Path $root "state/codex-homes/$run/reviewer"
    $runStatePath = Join-Path $root "runs/$run/state.json"
    $existingCompleted = $false
    if (Test-Path -LiteralPath $runStatePath -PathType Leaf) {
        try { $existingCompleted = ([string](Get-Content -Raw -LiteralPath $runStatePath | ConvertFrom-Json).status) -eq 'completed' } catch { $existingCompleted = $false }
    }

    if ([int](& git -C $worktree rev-list --count HEAD) -ne 1) { throw "$run can see Git history." }
    if (([string](& git -C $worktree rev-parse HEAD)).Trim() -ne $expectedRoot) { throw "$run is not at the frozen root." }
    if (@(& git -C $worktree remote).Count -ne 0) { throw "$run has a Git remote." }
    if (-not $existingCompleted -and @(& git -C $worktree status --porcelain).Count -ne 0) { throw "$run is dirty before launch." }
    $commonDir = ([string](& git -C $worktree rev-parse --path-format=absolute --git-common-dir)).Trim()
    if (-not $commonDirs.Add($commonDir)) { throw "$run shares a Git common directory." }
    if (@(& git -C $runBase worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -ne 2) { throw "$run can see a sibling worktree." }

    $projectSkills = Join-Path $worktree '.slim-superpowers/skills'
    $projectNames = @(Get-ChildItem -LiteralPath $projectSkills -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | Select-Object -ExpandProperty Name | Sort-Object)
    $expectedNames = @($experiment.slimSkills | ForEach-Object { [string]$_ } | Sort-Object)
    if (($projectNames -join ',') -ne ($expectedNames -join ',')) { throw "$run project Slim skill whitelist mismatch." }
    foreach ($name in $projectNames) {
        $path = Join-Path $projectSkills "$name/SKILL.md"
        $expectedHash = [string]$inputManifest.files.PSObject.Properties["skills/$name/SKILL.md"].Value
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() -ne $expectedHash.ToLowerInvariant()) {
            throw "$run project Slim skill hash mismatch: $name"
        }
    }

    $candidatePlugins = Get-PluginState $candidateHome
    $candidateInstalled = @($candidatePlugins.installed | Where-Object { [string]$_.pluginId -eq [string]$experiment.slimPlugin })
    if ($candidateInstalled.Count -ne 1 -or @($candidatePlugins.installed).Count -ne 1) { throw "$run candidate plugin state is not exact." }
    if (@((Get-PluginState $operatorHome).installed).Count -ne 0) { throw "$run operator unexpectedly has a plugin." }
    if (@((Get-PluginState $reviewerHome).installed).Count -ne 0) { throw "$run reviewer unexpectedly has a plugin." }
    $disabledSkills = New-DisabledSlimSkillsArgument $candidateHome
    $candidateAdapter = if ($condition -eq 'slim-requirement-review-loops') {
        $adapter + "`n`nThis run includes an independent implementation reviewer. After an implementation pass and current tests are complete, do not emit IMPLEMENTATION_COMPLETE; emit exactly:`n`nREVIEW_READY`n`nIf the fresh reviewer returns REVIEW_CHANGES_REQUIRED, address valid critical or major findings, retest, and emit REVIEW_READY again. Continue until REVIEW_APPROVED or the normal token/time cap. After REVIEW_APPROVED, read verification-before-completion and end with IMPLEMENTATION_COMPLETE."
    } else {
        $adapter + "`n`nThis run has no independent implementation reviewer. After implementation and tests, do not emit REVIEW_READY; read verification-before-completion and end with IMPLEMENTATION_COMPLETE."
    }
    $adapterToml = ConvertTo-Json -Compress -InputObject $candidateAdapter

    $previousHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $candidateHome
        Push-Location $worktree
        try {
            $candidateArgs = @(
                'debug','prompt-input',
                '-c','default_permissions=":workspace"',
                '-c','approval_policy="on-request"',
                '-c','approvals_reviewer="auto_review"',
                '-c','web_search="disabled"',
                '-c',"developer_instructions=$adapterToml",
                '-c',$disabledSkills,
                'preflight'
            )
            $candidatePrompt = (& codex @candidateArgs 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "$run candidate prompt-input failed." }
        }
        finally { Pop-Location }
        $env:CODEX_HOME = $operatorHome
        Push-Location (Join-Path $root 'ground-truth/reference')
        try {
            $operatorArgs = @('debug','prompt-input','-c','default_permissions=":read-only"','preflight')
            $operatorPrompt = (& codex @operatorArgs 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "$run operator prompt-input failed." }
        }
        finally { Pop-Location }
    }
    finally { $env:CODEX_HOME = $previousHome }

    if ($candidatePrompt -match '- superpowers:(brainstorming|writing-plans|systematic-debugging|verification-before-completion):') {
        throw "$run unexpectedly exposes native Slim skill entries."
    }
    if ($candidatePrompt -notmatch '<slim_loops_adapter>' -or $candidatePrompt -notmatch 'DESIGN_REVIEW_REQUEST' -or $candidatePrompt -notmatch 'DESIGN_APPROVED') { throw "$run loop adapter is absent." }
    if ($condition -eq 'slim-requirement-review-loops') {
        if ($candidatePrompt -notmatch 'REVIEW_READY' -or $candidatePrompt -notmatch 'REVIEW_CHANGES_REQUIRED') { throw "$run review-loop marker contract is absent." }
    }
    elseif ($candidatePrompt -match '(?m)^REVIEW_READY\b|REVIEW_CHANGES_REQUIRED') {
        throw "$run requirement-only prompt unexpectedly exposes review markers."
    }
    if ($candidatePrompt -match '<superpowers_bootstrap>|test-driven-development|requesting-code-review|subagent-driven-development|executing-plans') {
        throw "$run contains a removed full-workflow instruction."
    }
    if ($operatorPrompt -match 'superpowers:|slim_superpowers_adapter') { throw "$run operator is treatment-contaminated." }
    if ($candidatePrompt -notmatch 'sandbox_mode.*workspace-write' -or $candidatePrompt -notmatch 'Network access is restricted') { throw "$run candidate permission profile is wrong." }
    if ($candidatePrompt -notmatch 'approvals_reviewer.*auto_review') { throw "$run candidate lacks automatic safety review." }
    if ($operatorPrompt -notmatch 'sandbox_mode.*read-only') { throw "$run operator is not read-only." }

    $rows += [pscustomobject]@{
        run = $run
        condition = $condition
        git_commits = 1
        remotes = 0
        private_git_common_dir = $true
        plugin_id = [string]$candidateInstalled[0].pluginId
        plugin_version = [string]$candidateInstalled[0].version
        project_skill_count = $projectNames.Count
        native_skills_disabled = $true
        slim_adapter_injected = $true
        operator_plugins_visible = $false
        reviewer_plugins_visible = $false
        reviewer_read_only = $true
    }
}

$catalog = (& codex debug models --bundled 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $catalog -notmatch [regex]::Escape([string]$experiment.model)) { throw "Configured model '$($experiment.model)' is absent." }

$reportPath = Join-Path $root 'state/preflight.json'
[ordered]@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    model = [string]$experiment.model
    reasoningEffort = [string]$experiment.reasoningEffort
    adapterSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $adapterPath).Hash.ToLowerInvariant()
    runs = $rows
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM

$rows | Format-Table -AutoSize
Write-Output "Preflight passed: $reportPath"
