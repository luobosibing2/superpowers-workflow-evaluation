[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$experiment = Get-Content -Raw -LiteralPath (Join-Path $root 'experiment.json') | ConvertFrom-Json
$mapping = Get-Content -Raw -LiteralPath (Join-Path $root 'state\condition-map.json') | ConvertFrom-Json
$expectedRoot = ([string](& git -C (Join-Path $root 'fixtures\cli-baseline') rev-parse HEAD)).Trim()
$commonDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rows = @()
$bootstrapPath = Join-Path $root 'state\treatment-bootstrap.md'
$bootstrap = Get-Content -Raw -LiteralPath $bootstrapPath
$bootstrapToml = ConvertTo-Json -Compress -InputObject $bootstrap

function New-DisabledSuperpowersSkillsArgument {
    param([string]$CandidateHome, [string]$Version)
    $skillsRoot = Join-Path $CandidateHome "plugins\cache\superpowers-dev\superpowers\$Version\skills"
    $entries = Get-ChildItem -LiteralPath $skillsRoot -Directory | ForEach-Object {
        $path = (Join-Path $_.FullName 'SKILL.md').Replace('\', '/')
        if (Test-Path -LiteralPath $path) { "{ path = `"$path`", enabled = false }" }
    }
    return 'skills.config=[' + ($entries -join ',') + ']'
}

foreach ($entry in @($mapping.runs)) {
    $run = [string]$entry.run
    $condition = [string]$entry.condition
    $worktree = Join-Path $root "runs\worktrees\$run"
    $runBase = Join-Path $root "state\run-bases\$run"
    $candidateHome = Join-Path $root "state\codex-homes\$run\candidate"
    $operatorHome = Join-Path $root "state\codex-homes\$run\operator"

    if ([int](& git -C $worktree rev-list --count HEAD) -ne 1) { throw "$run can see Git history." }
    if (([string](& git -C $worktree rev-parse HEAD)).Trim() -ne $expectedRoot) { throw "$run is not at the frozen root." }
    if (@(& git -C $worktree remote).Count -ne 0) { throw "$run has a Git remote." }
    if (@(& git -C $worktree status --porcelain).Count -ne 0) { throw "$run is dirty before launch." }
    $projectSkill = Join-Path $worktree '.superpowers\skills\brainstorming\SKILL.md'
    if ((Test-Path -LiteralPath $projectSkill) -ne ($condition -eq 'with')) { throw "$run project-level Superpowers files do not match condition '$condition'." }
    $commonDir = ([string](& git -C $worktree rev-parse --path-format=absolute --git-common-dir)).Trim()
    if (-not $commonDirs.Add($commonDir)) { throw "$run shares a Git common directory with another run." }
    if (@(& git -C $runBase worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count -ne 2) {
        throw "$run can see a sibling worktree."
    }

    $previousHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $candidateHome
        Push-Location $worktree
        try {
            $candidateArgs = @('debug', 'prompt-input', '-c', 'default_permissions=":workspace"', '-c', 'approval_policy="on-request"', '-c', 'approvals_reviewer="auto_review"')
            if ($condition -eq 'with') {
                $candidateArgs += @('-c', "developer_instructions=$bootstrapToml", '-c', (New-DisabledSuperpowersSkillsArgument $candidateHome ([string]$experiment.superpowersVersion)))
            }
            $candidateArgs += 'preflight'
            $candidatePrompt = (& codex @candidateArgs 2>&1) -join "`n"
        }
        finally { Pop-Location }
        $env:CODEX_HOME = $operatorHome
        Push-Location (Join-Path $root 'ground-truth\reference')
        try { $operatorPrompt = (& codex debug prompt-input -c 'default_permissions=":read-only"' 'preflight' 2>&1) -join "`n" }
        finally { Pop-Location }
    }
    finally { $env:CODEX_HOME = $previousHome }

    $hasSuperpowers = $candidatePrompt -match '- superpowers:brainstorming:'
    if ($hasSuperpowers) { throw "$run unexpectedly exposes native Superpowers skill entries." }
    if ($candidatePrompt -match 'ponytail:' -or $operatorPrompt -match 'superpowers:|ponytail:') {
        throw "$run has an unintended candidate/operator skill."
    }
    $hasBootstrap = $candidatePrompt -match '<superpowers_bootstrap>' -and $candidatePrompt -match '<experiment_adapter>' -and $candidatePrompt -match 'test-driven-development'
    if ($hasBootstrap -ne ($condition -eq 'with')) { throw "$run bootstrap injection does not match condition '$condition'." }
    if ($candidatePrompt -notmatch 'sandbox_mode.*workspace-write' -or $candidatePrompt -notmatch 'Network access is restricted') {
        throw "$run candidate does not have the expected write-only/offline permission profile."
    }
    if ($candidatePrompt -notmatch 'approvals_reviewer.*auto_review') { throw "$run candidate does not use automatic safety review." }
    if ($operatorPrompt -notmatch 'sandbox_mode.*read-only') { throw "$run operator is not read-only." }
    $rows += [pscustomobject]@{
        run = $run
        condition = $condition
        git_commits = 1
        remotes = 0
        private_git_common_dir = $true
        superpowers_visible = $hasSuperpowers
        bootstrap_injected = $hasBootstrap
        project_superpowers_installed = (Test-Path -LiteralPath $projectSkill)
        operator_plugins_visible = $false
    }
}

$catalog = (& codex debug models --bundled 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $catalog -notmatch [regex]::Escape([string]$experiment.model)) {
    throw "Configured model '$($experiment.model)' is absent from the local Codex catalog."
}

$reportPath = Join-Path $root 'state\preflight.json'
[ordered]@{
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    model = [string]$experiment.model
    reasoningEffort = [string]$experiment.reasoningEffort
    runs = $rows
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM

$rows | Format-Table -AutoSize
Write-Output "Preflight passed: $reportPath"
