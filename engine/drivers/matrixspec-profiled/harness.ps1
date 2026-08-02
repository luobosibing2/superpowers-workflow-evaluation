Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-MatrixJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing JSON: $Path" }
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-MatrixJson([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-MatrixText([string]$Path, [string]$Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Get-MatrixValue($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    $property.Value
}

function Resolve-MatrixPath([string]$Base, [string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function Get-MatrixContext([string]$ExperimentPath, [string]$PlanPath) {
    $resolvedExperiment = (Resolve-Path -LiteralPath $ExperimentPath).Path
    $experiment = Read-MatrixJson $resolvedExperiment
    $experimentDirectory = Split-Path -Parent $resolvedExperiment
    $workspace = Resolve-MatrixPath $experimentDirectory ([string](Get-MatrixValue $experiment 'workspaceRoot' '../..'))
    $taskPath = Resolve-MatrixPath $experimentDirectory ([string]$experiment.taskPack)
    $task = Read-MatrixJson $taskPath
    $campaign = Resolve-MatrixPath $workspace ([string]$experiment.driverConfig.campaignRoot)
    $plan = Read-MatrixJson $PlanPath
    $capabilityPath = Resolve-MatrixPath $experimentDirectory ([string]$experiment.capabilities.matrixSpec)
    $capability = Read-MatrixJson $capabilityPath
    $matrixRoot = Resolve-MatrixPath $workspace ([string]$capability.source.checkout)
    $referenceRoot = Resolve-MatrixPath $workspace ([string]$task.assets.reference)
    [pscustomobject]@{
        experimentPath = $resolvedExperiment
        experimentDirectory = $experimentDirectory
        workspace = $workspace
        experiment = $experiment
        taskPath = $taskPath
        task = $task
        campaign = $campaign
        plan = $plan
        capabilityPath = $capabilityPath
        capability = $capability
        matrixRoot = $matrixRoot
        matrixCli = Join-Path $matrixRoot 'bin\matspec.js'
        referenceRoot = $referenceRoot
    }
}

function Invoke-MatrixGit([string]$Repository, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments) {
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git failed in '$Repository': $($output -join [Environment]::NewLine)" }
    $output
}

function Assert-MatrixFrozenGit([string]$Repository, [string]$Commit, [switch]$AllowDirty) {
    if (-not (Test-Path -LiteralPath $Repository -PathType Container)) { throw "Missing Git repository: $Repository" }
    $head = ([string](Invoke-MatrixGit $Repository rev-parse HEAD)).Trim()
    if ($head -ne $Commit) { throw "Unexpected HEAD in '$Repository': $head" }
    if (([int]([string](Invoke-MatrixGit $Repository rev-list --count HEAD)).Trim()) -ne 1) { throw "Repository is not single-commit: $Repository" }
    if (@(Invoke-MatrixGit $Repository remote).Count) { throw "Repository exposes remotes: $Repository" }
    if (-not $AllowDirty -and @(Invoke-MatrixGit $Repository status --porcelain).Count) { throw "Repository is dirty: $Repository" }
    $head
}

function Initialize-MatrixCodexHome([string]$CodexHome, [string]$AuthSource, [string]$Model, [string]$Effort) {
    [IO.Directory]::CreateDirectory($CodexHome) | Out-Null
    if (-not (Test-Path -LiteralPath $AuthSource -PathType Leaf)) { throw "Missing Codex auth: $AuthSource" }
    Copy-Item -LiteralPath $AuthSource -Destination (Join-Path $CodexHome 'auth.json') -Force
    $config = @"
model = "$Model"
model_reasoning_effort = "$Effort"
approval_policy = "never"
web_search = "disabled"

[features]
multi_agent = false

[sandbox_workspace_write]
network_access = false
"@
    Write-MatrixText (Join-Path $CodexHome 'config.toml') ($config + "`n")
}

function Invoke-MatrixProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$StdoutPath,
        [string]$StderrPath,
        [int]$TimeoutMinutes,
        [string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    [IO.Directory]::CreateDirectory((Split-Path -Parent $StdoutPath)) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path -Parent $StderrPath)) | Out-Null
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $info.StandardInputEncoding = $utf8
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    foreach ($argument in $Arguments) { $null = $info.ArgumentList.Add($argument) }
    foreach ($entry in $Environment.GetEnumerator()) { $info.Environment[[string]$entry.Key] = [string]$entry.Value }
    $started = [DateTime]::UtcNow
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Failed to start: $Executable" }
    if ($InputText) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutMinutes * 60 * 1000)
    if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
    Write-MatrixText $StdoutPath $stdoutTask.Result
    Write-MatrixText $StderrPath $stderrTask.Result
    [pscustomobject]@{
        exitCode = $process.ExitCode
        timedOut = $timedOut
        startedAtUtc = $started.ToString('o')
        endedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
        stdout = $stdoutTask.Result
        stderr = $stderrTask.Result
    }
}

function Get-MatrixLogSummary([string[]]$Paths) {
    $summary = [ordered]@{
        threadId = ''
        finalMessage = ''
        turns = 0
        parseErrors = 0
        toolCalls = 0
        usage = [ordered]@{ inputTokens=0L; cachedInputTokens=0L; outputTokens=0L; reasoningOutputTokens=0L; totalTokens=0L }
    }
    foreach ($path in @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
        foreach ($line in [IO.File]::ReadLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $event = $line | ConvertFrom-Json } catch { $summary.parseErrors++; continue }
            if ($event.type -eq 'thread.started') { $summary.threadId = [string]$event.thread_id }
            if ($event.type -eq 'turn.started') { $summary.turns++ }
            if ($event.type -eq 'item.completed') {
                if ($event.item.type -eq 'agent_message') { $summary.finalMessage = [string]$event.item.text }
                elseif ($event.item.type -notin @('reasoning')) { $summary.toolCalls++ }
            }
            if ($event.type -eq 'turn.completed' -and $null -ne $event.usage) {
                $inputTokens = [long]$event.usage.input_tokens
                $outputTokens = [long]$event.usage.output_tokens
                $summary.usage.inputTokens += $inputTokens
                $summary.usage.cachedInputTokens += [long]$event.usage.cached_input_tokens
                $summary.usage.outputTokens += $outputTokens
                $summary.usage.reasoningOutputTokens += [long]$event.usage.reasoning_output_tokens
                $summary.usage.totalTokens += $inputTokens + $outputTokens
            }
        }
    }
    [pscustomobject]$summary
}

function New-MatrixCodexArguments([string]$Model, [string]$Effort, [string]$FinalPath, [string]$ThreadId = '', [string]$WorkingDirectory = '') {
    $common = @(
        '--json', '--ignore-user-config', '-m', $Model,
        '-c', "model_reasoning_effort=`"$Effort`"",
        '-c', 'default_permissions=":workspace"',
        '-c', 'approval_policy="on-request"',
        '-c', 'approvals_reviewer="auto_review"',
        '-c', 'web_search="disabled"',
        '-c', 'features.multi_agent=false',
        '-c', 'sandbox_workspace_write.network_access=false'
    )
    if ($ThreadId) { return @('exec','resume') + $common + @('-o',$FinalPath,$ThreadId,'-') }
    @('exec') + $common + @('-C',$WorkingDirectory,'-o',$FinalPath,'-')
}

function Invoke-MatrixCodexTurn {
    param(
        [string]$Worktree, [string]$CodexHome, [string]$Prompt, [string]$LogRoot,
        [string]$Actor, [int]$Turn, [string]$Model, [string]$Effort,
        [int]$TimeoutMinutes, [string]$ThreadId = ''
    )
    $prefix = '{0}-turn-{1:d2}' -f $Actor,$Turn
    $stdout = Join-Path $LogRoot "$prefix.jsonl"
    $stderr = Join-Path $LogRoot "$prefix.stderr.txt"
    $final = Join-Path $LogRoot "$prefix.final.txt"
    $arguments = New-MatrixCodexArguments $Model $Effort $final $ThreadId $Worktree
    $pathValue = (Join-Path $Worktree '.experiment-bin') + [IO.Path]::PathSeparator + $env:PATH
    $environment = @{ CODEX_HOME=$CodexHome; PATH=$pathValue; MATSPEC_LANG='en'; MATSPEC_NPM_REGISTRY='http://127.0.0.1:9' }
    $result = Invoke-MatrixProcess -Executable (Get-Command codex.cmd -ErrorAction Stop).Source -Arguments $arguments -WorkingDirectory $Worktree -StdoutPath $stdout -StderrPath $stderr -TimeoutMinutes $TimeoutMinutes -InputText $Prompt -Environment $environment
    if ($result.timedOut) { throw "$Actor turn timed out." }
    if ($result.exitCode -ne 0) { throw "$Actor turn exited $($result.exitCode); see $stderr" }
    $result | Add-Member -NotePropertyName stdoutPath -NotePropertyValue $stdout
    $result | Add-Member -NotePropertyName finalPath -NotePropertyValue $final
    $result
}

function Invoke-MatrixCli {
    param(
        $Context, [string]$Worktree, [string]$CodexHome, [string[]]$Arguments,
        [string]$EvidenceRoot, [string]$Name, [int]$TimeoutMinutes = 10,
        [bool]$AllowFailure = $false
    )
    $stdout = Join-Path $EvidenceRoot "$Name.stdout.txt"
    $stderr = Join-Path $EvidenceRoot "$Name.stderr.txt"
    $pathValue = (Join-Path $Worktree '.experiment-bin') + [IO.Path]::PathSeparator + $env:PATH
    $environment = @{ CODEX_HOME=$CodexHome; PATH=$pathValue; MATSPEC_LANG='en'; MATSPEC_NPM_REGISTRY='http://127.0.0.1:9' }
    $nodeArguments = @($Context.matrixCli) + $Arguments
    $result = Invoke-MatrixProcess -Executable (Get-Command node -ErrorAction Stop).Source -Arguments $nodeArguments -WorkingDirectory $Worktree -StdoutPath $stdout -StderrPath $stderr -TimeoutMinutes $TimeoutMinutes -Environment $environment
    if ($result.timedOut) { throw "MatrixSpec command timed out: $($Arguments -join ' ')" }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw "MatrixSpec command failed: $($Arguments -join ' '); see $stdout and $stderr" }
    try { $payload = $result.stdout | ConvertFrom-Json } catch { $payload = $null }
    [pscustomobject]@{ process=$result; payload=$payload; stdoutPath=$stdout; stderrPath=$stderr }
}

function Invoke-MatrixDoneFinalization {
    param($Context,$Paths,[bool]$FullBaseline,[string]$Profile,[string]$ThreadId='')
    $candidateHome = Join-Path $Paths.homeRoot 'candidate'
    $finalRule = if ($FullBaseline) {
        'Merge the accepted delta-spec into matspec/specs/spec.md and refresh matspec/specs/design.md from the confirmed tasks implementation approach plus the final code. Both full documents must have a real content diff from the generated pre-implementation baseline and must match the final implementation.'
    } else {
        'The registered ablation kept both full documents absent through review. Create matspec/specs/spec.md and matspec/specs/design.md for the first time now from repository facts, accepted change artifacts, and final code. Do not claim that a pre-implementation full baseline existed.'
    }
    $finalPrompt = @"
Complete MatrixSpec done finalization for this experiment. $finalRule
The frozen workflow profile is $Profile. Neither light nor standard has a
delta-design artifact; use tasks.md as the confirmed file-level design input.
Run the focused package tests and inspect the final product diff. Verify the
full-document diffs explicitly. Do not run `matspec done`; the harness owns the
terminal state transition. End with exactly:
MATSPEC_STAGE_READY
"@
    $finalTurn = Invoke-MatrixStageTurn $Context $Paths 'candidate-main' 'candidate' $finalPrompt $ThreadId
    $thread = [string]$finalTurn.summary.threadId
    $doneName = if (Test-Path -LiteralPath (Join-Path $Paths.evidence 'change-done.stdout.txt')) { 'change-done-resume' } else { 'change-done' }
    $done = Invoke-MatrixCli $Context $Paths.worktree $candidateHome @('done','--json') $Paths.evidence $doneName 10 $true
    if ($null -ne $done.payload -and -not $done.payload.ok -and [string]$done.payload.code -eq 'FULL_DOCS_NOT_UPDATED') {
        $details = $done.payload | ConvertTo-Json -Depth 8
        $repairPrompt = @"
MatrixSpec rejected done finalization because the full documents were not
actually refreshed. Correct only this finalization defect now: merge the
accepted delta-spec into `matspec/specs/spec.md` and refresh
`matspec/specs/design.md` from tasks.md and the final implementation,
preserving existing full documents when this arm began with them. Inspect
`git diff -- matspec/specs/spec.md
matspec/specs/design.md` and ensure both files have substantive diffs.

Done gate result:
$details

Do not run `matspec done`. End with exactly:
MATSPEC_STAGE_READY
"@
        $repair = Invoke-MatrixStageTurn $Context $Paths 'candidate-main' 'candidate' $repairPrompt $thread
        $thread = [string]$repair.summary.threadId
        $done = Invoke-MatrixCli $Context $Paths.worktree $candidateHome @('done','--json') $Paths.evidence "$doneName-retry" 10 $true
    }
    if ($null -eq $done.payload -or -not $done.payload.ok) {
        $failure = if ($null -eq $done.payload) { 'no JSON payload' } else { $done.payload | ConvertTo-Json -Compress -Depth 8 }
        throw "MatrixSpec done failed after finalization repair: $failure"
    }
    foreach ($file in @('matspec\specs\spec.md','matspec\specs\design.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Paths.worktree $file) -PathType Leaf)) { throw "Done finalization omitted required full document: $file" }
    }
    [pscustomobject]@{threadId=$thread;done=$done.payload}
}

function Add-MatrixProcessRecord([string]$Path, [string]$Actor, [string]$Phase, $Result) {
    $record = [ordered]@{ actor=$Actor; phase=$Phase; startedAtUtc=$Result.startedAtUtc; endedAtUtc=$Result.endedAtUtc; durationSeconds=$Result.durationSeconds; exitCode=$Result.exitCode; timedOut=$Result.timedOut }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-MatrixRunPaths($Context, [string]$RunId) {
    [pscustomobject]@{
        evidence = Join-Path $Context.campaign "runs\$RunId"
        worktree = Join-Path $Context.campaign "runs\worktrees\$RunId"
        base = Join-Path $Context.campaign "state\run-bases\$RunId"
        homeRoot = Join-Path $Context.campaign "state\codex-homes\$RunId"
    }
}

function Copy-MatrixTaskAssets($Context) {
    [IO.Directory]::CreateDirectory($Context.campaign) | Out-Null
    $copies = [ordered]@{
        'task.md' = [string]$Context.task.assets.task
        'ground-truth\contract.md' = [string]$Context.task.assets.contract
        'ground-truth\rubric.md' = [string]$Context.task.assets.rubric
        'ground-truth\operator-guide.md' = [string]$Context.task.assets.operatorGuide
        'evaluation\judge-prompt.md' = [string]$Context.task.assets.judgePrompt
        'evaluation\judge-output.schema.json' = [string]$Context.task.assets.judgeSchema
        'pricing.json' = 'pricing.json'
    }
    foreach ($entry in $copies.GetEnumerator()) {
        $source = Resolve-MatrixPath $Context.workspace $entry.Value
        $target = Join-Path $Context.campaign $entry.Key
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing campaign input: $source" }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    $campaignExperiment = [IO.Path]::GetFullPath((Join-Path $Context.campaign 'experiment.json'))
    if ([IO.Path]::GetFullPath($Context.experimentPath) -ne $campaignExperiment) {
        Copy-Item -LiteralPath $Context.experimentPath -Destination $campaignExperiment -Force
    }
}

function Invoke-MatrixSpecPrepare {
    param($ExperimentPath,$PlanPath,$InternalRunId,$InternalCandidate,$JudgeReplicate,$Resume,$DriverPath)
    $context = Get-MatrixContext $ExperimentPath $PlanPath
    Copy-MatrixTaskAssets $context
    $baseline = Resolve-MatrixPath $context.workspace ([string]$context.task.baseline.checkout)
    $baselineCommit = [string]$context.task.baseline.commit
    Assert-MatrixFrozenGit $baseline $baselineCommit | Out-Null
    if (-not (Test-Path -LiteralPath $context.referenceRoot -PathType Container)) { throw "Missing Ground Truth reference checkout: $($context.referenceRoot)" }
    $auth = Join-Path $env:USERPROFILE '.codex\auth.json'
    $installCapability = Join-Path $context.workspace 'engine\install-capability.ps1'
    foreach ($row in @($context.plan.rows)) {
        $runId = [string]$row.runId
        $paths = Get-MatrixRunPaths $context $runId
        [IO.Directory]::CreateDirectory($paths.evidence) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $paths.base)) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $paths.worktree)) | Out-Null
        if (-not (Test-Path -LiteralPath $paths.base)) {
            & git -c core.autocrlf=false clone --no-hardlinks --quiet $baseline $paths.base
            if ($LASTEXITCODE -ne 0) { throw "Failed to clone run base: $runId" }
            Invoke-MatrixGit $paths.base remote remove origin | Out-Null
            Invoke-MatrixGit $paths.base config core.autocrlf false | Out-Null
        }
        Assert-MatrixFrozenGit $paths.base $baselineCommit | Out-Null
        if (-not (Test-Path -LiteralPath $paths.worktree)) {
            & git -C $paths.base worktree add -b $runId $paths.worktree $baselineCommit
            if ($LASTEXITCODE -ne 0) { throw "Failed to create run worktree: $runId" }
        }
        $head = ([string](Invoke-MatrixGit $paths.worktree rev-parse HEAD)).Trim()
        if ($head -ne $baselineCommit) { throw "Run worktree baseline mismatch: $runId" }
        $baselineNodeModules = Join-Path $baseline 'node_modules'
        $worktreeNodeModules = Join-Path $paths.worktree 'node_modules'
        if ((Test-Path -LiteralPath $baselineNodeModules -PathType Container) -and -not (Test-Path -LiteralPath $worktreeNodeModules)) {
            New-Item -ItemType Junction -Path $worktreeNodeModules -Target $baselineNodeModules | Out-Null
        }

        # Python editable installs rewrite site-packages/*.pth to the active
        # worktree. A shared .venv therefore lets concurrent pytest runs select
        # one another's source trees. Give every run a private runtime copy.
        $baselineVenv = Join-Path $baseline '.venv'
        $worktreeVenv = Join-Path $paths.worktree '.venv'
        if (Test-Path -LiteralPath $baselineVenv -PathType Container) {
            $venvItem = Get-Item -LiteralPath $worktreeVenv -ErrorAction SilentlyContinue
            if ($null -eq $venvItem) {
                Copy-Item -LiteralPath $baselineVenv -Destination $worktreeVenv -Recurse
            }
            elseif ($venvItem.LinkType -eq 'Junction') {
                Remove-Item -LiteralPath $worktreeVenv
                Copy-Item -LiteralPath $baselineVenv -Destination $worktreeVenv -Recurse
            }
        }

        $runtime = Get-MatrixValue $context.task 'runtime' $null
        foreach ($runtimeLink in @(Get-MatrixValue $runtime 'links' @())) {
            $linkPath = Join-Path $paths.worktree ([string]$runtimeLink.path)
            $targetPath = Resolve-MatrixPath $context.workspace ([string]$runtimeLink.target)
            if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) { throw "Missing prepared runtime target: $targetPath" }
            if (-not (Test-Path -LiteralPath $linkPath)) {
                New-Item -ItemType Junction -Path $linkPath -Target $targetPath | Out-Null
            }
        }

        # Hatch-generated pytest checkouts need this untracked module. It is
        # present in the sealed baseline but is not created by git worktree.
        $baselineVersion = Join-Path $baseline 'src\_pytest\_version.py'
        $worktreeVersion = Join-Path $paths.worktree 'src\_pytest\_version.py'
        if ((Test-Path -LiteralPath $baselineVersion -PathType Leaf) -and -not (Test-Path -LiteralPath $worktreeVersion)) {
            Copy-Item -LiteralPath $baselineVersion -Destination $worktreeVersion
        }
        foreach ($actor in @('candidate','generation','validator','reviewer','operator')) {
            Initialize-MatrixCodexHome (Join-Path $paths.homeRoot $actor) $auth ([string]$context.experiment.model) ([string]$context.experiment.reasoningEffort)
        }
        $record = Join-Path $paths.worktree '.experiment-capability.json'
        if (-not (Test-Path -LiteralPath $record)) {
            & $installCapability -Experiment $context.experimentPath -Arm ([string]$row.arm) -Worktree $paths.worktree
            if ($LASTEXITCODE -ne 0) { throw "Capability installation failed: $runId" }
        }
        $before = [ordered]@{
            runId=$runId; arm=[string]$row.arm; treatment=[string]$row.treatment
            profile=[string]$row.factors.profile
            specExists=(Test-Path -LiteralPath (Join-Path $paths.worktree 'matspec\specs\spec.md'))
            designExists=(Test-Path -LiteralPath (Join-Path $paths.worktree 'matspec\specs\design.md'))
            recordedAtUtc=[DateTime]::UtcNow.ToString('o')
        }
        Write-MatrixJson (Join-Path $paths.evidence 'baseline-docs-after-install.json') $before
    }
    $preparation = [ordered]@{ schemaVersion=1; preparedAtUtc=[DateTime]::UtcNow.ToString('o'); baselineCommit=$baselineCommit; matrixSpecCommit=[string]$context.capability.source.commit; runs=@($context.plan.rows.runId) }
    Write-MatrixJson (Join-Path $context.campaign 'state\preparation.json') $preparation
    [pscustomobject]@{action='Prepare';campaign=$context.campaign;runs=@($context.plan.rows).Count;status='complete'}
}

function New-MatrixStagePrompt {
    param([string]$Task, [string]$Stage, [bool]$FullBaseline, [bool]$Initial)
    $baselineRule = if ($FullBaseline) {
        'The authoritative full baseline exists under matspec/specs. Read it and keep the change documents consistent with it.'
    }
    else {
        'This is the registered no-full-baseline ablation. The experiment controller explicitly confirms that this condition overrides the normal missing-baseline gate: matspec/specs/spec.md and design.md must remain absent until post-review done finalization. Proceed from repository evidence and confirmed change artifacts, record the missing baseline as an accepted treatment risk, and do not ask for baseline generation or synthesize full documents before review.'
    }
    $initialBlock = if ($Initial) {
        @"
First read the complete repository skill at `.agents/skills/matspec/SKILL.md`.
Treat that skill and `matspec go --json` as the workflow authority.
"@
    } else { 'Continue the same MatrixSpec change and re-check `matspec go --json`.' }
    $completionRule = if ($Stage -eq 'implementation') {
        @"
When implementation is complete, end the response with exactly:
MATSPEC_STAGE_READY
"@
    }
    else {
        @"
Follow MatrixSpec's native clarification and confirmation gates. The experiment
controller is not the product owner and this prompt is not generation approval.
Ask the product owner about decisions that cannot be recovered from repository
evidence. When waiting for clarification, generation approval, or artifact
confirmation, stop and end with exactly one single-line marker:
OPERATOR_QUESTION: <question or approval request>

Do not write the stage artifact before explicit generation approval. After
writing it, request product-owner confirmation with the same marker. Do not run
`matspec accept`; the harness will do that only after explicit confirmation.
"@
    }
    @"
You are the implementation candidate in a controlled MatrixSpec experiment.
$initialBlock

Current harness phase: $Stage
$baselineRule

Read the complete stage-specific skill at `.agents/skills/matspec-$Stage/SKILL.md` when that file exists. Follow its artifact structure and executable checks exactly.

For a document stage, create only the current stage artifact at the exact path returned by `matspec go --json`. Inspect repository code as needed and distinguish repository facts, product-owner decisions, and agent inferences as required by the installed skill.

For the implementation stage, follow the confirmed MatrixSpec documents, implement the feature completely, add useful tests, execute focused verification, and use `matspec implement` task-state commands until the implementation stage is ready for confirmation. Do not modify or expose experiment harness files.

$completionRule

# Feature request

$Task
"@
}

function New-MatrixReviewPrompt([string]$Task, [string]$Profile, [bool]$Repeat) {
    $repeatText = if ($Repeat) { 'This is a re-review after the implementation candidate addressed the previous review. Replace review.md with a fresh verdict.' } else { 'Perform the first independent implementation review.' }
    @"
You are the independent MatrixSpec stage-generator for the review stage.
Read `.agents/skills/matspec-review/SKILL.md`, run `matspec go --json`, and follow its exact write boundary.
$repeatText
The frozen workflow profile is $Profile. Inspect the confirmed proposal,
delta-spec, tasks, the current product diff, and test evidence. For standard,
also inspect validation.md; light intentionally has no validation artifact.
Do not require delta-design because neither profile includes it. Do not modify
product code or any file other than the returned review.md path. Use
`Decision: Approved` only when the implementation satisfies the confirmed
requirements; otherwise use `Decision: Changes Required` and list concrete
defects.
End with exactly:
MATSPEC_STAGE_READY

# Feature request

$Task
"@
}

function Invoke-MatrixStageTurn {
    param($Context,$Paths,[string]$Actor,[string]$HomeName,[string]$Prompt,[string]$ThreadId='',[bool]$AllowClarification=$false)
    $logs = @(Get-ChildItem -LiteralPath $Paths.evidence -Filter "$Actor-turn-*.jsonl" -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty FullName)
    $turn = $logs.Count + 1
    $result = Invoke-MatrixCodexTurn -Worktree $Paths.worktree -CodexHome (Join-Path $Paths.homeRoot $HomeName) -Prompt $Prompt -LogRoot $Paths.evidence -Actor $Actor -Turn $turn -Model ([string]$Context.experiment.model) -Effort ([string]$Context.experiment.reasoningEffort) -TimeoutMinutes ([int]$Context.experiment.driverConfig.candidateTimeoutMinutes) -ThreadId $ThreadId
    Add-MatrixProcessRecord (Join-Path $Paths.evidence 'processes.jsonl') $Actor $Actor $result
    $summary = Get-MatrixLogSummary @($result.stdoutPath)
    $stageReady = $summary.finalMessage -match '(?m)^MATSPEC_STAGE_READY\s*$'
    $implementationComplete = $Actor -eq 'candidate-main' -and $summary.finalMessage -match '(?m)^IMPLEMENTATION_COMPLETE\s*$'
    $clarification = [string]$summary.finalMessage -match '(?im)^OPERATOR_QUESTION:\s*.+|^Q\d+\.|reply.+generate|reply.+confirm|please\s+(?:reply|review|confirm|either)|review\s+the\s+(?:repaired\s+)?(?:stage\s+)?artifact|implementation permission verdict:\s*needs'
    if (-not $stageReady -and -not $implementationComplete -and -not ($AllowClarification -and $clarification)) {
        throw "$Actor did not finish with an accepted MatrixSpec stage sentinel."
    }
    [pscustomobject]@{result=$result;summary=$summary}
}

function ConvertFrom-MatrixOperatorResponse([string]$Text) {
    $answer = [regex]::Match($Text, '(?m)^OPERATOR_ANSWER:\s*(.+)\s*$')
    $decision = [regex]::Match($Text, '(?m)^OPERATOR_DECISION:\s*(CONTINUE|CONFIRM)\s*$')
    if (-not $answer.Success -or -not $decision.Success) {
        throw 'MatrixSpec Ground Truth operator returned an invalid response.'
    }
    [pscustomobject]@{
        answer = "OPERATOR_ANSWER: $($answer.Groups[1].Value.Trim())"
        decision = $decision.Groups[1].Value.ToUpperInvariant()
        raw = $Text
    }
}

function Get-MatrixStageArtifact {
    param($Paths,[string]$Stage)
    $artifact = Get-ChildItem -LiteralPath (Join-Path $Paths.worktree 'matspec\changes') -Filter "$Stage.md" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $artifact) { return $null }
    [pscustomobject]@{ path=$artifact.FullName; content=(Get-Content -Raw -LiteralPath $artifact.FullName) }
}

function Invoke-MatrixOperatorAnswer {
    param($Context,$Paths,[string]$CandidateTurn,[string]$Phase,[string]$Stage,$Artifact=$null)
    $materials = @('operator-guide.md','contract.md','rubric.md') | ForEach-Object {
        $path = Join-Path $Context.campaign "ground-truth\$_"
        "# $_`n`n$(Get-Content -Raw -LiteralPath $path)"
    }
    $prompt = @"
# Frozen task

$(Get-Content -Raw -LiteralPath (Join-Path $Context.campaign 'task.md'))

$($materials -join "`n`n")

# Candidate workflow phase

$Phase

# Complete candidate turn

$CandidateTurn

# Current stage artifact

$(if ($null -eq $Artifact) { '(not written yet)' } else { $Artifact.content })

Act as the product owner for the MatrixSpec `$Stage` stage, using the hidden
Ground Truth as the authority. Your working directory is the complete frozen
reference implementation; inspect it whenever the documents do not determine
an answer precisely. Answer the candidate's product questions. If it
requests generation approval, approve only when its proposed decisions agree
with Ground Truth; otherwise correct the unresolved behavior. If it requests
confirmation of the written artifact, use CONFIRM only when the artifact
faithfully records the relevant Ground Truth and has no material unresolved
product decisions. Implementation details recoverable from the repository do
not require product-owner decisions.

Do not reveal code, paths, symbols, patches, exact tests, oracle, rubric, or
treatment identity. Return exactly two single-line markers:
`OPERATOR_ANSWER: <concise answer>`
`OPERATOR_DECISION: CONTINUE|CONFIRM`.
"@
    $logs = @(Get-ChildItem -LiteralPath $Paths.evidence -Filter 'operator-turn-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty FullName)
    $turn = $logs.Count + 1
    $operatorSummary = Get-MatrixLogSummary $logs
    $result = Invoke-MatrixCodexTurn -Worktree $Context.referenceRoot -CodexHome (Join-Path $Paths.homeRoot 'operator') -Prompt $prompt -LogRoot $Paths.evidence -Actor 'operator' -Turn $turn -Model ([string]$Context.experiment.model) -Effort ([string]$Context.experiment.reasoningEffort) -TimeoutMinutes ([int]$Context.experiment.driverConfig.candidateTimeoutMinutes) -ThreadId ([string]$operatorSummary.threadId)
    Add-MatrixProcessRecord (Join-Path $Paths.evidence 'processes.jsonl') 'operator' $Phase $result
    $summary = Get-MatrixLogSummary @($result.stdoutPath)
    ConvertFrom-MatrixOperatorResponse ([string]$summary.finalMessage)
}

function Invoke-MatrixDocumentStage {
    param(
        $Context,$Paths,[string]$Stage,[string]$Actor,[string]$HomeName,
        [string]$Prompt,[string]$ThreadId=''
    )
    $maxTurns = [int](Get-MatrixValue $Context.experiment.driverConfig 'maxTurns' 40)
    $thread = $ThreadId
    $nextPrompt = $Prompt
    while ($true) {
        $candidateLogs = @(Get-ChildItem -LiteralPath $Paths.evidence -Filter 'candidate-*.jsonl' -File -ErrorAction SilentlyContinue)
        if ($candidateLogs.Count -ge $maxTurns) { throw "MatrixSpec run exceeded $maxTurns candidate turns." }
        $turn = Invoke-MatrixStageTurn $Context $Paths $Actor $HomeName $nextPrompt $thread $true
        if (-not $thread) { $thread = [string]$turn.summary.threadId }
        $artifact = Get-MatrixStageArtifact $Paths $Stage
        $operator = Invoke-MatrixOperatorAnswer $Context $Paths ([string]$turn.summary.finalMessage) "$Stage-product-owner" $Stage $artifact
        $record = [ordered]@{
            timestampUtc=[DateTime]::UtcNow.ToString('o'); stage=$Stage; actor=$Actor
            candidateTurn=@(Get-ChildItem -LiteralPath $Paths.evidence -Filter 'candidate-*.jsonl' -File -ErrorAction SilentlyContinue).Count
            decision=$operator.decision; answer=$operator.answer
            artifactExists=($null -ne $artifact)
        }
        ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath (Join-Path $Paths.evidence 'operator-decisions.jsonl') -Encoding utf8NoBOM
        if ($operator.decision -eq 'CONFIRM') {
            if ($null -eq $artifact) { throw "Operator confirmed $Stage before its artifact existed." }
            return [pscustomobject]@{threadId=$thread;artifact=$artifact;operator=$operator}
        }
        $nextPrompt = @"
$($operator.answer)

Continue the same MatrixSpec `$Stage` stage and follow its installed skill.
This answer is product-owner input, not automatic artifact confirmation. When
you next need clarification, generation approval, or artifact confirmation,
end with exactly `OPERATOR_QUESTION: <question or approval request>` marker.
"@
    }
}

function Get-MatrixCurrentStage($Context,$Paths,[string]$HomeName,[string]$Name) {
    $command = Invoke-MatrixCli $Context $Paths.worktree (Join-Path $Paths.homeRoot $HomeName) @('go','--json') $Paths.evidence $Name
    if ($null -eq $command.payload -or -not $command.payload.ok) { throw "Could not read MatrixSpec stage: $Name" }
    $command.payload
}

function Accept-MatrixStage($Context,$Paths,[string]$Name) {
    $result = Invoke-MatrixCli $Context $Paths.worktree (Join-Path $Paths.homeRoot 'candidate') @('accept','--json') $Paths.evidence $Name
    if ($null -eq $result.payload -or -not $result.payload.ok) { throw "MatrixSpec accept failed: $Name" }
    $result.payload
}

function Invoke-MatrixFullGeneration($Context,$Paths) {
    $generationHome = Join-Path $Paths.homeRoot 'generation'
    $arguments = @(
        'generate','--runner','codex','--mode',([string]$Context.experiment.driverConfig.generationMode),
        '--model',([string]$Context.experiment.model),
        '--concurrency',([string]$Context.experiment.driverConfig.generationConcurrency),
        '--retries',([string]$Context.experiment.driverConfig.generationRetries),
        '--lang','en','--json'
    )
    $generated = Invoke-MatrixCli $Context $Paths.worktree $generationHome $arguments $Paths.evidence 'generation' ([int]$Context.experiment.driverConfig.generationTimeoutMinutes)
    Add-MatrixProcessRecord (Join-Path $Paths.evidence 'processes.jsonl') 'generation' 'full-baseline-generation' $generated.process
    if ($null -eq $generated.payload -or -not $generated.payload.ok) { throw 'MatrixSpec full baseline generation did not return ok.' }
    $null = Invoke-MatrixCli $Context $Paths.worktree $generationHome @('show','--json') $Paths.evidence 'generation-show'
    $applied = Invoke-MatrixCli $Context $Paths.worktree $generationHome @('apply','--json') $Paths.evidence 'generation-apply' 10 $true
    if ($null -ne $applied.payload -and -not $applied.payload.ok -and [string]$applied.payload.code -eq 'APPLY_QUALITY_FAILED') {
        $runId = [string]$generated.payload.runId
        $findings = $applied.payload.findings | ConvertTo-Json -Depth 8
        $repairPrompt = @"
You are repairing MatrixSpec-generated full-baseline documents after the
tool's pre-apply quality gate rejected them. Modify only these generated files:

- `.matspec-cli/runs/$runId/spec.md`
- `.matspec-cli/runs/$runId/design.md`

Remove runner, harness, execution-environment, or capability-reporting language
identified by the findings while preserving repository-grounded product and
architecture content. Do not modify product code or any other file.

Quality findings:
$findings

End with exactly:
MATSPEC_STAGE_READY
"@
        $null = Invoke-MatrixStageTurn $Context $Paths 'generation-repair' 'generation' $repairPrompt
        $applied = Invoke-MatrixCli $Context $Paths.worktree $generationHome @('apply','--json') $Paths.evidence 'generation-apply-retry' 10 $true
    }
    if ($null -eq $applied.payload -or -not $applied.payload.ok) { throw 'MatrixSpec full baseline apply failed.' }
    $spec = Join-Path $Paths.worktree 'matspec\specs\spec.md'
    $design = Join-Path $Paths.worktree 'matspec\specs\design.md'
    if (-not (Test-Path -LiteralPath $spec -PathType Leaf) -or -not (Test-Path -LiteralPath $design -PathType Leaf)) { throw 'Applied full baseline documents are missing.' }
    $record = [ordered]@{
        generated=$true; runId=[string]$generated.payload.runId
        specSha256=(Get-FileHash -LiteralPath $spec -Algorithm SHA256).Hash.ToLowerInvariant()
        designSha256=(Get-FileHash -LiteralPath $design -Algorithm SHA256).Hash.ToLowerInvariant()
        specBytes=(Get-Item -LiteralPath $spec).Length; designBytes=(Get-Item -LiteralPath $design).Length
        appliedAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    Write-MatrixJson (Join-Path $Paths.evidence 'full-baseline.json') $record
}

function Invoke-MatrixValidationLoop {
    param($Context,$Paths,[string]$Task,[bool]$FullBaseline,[string]$Profile)
    $maxAttempts = [int](Get-MatrixValue $Context.experiment.driverConfig 'maxValidationAttempts' 3)
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $validationStage = Get-MatrixCurrentStage $Context $Paths 'validator' "go-validation-$attempt"
        if ([string]$validationStage.stage.key -ne 'validation') { throw "MatrixSpec did not enter validation on attempt $attempt." }
        $validationBaselineRule = if ($FullBaseline) {
            'The authoritative full baseline documents exist and must be included in the consistency check.'
        }
        else {
            'This is the registered no-full-baseline ablation. The experiment controller explicitly confirms that the normal missing-baseline gate is overridden for this run. The two full documents must remain absent until post-review finalization. Record their absence as high risk, but proceed with delta-only validation if the proposal, delta-spec, executable tasks, and repository evidence are otherwise consistent.'
        }
        $validationPrompt = @"
You are the independent MatrixSpec stage-generator for validation.
Read `.agents/skills/matspec-validation/SKILL.md`, run `matspec go --json`, and follow its clarification, generation-approval, and artifact-confirmation gates. Write only the returned validation.md path. Independently check the proposal, delta-spec, tasks, repository evidence, and any full baseline documents that exist. Standard has no delta-design artifact; do not require one. Do not modify product code. Give a clear implementation permission verdict. Whenever waiting for the product owner, end with exactly `OPERATOR_QUESTION: <question or approval request>`.

$validationBaselineRule

Do not treat internal consistency as product-owner confirmation. Flag any material agent-inferred or unresolved product decision as required by the installed validation skill.

# Feature request

$Task
"@
        $null = Invoke-MatrixDocumentStage $Context $Paths 'validation' 'candidate-validation' 'validator' $validationPrompt
        $accepted = Invoke-MatrixCli $Context $Paths.worktree (Join-Path $Paths.homeRoot 'candidate') @('accept','--json') $Paths.evidence "accept-validation-$attempt" 10 $true
        if ($null -ne $accepted.payload -and $accepted.payload.ok) { return $accepted.payload }
        if ($null -eq $accepted.payload -or [string]$accepted.payload.code -ne 'STAGE_VERDICT_BLOCKED') {
            $failure = if ($null -eq $accepted.payload) { 'no JSON payload' } else { $accepted.payload | ConvertTo-Json -Compress -Depth 8 }
            throw "MatrixSpec validation accept failed: $failure"
        }
        if ($attempt -ge $maxAttempts) { throw "MatrixSpec validation remained revise after $maxAttempts attempts." }

        $repairTarget = [string]$accepted.payload.repairTarget
        $documentStages = @('proposal','delta-spec','tasks')
        $repairIndex = [array]::IndexOf($documentStages,$repairTarget)
        if ($repairIndex -lt 0) { throw "Unsupported validation repair target: $repairTarget" }
        $reason = "validation verdict requires revision on attempt $attempt"
        $back = Invoke-MatrixCli $Context $Paths.worktree (Join-Path $Paths.homeRoot 'candidate') @('back','--to',$repairTarget,'--reason',$reason,'--json') $Paths.evidence "validation-back-$attempt"
        if ($null -eq $back.payload -or -not $back.payload.ok) { throw "MatrixSpec validation back failed on attempt $attempt." }
        $details = $accepted.payload | ConvertTo-Json -Depth 8
        $repairBaselineRule = if ($FullBaseline) {
            'The authoritative full baseline exists under matspec/specs and remains an input to every repaired artifact.'
        }
        else {
            'This is the registered no-full-baseline ablation. The experiment controller explicitly overrides the normal missing-baseline gate: spec.md and design.md must stay absent until post-review finalization. Repair the delta documents from confirmed product-owner decisions and repository evidence; do not request baseline generation or restoration.'
        }
        for ($index = $repairIndex; $index -lt $documentStages.Count; $index++) {
            $stage = $documentStages[$index]
            $current = Get-MatrixCurrentStage $Context $Paths 'candidate' "go-validation-repair-$attempt-$stage"
            if ([string]$current.stage.key -ne $stage) { throw "Expected validation repair stage $stage, got $($current.stage.key)." }
            $repairPrompt = @"
MatrixSpec validation blocked implementation and routed repair to `$repairTarget`.
Read the current validation.md and revise the `$stage` artifact so the confirmed
document chain resolves every blocker below. Preserve already confirmed product
decisions and the $Profile profile; do not modify product code. Follow the
installed MatrixSpec `$stage` skill and its product-owner gates exactly.

$repairBaselineRule

Validation gate result:
$details

# Feature request

$Task
"@
            $null = Invoke-MatrixDocumentStage $Context $Paths $stage 'candidate-main' 'candidate' $repairPrompt
            $null = Accept-MatrixStage $Context $Paths "accept-validation-repair-$attempt-$stage"
        }
    }
}

function Invoke-MatrixOneRun($Context,$Row,[bool]$Resume=$false) {
    $runId = [string]$Row.runId
    $paths = Get-MatrixRunPaths $Context $runId
    $statePath = Join-Path $paths.evidence 'state.json'
    $resuming = $false
    if (Test-Path -LiteralPath $statePath) {
        $existing = Read-MatrixJson $statePath
        if ($existing.status -eq 'completed') { return $existing }
        if (-not $Resume) { throw "$runId has partial state; pass -Resume for stage-aware recovery." }
        $resuming = $true
    }
    elseif ($Resume -and (Test-Path -LiteralPath (Join-Path $paths.evidence 'change-start.stdout.txt') -PathType Leaf)) {
        # An outer scheduler termination can kill the PowerShell process before
        # its finally block writes state.json. The frozen MatrixSpec state and
        # completed process records are sufficient to continue the same run.
        $resuming = $true
    }
    $started = [DateTime]::UtcNow
    $processPath = Join-Path $paths.evidence 'processes.jsonl'
    if ($resuming -and (Test-Path -LiteralPath $processPath -PathType Leaf)) {
        $firstProcess = Get-Content -LiteralPath $processPath | Select-Object -First 1 | ConvertFrom-Json
        if ($null -ne $firstProcess.startedAtUtc) { $started = ([DateTime]$firstProcess.startedAtUtc).ToUniversalTime() }
    }
    $fullBaseline = [bool]$Row.factors.fullBaseline
    $profile = [string]$Row.factors.profile
    if ($profile -notin @('light','standard')) { throw "Unsupported MatrixSpec profile: $profile" }
    $task = Get-Content -Raw -LiteralPath (Join-Path $Context.campaign 'task.md')
    $candidateHome = Join-Path $paths.homeRoot 'candidate'
    $mainThread = ''
    $status = 'running'
    try {
        if ($resuming) {
            if ($fullBaseline -and (-not (Test-Path -LiteralPath (Join-Path $paths.worktree 'matspec\specs\spec.md')) -or -not (Test-Path -LiteralPath (Join-Path $paths.worktree 'matspec\specs\design.md')))) {
                Invoke-MatrixFullGeneration $Context $paths
            }
        }
        elseif ($fullBaseline) {
            Invoke-MatrixFullGeneration $Context $paths
        }
        else {
            foreach ($file in @('matspec\specs\spec.md','matspec\specs\design.md')) {
                if (Test-Path -LiteralPath (Join-Path $paths.worktree $file)) { throw "No-baseline arm unexpectedly contains $file" }
            }
            Write-MatrixJson (Join-Path $paths.evidence 'full-baseline.json') ([ordered]@{generated=$false;specExists=$false;designExists=$false})
        }

        $changeId = "AR20260724-$([string]$Context.task.id)"
        $changeStartEvidence = Join-Path $paths.evidence 'change-start.stdout.txt'
        if (-not $resuming -or -not (Test-Path -LiteralPath $changeStartEvidence)) {
            $startedChange = Invoke-MatrixCli $Context $paths.worktree $candidateHome @('start',$changeId,'--profile',$profile,'--json') $paths.evidence 'change-start'
            if ($null -eq $startedChange.payload -or -not $startedChange.payload.ok) { throw 'MatrixSpec change start failed.' }
            if ([string]$startedChange.payload.profile -ne $profile) { throw "MatrixSpec started profile $($startedChange.payload.profile), expected $profile." }
        }

        $resumeAtDone = $false
        $resumeStageKey = ''
        if ($resuming) {
            $resumeStage = Get-MatrixCurrentStage $Context $paths 'candidate' 'go-resume'
            $resumeAtDone = [string]$resumeStage.nextAction -eq 'done'
            if ($resumeAtDone) {
                $resumeStageKey = 'done'
            }
            elseif ($null -ne $resumeStage.PSObject.Properties['stage']) {
                $resumeStageKey = [string]$resumeStage.stage.key
            }
            else {
                throw 'MatrixSpec resume response omitted both a done action and a stage.'
            }
        }

        if (-not $resumeAtDone) {
        $resumeAfterDocuments = $resumeStageKey -in @('validation','implementation','review')
        $mainStages = @('proposal','delta-spec','tasks')
        if (-not $resumeAfterDocuments) {
        for ($index = 0; $index -lt $mainStages.Count; $index++) {
            $stage = $mainStages[$index]
            $current = Get-MatrixCurrentStage $Context $paths 'candidate' "go-$stage"
            $currentIndex = [array]::IndexOf($mainStages, [string]$current.stage.key)
            if ($currentIndex -gt $index) { continue }
            if ([string]$current.stage.key -ne $stage) { throw "Expected MatrixSpec stage $stage, got $($current.stage.key)" }
            $prompt = New-MatrixStagePrompt $task $stage $fullBaseline ($index -eq 0)
            # Confirmed artifacts are the cross-stage context. Keep one thread
            # inside a stage, but rotate at stage boundaries to cap replay size.
            $stageResult = Invoke-MatrixDocumentStage $Context $paths $stage 'candidate-main' 'candidate' $prompt ''
            $mainThread = [string]$stageResult.threadId
            $null = Accept-MatrixStage $Context $paths "accept-$stage"
        }
        }

        if ($profile -eq 'standard' -and $resumeStageKey -notin @('implementation','review')) {
            $null = Invoke-MatrixValidationLoop $Context $paths $task $fullBaseline $profile
        }

        if (-not $fullBaseline -and $resumeStageKey -ne 'review') {
            foreach ($file in @('matspec\specs\spec.md','matspec\specs\design.md')) {
                if (Test-Path -LiteralPath (Join-Path $paths.worktree $file)) { throw "No-baseline arm created $file before implementation." }
            }
            Write-MatrixJson (Join-Path $paths.evidence 'pre-implementation-baseline-isolation.json') ([ordered]@{
                profile=$profile;fullBaseline=$false;specExists=$false;designExists=$false;recordedAtUtc=[DateTime]::UtcNow.ToString('o')
            })
        }

        if ($resumeStageKey -ne 'review') {
        $implementationStage = Get-MatrixCurrentStage $Context $paths 'candidate' 'go-implementation'
        if ([string]$implementationStage.stage.key -ne 'implementation') { throw 'MatrixSpec did not enter implementation.' }
        $implementationPrompt = New-MatrixStagePrompt $task 'implementation' $fullBaseline $false
        $implementation = Invoke-MatrixStageTurn $Context $paths 'candidate-main' 'candidate' $implementationPrompt ''
        $mainThread = [string]$implementation.summary.threadId
        $null = Accept-MatrixStage $Context $paths 'accept-implementation'

        $reviewEntry = Invoke-MatrixCli $Context $paths.worktree $candidateHome @('review','--json') $paths.evidence 'review-entry'
        if ($null -eq $reviewEntry.payload -or -not $reviewEntry.payload.ok) { throw 'MatrixSpec review entry failed.' }
        }
        $reviewThread = ''
        $approved = $false
        $maxReviewAttempts = [int](Get-MatrixValue $Context.experiment.driverConfig 'maxReviewAttempts' 4)
        if ($resumeStageKey -eq 'review') {
            $resumeReviewPath = Join-Path $paths.worktree "matspec\changes\$changeId\review.md"
            if (Test-Path -LiteralPath $resumeReviewPath) {
                $resumeFixPrompt = @"
Resume the interrupted MatrixSpec review repair. Read
`matspec/changes/$changeId/review.md`, correct every actionable product defect,
add or update tests, and run the requested verification. If the review identifies
an inconsistency in confirmed MatrixSpec artifacts, correct the delta/full
documents and validation to match the already-confirmed product decisions; do
not invent a new decision. Do not edit review.md and do not advance MatrixSpec
state. End with exactly:
MATSPEC_STAGE_READY
"@
                $resumeFix = Invoke-MatrixStageTurn $Context $paths 'candidate-main' 'candidate' $resumeFixPrompt ''
                $mainThread = [string]$resumeFix.summary.threadId
            }
        }
        for ($attempt = 1; $attempt -le $maxReviewAttempts; $attempt++) {
            $review = Invoke-MatrixStageTurn $Context $paths 'candidate-review' 'reviewer' (New-MatrixReviewPrompt $task $profile ($attempt -gt 1)) $reviewThread
            if (-not $reviewThread) { $reviewThread = [string]$review.summary.threadId }
            $reviewPath = Join-Path $paths.worktree "matspec\changes\$changeId\review.md"
            $reviewText = Get-Content -Raw -LiteralPath $reviewPath
            if ($reviewText -match '(?im)^\s*(?:[-*]\s*)?\*{0,2}Decision\*{0,2}\s*:\s*Approved\b') { $approved = $true; break }
            if ($attempt -lt $maxReviewAttempts) {
                $fixPrompt = @"
The independent MatrixSpec review requested changes. Read `matspec/changes/$changeId/review.md`, correct every actionable product defect, add or update tests, and verify the implementation. If the review identifies an inconsistency in confirmed MatrixSpec artifacts, correct the delta/full documents and validation to match the already-confirmed product decisions; do not invent a new decision. Do not edit review.md and do not advance MatrixSpec state. End with exactly:
MATSPEC_STAGE_READY
"@
                $fix = Invoke-MatrixStageTurn $Context $paths 'candidate-main' 'candidate' $fixPrompt $mainThread
                $mainThread = [string]$fix.summary.threadId
            }
        }
        if (-not $approved) { throw "MatrixSpec review remained Changes Required after $maxReviewAttempts attempts." }
        $null = Accept-MatrixStage $Context $paths 'accept-review'
        }
        $finalization = Invoke-MatrixDoneFinalization $Context $paths $fullBaseline $profile ''
        $mainThread = [string]$finalization.threadId
        $status = 'completed'
    }
    catch {
        $status = 'failed'
        Write-MatrixText (Join-Path $paths.evidence 'harness-error.txt') ($_.Exception.ToString() + "`n")
        throw
    }
    finally {
        $logs = @(Get-ChildItem -LiteralPath $paths.evidence -Filter 'candidate-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime,Name | Select-Object -ExpandProperty FullName)
        $summary = Get-MatrixLogSummary $logs
        $state = [ordered]@{
            schemaVersion=1;runId=$runId;arm=[string]$Row.arm;treatment=[string]$Row.treatment;profile=$profile;fullBaseline=$fullBaseline
            status=$status;startedAtUtc=$started.ToString('o');endedAtUtc=[DateTime]::UtcNow.ToString('o')
            wallClockSeconds=[math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,3)
            mainThreadId=$mainThread;candidate=$summary
        }
        Write-MatrixJson $statePath $state
    }
    Read-MatrixJson $statePath
}

function Invoke-MatrixSpecRun {
    param($ExperimentPath,$PlanPath,$InternalRunId,$InternalCandidate,$JudgeReplicate,$Resume,$DriverPath)
    $context = Get-MatrixContext $ExperimentPath $PlanPath
    if ($InternalRunId) {
        $row = @($context.plan.rows | Where-Object { [string]$_.runId -eq $InternalRunId })
        if ($row.Count -ne 1) { throw "Unknown internal run: $InternalRunId" }
        return Invoke-MatrixOneRun $context $row[0] $Resume
    }
    $pending = @($context.plan.rows | Where-Object {
        $runState = Join-Path $context.campaign "runs\$($_.runId)\state.json"
        if (-not (Test-Path -LiteralPath $runState)) { return $true }
        $Resume -and (Read-MatrixJson $runState).status -ne 'completed'
    })
    $maxParallel = [int]$context.experiment.driverConfig.maxParallel
    $experimentValue = $context.experimentPath
    $planValue = $PlanPath
    $driverValue = $DriverPath
    $resumeValue = $Resume
    $outcomes = @($pending | ForEach-Object -Parallel {
        try {
            $null = & $using:driverValue -Action Run -ExperimentPath $using:experimentValue -PlanPath $using:planValue -InternalRunId ([string]$_.runId) -Resume:$using:resumeValue
            [pscustomobject]@{runId=[string]$_.runId;ok=$true;error=$null}
        }
        catch { [pscustomobject]@{runId=[string]$_.runId;ok=$false;error=$_.Exception.Message} }
    } -ThrottleLimit $maxParallel)
    $failures = @($outcomes | Where-Object { -not $_.ok })
    Write-MatrixJson (Join-Path $context.campaign 'reports\run-outcomes.json') ([ordered]@{
        generatedAtUtc=[DateTime]::UtcNow.ToString('o');outcomes=$outcomes
    })
    [pscustomobject]@{action='Run';campaign=$context.campaign;completed=$outcomes.Count;failed=$failures.Count;status='complete'}
}

function Invoke-MatrixFocusedTests($Context,$Paths) {
    $results = @()
    $combined = [Text.StringBuilder]::new()
    $index = 0
    foreach ($command in @($Context.task.validation.focusedTests)) {
        $index++
        $stdout = Join-Path $Paths.evidence ('focused-test-{0:d2}.stdout.txt' -f $index)
        $stderr = Join-Path $Paths.evidence ('focused-test-{0:d2}.stderr.txt' -f $index)
        $environment = @{
            GOPROXY='off'; HTTP_PROXY='http://127.0.0.1:9'; HTTPS_PROXY='http://127.0.0.1:9';
            ALL_PROXY='http://127.0.0.1:9'; NO_PROXY=''
        }
        $result = Invoke-MatrixProcess -Executable (Get-Command pwsh.exe -ErrorAction Stop).Source -Arguments @('-NoProfile','-NonInteractive','-Command',[string]$command) -WorkingDirectory $Paths.worktree -StdoutPath $stdout -StderrPath $stderr -TimeoutMinutes 30 -Environment $environment
        $null = $combined.AppendLine("COMMAND: $command")
        $null = $combined.Append($result.stdout)
        if ($result.stderr) { $null = $combined.AppendLine(); $null = $combined.Append($result.stderr) }
        $null = $combined.AppendLine()
        $null = $combined.AppendLine("EXIT_CODE: $($result.exitCode)")
        $results += [ordered]@{command=[string]$command;exitCode=$result.exitCode;timedOut=$result.timedOut}
    }
    Write-MatrixText (Join-Path $Paths.evidence 'tests.log') $combined.ToString()
    $results
}

function Copy-MatrixSessionTrees($Paths) {
    foreach ($actor in @('candidate','generation','validator','reviewer','operator')) {
        $source = Join-Path $Paths.homeRoot "$actor\sessions"
        $target = Join-Path $Paths.evidence "raw-sessions\$actor"
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        [IO.Directory]::CreateDirectory($target) | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $source -Filter '*.jsonl' -File -Recurse) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\','/')
            $destination = Join-Path $target $relative
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
    }
}

function Write-MatrixEvidenceManifest([string]$Directory) {
    $manifestPath = Join-Path $Directory 'manifest.json'
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object FullName -ne $manifestPath | Sort-Object FullName)
    $manifest = [ordered]@{
        schemaVersion=1;frozenAtUtc=[DateTime]::UtcNow.ToString('o')
        files=@($files | ForEach-Object { [ordered]@{
            path=$_.FullName.Substring($Directory.Length).TrimStart('\','/').Replace('\','/');bytes=$_.Length
            sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        } })
    }
    Write-MatrixJson $manifestPath $manifest
}

function Invoke-MatrixSpecFreeze {
    param($ExperimentPath,$PlanPath,$InternalRunId,$InternalCandidate,$JudgeReplicate,$Resume,$DriverPath)
    $context = Get-MatrixContext $ExperimentPath $PlanPath
    $productPaths = @($context.task.validation.productDiffPaths | ForEach-Object { ([string]$_).Replace('\','/') })
    foreach ($row in @($context.plan.rows)) {
        $runId = [string]$row.runId
        $paths = Get-MatrixRunPaths $context $runId
        $state = Read-MatrixJson (Join-Path $paths.evidence 'state.json')
        if ($state.status -notin @('completed','failed')) { throw "Cannot freeze non-terminal run: $runId" }
        $tests = @(Invoke-MatrixFocusedTests $context $paths)
        Write-MatrixJson (Join-Path $paths.evidence 'focused-tests.json') $tests
        $base = ([string](Invoke-MatrixGit $paths.worktree rev-list --max-parents=0 HEAD)).Trim()
        $intentPaths = @($productPaths | Where-Object { Test-Path -LiteralPath (Join-Path $paths.worktree $_) })
        if ($intentPaths.Count) {
            $null = @(& git -C $paths.worktree add -N -- @intentPaths)
            if ($LASTEXITCODE -ne 0) { throw "Could not mark untracked product files as intent-to-add: $runId" }
        }
        $productDiff = @(& git -C $paths.worktree diff --binary $base -- @productPaths)
        if ($LASTEXITCODE -ne 0) { throw "Product diff failed: $runId" }
        Write-MatrixText (Join-Path $paths.evidence 'product-code.diff') (($productDiff -join "`n") + "`n")
        $fullDiff = @(& git -C $paths.worktree diff --binary $base)
        Write-MatrixText (Join-Path $paths.evidence 'workspace.diff') (($fullDiff -join "`n") + "`n")
        Write-MatrixText (Join-Path $paths.evidence 'git-status.txt') ((@(& git -C $paths.worktree status --short --untracked-files=all) -join "`n") + "`n")
        Write-MatrixText (Join-Path $paths.evidence 'git-log.txt') ((@(& git -C $paths.worktree log --oneline --decorate -5) -join "`n") + "`n")
        foreach ($entry in @(
            @{source='matspec';target='process-artifacts\matspec'},
            @{source='.matspec-cli\runs';target='process-artifacts\runtime-runs'},
            @{source='.agents\skills';target='process-artifacts\installed-skills'}
        )) {
            $source = Join-Path $paths.worktree $entry.source
            $target = Join-Path $paths.evidence $entry.target
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $target -Recurse -Force }
        }
        Copy-MatrixSessionTrees $paths
        Write-MatrixEvidenceManifest $paths.evidence
    }
    [pscustomobject]@{action='Freeze';campaign=$context.campaign;runs=@($context.plan.rows).Count;status='complete'}
}

function Test-MatrixSkillRead([string]$EvidenceRoot) {
    foreach ($file in Get-ChildItem -LiteralPath $EvidenceRoot -Filter 'candidate-*.jsonl' -File -ErrorAction SilentlyContinue) {
        if ([IO.File]::ReadAllText($file.FullName) -match '(?i)\.agents[/\\]skills[/\\]matspec[/\\]SKILL\.md') { return $true }
    }
    $false
}

function Invoke-MatrixSpecAudit {
    param($ExperimentPath,$PlanPath,$InternalRunId,$InternalCandidate,$JudgeReplicate,$Resume,$DriverPath)
    $context = Get-MatrixContext $ExperimentPath $PlanPath
    $audits = @()
    foreach ($row in @($context.plan.rows)) {
        $runId = [string]$row.runId
        $paths = Get-MatrixRunPaths $context $runId
        $state = Read-MatrixJson (Join-Path $paths.evidence 'state.json')
        $full = [bool]$row.factors.fullBaseline
        $profile = [string]$row.factors.profile
        $baseline = Read-MatrixJson (Join-Path $paths.evidence 'full-baseline.json')
        $tests = Read-MatrixJson (Join-Path $paths.evidence 'focused-tests.json')
        $artifactRoot = Join-Path $paths.evidence 'process-artifacts\matspec'
        $stageFiles = @('proposal.md','delta-spec.md','tasks.md','review.md')
        if ($profile -eq 'standard') { $stageFiles = @('proposal.md','delta-spec.md','tasks.md','validation.md','review.md') }
        $missingStages = @()
        foreach ($stage in $stageFiles) {
            if (-not (Get-ChildItem -LiteralPath $artifactRoot -Filter $stage -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)) { $missingStages += $stage }
        }
        $specFiles = @(Get-ChildItem -LiteralPath (Join-Path $artifactRoot 'specs') -Filter '*.md' -File -ErrorAction SilentlyContinue)
        $productDiff = Get-Content -Raw -LiteralPath (Join-Path $paths.evidence 'product-code.diff')
        $findings = @()
        $workflowFindings = @()
        if ($state.status -ne 'completed') { $workflowFindings += 'run-terminal-failed' }
        if (-not (Test-MatrixSkillRead $paths.evidence)) { $workflowFindings += 'entry-skill-read-not-observed' }
        if ($missingStages.Count) { $workflowFindings += "missing-stages:$($missingStages -join ',')" }
        if (@($tests | Where-Object { $_.exitCode -ne 0 }).Count) { $workflowFindings += 'focused-tests-failed' }
        if ([string]$state.profile -ne $profile) { $findings += "profile-mismatch:$($state.profile)" }
        if ($full -and (-not $baseline.generated -or $specFiles.Count -lt 2)) { $findings += 'full-baseline-evidence-missing' }
        if (-not $full -and $baseline.generated) { $findings += 'no-baseline-arm-generated-pre-implementation-baseline' }
        if (-not $full) {
            $isolationPath = Join-Path $paths.evidence 'pre-implementation-baseline-isolation.json'
            if (-not (Test-Path -LiteralPath $isolationPath -PathType Leaf)) { $workflowFindings += 'no-baseline-isolation-evidence-missing' }
            else {
                $isolation = Read-MatrixJson $isolationPath
                if ($isolation.specExists -or $isolation.designExists) { $findings += 'no-baseline-full-docs-existed-before-implementation' }
            }
            if ($state.status -eq 'completed' -and $specFiles.Count -lt 2) { $workflowFindings += 'post-review-full-doc-finalization-missing' }
        }
        if ($productDiff -match '(?i)matspec|matrixspec|\.agents|\.matspec-cli|(?<![A-Za-z0-9])M[01](?![A-Za-z0-9])|(?<![A-Za-z0-9])m[01]-r') { $findings += 'condition-leak-in-product-diff' }
        $audit = [ordered]@{
            runId=$runId;arm=[string]$row.arm;profile=$profile;fullBaseline=$full;passed=($findings.Count -eq 0);findings=$findings
            workflowCompleted=($state.status -eq 'completed');workflowFindings=$workflowFindings
            stageFiles=$stageFiles;focusedTestsPassed=(@($tests | Where-Object { $_.exitCode -ne 0 }).Count -eq 0)
            productDiffSha256=(Get-FileHash -LiteralPath (Join-Path $paths.evidence 'product-code.diff') -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Write-MatrixJson (Join-Path $paths.evidence 'treatment-audit.json') $audit
        $audits += $audit
    }
    Write-MatrixJson (Join-Path $context.campaign 'reports\treatment-audit.json') ([ordered]@{generatedAtUtc=[DateTime]::UtcNow.ToString('o');runs=$audits})
    $failed = @($audits | Where-Object { -not $_.passed })
    if ($failed.Count) { throw "Treatment audit failed: $(($failed | ForEach-Object { "$($_.runId)[$($_.findings -join ',')]" }) -join '; ')" }
    [pscustomobject]@{action='Audit';campaign=$context.campaign;runs=$audits.Count;status='complete'}
}

function Get-MatrixBlindMap($Context) {
    $path = Join-Path $Context.campaign 'state\blind-map.json'
    if (Test-Path -LiteralPath $path) { return Read-MatrixJson $path }
    $rows = @($Context.plan.rows | Sort-Object { [guid]::NewGuid() })
    $entries = for ($index = 0; $index -lt $rows.Count; $index++) {
        [ordered]@{candidate=('Candidate-' + [char]([int][char]'A' + $index));runId=[string]$rows[$index].runId}
    }
    $map = [ordered]@{schemaVersion=1;generatedAtUtc=[DateTime]::UtcNow.ToString('o');candidates=$entries}
    Write-MatrixJson $path $map
    Read-MatrixJson $path
}

function New-MatrixJudgePackages($Context,$Map) {
    $baseline = Resolve-MatrixPath $Context.workspace ([string]$Context.task.baseline.checkout)
    foreach ($entry in @($Map.candidates)) {
        $label = [string]$entry.candidate
        $runId = [string]$entry.runId
        $package = Join-Path $Context.campaign "evaluation\candidates\$label"
        [IO.Directory]::CreateDirectory($package) | Out-Null
        $copies = [ordered]@{
            'task.md'=Join-Path $Context.campaign 'task.md'
            'contract.md'=Join-Path $Context.campaign 'ground-truth\contract.md'
            'rubric.md'=Join-Path $Context.campaign 'ground-truth\rubric.md'
            'judge-prompt.md'=Join-Path $Context.campaign 'evaluation\judge-prompt.md'
            'product.diff'=Join-Path $Context.campaign "runs\$runId\product-code.diff"
            'tests.log'=Join-Path $Context.campaign "runs\$runId\tests.log"
        }
        foreach ($copy in $copies.GetEnumerator()) { Copy-Item -LiteralPath $copy.Value -Destination (Join-Path $package $copy.Key) -Force }
        foreach ($relative in @($Context.task.validation.judgeContextPaths)) {
            $source = Join-Path $baseline ([string]$relative)
            $target = Join-Path $package "baseline\$relative"
            [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        $names = @(Get-ChildItem -LiteralPath $package -File -Recurse | ForEach-Object { $_.FullName.Substring($package.Length) }) -join "`n"
        if ($names -match '(?i)matspec|matrixspec|m0-r|m1-r') { throw "Judge package identity leak: $label" }
    }
}

function Assert-MatrixJudgeResult([string]$Path,[string]$Candidate) {
    $result = Read-MatrixJson $Path
    if ([string]$result.candidate -ne $Candidate) { throw "Judge returned wrong candidate: $Candidate" }
    if (@($result.dimensions).Count -ne 6) { throw "Judge returned wrong dimension count: $Candidate" }
    $score = ($result.dimensions | Measure-Object score -Sum).Sum
    $max = ($result.dimensions | Measure-Object maxScore -Sum).Sum
    if ([int]$score -ne [int]$result.totalScore -or [int]$max -ne 100) { throw "Judge score arithmetic failed: $Candidate" }
}

function Invoke-MatrixOneJudge($Context,[string]$Candidate,[int]$Replicate) {
    $package = Join-Path $Context.campaign "evaluation\candidates\$Candidate"
    $resultRoot = Join-Path $Context.campaign ("evaluation\results\judge-{0:d2}\$Candidate" -f $Replicate)
    $judgeHome = Join-Path $Context.campaign ("evaluation\.judge-homes\judge-{0:d2}\$Candidate" -f $Replicate)
    $final = Join-Path $resultRoot 'judge.final.json'
    if (Test-Path -LiteralPath $final) { Assert-MatrixJudgeResult $final $Candidate; return }
    Initialize-MatrixCodexHome $judgeHome (Join-Path $env:USERPROFILE '.codex\auth.json') ([string]$Context.experiment.model) ([string]$Context.experiment.reasoningEffort)
    $prompt = (Get-Content -Raw -LiteralPath (Join-Path $package 'judge-prompt.md')) + "`n`nAnonymous candidate label: $Candidate"
    $stdout = Join-Path $resultRoot 'judge.jsonl'
    $stderr = Join-Path $resultRoot 'judge.stderr.txt'
    $arguments = @(
        'exec','--json','--ignore-user-config','-m',([string]$Context.experiment.model),
        '-c',"model_reasoning_effort=`"$([string]$Context.experiment.reasoningEffort)`"",
        '-c','approval_policy="never"','-c','web_search="disabled"','-c','features.multi_agent=false',
        '-c','sandbox_workspace_write.network_access=false','-s','read-only','-C',$package,
        '--output-schema',(Join-Path $Context.campaign 'evaluation\judge-output.schema.json'),'-o',$final,'-'
    )
    $process = Invoke-MatrixProcess -Executable (Get-Command codex.cmd -ErrorAction Stop).Source -Arguments $arguments -WorkingDirectory $package -StdoutPath $stdout -StderrPath $stderr -TimeoutMinutes ([int]$Context.experiment.driverConfig.judgeTimeoutMinutes) -InputText $prompt -Environment @{CODEX_HOME=$judgeHome}
    if ($process.timedOut -or $process.exitCode -ne 0) { throw "Judge failed: $Candidate/$Replicate" }
    Assert-MatrixJudgeResult $final $Candidate
    Write-MatrixJson (Join-Path $resultRoot 'metadata.json') ([ordered]@{candidate=$Candidate;replicate=$Replicate;model=[string]$Context.experiment.model;reasoningEffort=[string]$Context.experiment.reasoningEffort;durationSeconds=$process.durationSeconds})
}

function Invoke-MatrixSpecJudge {
    param($ExperimentPath,$PlanPath,$InternalRunId,$InternalCandidate,$JudgeReplicate,$Resume,$DriverPath)
    $context = Get-MatrixContext $ExperimentPath $PlanPath
    $map = Get-MatrixBlindMap $context
    if ($InternalCandidate) {
        if ($JudgeReplicate -lt 1) { throw 'Internal judge requires JudgeReplicate.' }
        Invoke-MatrixOneJudge $context $InternalCandidate $JudgeReplicate
        return
    }
    New-MatrixJudgePackages $context $map
    $jobs = foreach ($replicate in 1..([int]$context.experiment.driverConfig.judgeReplicates)) { foreach ($entry in @($map.candidates)) { [pscustomobject]@{candidate=[string]$entry.candidate;replicate=$replicate} } }
    $driverValue=$DriverPath;$experimentValue=$context.experimentPath;$planValue=$PlanPath
    $outcomes=@($jobs|ForEach-Object -Parallel{
        try { $null = & $using:driverValue -Action Judge -ExperimentPath $using:experimentValue -PlanPath $using:planValue -InternalCandidate $_.candidate -JudgeReplicate $_.replicate;[pscustomobject]@{candidate=$_.candidate;replicate=$_.replicate;ok=$true;error=$null} }
        catch { [pscustomobject]@{candidate=$_.candidate;replicate=$_.replicate;ok=$false;error=$_.Exception.Message} }
    } -ThrottleLimit 6)
    $failed=@($outcomes|Where-Object{-not $_.ok})
    if($failed.Count){throw "Judge failures: $(($failed|ForEach-Object{"$($_.candidate)/$($_.replicate): $($_.error)"})-join'; ')"}
    [pscustomobject]@{action='Judge';campaign=$context.campaign;judgments=$outcomes.Count;status='complete'}
}

function Get-MatrixRawSessionUsage([string]$Root, [string[]]$ExcludeActors = @()) {
    $usage = [ordered]@{inputTokens=0L;cachedInputTokens=0L;outputTokens=0L;reasoningOutputTokens=0L;totalTokens=0L;sessions=0;toolCalls=0;tools=[ordered]@{}}
    $seenTools = [Collections.Generic.HashSet[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\','/')
        $actor = @($relative -split '[\\/]')[0]
        if ($actor -in $ExcludeActors) { continue }
        $last = $null
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            try { $event = $line | ConvertFrom-Json } catch { continue }
            $payload = Get-MatrixValue $event 'payload'
            $eventType = Get-MatrixValue $event 'type' ''
            if ($eventType -eq 'event_msg' -and (Get-MatrixValue $payload 'type' '') -eq 'token_count') {
                $info = Get-MatrixValue $payload 'info'
                $totalUsage = Get-MatrixValue $info 'total_token_usage'
                if ($null -ne $totalUsage) { $last = $totalUsage }
            }
            elseif ($eventType -eq 'response_item' -and (Get-MatrixValue $payload 'type' '') -in @('custom_tool_call','function_call','mcp_tool_call')) {
                $callId = [string](Get-MatrixValue $payload 'call_id' (Get-MatrixValue $payload 'id' ''))
                if (-not $callId) { $callId = "$($file.FullName):$line" }
                if ($seenTools.Add($callId)) {
                    $tool = [string](Get-MatrixValue $payload 'name' (Get-MatrixValue $payload 'tool' 'unknown'))
                    if (-not $usage.tools.Contains($tool)) { $usage.tools[$tool] = 0 }
                    $usage.tools[$tool]++
                    $usage.toolCalls++
                }
            }
        }
        if ($null -eq $last) { continue }
        $usage.sessions++
        $usage.inputTokens += [long](Get-MatrixValue $last 'input_tokens' 0)
        $usage.cachedInputTokens += [long](Get-MatrixValue $last 'cached_input_tokens' 0)
        $usage.outputTokens += [long](Get-MatrixValue $last 'output_tokens' 0)
        $usage.reasoningOutputTokens += [long](Get-MatrixValue $last 'reasoning_output_tokens' 0)
        $usage.totalTokens += [long](Get-MatrixValue $last 'total_tokens' 0)
    }
    [pscustomobject]$usage
}

function Get-MatrixCredits($Usage,$Pricing) {
    $uncached = [math]::Max(0,[long]$Usage.inputTokens-[long]$Usage.cachedInputTokens)
    [math]::Round((($uncached*[double]$Pricing.input)+([long]$Usage.cachedInputTokens*[double]$Pricing.cachedInput)+([long]$Usage.outputTokens*[double]$Pricing.output))/1000000,2)
}

function Get-MatrixActiveSeconds([string]$EvidenceRoot, [string[]]$ExcludeActors = @('operator')) {
    $total = 0.0
    $path = Join-Path $EvidenceRoot 'processes.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return $total }
    foreach ($line in [IO.File]::ReadLines($path)) {
        if (-not $line.Trim()) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ([string]$record.actor -in $ExcludeActors) { continue }
        if ($null -ne $record.durationSeconds) { $total += [double]$record.durationSeconds }
    }
    [math]::Round($total,3)
}

function Get-MatrixElapsedMetrics([string]$EvidenceRoot, [double]$SchedulerGapThresholdSeconds = 300) {
    $path = Join-Path $EvidenceRoot 'processes.jsonl'
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{grossSeconds=0.0;adjustedSeconds=0.0;schedulerGapSeconds=0.0}
    }
    $intervals = @()
    foreach ($line in [IO.File]::ReadLines($path)) {
        if (-not $line.Trim()) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if (-not $record.startedAtUtc -or -not $record.endedAtUtc) { continue }
        $intervals += [pscustomobject]@{
            started=[DateTimeOffset]::Parse([string]$record.startedAtUtc).UtcDateTime
            ended=[DateTimeOffset]::Parse([string]$record.endedAtUtc).UtcDateTime
        }
    }
    if (-not $intervals.Count) {
        return [pscustomobject]@{grossSeconds=0.0;adjustedSeconds=0.0;schedulerGapSeconds=0.0}
    }
    $ordered = @($intervals | Sort-Object started,ended)
    $first = $ordered[0].started
    $last = ($ordered | Sort-Object ended | Select-Object -Last 1).ended
    $schedulerGap = 0.0
    $coveredUntil = $ordered[0].ended
    foreach ($interval in $ordered | Select-Object -Skip 1) {
        if ($interval.started -gt $coveredUntil) {
            $gap = ($interval.started - $coveredUntil).TotalSeconds
            if ($gap -gt $SchedulerGapThresholdSeconds) { $schedulerGap += $gap }
        }
        if ($interval.ended -gt $coveredUntil) { $coveredUntil = $interval.ended }
    }
    $gross = [math]::Max(0,($last-$first).TotalSeconds)
    [pscustomobject]@{
        grossSeconds=[math]::Round($gross,3)
        adjustedSeconds=[math]::Round([math]::Max(0,$gross-$schedulerGap),3)
        schedulerGapSeconds=[math]::Round($schedulerGap,3)
    }
}

function Get-MatrixBareReferences($Context) {
    $path = Resolve-MatrixPath $Context.workspace ([string]$Context.experiment.driverConfig.bareReferenceReport)
    $text = Get-Content -Raw -LiteralPath $path
    $values = @()
    foreach ($name in @('Terse bare','Detailed bare')) {
        $match = [regex]::Match($text, "(?m)^\| $([regex]::Escape($name)) \|\s*(?<n>\d+)\s*\|\s*\*{0,2}(?<score>[0-9.]+)\*{0,2}\s*\|\s*(?<time>[0-9.]+) min\s*\|\s*(?<tokens>[0-9.]+)M\s*\|\s*(?<tools>[0-9.]+)\s*\|\s*(?<candidate>[0-9.]+)")
        if (-not $match.Success) { continue }
        $values += [ordered]@{
            arm=$name;n=[int]$match.Groups['n'].Value;blindScore=[double]$match.Groups['score'].Value
            activeMinutes=[double]$match.Groups['time'].Value;tokensMillions=[double]$match.Groups['tokens'].Value
            toolCalls=[double]$match.Groups['tools'].Value;candidateCredits=[double]$match.Groups['candidate'].Value
            provenance='historical-frozen';source=$path
        }
    }
    if (-not $values.Count) {
        $match = [regex]::Match($text, '(?m)^\| Historical bare \|\s*(?<n>\d+)\s*\|\s*(?<score>[0-9.]+)\s*\|\s*(?<seconds>[0-9.]+)\s*\|\s*(?<tokens>[0-9,]+)\s*\|\s*(?<tools>[0-9.]+)\s*\|\s*(?<candidate>[0-9.]+)')
        if (-not $match.Success) {
            $match = [regex]::Match($text, '(?m)^\| B \| bare \|\s*(?<n>\d+)\s*\|\s*(?<score>[0-9.]+)\s*\|\s*(?<seconds>[0-9.]+)\s*\|\s*(?<tokens>[0-9,]+)\s*\|\s*(?<tools>[0-9.]+)\s*\|\s*(?<candidate>[0-9.]+)')
        }
        if (-not $match.Success) {
            $match = [regex]::Match($text, '(?m)^\| B \|\s*(?<n>\d+)\s*\|\s*(?<score>[0-9.]+)\s*\|\s*(?<seconds>[0-9.]+)\s*\|\s*(?<tokens>[0-9,]+)\s*\|\s*(?<tools>[0-9.]+)\s*\|\s*(?<candidate>[0-9.]+)')
        }
        if (-not $match.Success) { throw "Could not parse a historical bare reference row: $path" }
        $values += [ordered]@{
            arm='Historical bare';n=[int]$match.Groups['n'].Value;blindScore=[double]$match.Groups['score'].Value
            activeMinutes=[math]::Round(([double]$match.Groups['seconds'].Value/60),2)
            tokensMillions=[math]::Round(([double]($match.Groups['tokens'].Value -replace ',','')/1000000),2)
            toolCalls=[double]$match.Groups['tools'].Value;candidateCredits=[double]$match.Groups['candidate'].Value
            provenance='historical-frozen';source=$path
        }
    }
    $values
}

function Invoke-MatrixSpecSummarize {
    param($ExperimentPath,$PlanPath,$InternalRunId,$InternalCandidate,$JudgeReplicate,$Resume,$DriverPath)
    $context = Get-MatrixContext $ExperimentPath $PlanPath
    $map = Get-MatrixBlindMap $context
    $pricing = Read-MatrixJson (Join-Path $context.campaign 'pricing.json')
    $anonymous = @()
    $runs = @()
    foreach ($entry in @($map.candidates)) {
        $candidate = [string]$entry.candidate
        $runId = [string]$entry.runId
        $scores = @()
        foreach ($replicate in 1..([int]$context.experiment.driverConfig.judgeReplicates)) {
            $result = Read-MatrixJson (Join-Path $context.campaign ("evaluation\results\judge-{0:d2}\$candidate\judge.final.json" -f $replicate))
            $scores += [int]$result.totalScore
        }
        $mean = [math]::Round(($scores | Measure-Object -Average).Average,2)
        $anonymous += [ordered]@{candidate=$candidate;judgeScores=$scores;mean=$mean}
        $row = @($context.plan.rows | Where-Object { [string]$_.runId -eq $runId })[0]
        $state = Read-MatrixJson (Join-Path $context.campaign "runs\$runId\state.json")
        $audit = Read-MatrixJson (Join-Path $context.campaign "runs\$runId\treatment-audit.json")
        $rawSessions = Join-Path $context.campaign "runs\$runId\raw-sessions"
        $usage = Get-MatrixRawSessionUsage $rawSessions @('operator')
        $operatorUsage = Get-MatrixRawSessionUsage (Join-Path $rawSessions 'operator')
        $elapsed = Get-MatrixElapsedMetrics (Join-Path $context.campaign "runs\$runId")
        $candidateActiveSeconds = Get-MatrixActiveSeconds (Join-Path $context.campaign "runs\$runId")
        $totalActiveSeconds = Get-MatrixActiveSeconds (Join-Path $context.campaign "runs\$runId") -ExcludeActors @('')
        $operatorActiveSeconds = [math]::Max(0,$totalActiveSeconds-$candidateActiveSeconds)
        $runs += [ordered]@{
            runId=$runId;candidate=$candidate;arm=[string]$row.arm;treatment=[string]$row.treatment
            profile=[string]$row.factors.profile;fullBaseline=[bool]$row.factors.fullBaseline;status=[string]$state.status;judgeScores=$scores;blindScore=$mean
            activeMinutes=[math]::Round($candidateActiveSeconds/60,2)
            operatorActiveMinutes=[math]::Round($operatorActiveSeconds/60,2)
            wallClockMinutes=[math]::Round(([math]::Max(0,[double]$elapsed.adjustedSeconds-$operatorActiveSeconds)/60),2)
            totalAdjustedWallClockMinutes=[math]::Round(([double]$elapsed.adjustedSeconds/60),2)
            grossWallClockMinutes=[math]::Round(([double]$elapsed.grossSeconds/60),2)
            schedulerGapMinutes=[math]::Round(([double]$elapsed.schedulerGapSeconds/60),2)
            usage=$usage;credits=(Get-MatrixCredits $usage $pricing);operatorUsage=$operatorUsage;operatorCredits=(Get-MatrixCredits $operatorUsage $pricing)
            auditPassed=[bool]$audit.passed;focusedTestsPassed=[bool]$audit.focusedTestsPassed
        }
    }
    Write-MatrixJson (Join-Path $context.campaign 'evaluation\anonymous-summary.json') ([ordered]@{generatedAtUtc=[DateTime]::UtcNow.ToString('o');candidates=$anonymous})
    $arms = @()
    foreach ($armId in @($runs.arm | Select-Object -Unique)) {
        $selected = @($runs | Where-Object { $_.arm -eq $armId })
        $arms += [ordered]@{
            arm=$armId;treatment=[string]$selected[0].treatment;n=$selected.Count
            profile=[string]$selected[0].profile;fullBaseline=[bool]$selected[0].fullBaseline
            blindScore=[math]::Round(($selected.blindScore|Measure-Object -Average).Average,2)
            workflowCompleted=@($selected|Where-Object{$_.status -eq 'completed'}).Count
            completionRate=[math]::Round((@($selected|Where-Object{$_.status -eq 'completed'}).Count/$selected.Count),4)
            focusedTestsPassed=@($selected|Where-Object{$_.focusedTestsPassed}).Count
            activeMinutes=[math]::Round(($selected.activeMinutes|Measure-Object -Average).Average,2)
            operatorActiveMinutes=[math]::Round(($selected.operatorActiveMinutes|Measure-Object -Average).Average,2)
            wallClockMinutes=[math]::Round(($selected.wallClockMinutes|Measure-Object -Average).Average,2)
            totalAdjustedWallClockMinutes=[math]::Round(($selected.totalAdjustedWallClockMinutes|Measure-Object -Average).Average,2)
            grossWallClockMinutes=[math]::Round(($selected.grossWallClockMinutes|Measure-Object -Average).Average,2)
            schedulerGapMinutes=[math]::Round(($selected.schedulerGapMinutes|Measure-Object -Average).Average,2)
            tokensPerRun=[math]::Round(($selected|ForEach-Object{[double]$_.usage.totalTokens}|Measure-Object -Average).Average,0)
            toolCallsPerRun=[math]::Round(($selected|ForEach-Object{[double]$_.usage.toolCalls}|Measure-Object -Average).Average,1)
            creditsPerRun=[math]::Round(($selected.credits|Measure-Object -Average).Average,2)
            operatorTokensPerRun=[math]::Round(($selected|ForEach-Object{[double]$_.operatorUsage.totalTokens}|Measure-Object -Average).Average,0)
            operatorToolCallsPerRun=[math]::Round(($selected|ForEach-Object{[double]$_.operatorUsage.toolCalls}|Measure-Object -Average).Average,1)
            operatorCreditsPerRun=[math]::Round(($selected.operatorCredits|Measure-Object -Average).Average,2)
        }
    }
    $bareReport = [string](Get-MatrixValue $context.experiment.driverConfig 'bareReferenceReport' '')
    $bare = if ($bareReport) { @(Get-MatrixBareReferences $context) } else { @() }
    $effects = [ordered]@{}
    foreach ($arm in $arms) {
        $key = ([string]$arm.treatment -replace '[^A-Za-z0-9]+','-').Trim('-')
        foreach ($reference in $bare) {
            $referenceKey = ([string]$reference.arm -replace '[^A-Za-z0-9]+','-').Trim('-').ToLowerInvariant()
            $effects["$key-minus-$referenceKey"] = [math]::Round(([double]$arm.blindScore-[double]$reference.blindScore),2)
        }
    }
    $noBaseline = @($arms | Where-Object { -not $_.fullBaseline })
    $fullBaseline = @($arms | Where-Object { $_.fullBaseline })
    if ($noBaseline.Count -and $fullBaseline.Count) {
        foreach ($profile in @('light','standard')) {
            $with = @($arms | Where-Object { $_.treatment -eq "$profile-full-baseline" })
            $without = @($arms | Where-Object { $_.treatment -eq "$profile-no-baseline" })
            if ($with.Count -and $without.Count) { $effects["$profile-baseline-effect"] = [math]::Round(([double]$with[0].blindScore-[double]$without[0].blindScore),2) }
        }
        foreach ($baselineMode in @('no-baseline','full-baseline')) {
            $standard = @($arms | Where-Object { $_.treatment -eq "standard-$baselineMode" })
            $light = @($arms | Where-Object { $_.treatment -eq "light-$baselineMode" })
            if ($standard.Count -and $light.Count) { $effects["standard-minus-light-$baselineMode"] = [math]::Round(([double]$standard[0].blindScore-[double]$light[0].blindScore),2) }
        }
    }
    $summary = [ordered]@{
        schemaVersion=1;generatedAtUtc=[DateTime]::UtcNow.ToString('o')
        provenance=[ordered]@{matrixSpec='fresh-current-run';operatorCost='reported-separately-and-excluded-from-arm-cost';wallClock='recomputed-from-process-intervals-with-operator-active-time-and-scheduler-gaps-over-300-seconds-reported-and-excluded'}
        bareReferences=$bare;matrixSpecArms=$arms;runs=$runs
        effects=$effects
    }
    Write-MatrixJson (Join-Path $context.campaign 'reports\matrixspec-comparison.json') $summary

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# MatrixSpec experiment comparison')
    $lines.Add('')
    $lines.Add('## Result')
    $lines.Add('')
    $lines.Add('| Arm | Provenance | n | Workflow complete | Blind score | Active time/run | Wall time/run | Tokens/run | Tool calls/run | Credits/run |')
    $lines.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    foreach ($item in $bare) { $lines.Add("| $($item.arm) | historical frozen | $($item.n) | not recorded | $($item.blindScore) | $($item.activeMinutes) min | $($item.tokensMillions)M | $($item.candidateCredits) |") }
    foreach ($item in $arms) { $lines.Add("| MatrixSpec $($item.treatment) | fresh | $($item.n) | $($item.workflowCompleted)/$($item.n) | $($item.blindScore) | $($item.activeMinutes) min | $($item.wallClockMinutes) min | $([math]::Round($item.tokensPerRun/1000000,2))M | $($item.toolCallsPerRun) | $($item.creditsPerRun) |") }
    $lines.Add('')
    $lines.Add('Score effects against historical bare references:')
    $lines.Add('')
    foreach ($effect in $effects.GetEnumerator()) { $lines.Add("- $($effect.Key): $($effect.Value) points.") }
    $lines.Add('')
    $lines.Add('## Per-run evidence')
    $lines.Add('')
    $lines.Add('| Run | Anonymous candidate | Treatment | Workflow | Judge scores | Mean | Active time | Wall time | Scheduler gap | Tokens | Tools | Credits |')
    $lines.Add('|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    foreach ($run in $runs) { $lines.Add("| $($run.runId) | $($run.candidate) | $($run.treatment) | $($run.status) | $($run.judgeScores -join ' / ') | $($run.blindScore) | $($run.activeMinutes) min | $($run.wallClockMinutes) min | $($run.schedulerGapMinutes) min | $([math]::Round($run.usage.totalTokens/1000000,2))M | $($run.usage.toolCalls) | $($run.credits) |") }
    $lines.Add('')
    $lines.Add('## Evidence boundary')
    $lines.Add('')
    $lines.Add('- MatrixSpec results are fresh runs from this campaign. Ground Truth operator time, tokens, and tools are preserved separately but excluded from candidate arm cost.')
    $lines.Add("- Every MatrixSpec arm used the experiment's frozen one-commit baseline, task, model, effort, focused tests, product diff scope, rubric, and two-judge protocol.")
    $lines.Add('- Full-baseline arms generated and applied spec.md/design.md before the feature request. No-baseline arms kept them absent through review, then created them only for the mandatory done finalization gate.')
    $lines.Add('- Blind scores include every predeclared trajectory, including terminal workflow failures; workflow completion is reported separately and no replacement run was selected.')
    $lines.Add('- Wall time is recomputed from process timestamps. GT operator active time and gaps over five minutes between recorded subprocesses are excluded from candidate wall time and retained separately.')
    $lines.Add("- This is a one-task comparison with $($runs.Count) fresh run(s), and the bare data were executed earlier, so report task-specific effects rather than a universal causal claim.")
    Write-MatrixText (Join-Path $context.campaign 'reports\matrixspec-comparison.md') (($lines -join "`n") + "`n")
    [pscustomobject]@{action='Summarize';campaign=$context.campaign;report=(Join-Path $context.campaign 'reports\matrixspec-comparison.md');status='complete'}
}
