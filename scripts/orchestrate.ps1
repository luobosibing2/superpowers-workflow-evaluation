[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string[]]$RunIds,
    [Nullable[int]]$MaxParallel,
    [Nullable[int]]$TimeoutMinutes,
    [Nullable[long]]$TokenSoftCap,
    [string]$Model,
    [string]$ReasoningEffort,
    [switch]$Resume,
    [switch]$NoPrepare,
    [switch]$SkipProbeGate,
    [switch]$SelfTest,
    [switch]$InternalWorker,
    [string]$InternalRunId,
    [string]$CodexCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-PropertyValue {
    param([AllowNull()][object]$Object, [string]$Name, [AllowNull()][object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-ConditionMap {
    param([string]$Path)
    $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $map = @{}
    if ($null -ne $document.runs) {
        foreach ($entry in $document.runs) { $map[[string]$entry.run] = ([string]$entry.condition).ToLowerInvariant() }
    }
    else {
        foreach ($property in $document.PSObject.Properties) {
            if ($property.Name -match '^run-\d+$') { $map[$property.Name] = ([string]$property.Value).ToLowerInvariant() }
        }
    }
    return $map
}

function Get-EventUsage {
    param([object]$Event)
    if ((Get-PropertyValue $Event 'type') -ne 'turn.completed') { return $null }
    $usage = Get-PropertyValue $Event 'usage'
    if ($null -eq $usage) { return $null }
    $inputTokens = [long](Get-PropertyValue $usage 'input_tokens' 0L)
    $cachedTokens = [long](Get-PropertyValue $usage 'cached_input_tokens' 0L)
    $outputTokens = [long](Get-PropertyValue $usage 'output_tokens' 0L)
    $reasoningTokens = [long](Get-PropertyValue $usage 'reasoning_output_tokens' 0L)
    $totalTokens = [long](Get-PropertyValue $usage 'total_tokens' ($inputTokens + $outputTokens))
    return [ordered]@{
        inputTokens = $inputTokens
        cachedInputTokens = $cachedTokens
        outputTokens = $outputTokens
        reasoningOutputTokens = $reasoningTokens
        totalTokens = $totalTokens
    }
}

function Get-LogSummary {
    param([string[]]$Paths)
    $threadId = $null
    $finalMessage = $null
    $usage = [ordered]@{ inputTokens = 0L; cachedInputTokens = 0L; outputTokens = 0L; reasoningOutputTokens = 0L; totalTokens = 0L }
    $toolIds = [Collections.Generic.HashSet[string]]::new()
    $toolTypes = @{}
    $turns = 0

    foreach ($path in $Paths | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $path) {
            $lineNumber++
            try { $event = $line | ConvertFrom-Json } catch { continue }
            if ((Get-PropertyValue $event 'type') -eq 'thread.started') { $threadId = [string](Get-PropertyValue $event 'thread_id' $threadId) }
            $item = Get-PropertyValue $event 'item'
            $eventType = Get-PropertyValue $event 'type'
            if ($eventType -in @('item.started', 'item.completed') -and $null -ne $item) {
                if ($eventType -eq 'item.completed' -and (Get-PropertyValue $item 'type') -eq 'agent_message') {
                    $text = Get-PropertyValue $item 'text'
                    if ($null -eq $text) { $text = Get-PropertyValue $item 'content' }
                    if ($null -ne $text) { $finalMessage = [string]$text }
                }
                $toolType = [string](Get-PropertyValue $item 'type' '')
                if ($toolType -match 'command|tool_call|web_search|mcp|collaboration|subagent') {
                    $itemId = Get-PropertyValue $item 'id'
                    $id = if ($null -ne $itemId) { "$path::$itemId" } else { "$path::$lineNumber" }
                    if ($toolIds.Add($id)) { $toolTypes[$toolType] = 1 + [int]($toolTypes[$toolType] ?? 0) }
                }
            }
            $turnUsage = Get-EventUsage $event
            if ($null -ne $turnUsage) {
                $turns++
                foreach ($key in @($usage.Keys)) { $usage[$key] += [long]$turnUsage[$key] }
            }
        }
    }
    return [pscustomobject]@{
        threadId = $threadId
        finalMessage = $finalMessage
        turns = $turns
        usage = $usage
        toolCalls = $toolIds.Count
        toolCallsByType = $toolTypes
    }
}

function Get-OperatorQuestion {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    $match = [regex]::Match($Message, '(?s)OPERATOR_QUESTION:\s*(.+?)\s*$')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim()
}

function Normalize-OperatorAnswer {
    param([AllowNull()][string]$Answer)
    if ($null -eq $Answer) { return '' }
    return [regex]::Replace($Answer, '(?s)^\s*OPERATOR_ANSWER:\s*', '', 1).Trim()
}

function Get-RunActorSummary {
    param([string]$RunRoot, [string]$Actor)
    $logs = @(Get-ChildItem -LiteralPath $RunRoot -Filter "$Actor-turn-*.jsonl" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $summary = Get-LogSummary $logs
    if ([string]::IsNullOrWhiteSpace($summary.finalMessage)) {
        $final = Get-ChildItem -LiteralPath $RunRoot -Filter "$Actor-turn-*.final.txt" -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($null -ne $final) { $summary.finalMessage = Get-Content -Raw -LiteralPath $final.FullName }
    }
    return $summary
}

function Merge-TurnLogs {
    param([string]$RunRoot, [string]$Actor)
    $target = Join-Path $RunRoot "$Actor.jsonl"
    $logs = @(Get-ChildItem -LiteralPath $RunRoot -Filter "$Actor-turn-*.jsonl" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $writer = [IO.StreamWriter]::new($target, $false, [Text.UTF8Encoding]::new($false))
    try {
        foreach ($log in $logs) {
            foreach ($line in Get-Content -LiteralPath $log.FullName) { $writer.WriteLine($line) }
        }
    }
    finally { $writer.Dispose() }
    return $target
}

function Invoke-CodexProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Prompt,
        [string]$WorkingDirectory,
        [string]$CodexHome,
        [string]$StdoutPath,
        [string]$StderrPath,
        [datetime]$DeadlineUtc,
        [long]$RemainingTokenBudget
    )
    $start = [DateTime]::UtcNow
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
    $info.Environment['CODEX_HOME'] = $CodexHome
    $info.Environment['SUPERPOWERS_DISABLE_TELEMETRY'] = '1'
    foreach ($argument in $Arguments) { $null = $info.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Failed to start $Executable" }
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Prompt)
    $process.StandardInput.Close()

    $reportedTokens = 0L
    $timedOut = $false
    $tokenCapReached = $false
    $writer = [IO.StreamWriter]::new($StdoutPath, $false, [Text.UTF8Encoding]::new($false))
    try {
        $readTask = $process.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($readTask.Wait(250)) {
                $line = $readTask.Result
                if ($null -eq $line) { break }
                $writer.WriteLine($line)
                $writer.Flush()
                try {
                    $eventUsage = Get-EventUsage ($line | ConvertFrom-Json)
                    if ($null -ne $eventUsage) { $reportedTokens += [long]$eventUsage.totalTokens }
                }
                catch { }
                if ($RemainingTokenBudget -ge 0 -and $reportedTokens -ge $RemainingTokenBudget) {
                    $tokenCapReached = $true
                }
                $readTask = $process.StandardOutput.ReadLineAsync()
            }
            if ([DateTime]::UtcNow -ge $DeadlineUtc) {
                $timedOut = $true
                if (-not $process.HasExited) { $process.Kill($true) }
                break
            }
        }
    }
    finally {
        $writer.Dispose()
        if (-not $process.HasExited) { $process.WaitForExit(5000) | Out-Null }
        $stderrTask.Result | Set-Content -LiteralPath $StderrPath -Encoding utf8NoBOM
    }
    return [pscustomobject]@{
        exitCode = if ($process.HasExited) { $process.ExitCode } else { -1 }
        startedAtUtc = $start.ToString('o')
        endedAtUtc = [DateTime]::UtcNow.ToString('o')
        durationSeconds = [math]::Round(([DateTime]::UtcNow - $start).TotalSeconds, 3)
        timedOut = $timedOut
        tokenCapReached = $tokenCapReached
    }
}

function New-CommonCodexArguments {
    param(
        [string]$SelectedModel,
        [string]$SelectedEffort,
        [bool]$EnableMultiAgent,
        [string]$SubagentModel,
        [string]$SubagentEffort,
        [int]$MaxSubagents,
        [string]$DeveloperInstructions = ''
    )
    $arguments = @(
        '--json', '--ignore-user-config', '-m', $SelectedModel,
        '-c', "model_reasoning_effort=`"$SelectedEffort`"",
        '-c', 'web_search="disabled"',
        '-c', 'shell_environment_policy.set={ HTTP_PROXY = "http://127.0.0.1:9", HTTPS_PROXY = "http://127.0.0.1:9", ALL_PROXY = "http://127.0.0.1:9", NO_PROXY = "", GOPROXY = "off", SUPERPOWERS_DISABLE_TELEMETRY = "1" }'
    )
    if (-not [string]::IsNullOrEmpty($DeveloperInstructions)) {
        $toml = ConvertTo-Json -Compress -InputObject $DeveloperInstructions
        $arguments += @('-c', "developer_instructions=$toml")
    }
    if ($EnableMultiAgent) {
        $arguments += @(
            '-c', 'approval_policy="on-request"',
            '-c', 'approvals_reviewer="auto_review"',
            '-c', 'features.multi_agent=true',
            '-c', "agents.default_subagent_model=`"$SubagentModel`"",
            '-c', "agents.default_subagent_reasoning_effort=`"$SubagentEffort`"",
            '-c', "agents.max_concurrent_threads_per_session=$MaxSubagents"
        )
    }
    else { $arguments += @('-c', 'approval_policy="never"', '-c', 'features.multi_agent=false') }
    return $arguments
}

function New-DisabledSuperpowersSkillsArgument {
    param([string]$CandidateHome, [string]$Version)
    $skillsRoot = Join-Path $CandidateHome "plugins\cache\superpowers-dev\superpowers\$Version\skills"
    $entries = Get-ChildItem -LiteralPath $skillsRoot -Directory | ForEach-Object {
        $path = (Join-Path $_.FullName 'SKILL.md').Replace('\', '/')
        if (Test-Path -LiteralPath $path) { "{ path = `"$path`", enabled = false }" }
    }
    if (@($entries).Count -eq 0) { throw "No installed Superpowers skills found under $skillsRoot" }
    return 'skills.config=[' + ($entries -join ',') + ']'
}

function Initialize-OperatorHome {
    param([string]$CandidateHome, [string]$OperatorHome)
    New-Item -ItemType Directory -Force -Path $OperatorHome | Out-Null
    $sourceAuth = Join-Path $CandidateHome 'auth.json'
    $targetAuth = Join-Path $OperatorHome 'auth.json'
    if (-not (Test-Path -LiteralPath $targetAuth)) {
        if (-not (Test-Path -LiteralPath $sourceAuth)) { throw "Candidate authentication is missing: $sourceAuth" }
        Copy-Item -LiteralPath $sourceAuth -Destination $targetAuth
    }
}

function Add-ProcessRecord {
    param([string]$RunRoot, [string]$Actor, [int]$Turn, [object]$Result)
    [ordered]@{
        actor = $Actor
        turn = $Turn
        startedAtUtc = $Result.startedAtUtc
        endedAtUtc = $Result.endedAtUtc
        durationSeconds = $Result.durationSeconds
        exitCode = $Result.exitCode
        timedOut = $Result.timedOut
        tokenCapReached = $Result.tokenCapReached
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $RunRoot 'processes.jsonl') -Encoding utf8NoBOM
}

function Export-CommandLog {
    param([string]$CandidateJsonl, [string]$OutputPath)
    $commands = @()
    if (Test-Path -LiteralPath $CandidateJsonl) {
        foreach ($line in Get-Content -LiteralPath $CandidateJsonl) {
            try { $event = $line | ConvertFrom-Json } catch { continue }
            $item = Get-PropertyValue $event 'item'
            if ($null -ne $item -and (Get-PropertyValue $item 'type' '') -match 'command') { $commands += $line }
        }
    }
    $commands | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
}

function Merge-TestLogs {
    param([string]$RunRoot, [string]$OutputPath)
    $writer = [IO.StreamWriter]::new($OutputPath, $false, [Text.UTF8Encoding]::new($false))
    try {
        foreach ($log in Get-ChildItem -LiteralPath $RunRoot -Filter 'focused-test-*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name) {
            $writer.WriteLine("===== $($log.Name) =====")
            foreach ($line in Get-Content -LiteralPath $log.FullName) { $writer.WriteLine($line) }
        }
    }
    finally { $writer.Dispose() }
}

function Save-GitEvidence {
    param([string]$Worktree, [string]$RunRoot, [object]$ExperimentConfig)
    $baselineRoot = ((& git -C $Worktree rev-list --max-parents=0 HEAD 2>&1) | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($baselineRoot)) { throw "Cannot resolve synthetic root for $Worktree" }
    $commands = @(
        @{ name = 'git-status.txt'; args = @('status', '--short') },
        @{ name = 'product.diff'; args = @('diff', '--binary', $baselineRoot) },
        @{ name = 'git-diff-stat.txt'; args = @('diff', '--stat', $baselineRoot) },
        @{ name = 'git-log.txt'; args = @('log', '--oneline', '--decorate', '-10') }
    )
    foreach ($command in $commands) {
        $output = & git -C $Worktree @($command.args) 2>&1
        $output | Set-Content -LiteralPath (Join-Path $RunRoot $command.name) -Encoding utf8NoBOM
    }
    $specSource = Join-Path $Worktree 'docs\superpowers'
    if (Test-Path -LiteralPath $specSource) {
        $archive = Join-Path $RunRoot 'archived-spec'
        New-Item -ItemType Directory -Force -Path $archive | Out-Null
        Copy-Item -LiteralPath $specSource -Destination $archive -Recurse -Force
    }
    Get-ChildItem -LiteralPath $Worktree -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/](docs[\\/](superpowers|plans|specs)|specs?|plans?)[\\/]' } |
        ForEach-Object { $_.FullName.Substring($Worktree.Length).TrimStart('\', '/') } |
        Sort-Object | Set-Content -LiteralPath (Join-Path $RunRoot 'spec-files.txt') -Encoding utf8NoBOM

    $previous = @{
        GOPROXY = $env:GOPROXY; HTTP_PROXY = $env:HTTP_PROXY; HTTPS_PROXY = $env:HTTPS_PROXY
        NO_PROXY = $env:NO_PROXY; SUPERPOWERS_DISABLE_TELEMETRY = $env:SUPERPOWERS_DISABLE_TELEMETRY
    }
    $testResults = @()
    try {
        $env:GOPROXY = 'off'
        $env:HTTP_PROXY = 'http://127.0.0.1:9'
        $env:HTTPS_PROXY = 'http://127.0.0.1:9'
        $env:NO_PROXY = ''
        $env:SUPERPOWERS_DISABLE_TELEMETRY = '1'
        Push-Location $Worktree
        try {
            $testNumber = 0
            foreach ($test in @($ExperimentConfig.focusedTests)) {
                $testNumber++
                $testPath = Join-Path $RunRoot ('focused-test-{0:d2}.log' -f $testNumber)
                "COMMAND: $test" | Set-Content -LiteralPath $testPath -Encoding utf8NoBOM
                & $env:ComSpec /d /s /c ([string]$test) 2>&1 | Add-Content -LiteralPath $testPath -Encoding utf8NoBOM
                "EXIT_CODE: $LASTEXITCODE" | Add-Content -LiteralPath $testPath -Encoding utf8NoBOM
                $testResults += [ordered]@{ command = [string]$test; exitCode = $LASTEXITCODE; log = [IO.Path]::GetFileName($testPath) }
            }
        }
        finally { Pop-Location }
    }
    finally {
        foreach ($key in $previous.Keys) {
            if ($null -eq $previous[$key]) { Remove-Item -LiteralPath "env:$key" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "env:$key" -Value $previous[$key] }
        }
    }
    Merge-TestLogs $RunRoot (Join-Path $RunRoot 'tests.log')
    Export-CommandLog (Join-Path $RunRoot 'candidate.jsonl') (Join-Path $RunRoot 'commands.log')
    return $testResults
}

function Invoke-OneRun {
    param(
        [string]$RunId,
        [string]$ExperimentRoot,
        [string]$Executable,
        [string]$SelectedModel,
        [string]$SelectedEffort,
        [int]$SelectedTimeoutMinutes,
        [long]$SelectedTokenCap,
        [bool]$ContinueRun
    )
    $config = Get-Content -Raw -LiteralPath (Join-Path $ExperimentRoot 'experiment.json') | ConvertFrom-Json
    $conditionMap = Get-ConditionMap (Join-Path $ExperimentRoot 'state\condition-map.json')
    if (-not $conditionMap.ContainsKey($RunId)) { throw "Unknown run id: $RunId" }

    $runRoot = Join-Path $ExperimentRoot "runs\$RunId"
    $worktree = Join-Path $ExperimentRoot "runs\worktrees\$RunId"
    $homeRoot = Join-Path $ExperimentRoot "state\codex-homes\$RunId"
    $candidateHome = Join-Path $homeRoot 'candidate'
    $operatorHome = Join-Path $homeRoot 'operator'
    $statePath = Join-Path $runRoot 'state.json'
    if (-not (Test-Path -LiteralPath $worktree)) { throw "Run is not prepared: $worktree" }
    Initialize-OperatorHome $candidateHome $operatorHome
    $invocationStartedAt = [DateTime]::UtcNow
    $priorActiveWallClockSeconds = 0.0

    if (Test-Path -LiteralPath $statePath) {
        $existingState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ($existingState.status -eq 'completed') { return $existingState }
        if (-not $ContinueRun) { throw "$RunId already has state '$($existingState.status)'; pass -Resume to continue." }
        $startedAt = [datetime]$existingState.startedAtUtc
        if ($null -ne $existingState.PSObject.Properties['activeWallClockSeconds']) {
            $priorActiveWallClockSeconds = [double]$existingState.activeWallClockSeconds
        }
        elseif (Test-Path -LiteralPath (Join-Path $runRoot 'processes.jsonl')) {
            foreach ($line in Get-Content -LiteralPath (Join-Path $runRoot 'processes.jsonl')) {
                $priorActiveWallClockSeconds += [double](($line | ConvertFrom-Json).durationSeconds)
            }
        }
    }
    else { $startedAt = [DateTime]::UtcNow }
    $remainingWallClockSeconds = [math]::Max(0.0, ($SelectedTimeoutMinutes * 60.0) - $priorActiveWallClockSeconds)
    $deadline = $invocationStartedAt.AddSeconds($remainingWallClockSeconds)

    $state = [ordered]@{
        schemaVersion = 1
        runId = $RunId
        condition = $conditionMap[$RunId]
        status = 'running'
        startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        model = $SelectedModel
        reasoningEffort = $SelectedEffort
        codexVersion = ((& $Executable --version 2>&1) -join ' ').Trim()
        host = [ordered]@{ os = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString() }
        tokenSoftCap = $SelectedTokenCap
        wallClockMinutes = $SelectedTimeoutMinutes
    }
    Write-JsonAtomic $statePath $state

    $task = Get-Content -Raw -LiteralPath (Join-Path $ExperimentRoot 'task.md')
    $operatorMaterials = @('operator-guide.md', 'contract.md', 'rubric.md') | ForEach-Object {
        $path = Join-Path $ExperimentRoot "ground-truth\$_"
        "# $_`n`n$(Get-Content -Raw -LiteralPath $path)"
    }
    $operatorContext = "# Frozen task.md`n`n$task`n`n" + ($operatorMaterials -join "`n`n")
    $operatorRepo = Join-Path $ExperimentRoot 'ground-truth\reference'
    $decisionsPath = Join-Path $runRoot 'operator-decisions.jsonl'
    $developerInstructions = if ($conditionMap[$RunId] -eq 'with') {
        Get-Content -Raw -LiteralPath (Join-Path $ExperimentRoot 'state\treatment-bootstrap.md')
    } else { '' }
    $disabledSkillsArgument = if ($conditionMap[$RunId] -eq 'with') {
        New-DisabledSuperpowersSkillsArgument $candidateHome ([string]$config.superpowersVersion)
    } else { $null }
    $state.treatment = [ordered]@{
        bootstrapInjected = ($conditionMap[$RunId] -eq 'with')
        bootstrapSha256 = if ($conditionMap[$RunId] -eq 'with') { (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ExperimentRoot 'state\treatment-bootstrap.md')).Hash } else { $null }
    }
    Write-JsonAtomic $statePath $state

    try {
        while ($true) {
            $candidateLogs = @(Get-ChildItem -LiteralPath $runRoot -Filter 'candidate-turn-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
            $operatorLogs = @(Get-ChildItem -LiteralPath $runRoot -Filter 'operator-turn-*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
            $candidate = Get-RunActorSummary $runRoot 'candidate'
            $operator = Get-RunActorSummary $runRoot 'operator'
            $question = Get-OperatorQuestion $candidate.finalMessage
            if ($null -eq $question -and $conditionMap[$RunId] -eq 'with' -and $candidate.finalMessage -match '\?\s*$') {
                $question = $candidate.finalMessage.Trim()
            }

            if ($candidate.finalMessage -match '(?m)^IMPLEMENTATION_COMPLETE\s*$') {
                $state.status = 'completed'
                break
            }
            if ($candidate.usage.totalTokens -ge $SelectedTokenCap) {
                $state.status = 'token_cap'
                break
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                $state.status = 'timeout'
                break
            }

            if ($null -ne $question -and $operator.turns -lt $candidate.turns) {
                $turn = $operatorLogs.Count + 1
                $stdout = Join-Path $runRoot ('operator-turn-{0:d2}.jsonl' -f $turn)
                $stderr = Join-Path $runRoot ('operator-turn-{0:d2}.stderr.txt' -f $turn)
                $lastMessagePath = Join-Path $runRoot ('operator-turn-{0:d2}.final.txt' -f $turn)
                $artifactContext = ''
                $artifactKinds = @()
                if ($question -match '(?i)spec|design') { $artifactKinds += 'specs' }
                if ($question -match '(?i)plan') { $artifactKinds += 'plans' }
                foreach ($kind in $artifactKinds | Select-Object -Unique) {
                    $artifact = Get-ChildItem -LiteralPath (Join-Path $worktree "docs\superpowers\$kind") -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
                    if ($null -ne $artifact) {
                        $artifactContext += "`n`n# Candidate $kind artifact: $($artifact.Name)`n`n$(Get-Content -Raw -LiteralPath $artifact.FullName)"
                    }
                }
                $prompt = "$operatorContext`n`n# Candidate turn`n`n$($candidate.finalMessage)$artifactContext`n`n# Parsed question`n`n$question`n`nAssess any design or specification included in the candidate turn or attached candidate artifact against the Ground Truth. Answer only at the behavioral requirement level. Do not reveal historical file paths, symbols, code, patches, or test bodies."
                $common = (New-CommonCodexArguments ([string]$config.operatorModel) ([string]$config.operatorReasoningEffort) $false '' '' 0 '') + @('-c', 'default_permissions=":read-only"')
                if ($null -eq $operator.threadId) {
                    $arguments = @('exec') + $common + @('-C', $operatorRepo, '-o', $lastMessagePath, '-')
                }
                else {
                    $arguments = @('exec', 'resume') + $common + @('-o', $lastMessagePath, $operator.threadId, '-')
                }
                $result = Invoke-CodexProcess $Executable $arguments $prompt $operatorRepo $operatorHome $stdout $stderr $deadline -1
                Add-ProcessRecord $runRoot 'operator' $turn $result
                if ($result.timedOut) { $state.status = 'timeout'; break }
                if ($result.exitCode -ne 0) { throw "Operator Codex exited with $($result.exitCode). See $stderr" }
                $updatedOperator = Get-RunActorSummary $runRoot 'operator'
                [ordered]@{
                    timestampUtc = [DateTime]::UtcNow.ToString('o')
                    candidateTurn = $candidate.turns
                    question = $question
                    answer = $updatedOperator.finalMessage
                    operatorThreadId = $updatedOperator.threadId
                } | ConvertTo-Json -Compress | Add-Content -LiteralPath $decisionsPath -Encoding utf8NoBOM
                continue
            }

            $turn = $candidateLogs.Count + 1
            $stdout = Join-Path $runRoot ('candidate-turn-{0:d2}.jsonl' -f $turn)
            $stderr = Join-Path $runRoot ('candidate-turn-{0:d2}.stderr.txt' -f $turn)
            $lastMessagePath = Join-Path $runRoot ('candidate-turn-{0:d2}.final.txt' -f $turn)
            $common = (New-CommonCodexArguments $SelectedModel $SelectedEffort $true ([string]$config.subagentModel) ([string]$config.subagentReasoningEffort) ([int]$config.maxSubagentsPerRun) $developerInstructions) + @('-c', 'default_permissions=":workspace"')
            if ($null -ne $disabledSkillsArgument) { $common += @('-c', $disabledSkillsArgument) }
            if ($null -eq $candidate.threadId) {
                $prompt = $task
                $arguments = @('exec') + $common + @('-C', $worktree, '-o', $lastMessagePath, '-')
            }
            elseif ($null -ne $question) {
                if ($operator.turns -lt $candidate.turns) { throw 'Operator answer was not recorded.' }
                $decisionCount = if (Test-Path -LiteralPath $decisionsPath) { @(Get-Content -LiteralPath $decisionsPath).Count } else { 0 }
                if ($decisionCount -lt $operator.turns) {
                    [ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                        candidateTurn = $candidate.turns
                        question = $question
                        answer = $operator.finalMessage
                        operatorThreadId = $operator.threadId
                        recoveredAfterInterruption = $true
                    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $decisionsPath -Encoding utf8NoBOM
                }
                $answer = Normalize-OperatorAnswer ([string](Get-Content -LiteralPath $decisionsPath | Select-Object -Last 1 | ConvertFrom-Json).answer)
                $prompt = "OPERATOR_ANSWER:`n$answer`n`nContinue the task. Use OPERATOR_QUESTION or IMPLEMENTATION_COMPLETE exactly as specified."
                $arguments = @('exec', 'resume') + $common + @('-o', $lastMessagePath, $candidate.threadId, '-')
            }
            elseif ($ContinueRun -and ($candidateLogs.Count -gt $candidate.turns -or [string]::IsNullOrWhiteSpace($candidate.finalMessage))) {
                $prompt = 'The previous harness process was interrupted. Continue the task from the current workspace state. Use OPERATOR_QUESTION or IMPLEMENTATION_COMPLETE exactly as specified.'
                $arguments = @('exec', 'resume') + $common + @('-o', $lastMessagePath, $candidate.threadId, '-')
            }
            else {
                $state.status = 'ambiguous_stop'
                break
            }
            $remaining = [math]::Max(0L, $SelectedTokenCap - [long]$candidate.usage.totalTokens)
            $result = Invoke-CodexProcess $Executable $arguments $prompt $worktree $candidateHome $stdout $stderr $deadline $remaining
            Add-ProcessRecord $runRoot 'candidate' $turn $result
            if ($result.timedOut) { $state.status = 'timeout'; break }
            if ($result.exitCode -ne 0) { throw "Candidate Codex exited with $($result.exitCode). See $stderr" }
        }
    }
    catch {
        $state.status = 'harness_error'
        $state.error = $_.Exception.Message
    }
    finally {
        $candidatePath = Merge-TurnLogs $runRoot 'candidate'
        $operatorPath = Merge-TurnLogs $runRoot 'operator'
        $candidate = Get-RunActorSummary $runRoot 'candidate'
        $operator = Get-RunActorSummary $runRoot 'operator'
        $processRecords = if (Test-Path -LiteralPath (Join-Path $runRoot 'processes.jsonl')) {
            @(Get-Content -LiteralPath (Join-Path $runRoot 'processes.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        } else { @() }
        $candidateActiveSeconds = 0.0
        $operatorActiveSeconds = 0.0
        foreach ($record in $processRecords) {
            if ($record.actor -eq 'candidate') { $candidateActiveSeconds += [double]$record.durationSeconds }
            elseif ($record.actor -eq 'operator') { $operatorActiveSeconds += [double]$record.durationSeconds }
        }
        $state.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        $state.endedAtUtc = if ($state.status -eq 'running') { $null } else { $state.updatedAtUtc }
        $state.elapsedWallClockSeconds = [math]::Round(([DateTime]::UtcNow - $startedAt.ToUniversalTime()).TotalSeconds, 3)
        $state.activeWallClockSeconds = [math]::Round($priorActiveWallClockSeconds + ([DateTime]::UtcNow - $invocationStartedAt).TotalSeconds, 3)
        $state.wallClockSeconds = $state.activeWallClockSeconds
        $state.candidate = [ordered]@{
            threadId = $candidate.threadId
            turns = $candidate.turns
            finalMessage = $candidate.finalMessage
            usage = $candidate.usage
            toolCalls = $candidate.toolCalls
            toolCallsByType = $candidate.toolCallsByType
            modelActiveSeconds = [math]::Round($candidateActiveSeconds, 3)
        }
        $state.operator = [ordered]@{
            threadId = $operator.threadId
            turns = $operator.turns
            usage = $operator.usage
            toolCalls = $operator.toolCalls
            toolCallsByType = $operator.toolCallsByType
            modelActiveSeconds = [math]::Round($operatorActiveSeconds, 3)
        }
        $state.focusedTests = @(Save-GitEvidence $worktree $runRoot $config)
        Write-JsonAtomic $statePath $state
        Write-JsonAtomic (Join-Path $runRoot 'metadata.json') $state
    }
    return [pscustomobject]$state
}

function Invoke-SelfTest {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("orchestrate-selftest-$([guid]::NewGuid().ToString('n'))")
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $log = Join-Path $temp 'candidate-turn-01.jsonl'
        @(
            '{"type":"thread.started","thread_id":"thread-1"}',
            '{"type":"item.completed","item":{"id":"tool-1","type":"command_execution","command":"go test ./..."}}',
            '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"OPERATOR_QUESTION: Should names be case insensitive?"}}',
            '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5}}'
        ) | Set-Content -LiteralPath $log -Encoding utf8NoBOM
        $summary = Get-LogSummary @($log)
        if ($summary.threadId -ne 'thread-1' -or $summary.turns -ne 1 -or $summary.usage.totalTokens -ne 120 -or $summary.toolCalls -ne 1) { throw 'JSONL summary failed.' }
        if ((Get-OperatorQuestion $summary.finalMessage) -ne 'Should names be case insensitive?') { throw 'Operator marker parsing failed.' }
        if ($null -ne (Get-OperatorQuestion 'IMPLEMENTATION_COMPLETE')) { throw 'Completion marker was misclassified.' }
        if ((Normalize-OperatorAnswer "OPERATOR_ANSWER:`nYes") -ne 'Yes') { throw 'Operator answer normalization failed.' }
        $commands = Join-Path $temp 'commands.log'
        Export-CommandLog $log $commands
        if (@(Get-Content -LiteralPath $commands).Count -ne 1) { throw 'Command log derivation failed.' }
        'COMMAND: go test ./...' | Set-Content -LiteralPath (Join-Path $temp 'focused-test-01.log') -Encoding utf8NoBOM
        Merge-TestLogs $temp (Join-Path $temp 'tests.log')
        if ((Get-Content -Raw -LiteralPath (Join-Path $temp 'tests.log')) -notmatch 'go test') { throw 'Test log merge failed.' }
        Write-Output 'orchestrate self-test passed'
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$configPath = Join-Path $Root 'experiment.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw "Missing experiment config: $configPath" }
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$selectedModel = if ($Model) { $Model } else { [string]$config.model }
$selectedEffort = if ($ReasoningEffort) { $ReasoningEffort } else { [string]$config.reasoningEffort }
$selectedParallel = if ($null -ne $MaxParallel) { [int]$MaxParallel } else { [int]$config.maxParallel }
$selectedTimeout = if ($null -ne $TimeoutMinutes) { [int]$TimeoutMinutes } else { [int]$config.wallClockMinutes }
$selectedCap = if ($null -ne $TokenSoftCap) { [long]$TokenSoftCap } else { [long]$config.softTokenCap }
if ($selectedParallel -lt 2) { throw 'MaxParallel must be at least 2 so matched runs can start together.' }
if ($selectedTimeout -lt 1 -or $selectedCap -lt 1) { throw 'TimeoutMinutes and TokenSoftCap must be positive.' }
if (-not $CodexCommand) {
    $command = Get-Command codex.cmd -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command codex -ErrorAction Stop }
    $native = Join-Path (Split-Path -Parent $command.Source) 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe'
    $CodexCommand = if (Test-Path -LiteralPath $native) { $native } else { $command.Source }
}

if ($InternalWorker) {
    Invoke-OneRun $InternalRunId $Root $CodexCommand $selectedModel $selectedEffort $selectedTimeout $selectedCap $Resume.IsPresent
    exit
}

$conditionMapPath = Join-Path $Root 'state\condition-map.json'
$allRuns = if ($RunIds) { @($RunIds) } else { @($config.runIds | ForEach-Object { [string]$_ }) }
if (-not $NoPrepare) {
    $needsPreparation = -not (Test-Path -LiteralPath $conditionMapPath)
    foreach ($run in $allRuns) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root "runs\worktrees\$run")) -or
            -not (Test-Path -LiteralPath (Join-Path $Root "state\codex-homes\$run\candidate\auth.json")) -or
            -not (Test-Path -LiteralPath (Join-Path $Root 'ground-truth\reference'))) { $needsPreparation = $true }
    }
    if ($needsPreparation) { & (Join-Path $Root 'scripts\prepare.ps1') | Write-Verbose }
}
if (-not (Test-Path -LiteralPath $conditionMapPath)) { throw 'Missing condition map. Run scripts/prepare.ps1 first.' }
$conditionMap = Get-ConditionMap $conditionMapPath
foreach ($run in $allRuns) { if (-not $conditionMap.ContainsKey($run)) { throw "Run is absent from condition map: $run" } }

$scriptPath = $MyInvocation.MyCommand.Path
$commonWorkerArguments = @{
    Root = $Root
    MaxParallel = $selectedParallel
    TimeoutMinutes = $selectedTimeout
    TokenSoftCap = $selectedCap
    Model = $selectedModel
    ReasoningEffort = $selectedEffort
    Resume = $Resume
    NoPrepare = $true
    InternalWorker = $true
    CodexCommand = $CodexCommand
}

function Invoke-RunBatch {
    param([object[]]$PairGroups)
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($pair in $PairGroups) {
        $members = @($pair.members | Where-Object { $_ -in $allRuns })
        if ($members.Count -gt 0) { $pending.Enqueue($members) }
    }
    $jobs = @()
    while ($pending.Count -gt 0 -or $jobs.Count -gt 0) {
        while ($pending.Count -gt 0) {
            $pair = @($pending.Peek())
            if ($jobs.Count + $pair.Count -gt $selectedParallel) { break }
            $null = $pending.Dequeue()
            foreach ($run in $pair) {
                $statePath = Join-Path $Root "runs\$run\state.json"
                if ($Resume -and (Test-Path -LiteralPath $statePath) -and (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).status -eq 'completed') { continue }
                $arguments = $commonWorkerArguments.Clone()
                $arguments.InternalRunId = $run
                $jobs += Start-Job -Name $run -ScriptBlock { param($Path, $Arguments) & $Path @Arguments } -ArgumentList $scriptPath, $arguments
            }
        }
        if ($jobs.Count -eq 0 -and $pending.Count -gt 0) { throw 'MaxParallel cannot fit the next matched pair.' }
        $finished = Wait-Job -Job $jobs -Any -Timeout 2
        if ($null -ne $finished) {
            Receive-Job -Job $finished -ErrorAction Continue
            if ($finished.State -eq 'Failed') { Write-Warning "$($finished.Name) worker failed: $($finished.ChildJobs[0].JobStateInfo.Reason)" }
            Remove-Job -Job $finished -Force
            $jobs = @($jobs | Where-Object Id -ne $finished.Id)
        }
    }
}

$pairs = @($config.pairIds | ForEach-Object { ,@($_ | ForEach-Object { [string]$_ }) })
$pairGroups = @($pairs | ForEach-Object { [pscustomobject]@{ members = @($_) } })
if ($SkipProbeGate -or $RunIds) { Invoke-RunBatch $pairGroups }
else {
    Invoke-RunBatch @($pairGroups[0])
    $probeInvalid = @($pairs[0] | Where-Object {
        $status = (Get-Content -Raw -LiteralPath (Join-Path $Root "runs\$_\state.json") | ConvertFrom-Json).status
        $status -in @('harness_error', 'timeout')
    })
    if ($probeInvalid.Count -gt 0) { throw "Probe gate failed: $($probeInvalid -join ', ')" }
    Invoke-RunBatch @($pairGroups | Select-Object -Skip 1)
}

$summary = foreach ($run in $allRuns) {
    $statePath = Join-Path $Root "runs\$run\state.json"
    if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json }
}
$summary | Select-Object runId, condition, status, wallClockSeconds, @{n='candidateTokens';e={$_.candidate.usage.totalTokens}}, @{n='candidateToolCalls';e={$_.candidate.toolCalls}}, @{n='operatorTokens';e={$_.operator.usage.totalTokens}} | Format-Table -AutoSize
