[CmdletBinding()]
param(
    [string]$RunsPath,
    [string]$ReportsPath,
    [Nullable[double]]$InputRatePerMillion,
    [Nullable[double]]$CachedInputRatePerMillion,
    [Nullable[double]]$OutputRatePerMillion
)

$ErrorActionPreference = 'Stop'
if (-not $RunsPath) { $RunsPath = Join-Path $PSScriptRoot '..\runs' }
if (-not $ReportsPath) { $ReportsPath = Join-Path $PSScriptRoot '..\reports' }

function Get-PropertyValue($Object, [string[]]$Names) {
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $null
}

function Get-Number($Object, [string[]]$Names) {
    $value = Get-PropertyValue $Object $Names
    if ($null -eq $value) { return [int64]0 }
    return [int64]$value
}

function Get-EventText($Event) {
    $item = Get-PropertyValue $Event @('item')
    $payload = Get-PropertyValue $Event @('payload')
    if ($null -ne $item -and (Get-PropertyValue $item @('type')) -eq 'agent_message') {
        return [string](Get-PropertyValue $item @('text', 'message'))
    }
    if ($null -ne $payload -and (Get-PropertyValue $payload @('type')) -eq 'agent_message') {
        return [string](Get-PropertyValue $payload @('message', 'text'))
    }
    return ''
}

function Get-ToolName($Event) {
    $eventType = [string](Get-PropertyValue $Event @('type'))
    $item = if ($eventType -in @('item.started', 'item.completed')) {
        Get-PropertyValue $Event @('item')
    } elseif ($eventType -eq 'response_item') {
        Get-PropertyValue $Event @('payload')
    }
    if ($null -eq $item) { return $null }

    $type = [string](Get-PropertyValue $item @('type'))
    switch ($type) {
        'command_execution' { return 'shell_command' }
        'file_change' { return 'apply_patch' }
        'web_search' { return 'web_search' }
        'image_generation' { return 'image_generation' }
        'function_call' { return [string](Get-PropertyValue $item @('name')) }
        'custom_tool_call' { return [string](Get-PropertyValue $item @('name')) }
        'mcp_tool_call' {
            $tool = [string](Get-PropertyValue $item @('tool', 'name'))
            if ($tool) { return "mcp:$tool" }
            return 'mcp_tool_call'
        }
        default {
            if ($type -match '(tool_call|command_execution|file_change|web_search|image_generation)$') {
                $name = [string](Get-PropertyValue $item @('name'))
                if ($name) { return $name }
                return $type
            }
        }
    }
    return $null
}

function Read-Participant([string]$Path) {
    $result = [ordered]@{
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        turns = 0
        tool_calls = 0
        tools = [ordered]@{}
        input_tokens = [int64]0
        cached_input_tokens = [int64]0
        output_tokens = [int64]0
        reasoning_tokens = [int64]0
        parse_errors = 0
        implementation_complete = $false
        operator_questions = 0
    }
    if (-not $result.exists) { return [pscustomobject]$result }

    $startedTurns = 0
    $completedTurns = 0
    $seenTools = [System.Collections.Generic.HashSet[string]]::new()
    $lineNumber = 0
    $turnIndex = 0
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Path))) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { $result.parse_errors++; continue }

        $eventType = [string](Get-PropertyValue $event @('type'))
        if ($eventType -eq 'turn.started') { $startedTurns++; $turnIndex++ }
        if ($eventType -eq 'turn.completed') { $completedTurns++ }

        $usage = $null
        if ($eventType -eq 'turn.completed') {
            $usage = Get-PropertyValue $event @('usage')
        } elseif ($eventType -eq 'event_msg') {
            $payload = Get-PropertyValue $event @('payload')
            if ((Get-PropertyValue $payload @('type')) -eq 'token_count') {
                $info = Get-PropertyValue $payload @('info')
                $usage = Get-PropertyValue $info @('last_token_usage')
            }
        }
        if ($null -ne $usage) {
            $result.input_tokens += Get-Number $usage @('input_tokens', 'inputTokens')
            $result.cached_input_tokens += Get-Number $usage @('cached_input_tokens', 'cachedInputTokens')
            $result.output_tokens += Get-Number $usage @('output_tokens', 'outputTokens')
            $result.reasoning_tokens += Get-Number $usage @('reasoning_output_tokens', 'reasoning_tokens', 'reasoningTokens')
        }

        $toolName = Get-ToolName $event
        if ($toolName) {
            $item = if ($eventType -eq 'response_item') { Get-PropertyValue $event @('payload') } else { Get-PropertyValue $event @('item') }
            $id = [string](Get-PropertyValue $item @('id', 'call_id'))
            if (-not $id) {
                if ($eventType -eq 'item.completed') { continue }
                $id = "line:$lineNumber"
            }
            if ($seenTools.Add("$turnIndex::$id")) {
                if (-not $result.tools.Contains($toolName)) { $result.tools[$toolName] = 0 }
                $result.tools[$toolName]++
                $result.tool_calls++
            }
        }

        $text = Get-EventText $event
        if ($text -match '(?m)^IMPLEMENTATION_COMPLETE\b') { $result.implementation_complete = $true }
        $result.operator_questions += [regex]::Matches($text, '(?m)^OPERATOR_QUESTION\b').Count
    }
    $result.turns = if ($startedTurns) { $startedTurns } else { $completedTurns }
    return [pscustomobject]$result
}

function Convert-Date($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Read-SessionTree([string]$HomePath, $Start, $End) {
    $result = [ordered]@{
        available = $false
        session_files = 0
        input_tokens = [int64]0
        cached_input_tokens = [int64]0
        output_tokens = [int64]0
        reasoning_tokens = [int64]0
        tool_calls = 0
        tools = [ordered]@{}
        confidence = 'unavailable'
        notes = 'No candidate session files found.'
        parse_errors = 0
    }
    $sessionsPath = Join-Path $HomePath 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsPath -PathType Container)) { return [pscustomobject]$result }
    $files = @(Get-ChildItem -LiteralPath $sessionsPath -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return [pscustomobject]$result }

    $result.available = $true
    $result.session_files = $files.Count
    $seenEvents = [System.Collections.Generic.HashSet[string]]::new()
    $seenTools = [System.Collections.Generic.HashSet[string]]::new()
    $usageEvents = 0
    foreach ($file in $files) {
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            try { $event = $line | ConvertFrom-Json } catch { $result.parse_errors++; continue }
            $timestamp = Convert-Date (Get-PropertyValue $event @('timestamp'))
            if ($null -ne $Start -and $null -ne $timestamp -and $timestamp -lt $Start.AddMinutes(-5)) { continue }
            if ($null -ne $End -and $null -ne $timestamp -and $timestamp -gt $End.AddMinutes(5)) { continue }

            $eventType = [string](Get-PropertyValue $event @('type'))
            $payload = Get-PropertyValue $event @('payload')
            if ($eventType -eq 'event_msg' -and (Get-PropertyValue $payload @('type')) -eq 'token_count') {
                # Forked subagent rollouts may copy parent events verbatim; exact-line dedupe counts each model call once.
                if (-not $seenEvents.Add($line)) { continue }
                $info = Get-PropertyValue $payload @('info')
                $usage = Get-PropertyValue $info @('last_token_usage')
                if ($null -eq $usage) { continue }
                $result.input_tokens += Get-Number $usage @('input_tokens', 'inputTokens')
                $result.cached_input_tokens += Get-Number $usage @('cached_input_tokens', 'cachedInputTokens')
                $result.output_tokens += Get-Number $usage @('output_tokens', 'outputTokens')
                $result.reasoning_tokens += Get-Number $usage @('reasoning_output_tokens', 'reasoning_tokens', 'reasoningTokens')
                $usageEvents++
            } elseif ($eventType -eq 'response_item') {
                $payloadType = [string](Get-PropertyValue $payload @('type'))
                if ($payloadType -in @('custom_tool_call', 'function_call', 'mcp_tool_call')) {
                    $id = [string](Get-PropertyValue $payload @('call_id', 'id'))
                    if (-not $id) { $id = "$($file.FullName):$line" }
                    if ($seenTools.Add($id)) {
                        $name = [string](Get-PropertyValue $payload @('name', 'tool'))
                        if (-not $name) { $name = $payloadType }
                        if (-not $result.tools.Contains($name)) { $result.tools[$name] = 0 }
                        $result.tools[$name]++
                        $result.tool_calls++
                    }
                }
            }
        }
    }
    if ($result.parse_errors -gt 0) {
        $result.confidence = 'low'
        $result.notes = "Per-run candidate CODEX_HOME only; $($result.parse_errors) malformed session lines skipped."
    } elseif ($usageEvents -eq 0) {
        $result.confidence = 'low'
        $result.notes = 'Candidate session files exist but contain no token usage events.'
    } elseif ($null -eq $Start -or $null -eq $End) {
        $result.confidence = 'medium'
        $result.notes = 'Per-run candidate CODEX_HOME only; no complete metadata time window was available.'
    } else {
        $result.confidence = 'high'
        $result.notes = 'Per-run candidate CODEX_HOME and metadata time window; exact duplicate forked events removed.'
    }
    return [pscustomobject]$result
}

function Get-Artifact([string]$RunPath, [string]$Name) {
    $file = Get-ChildItem -LiteralPath $RunPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $file) { return [pscustomobject]@{ exists = $false; bytes = 0; lines = 0 } }
    $lines = 0
    foreach ($null in [IO.File]::ReadLines($file.FullName)) { $lines++ }
    return [pscustomobject]@{ exists = $true; bytes = $file.Length; lines = $lines }
}

function Get-DiffStats([string]$Path) {
    $stats = [ordered]@{ files = 0; additions = 0; deletions = 0 }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$stats }
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Path))) {
        if ($line.StartsWith('diff --git ')) { $stats.files++ }
        elseif ($line.StartsWith('+') -and -not $line.StartsWith('+++')) { $stats.additions++ }
        elseif ($line.StartsWith('-') -and -not $line.StartsWith('---')) { $stats.deletions++ }
    }
    return [pscustomobject]$stats
}

function Get-Cost($Participant, [bool]$RatesConfigured) {
    if (-not $RatesConfigured) { return $null }
    $inputRate = if ($null -eq $InputRatePerMillion) { 0 } else { [double]$InputRatePerMillion }
    $cachedRate = if ($null -eq $CachedInputRatePerMillion) { 0 } else { [double]$CachedInputRatePerMillion }
    $outputRate = if ($null -eq $OutputRatePerMillion) { 0 } else { [double]$OutputRatePerMillion }
    $uncached = [Math]::Max([int64]0, $Participant.input_tokens - $Participant.cached_input_tokens)
    return [Math]::Round((($uncached * $inputRate) + ($Participant.cached_input_tokens * $cachedRate) + ($Participant.output_tokens * $outputRate)) / 1000000, 6)
}

$runsRoot = (Resolve-Path -LiteralPath $RunsPath).Path
$experimentRoot = Split-Path -Parent $runsRoot
$candidateHomes = Join-Path $experimentRoot 'state\codex-homes'
$ratesConfigured = $PSBoundParameters.ContainsKey('InputRatePerMillion') -or
    $PSBoundParameters.ContainsKey('CachedInputRatePerMillion') -or
    $PSBoundParameters.ContainsKey('OutputRatePerMillion')
$rateSource = if ($ratesConfigured) { 'parameters' } else { $null }
$rateUnit = if ($ratesConfigured) { 'user_supplied_units' } else { $null }
$rateReference = $null
$experimentPath = Join-Path $experimentRoot 'experiment.json'
if (Test-Path -LiteralPath $experimentPath -PathType Leaf) {
    try {
        $experiment = Get-Content -Raw -LiteralPath $experimentPath | ConvertFrom-Json
        $pricingName = [string](Get-PropertyValue $experiment @('pricing'))
        if ($pricingName) {
            $pricingPath = Join-Path $experimentRoot $pricingName
            $pricing = Get-Content -Raw -LiteralPath $pricingPath | ConvertFrom-Json
            if (-not $PSBoundParameters.ContainsKey('InputRatePerMillion')) { $InputRatePerMillion = [double](Get-PropertyValue $pricing @('input')) }
            if (-not $PSBoundParameters.ContainsKey('CachedInputRatePerMillion')) { $CachedInputRatePerMillion = [double](Get-PropertyValue $pricing @('cachedInput', 'cached_input')) }
            if (-not $PSBoundParameters.ContainsKey('OutputRatePerMillion')) { $OutputRatePerMillion = [double](Get-PropertyValue $pricing @('output')) }
            $ratesConfigured = $true
            $rateSource = if ($rateSource) { 'pricing file with parameter overrides' } else { $pricingName }
            $rateUnit = [string](Get-PropertyValue $pricing @('unit'))
            $rateReference = [string](Get-PropertyValue $pricing @('source'))
        }
    } catch { throw "Unable to load experiment pricing: $($_.Exception.Message)" }
}
$conditionMap = @{}
$conditionMapPath = Join-Path $experimentRoot 'state\condition-map.json'
if (Test-Path -LiteralPath $conditionMapPath -PathType Leaf) {
    try {
        $mapJson = Get-Content -Raw -LiteralPath $conditionMapPath | ConvertFrom-Json
        foreach ($entry in @($mapJson.runs)) { $conditionMap[[string]$entry.run] = [string]$entry.condition }
    } catch { }
}
$rows = @()
$toolNames = [System.Collections.Generic.HashSet[string]]::new()
$sessionToolNames = [System.Collections.Generic.HashSet[string]]::new()

foreach ($run in Get-ChildItem -LiteralPath $runsRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'metadata.json') -PathType Leaf } | Sort-Object Name) {
    $metadataPath = Join-Path $run.FullName 'metadata.json'
    $metadata = $null
    $metadataError = $false
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try { $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json } catch { $metadataError = $true }
    } else {
        $metadataError = $true
    }

    $candidate = Read-Participant (Join-Path $run.FullName 'candidate.jsonl')
    $operator = Read-Participant (Join-Path $run.FullName 'operator.jsonl')
    foreach ($name in @($candidate.tools.Keys) + @($operator.tools.Keys)) { [void]$toolNames.Add($name) }

    $start = Convert-Date (Get-PropertyValue $metadata @('start', 'started_at', 'start_time', 'startedAt', 'startedAtUtc'))
    $end = Convert-Date (Get-PropertyValue $metadata @('end', 'ended_at', 'end_time', 'endedAt', 'endedAtUtc'))
    $homeRoot = Join-Path $candidateHomes $run.Name
    $candidateHome = Join-Path $homeRoot 'candidate'
    if (-not (Test-Path -LiteralPath $candidateHome -PathType Container)) { $candidateHome = $homeRoot }
    $sessionTree = Read-SessionTree $candidateHome $start $end
    foreach ($name in @($sessionTree.tools.Keys)) { [void]$sessionToolNames.Add($name) }
    $metadataWall = Get-PropertyValue $metadata @('wallClockSeconds', 'wall_seconds')
    $wallSeconds = if ($null -ne $metadataWall) { [Math]::Round([double]$metadataWall, 3) } elseif ($null -ne $start -and $null -ne $end) { [Math]::Round(($end - $start).TotalSeconds, 3) } else { $null }
    $rawStatus = [string](Get-PropertyValue $metadata @('status'))
    $exitCode = Get-PropertyValue $metadata @('exit_code', 'exitCode')
    $status = if ($rawStatus -match 'timeout|timed_out' -or "$exitCode" -eq '124') {
        'timeout'
    } elseif ($metadataError -or -not $candidate.exists -or $candidate.parse_errors -gt 0 -or $operator.parse_errors -gt 0) {
        'invalid'
    } elseif ($rawStatus -match 'complete|completed|success|succeeded' -or $candidate.implementation_complete) {
        'completed'
    } else {
        'invalid'
    }

    $commands = Get-Artifact $run.FullName 'commands.log'
    $tests = Get-Artifact $run.FullName 'tests.log'
    $diff = Get-Artifact $run.FullName 'product.diff'
    $diffStats = Get-DiffStats (Join-Path $run.FullName 'product.diff')
    $candidateCost = Get-Cost $candidate $ratesConfigured
    $sessionCost = if ($sessionTree.available) { Get-Cost $sessionTree $ratesConfigured } else { $null }
    $operatorCost = Get-Cost $operator $ratesConfigured
    $candidateBilledCost = if ($null -ne $sessionCost) { $sessionCost } else { $candidateCost }
    $metadataCondition = [string](Get-PropertyValue $metadata @('condition'))
    $metadataCandidate = Get-PropertyValue $metadata @('candidate')
    $metadataOperator = Get-PropertyValue $metadata @('operator')
    $candidateParentToolCalls = Get-Number $metadataCandidate @('toolCalls', 'tool_calls')
    $operatorParentToolCalls = Get-Number $metadataOperator @('toolCalls', 'tool_calls')
    $row = [ordered]@{
        run_id = if (Get-PropertyValue $metadata @('run_id', 'runId')) { [string](Get-PropertyValue $metadata @('run_id', 'runId')) } else { $run.Name }
        condition = if ($metadataCondition) { $metadataCondition } elseif ($conditionMap.ContainsKey($run.Name)) { $conditionMap[$run.Name] } else { '' }
        status = $status
        raw_status = $rawStatus
        exit_code = $exitCode
        start = if ($null -ne $start) { $start.ToString('o') } else { $null }
        end = if ($null -ne $end) { $end.ToString('o') } else { $null }
        wall_seconds = $wallSeconds
        turns = $candidate.turns + $operator.turns
        candidate_turns = $candidate.turns
        operator_turns = $operator.turns
        tool_calls = $candidate.tool_calls + $operator.tool_calls
        candidate_tool_calls = $candidate.tool_calls
        operator_tool_calls = $operator.tool_calls
        parent_reported_tool_calls = $candidateParentToolCalls + $operatorParentToolCalls
        candidate_parent_reported_tool_calls = $candidateParentToolCalls
        operator_parent_reported_tool_calls = $operatorParentToolCalls
        candidate_all_session_tool_calls = if ($sessionTree.available) { $sessionTree.tool_calls } else { $null }
        input_tokens = $candidate.input_tokens + $operator.input_tokens
        cached_input_tokens = $candidate.cached_input_tokens + $operator.cached_input_tokens
        output_tokens = $candidate.output_tokens + $operator.output_tokens
        reasoning_tokens = $candidate.reasoning_tokens + $operator.reasoning_tokens
        candidate_input_tokens = $candidate.input_tokens
        candidate_cached_input_tokens = $candidate.cached_input_tokens
        candidate_output_tokens = $candidate.output_tokens
        candidate_reasoning_tokens = $candidate.reasoning_tokens
        candidate_parent_reported_tokens = $candidate.input_tokens + $candidate.output_tokens
        candidate_all_session_tokens = if ($sessionTree.available) { $sessionTree.input_tokens + $sessionTree.output_tokens } else { $null }
        candidate_all_session_input_tokens = if ($sessionTree.available) { $sessionTree.input_tokens } else { $null }
        candidate_all_session_cached_input_tokens = if ($sessionTree.available) { $sessionTree.cached_input_tokens } else { $null }
        candidate_all_session_output_tokens = if ($sessionTree.available) { $sessionTree.output_tokens } else { $null }
        candidate_all_session_reasoning_tokens = if ($sessionTree.available) { $sessionTree.reasoning_tokens } else { $null }
        candidate_session_files = $sessionTree.session_files
        candidate_session_attribution_confidence = $sessionTree.confidence
        candidate_session_attribution_notes = $sessionTree.notes
        operator_input_tokens = $operator.input_tokens
        operator_cached_input_tokens = $operator.cached_input_tokens
        operator_output_tokens = $operator.output_tokens
        operator_reasoning_tokens = $operator.reasoning_tokens
        estimated_cost = if ($null -ne $candidateBilledCost -and $null -ne $operatorCost) { [Math]::Round($candidateBilledCost + $operatorCost, 6) } else { $null }
        estimated_cost_unit = $rateUnit
        candidate_estimated_cost = $candidateBilledCost
        candidate_parent_reported_estimated_cost = $candidateCost
        candidate_all_session_estimated_cost = $sessionCost
        operator_estimated_cost = $operatorCost
        operator_questions = $candidate.operator_questions
        implementation_complete = $candidate.implementation_complete
        commands_exists = $commands.exists
        commands_bytes = $commands.bytes
        commands_lines = $commands.lines
        tests_exists = $tests.exists
        tests_bytes = $tests.bytes
        tests_lines = $tests.lines
        diff_exists = $diff.exists
        diff_bytes = $diff.bytes
        diff_lines = $diff.lines
        product_files_changed = $diffStats.files
        product_additions = $diffStats.additions
        product_deletions = $diffStats.deletions
        candidate_parse_errors = $candidate.parse_errors
        operator_parse_errors = $operator.parse_errors
        candidate_tools = $candidate.tools
        operator_tools = $operator.tools
        candidate_all_session_tools = $sessionTree.tools
    }
    $rows += [pscustomobject]$row
}

New-Item -ItemType Directory -Force -Path $ReportsPath | Out-Null
$csvRows = foreach ($row in $rows) {
    $flat = [ordered]@{}
    foreach ($property in $row.PSObject.Properties) {
        if ($property.Name -notin @('candidate_tools', 'operator_tools', 'candidate_all_session_tools')) { $flat[$property.Name] = $property.Value }
    }
    foreach ($toolName in $sessionToolNames | Sort-Object) {
        $safeName = $toolName -replace '[^a-zA-Z0-9]+', '_'
        $flat["candidate_all_session_tool_$safeName"] = if ($row.candidate_all_session_tools.Contains($toolName)) { $row.candidate_all_session_tools[$toolName] } else { 0 }
    }
    foreach ($toolName in $toolNames | Sort-Object) {
        $safeName = $toolName -replace '[^a-zA-Z0-9]+', '_'
        $candidateCount = if ($row.candidate_tools.Contains($toolName)) { $row.candidate_tools[$toolName] } else { 0 }
        $operatorCount = if ($row.operator_tools.Contains($toolName)) { $row.operator_tools[$toolName] } else { 0 }
        $flat["tool_$safeName"] = $candidateCount + $operatorCount
        $flat["candidate_tool_$safeName"] = $candidateCount
        $flat["operator_tool_$safeName"] = $operatorCount
    }
    [pscustomobject]$flat
}

$csvPath = Join-Path $ReportsPath 'metrics.csv'
$jsonPath = Join-Path $ReportsPath 'metrics.json'
$csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
[pscustomobject]@{
    generated_at = [DateTimeOffset]::UtcNow.ToString('o')
    runs_path = $runsRoot
    rates_per_million = if ($ratesConfigured) {
        [ordered]@{ source = $rateSource; reference = $rateReference; unit = $rateUnit; input = $InputRatePerMillion; cached_input = $CachedInputRatePerMillion; output = $OutputRatePerMillion }
    } else { $null }
    runs = $rows
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

Write-Output "Wrote $($rows.Count) runs to $csvPath and $jsonPath"
