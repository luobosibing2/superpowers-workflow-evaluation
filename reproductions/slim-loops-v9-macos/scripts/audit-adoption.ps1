[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string[]]$RunIds,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allowedSkills = @('brainstorming','writing-plans','systematic-debugging','verification-before-completion')

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-ItemText($Item) {
    if ($null -eq $Item) { return '' }
    $parts = @([string](Get-PropertyValue $Item 'command'), [string](Get-PropertyValue $Item 'text'), [string](Get-PropertyValue $Item 'name'))
    if ($null -ne $Item.PSObject.Properties['changes']) {
        $parts += @($Item.changes | ForEach-Object { [string]$_.path })
    }
    return ($parts -join "`n")
}

function Read-RunEvents([string]$RunPath) {
    $events = @()
    $sequence = 0
    foreach ($file in Get-ChildItem -LiteralPath $RunPath -Filter 'candidate-turn-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name) {
        $lineNumber = 0
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $event = $line | ConvertFrom-Json } catch { continue }
            if ([string]$event.type -ne 'item.started' -and [string]$event.type -ne 'item.completed') { continue }
            $item = $event.item
            if ($null -eq $item) { continue }
            if ([string]$event.type -eq 'item.completed' -and [string]$item.type -notin @('agent_message','command_execution')) { continue }
            $sequence++
            $events += [pscustomobject]@{
                sequence = $sequence
                eventType = [string]$event.type
                itemType = [string]$item.type
                text = Get-ItemText $item
                source = "$($file.Name):$lineNumber"
                item = $item
            }
        }
    }
    return $events
}

function Test-ProductMutation($Event) {
    if ($Event.eventType -ne 'item.started') { return $false }
    if ($Event.itemType -eq 'file_change') {
        return @($Event.item.changes | Where-Object {
            ([string]$_.path).Replace('\','/') -match '/(pkg|cmd|internal|api)/' -and ([string]$_.path).Replace('\','/') -notmatch '/\.slim-superpowers/'
        }).Count -gt 0
    }
    if ($Event.itemType -eq 'command_execution') {
        $command = $Event.text
        return $command -match '(?i)(gofmt\s+-w|sed\s+-i|perl\s+-pi|git\s+apply|\bpatch\b)' -and $command -match '(?i)(pkg/|cmd/|internal/|api/)'
    }
    return $false
}

function Test-ExactBrainstormRead([string]$Command) {
    $inner = $Command.Trim()
    $prefix = '/bin/zsh -lc '
    if ($inner.StartsWith($prefix, [StringComparison]::Ordinal)) {
        $inner = $inner.Substring($prefix.Length).Trim()
        if ($inner.Length -ge 2 -and (($inner[0] -eq '"' -and $inner[$inner.Length - 1] -eq '"') -or ($inner[0] -eq "'" -and $inner[$inner.Length - 1] -eq "'"))) {
            $inner = $inner.Substring(1, $inner.Length - 2)
        }
        $inner = $inner.Replace('\"', '"')
    }
    return $inner -ceq 'cat ".slim-superpowers/skills/brainstorming/SKILL.md"'
}

function Get-AdoptionResult([string]$RunId, [string]$RunPath) {
    $events = @(Read-RunEvents $RunPath)
    $started = @($events | Where-Object { $_.eventType -eq 'item.started' })
    $firstAction = $started | Select-Object -First 1
    $skillReads = @()
    foreach ($event in $started) {
        foreach ($match in [regex]::Matches($event.text, '(?i)\.slim-superpowers/skills/([^/\s"'']+)/SKILL\.md')) {
            $skillReads += [pscustomobject]@{ name = $match.Groups[1].Value.ToLowerInvariant(); sequence = $event.sequence; source = $event.source }
        }
    }
    $brainstorm = $skillReads | Where-Object name -eq 'brainstorming' | Select-Object -First 1
    $planning = $skillReads | Where-Object name -eq 'writing-plans' | Select-Object -First 1
    $verification = $skillReads | Where-Object name -eq 'verification-before-completion' | Select-Object -Last 1
    $debugging = @($skillReads | Where-Object name -eq 'systematic-debugging')
    $removed = @($skillReads | Where-Object { $_.name -notin $allowedSkills } | Select-Object -ExpandProperty name -Unique)
    $firstMutation = $started | Where-Object { Test-ProductMutation $_ } | Select-Object -First 1
    $completion = $events | Where-Object { $_.itemType -eq 'agent_message' -and $_.text -match '(?m)^IMPLEMENTATION_COMPLETE\s*$' } | Select-Object -Last 1
    $questions = @($events | Where-Object { $_.itemType -eq 'agent_message' -and $_.text -match '(?m)^OPERATOR_QUESTION:' })
    $designRequests = @($events | Where-Object { $_.itemType -eq 'agent_message' -and $_.text -match '(?m)^DESIGN_REVIEW_REQUEST:' })
    $reviewReady = @($events | Where-Object { $_.itemType -eq 'agent_message' -and $_.text -match '(?m)^REVIEW_READY\s*$' })
    $decisionsPath = Join-Path $RunPath 'operator-decisions.jsonl'
    $decisionRows = if (Test-Path -LiteralPath $decisionsPath -PathType Leaf) { @(Get-Content -LiteralPath $decisionsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    $answers = @($decisionRows | Where-Object { $_.kind -eq 'question' }).Count
    $designDecisionsPath = Join-Path $RunPath 'design-decisions.jsonl'
    $designRows = @(if (Test-Path -LiteralPath $designDecisionsPath -PathType Leaf) { @(Get-Content -LiteralPath $designDecisionsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() })
    $designApproved = $designRows | Where-Object { [string]$_.status -eq 'approved' } | Select-Object -Last 1
    $reviewPath = Join-Path $RunPath 'review-decisions.jsonl'
    $reviewRows = @(if (Test-Path -LiteralPath $reviewPath -PathType Leaf) { @(Get-Content -LiteralPath $reviewPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() })
    $condition = ''
    $statePath = Join-Path $RunPath 'state.json'
    if (Test-Path -LiteralPath $statePath) { $condition = [string]((Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).condition) }
    $warnings = @()
    if ($null -ne $planning) {
        $shellWarnings = @($started | Where-Object {
            $_.sequence -lt $planning.sequence -and $_.itemType -eq 'command_execution' -and $_.text -match '(?i)(gofmt\s+-w|sed\s+-i|perl\s+-pi|git\s+apply|\bpatch\b|\s>\s)'
        })
        if ($shellWarnings.Count -gt 0) { $warnings += "possible shell mutation before planning: $($shellWarnings.source -join ', ')" }
    }
    $reasons = @()
    $firstActionValid = $null -ne $firstAction -and $firstAction.itemType -eq 'command_execution' -and (Test-ExactBrainstormRead $firstAction.text)
    if (-not $firstActionValid) { $reasons += 'first action was not the exact brainstorming read' }
    if ($questions.Count -lt 1 -or $answers -lt 1) { $reasons += 'no completed GT operator clarification turn' }
    if ($designRequests.Count -lt 1 -or $null -eq $designApproved) { $reasons += 'design was not approved by the GT operator' }
    if ($null -eq $planning) { $reasons += 'writing-plans was not read' }
    if ($null -ne $firstMutation -and $designRequests.Count -gt 0 -and $firstMutation.sequence -lt $designRequests[-1].sequence) { $reasons += 'product mutation preceded the final submitted design' }
    if ($null -ne $firstMutation -and $null -ne $planning -and $planning.sequence -gt $firstMutation.sequence) { $reasons += 'product mutation preceded writing-plans' }
    if ($null -eq $completion) { $reasons += 'IMPLEMENTATION_COMPLETE was not emitted' }
    if ($null -eq $verification) { $reasons += 'verification-before-completion was not read' }
    elseif ($null -ne $completion -and $verification.sequence -gt $completion.sequence) { $reasons += 'verification skill read followed completion' }
    if ($removed.Count -gt 0) { $reasons += "removed skill read: $($removed -join ', ')" }
    if ($condition -eq 'slim-requirement-loop' -and $reviewRows.Count -gt 0) { $reasons += 'requirement-only condition unexpectedly used an independent reviewer' }
    if ($condition -eq 'slim-requirement-loop' -and $reviewReady.Count -gt 0) { $reasons += 'requirement-only candidate emitted REVIEW_READY' }
    if ($condition -eq 'slim-requirement-review-loops') {
        if ($reviewReady.Count -lt 1 -or $reviewRows.Count -lt 1) { $reasons += 'review loop has no review-ready/request evidence' }
        if ($null -eq ($reviewRows | Where-Object { [string]$_.verdict -eq 'pass' } | Select-Object -Last 1)) { $reasons += 'review loop never reached REVIEW_APPROVED' }
        if ($null -ne $completion -and $null -ne ($reviewRows | Where-Object { [string]$_.verdict -eq 'pass' } | Select-Object -Last 1) -and $completion.sequence -lt $reviewReady[-1].sequence) { $reasons += 'completion ordering is inconsistent with review loop' }
    }

    $testFailures = @($started | Where-Object { $_.itemType -eq 'command_execution' -and $_.text -match '(?i)(go test|go vet|make lint|golangci)' } | Where-Object {
        $id = [string](Get-PropertyValue $_.item 'id')
        @($events | Where-Object { $_.eventType -eq 'item.completed' -and [string](Get-PropertyValue $_.item 'id') -eq $id -and [int](Get-PropertyValue $_.item 'exit_code') -ne 0 }).Count -gt 0
    })
    $debuggingStatus = if ($debugging.Count -gt 0) { 'used' } elseif ($testFailures.Count -gt 0) { 'failure-without-skill' } else { 'not-applicable' }
    return [pscustomobject][ordered]@{
        run_id = $RunId
        valid = ($reasons.Count -eq 0)
        reasons = $reasons
        warnings = $warnings
        first_action_valid = $firstActionValid
        first_action_evidence = if ($null -ne $firstAction) { $firstAction.source } else { $null }
        operator_questions = $questions.Count
        operator_answers = $answers
        design_requests = $designRequests.Count
        design_approval_rounds = $designRows.Count
        design_approved = ($null -ne $designApproved)
        review_ready = $reviewReady.Count
        review_rounds = $reviewRows.Count
        review_approved = ($null -ne ($reviewRows | Where-Object { [string]$_.verdict -eq 'pass' } | Select-Object -Last 1))
        brainstorming_evidence = if ($null -ne $brainstorm) { $brainstorm.source } else { $null }
        writing_plans_evidence = if ($null -ne $planning) { $planning.source } else { $null }
        first_product_mutation_evidence = if ($null -ne $firstMutation) { $firstMutation.source } else { $null }
        debugging_status = $debuggingStatus
        verification_evidence = if ($null -ne $verification) { $verification.source } else { $null }
        completion_evidence = if ($null -ne $completion) { $completion.source } else { $null }
        skill_reads = @($skillReads | ForEach-Object { [ordered]@{ name=$_.name; sequence=$_.sequence; source=$_.source } })
    }
}

function Invoke-SelfTest {
    $temp = Join-Path ([IO.Path]::GetTempPath()) "slim-adoption-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        @(
            '{"type":"item.started","item":{"id":"1","type":"command_execution","command":"/bin/zsh -lc ''cat \".slim-superpowers/skills/brainstorming/SKILL.md\"''"}}',
            '{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"OPERATOR_QUESTION: clarify behavior"}}',
            '{"type":"item.completed","item":{"id":"3","type":"agent_message","text":"DESIGN_REVIEW_REQUEST: behavior design"}}',
            '{"type":"item.started","item":{"id":"4","type":"command_execution","command":"/bin/zsh -lc ''cat \".slim-superpowers/skills/writing-plans/SKILL.md\"''"}}',
            '{"type":"item.started","item":{"id":"5","type":"file_change","changes":[{"path":"/tmp/repo/pkg/x.go"}]}}',
            '{"type":"item.started","item":{"id":"6","type":"command_execution","command":"/bin/zsh -lc ''cat \".slim-superpowers/skills/verification-before-completion/SKILL.md\"''"}}',
            '{"type":"item.completed","item":{"id":"7","type":"agent_message","text":"IMPLEMENTATION_COMPLETE"}}'
        ) | Set-Content -LiteralPath (Join-Path $temp 'candidate-turn-01.jsonl') -Encoding utf8NoBOM
        '{"kind":"question","question":"clarify behavior","answer":"OPERATOR_ANSWER: yes"}' | Set-Content -LiteralPath (Join-Path $temp 'operator-decisions.jsonl') -Encoding utf8NoBOM
        '{"status":"approved","candidateTurn":1}' | Set-Content -LiteralPath (Join-Path $temp 'design-decisions.jsonl') -Encoding utf8NoBOM
        '{"condition":"slim-requirement-loop"}' | Set-Content -LiteralPath (Join-Path $temp 'state.json') -Encoding utf8NoBOM
        $result = Get-AdoptionResult 'selftest' $temp
        if (-not $result.valid -or $result.operator_questions -ne 1 -or $result.debugging_status -ne 'not-applicable') { throw "Adoption happy-path self-test failed: $($result | ConvertTo-Json -Depth 6)" }
        Write-Output 'adoption self-test passed'
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$experiment = Get-Content -Raw -LiteralPath (Join-Path $Root 'experiment.json') | ConvertFrom-Json
$selectedRuns = if ($RunIds) { @($RunIds) } else { @($experiment.runIds) }
$unknownRuns = @($selectedRuns | Where-Object { [string]$_ -notin @($experiment.runIds | ForEach-Object { [string]$_ }) })
if ($unknownRuns.Count -gt 0) { throw "Unknown run ids: $($unknownRuns -join ', ')" }
$results = @($selectedRuns | ForEach-Object {
    $runId = [string]$_
    Get-AdoptionResult $runId (Join-Path $Root "runs/$runId")
})
$reports = Join-Path $Root 'reports'
New-Item -ItemType Directory -Force -Path $reports | Out-Null
$reportName = if ($RunIds) { 'adoption-probe.json' } else { 'adoption.json' }
[ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    treatment = 'slim-requirement-and-review-loops'
    runs = $results
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reports $reportName) -Encoding utf8NoBOM
if (-not $RunIds) {
    $results | Select-Object run_id,valid,operator_questions,operator_answers,debugging_status,first_action_evidence,writing_plans_evidence,verification_evidence,completion_evidence |
        Export-Csv -LiteralPath (Join-Path $reports 'adoption.csv') -NoTypeInformation -Encoding utf8NoBOM
}

foreach ($result in $results) {
    $statePath = Join-Path $Root "runs/$($result.run_id)/state.json"
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        $state.treatment | Add-Member -NotePropertyName adoptionValid -NotePropertyValue ([bool]$result.valid) -Force
        $state.treatment | Add-Member -NotePropertyName adoptionReasons -NotePropertyValue @($result.reasons) -Force
        $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
        $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Root "runs/$($result.run_id)/metadata.json") -Encoding utf8NoBOM
    }
}

$results | Format-Table run_id, valid, operator_questions, debugging_status -AutoSize
