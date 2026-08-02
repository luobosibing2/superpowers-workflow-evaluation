$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ("sdd-summary-" + [guid]::NewGuid())
$run = Join-Path $root 'runs\run-01'
$reports = Join-Path $root 'reports'
New-Item -ItemType Directory -Force -Path $run | Out-Null
'{"pricing":"pricing.json"}' | Set-Content -LiteralPath (Join-Path $root 'experiment.json')
'{"input":2,"cachedInput":1,"output":10}' | Set-Content -LiteralPath (Join-Path $root 'pricing.json')

@'
{"type":"turn.started"}
{"type":"item.started","item":{"id":"1","type":"command_execution"}}
{"type":"item.completed","item":{"id":"1","type":"command_execution"}}
{"type":"item.completed","item":{"id":"2","type":"file_change"}}
{"type":"item.completed","item":{"id":"3","type":"agent_message","text":"OPERATOR_QUESTION: clarify\nIMPLEMENTATION_COMPLETE"}}
{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50}}
'@ | Set-Content -LiteralPath (Join-Path $run 'candidate.jsonl') -Encoding UTF8
@'
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"o1","type":"mcp_tool_call","tool":"ground_truth"}}
{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":100,"reasoning_output_tokens":25}}
'@ | Set-Content -LiteralPath (Join-Path $run 'operator.jsonl') -Encoding UTF8
'{"run_id":"run-01","condition":"with","start":"2026-07-23T00:00:00Z","end":"2026-07-23T00:02:00Z","status":"completed","exit_code":0}' |
    Set-Content -LiteralPath (Join-Path $run 'metadata.json') -Encoding UTF8
'command' | Set-Content -LiteralPath (Join-Path $run 'commands.log')
'ok' | Set-Content -LiteralPath (Join-Path $run 'tests.log')
@('diff --git a/a.go b/a.go', '--- a/a.go', '+++ b/a.go', '-old', '+new') | Set-Content -LiteralPath (Join-Path $run 'product.diff')

$timeoutRun = Join-Path $root 'runs\run-02'
$invalidRun = Join-Path $root 'runs\run-03'
New-Item -ItemType Directory -Force -Path $timeoutRun, $invalidRun | Out-Null
'{"status":"timed_out","start":"2026-07-23T00:00:00Z","end":"2026-07-23T01:00:00Z","exit_code":124}' |
    Set-Content -LiteralPath (Join-Path $timeoutRun 'metadata.json')
'{"type":"turn.started"}' | Set-Content -LiteralPath (Join-Path $invalidRun 'candidate.jsonl')
'{"status":"running"}' | Set-Content -LiteralPath (Join-Path $invalidRun 'metadata.json')

$sessionDir = Join-Path $root 'state\codex-homes\run-01\candidate\sessions\2026\07\23'
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
$sessionEvent = '{"timestamp":"2026-07-23T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":500,"output_tokens":250,"reasoning_output_tokens":60}}}}'
$sessionEvent | Set-Content -LiteralPath (Join-Path $sessionDir 'parent.jsonl')
@($sessionEvent, $sessionEvent, '{"timestamp":"2026-07-23T00:01:30Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10}}}}') |
    Set-Content -LiteralPath (Join-Path $sessionDir 'child.jsonl')
Add-Content -LiteralPath (Join-Path $sessionDir 'parent.jsonl') -Value '{"timestamp":"2026-07-23T00:01:10Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","name":"exec"}}'
Add-Content -LiteralPath (Join-Path $sessionDir 'child.jsonl') -Value '{"timestamp":"2026-07-23T00:01:10Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","name":"exec"}}'

try {
    & (Join-Path $PSScriptRoot 'summarize.ps1') -RunsPath (Join-Path $root 'runs') -ReportsPath $reports | Out-Null
    $json = Get-Content -Raw -LiteralPath (Join-Path $reports 'metrics.json') | ConvertFrom-Json
    $csv = Import-Csv -LiteralPath (Join-Path $reports 'metrics.csv')
    $first = $csv | Where-Object run_id -eq 'run-01'
    if ($json.runs.Count -ne 3 -or ($json.runs.status -join ',') -ne 'completed,timeout,invalid') { throw 'status/run count mismatch' }
    if ($json.runs[0].wall_seconds -ne 120 -or $json.runs[0].tool_calls -ne 3) { throw 'wall/tool count mismatch' }
    if ($json.runs[0].input_tokens -ne 1500 -or $json.runs[0].reasoning_tokens -ne 75) { throw 'token mismatch' }
    if ($json.runs[0].candidate_parent_reported_tokens -ne 1200 -or $json.runs[0].candidate_all_session_tokens -ne 1800) { throw 'session-tree token mismatch' }
    if ($json.runs[0].candidate_session_attribution_confidence -ne 'high') { throw 'session-tree attribution mismatch' }
    if ($json.runs[0].candidate_all_session_tool_calls -ne 1) { throw 'session-tree tool dedupe mismatch' }
    if ($json.runs[0].product_files_changed -ne 1 -or $json.runs[0].product_additions -ne 1 -or $json.runs[0].product_deletions -ne 1) { throw 'diff stats mismatch' }
    if ($json.runs[0].estimated_cost -ne 0.0073) { throw "cost mismatch: $($json.runs[0].estimated_cost)" }
    if ($json.rates_per_million.source -ne 'pricing.json') { throw 'pricing source mismatch' }
    if ($first.tool_shell_command -ne '1' -or $first.tool_apply_patch -ne '1' -or $first.tool_mcp_ground_truth -ne '1') { throw 'CSV tool columns mismatch' }
    Write-Output 'summarize self-test passed'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
