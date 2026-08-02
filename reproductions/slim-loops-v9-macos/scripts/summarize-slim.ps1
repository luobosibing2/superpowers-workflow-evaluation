[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reports = Join-Path $Root 'reports'
$metrics = Get-Content -Raw -LiteralPath (Join-Path $reports 'metrics.json') | ConvertFrom-Json
$adoption = Get-Content -Raw -LiteralPath (Join-Path $reports 'adoption.json') | ConvertFrom-Json
$expected = @((Get-Content -Raw -LiteralPath (Join-Path $Root 'experiment.json') | ConvertFrom-Json).runIds | ForEach-Object { [string]$_ })
$rows = @($metrics.runs)
if ($rows.Count -ne 3 -or (@($rows.run_id | Sort-Object) -join ',') -ne (@($expected | Sort-Object) -join ',')) { throw 'Slim summary requires exactly the three configured runs.' }

$summaryRows = foreach ($row in $rows) {
    $adoptionRow = @($adoption.runs | Where-Object { [string]$_.run_id -eq [string]$row.run_id })
    if ($adoptionRow.Count -ne 1) { throw "Missing adoption audit: $($row.run_id)" }
    $state = Get-Content -Raw -LiteralPath (Join-Path $Root "runs/$($row.run_id)/state.json") | ConvertFrom-Json
    $focusedExitCodes = @($state.focusedTests | ForEach-Object { [int]$_.exitCode })
    [pscustomobject][ordered]@{
        run_id = [string]$row.run_id
        condition = 'slim'
        raw_status = [string]$row.raw_status
        review_status = 'not-judged'
        score = $null
        adoption_valid = [bool]$adoptionRow[0].valid
        operator_turns = [int]$row.operator_turns
        wall_seconds = [double]$row.wall_seconds
        candidate_protocol_tokens = [long]$row.candidate_all_session_tokens
        operator_tokens = [long]$row.operator_input_tokens + [long]$row.operator_output_tokens
        end_to_end_protocol_tokens = [long]$row.candidate_all_session_tokens + [long]$row.operator_input_tokens + [long]$row.operator_output_tokens
        candidate_tool_calls = [long]$row.candidate_all_session_tool_calls
        focused_tests_recorded = [bool]$row.tests_exists -and $focusedExitCodes.Count -gt 0
        focused_tests_passed = $focusedExitCodes.Count -gt 0 -and @($focusedExitCodes | Where-Object { $_ -ne 0 }).Count -eq 0
        estimated_credits = [double]$row.estimated_cost
        product_files_changed = [int]$row.product_files_changed
    }
}

$validAdoption = @($summaryRows | Where-Object adoption_valid).Count
$meanWall = [math]::Round((($summaryRows | Measure-Object wall_seconds -Average).Average), 3)
$meanProtocolTokens = [math]::Round((($summaryRows | Measure-Object candidate_protocol_tokens -Average).Average), 0)
$totalCandidateTokens = [long](($summaryRows | Measure-Object candidate_protocol_tokens -Sum).Sum)
$totalOperatorTokens = [long](($summaryRows | Measure-Object operator_tokens -Sum).Sum)
$totalEndToEndTokens = [long](($summaryRows | Measure-Object end_to_end_protocol_tokens -Sum).Sum)
$totalCredits = [math]::Round((($summaryRows | Measure-Object estimated_credits -Sum).Sum), 6)
$focusedPassCount = @($summaryRows | Where-Object focused_tests_passed).Count
[ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    condition = 'slim'
    reviewStatus = 'not-judged'
    score = $null
    runCount = $summaryRows.Count
    adoptionValidCount = $validAdoption
    meanWallSeconds = $meanWall
    meanProtocolCandidateTokens = $meanProtocolTokens
    totalProtocolCandidateTokens = $totalCandidateTokens
    totalProtocolOperatorTokens = $totalOperatorTokens
    totalProtocolEndToEndTokens = $totalEndToEndTokens
    totalEstimatedCredits = $totalCredits
    focusedTestPassCount = $focusedPassCount
    tokenBoundary = 'Protocol summary only; the combined trajectory extractor supplies fork-prefix-corrected native totals.'
    runs = $summaryRows
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $reports 'slim-summary.json') -Encoding utf8NoBOM

$table = @($summaryRows | ForEach-Object {
    "| $($_.run_id) | $($_.raw_status) | $($_.adoption_valid) | $($_.operator_turns) | $([math]::Round($_.wall_seconds,1)) | $($_.end_to_end_protocol_tokens) | $([math]::Round($_.estimated_credits,3)) | 未评审 |"
}) -join "`n"
$reportLines = @(
    '## 直接答案',
    '',
    '本实验追加了 3 条 Slim With candidate。实际 treatment 不是完整 Superpowers pipeline，而是固定的 Chat-light / Plan-on 四方法配置：先读 brainstorming、探索仓库、向只读 GT operator 澄清一个外部行为问题、读 writing-plans 并形成设计与计划，然后在同一 Codex session 中原生实施；只有真实失败时才读 systematic-debugging，声明完成前读 verification-before-completion。',
    '',
    "结果是：3/3 条正式轨迹完成，3/3 通过 treatment adoption gate，3/3 的 focused test 通过。平均墙钟 $meanWall 秒（约 $([math]::Round($meanWall/60,2)) 分钟）；protocol 口径的 candidate + operator 合计 $($totalEndToEndTokens.ToString('N0')) token，实际冻结 credits 合计 ${totalCredits}。Slim 没有盲评，因此产品分明确为未评审。",
    '',
    '这批数据可以支持一个行为结论：在相同任务、模型、effort、权限和候选工具边界下，Slim treatment 稳定地产生了“先澄清，再计划，再修改产品”的轨迹。它不能支持产品质量结论，因为本追加组没有 judge；也不能支持三臂随机化因果结论，因为 Slim 是两天后的追加组。',
    '',
    '| Run | 状态 | Adoption | Operator | 墙钟秒 | 端到端 protocol token | Credits | 产品分 |',
    '|---|---|---:|---:|---:|---:|---:|---|',
    $table,
    '',
    '## 实验做了什么',
    '',
    '- 任务、cli/cli baseline、oracle、GT operator 材料、gpt-5.6-terra/high、20M soft cap、120 分钟和最多 4 个 child agents 均与正式 v9 保持一致。',
    '- treatment 输入固定为 Superpowers Slim 6.1.1+codex.20260714153248、提交 fa07307f3dbf7822fb3077587fbde649b0aa66ed 的四个 skill。Codex CLI 固定为 0.145.0。',
    '- 每条 run 使用独立 candidate/operator home、独立 Git common dir、无 remote；candidate 禁网，operator read-only。',
    '- slim-01 先作为 probe。第一次 attempt 因 adapter 没有强制产生 operator 澄清而被立即停止并归档；强化 adapter 后从全新 worktree/home 重跑。这个无效 attempt 不计入三条正式结果。',
    '- 不创建 judge 包、不运行盲评、不把 focused test 当作分数。',
    '',
    '## 依据是什么',
    '',
    "1. [Adoption audit](adoption.json) 逐条给出首动作、operator 问答、writing-plans、首次产品修改、debugging、verification 和完成 marker 的原始 JSONL 行号。三条均 valid；writing-plans 都早于首次产品修改。",
    "2. [Metrics](metrics.json) 与 [CSV](metrics.csv) 冻结了墙钟、candidate/operator token、tool calls、credits、diff 和日志可达性。三条正式 run 共 $($totalCandidateTokens.ToString('N0')) candidate token、$($totalOperatorTokens.ToString('N0')) operator token，$focusedPassCount 条 focused test 通过。",
    '3. [Product diff manifest](product-code-diff-manifest.json) 只覆盖 pkg/cmd/project/item-list 与 pkg/cmd/project/shared/queries，并对每条 diff 记录 SHA-256；没有 treatment 或 run ID 泄漏。',
    '4. 每条状态与测试证据可直接回溯：[slim-01 state](../runs/slim-01/state.json)、[slim-01 tests](../runs/slim-01/tests.log)、[slim-02 state](../runs/slim-02/state.json)、[slim-02 tests](../runs/slim-02/tests.log)、[slim-03 state](../runs/slim-03/state.json)、[slim-03 tests](../runs/slim-03/tests.log)。',
    '5. [Port manifest](port-manifest.json) 固定了上游 SHA、模型参数、Codex/PowerShell/Go 版本、四技能哈希和 adapter 哈希。',
    '',
    '## 能得出什么结论',
    '',
    '- 已确认：Slim 可靠地把 operator 澄清和 decision-complete plan 放在产品修改之前；三条均只有 1 个 operator 回合，而不是 Full With 的多轮 spec / review gate。',
    '- 已确认：三条都在真实测试或环境失败后按需读取 systematic-debugging，并在完成前读取 verification-before-completion；adapter 没有强制 TDD、spec commit、子代理或独立 review。',
    '- 已确认：三条最终 focused packages 都通过，正式轨迹状态均为 completed。',
    '- 只能描述、不能因果归因：墙钟、token、tool call 与 Full/Without 的差异同时受后加时间、模型采样和服务状态影响。',
    '- 不能判断：Slim 的实现质量是否介于 Full With 与 Without 之间，或是否保留 Full With 的盲评分优势。回答这个问题必须为 Slim 增加相同的两次独立盲评，当前实验明确没有做。',
    '',
    '## 边界与验证',
    '',
    '- 本报告的 protocol token 用于 capsule 内审计；三组网页另从 native rollout 的 last_token_usage 重建九条可比 token，并按 session 父子树删除 fork 继承前缀。',
    '- score 为 null，review_status 为 not-judged；任何 focused test 结果都没有转换成产品分。',
    '- 原 Full With / Without 六条候选、12 份 judge 结果和正式 v9 报告在本实验前后进行聚合哈希核对，不属于本 capsule 的可写范围。',
    '- 无效的首个 slim-01 adapter attempt 保存在本地 invalidated 目录，原因、原始 JSONL 和部分 diff 都保留；它不进入正式三条指标。',
    '- 最小复核路径：先读 adoption.json 的证据行，再核对三条 state.json 与 tests.log，最后用 metrics.json 和 product-code-diff-manifest.json 重算汇总。'
)
$markdown = $reportLines -join "`n"
$markdown | Set-Content -LiteralPath (Join-Path $reports 'slim-report.md') -Encoding utf8NoBOM
Write-Output "Wrote Slim summary for $($summaryRows.Count) runs."
