[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Mean {
    param([object[]]$Values)
    if ($Values.Count -eq 0) { return 0.0 }
    return [double](($Values | Measure-Object -Average).Average)
}

function Get-ConditionMap {
    param([object]$Document)
    $map = @{}
    foreach ($entry in @($Document.runs)) {
        $map[[string]$entry.run] = [string]$entry.condition
    }
    return $map
}

$metricsPath = Join-Path $Root 'reports/metrics.json'
$blindMapPath = Join-Path $Root 'state/blind-map.json'
$conditionMapPath = Join-Path $Root 'state/condition-map.json'
$experimentPath = Join-Path $Root 'experiment.json'
foreach ($required in @($metricsPath, $blindMapPath, $conditionMapPath, $experimentPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing summary input: $required" }
}

$metrics = Get-Content -Raw -LiteralPath $metricsPath | ConvertFrom-Json
$blindMap = Get-Content -Raw -LiteralPath $blindMapPath | ConvertFrom-Json
$conditionMap = Get-ConditionMap (Get-Content -Raw -LiteralPath $conditionMapPath | ConvertFrom-Json)
$experiment = Get-Content -Raw -LiteralPath $experimentPath | ConvertFrom-Json
$metricsByRun = @{}
foreach ($run in @($metrics.runs)) { $metricsByRun[[string]$run.run_id] = $run }

$candidateRows = @()
$runScores = @{}
foreach ($entry in @($blindMap.candidates | Sort-Object candidate)) {
    $candidate = [string]$entry.candidate
    $runId = [string]$entry.run
    $scores = @()
    $verdicts = @()
    foreach ($replicate in 1,2) {
        $resultPath = Join-Path $Root ("evaluation/results/judge-{0:d2}/{1}/judge.final.json" -f $replicate, $candidate)
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Missing formal judge result: $resultPath"
        }
        $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
        if ($result.candidate -ne $candidate) { throw "Judge label mismatch for $candidate" }
        $scores += [int]$result.totalScore
        $verdicts += $result
    }
    $mean = [Math]::Round((Get-Mean $scores), 4)
    $runScores[$runId] = $mean
    $candidateRows += [pscustomobject]@{
        candidate = $candidate
        run = $runId
        condition = [string]$conditionMap[$runId]
        scores = $scores
        mean = $mean
        verdicts = $verdicts
    }
}

$anonymousSummary = [ordered]@{
    schemaVersion = 1
    status = 'macos-protocol-reproduction-condition-neutral-product-code-diff'
    judgeReplicates = 2
    humanJudge = 'not-performed'
    candidates = @($candidateRows | ForEach-Object {
        [ordered]@{ candidate = $_.candidate; scores = $_.scores; mean = $_.mean }
    })
}
$anonymousPath = Join-Path $Root 'evaluation/anonymous-summary.json'
$anonymousSummary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $anonymousPath -Encoding utf8NoBOM

$withRows = @($candidateRows | Where-Object condition -eq 'with')
$withoutRows = @($candidateRows | Where-Object condition -eq 'without')
if ($withRows.Count -ne 3 -or $withoutRows.Count -ne 3) {
    throw "Expected 3 With and 3 Without candidates; found $($withRows.Count) and $($withoutRows.Count)."
}
$withMean = [Math]::Round((Get-Mean @($withRows.mean)), 4)
$withoutMean = [Math]::Round((Get-Mean @($withoutRows.mean)), 4)
$completedWithRunIds = @($metrics.runs | Where-Object { $_.condition -eq 'with' -and $_.raw_status -eq 'completed' } | ForEach-Object { [string]$_.run_id })
$completedWithMean = [Math]::Round((Get-Mean @($withRows | Where-Object { $completedWithRunIds -contains $_.run } | ForEach-Object { $_.mean })), 4)
$completedOnlyDifference = [Math]::Round(($completedWithMean - $withoutMean), 4)
$pairedDifferences = @()
foreach ($pair in @($experiment.pairIds)) {
    $firstRun = [string]$pair[0]
    $secondRun = [string]$pair[1]
    $withRun = if ($conditionMap[$firstRun] -eq 'with') { $firstRun } else { $secondRun }
    $withoutRun = if ($conditionMap[$firstRun] -eq 'without') { $firstRun } else { $secondRun }
    $pairedDifferences += [Math]::Round(([double]$runScores[$withRun] - [double]$runScores[$withoutRun]), 4)
}

$deblindedSummary = [ordered]@{
    schemaVersion = 1
    mapping = @($candidateRows | ForEach-Object {
        [ordered]@{
            candidate = $_.candidate
            run = $_.run
            condition = $_.condition
            meanScore = $_.mean
        }
    })
    groups = [ordered]@{
        with = [ordered]@{ n = $withRows.Count; meanScore = $withMean }
        without = [ordered]@{ n = $withoutRows.Count; meanScore = $withoutMean }
        meanDifference = [Math]::Round(($withMean - $withoutMean), 4)
    }
    pairedDifferences = $pairedDifferences
}
$deblindedPath = Join-Path $Root 'evaluation/deblinded-summary.json'
$deblindedSummary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $deblindedPath -Encoding utf8NoBOM

$judgeMetadata = @(Get-ChildItem -LiteralPath (Join-Path $Root 'evaluation/results') -Filter metadata.json -File -Recurse)
$judgeTokens = 0L
$judgeInputTokens = 0L
$judgeCachedInputTokens = 0L
$judgeOutputTokens = 0L
$judgeSeconds = 0.0
foreach ($path in $judgeMetadata) {
    $metadata = Get-Content -Raw -LiteralPath $path.FullName | ConvertFrom-Json
    $judgeTokens += [long]$metadata.usage.totalTokens
    $judgeInputTokens += [long]$metadata.usage.inputTokens
    $judgeCachedInputTokens += [long]$metadata.usage.cachedInputTokens
    $judgeOutputTokens += [long]$metadata.usage.outputTokens
    $judgeSeconds += [double]$metadata.durationSeconds
}
$judgeUncachedInputTokens = [Math]::Max(0L, $judgeInputTokens - $judgeCachedInputTokens)
$judgeCredits = (
    ($judgeUncachedInputTokens * [double]$metrics.rates_per_million.input) +
    ($judgeCachedInputTokens * [double]$metrics.rates_per_million.cached_input) +
    ($judgeOutputTokens * [double]$metrics.rates_per_million.output)
) / 1000000.0
$candidateTokensTotal = [long](($metrics.runs | Measure-Object -Property candidate_all_session_tokens -Sum).Sum)
$operatorTokensTotal = [long](($metrics.runs | ForEach-Object {
    [long]$_.operator_input_tokens + [long]$_.operator_output_tokens
} | Measure-Object -Sum).Sum)
$candidateToolsTotal = [long](($metrics.runs | Measure-Object -Property candidate_all_session_tool_calls -Sum).Sum)
$candidateCreditsTotal = [double](($metrics.runs | Measure-Object -Property candidate_estimated_cost -Sum).Sum)
$operatorCreditsTotal = [double](($metrics.runs | Measure-Object -Property operator_estimated_cost -Sum).Sum)
$allTokensTotal = $candidateTokensTotal + $operatorTokensTotal + $judgeTokens
$allCreditsTotal = $candidateCreditsTotal + $operatorCreditsTotal + $judgeCredits

function Get-GroupMetrics {
    param([string]$Condition)
    $rows = @($metrics.runs | Where-Object condition -eq $Condition)
    return [ordered]@{
        wallMinutes = [Math]::Round((Get-Mean @($rows | ForEach-Object { [double]$_.wall_seconds / 60.0 })), 2)
        candidateTokens = [Math]::Round((Get-Mean @($rows | ForEach-Object { [double]$_.candidate_all_session_tokens })), 0)
        candidateTools = [Math]::Round((Get-Mean @($rows | ForEach-Object { [double]$_.candidate_all_session_tool_calls })), 1)
        candidateCredits = [Math]::Round((Get-Mean @($rows | ForEach-Object { [double]$_.candidate_estimated_cost })), 2)
        operatorCredits = [Math]::Round((Get-Mean @($rows | ForEach-Object { [double]$_.operator_estimated_cost })), 2)
        operatorTurns = [Math]::Round((Get-Mean @($rows | ForEach-Object { [double]$_.operator_turns })), 1)
    }
}

$withMetrics = Get-GroupMetrics 'with'
$withoutMetrics = Get-GroupMetrics 'without'
$wallRatio = [Math]::Round(($withMetrics.wallMinutes / $withoutMetrics.wallMinutes), 2)
$tokenRatio = [Math]::Round(($withMetrics.candidateTokens / $withoutMetrics.candidateTokens), 2)
$toolRatio = [Math]::Round(($withMetrics.candidateTools / $withoutMetrics.candidateTools), 2)
$candidateCreditRatio = [Math]::Round(($withMetrics.candidateCredits / $withoutMetrics.candidateCredits), 2)
$withTotalExecutionCredits = $withMetrics.candidateCredits + $withMetrics.operatorCredits
$withoutTotalExecutionCredits = $withoutMetrics.candidateCredits + $withoutMetrics.operatorCredits
$executionCreditRatio = [Math]::Round(($withTotalExecutionCredits / $withoutTotalExecutionCredits), 2)

$dimensionRows = @()
$dimensionNames = @($candidateRows[0].verdicts[0].dimensions | ForEach-Object { [string]$_.name })
foreach ($dimensionName in $dimensionNames) {
    $withDimensionScores = @($withRows | ForEach-Object {
        $_.verdicts | ForEach-Object {
            @($_.dimensions | Where-Object name -eq $dimensionName)[0].score
        }
    })
    $withoutDimensionScores = @($withoutRows | ForEach-Object {
        $_.verdicts | ForEach-Object {
            @($_.dimensions | Where-Object name -eq $dimensionName)[0].score
        }
    })
    $maxScore = [int]@($candidateRows[0].verdicts[0].dimensions | Where-Object name -eq $dimensionName)[0].maxScore
    $dimensionRows += [pscustomobject]@{
        name = $dimensionName
        maxScore = $maxScore
        withMean = [Math]::Round((Get-Mean $withDimensionScores), 2)
        withoutMean = [Math]::Round((Get-Mean $withoutDimensionScores), 2)
        difference = [Math]::Round(((Get-Mean $withDimensionScores) - (Get-Mean $withoutDimensionScores)), 2)
    }
}

$judgeDifferences = @($candidateRows | ForEach-Object { [Math]::Abs([double]$_.scores[0] - [double]$_.scores[1]) })
$judgeDifferenceMean = [Math]::Round((Get-Mean $judgeDifferences), 2)
$judgeDifferenceMax = [Math]::Round((($judgeDifferences | Measure-Object -Maximum).Maximum), 2)

$pairRows = @()
foreach ($pair in @($experiment.pairIds)) {
    $firstRun = [string]$pair[0]
    $secondRun = [string]$pair[1]
    $withRunId = if ($conditionMap[$firstRun] -eq 'with') { $firstRun } else { $secondRun }
    $withoutRunId = if ($conditionMap[$firstRun] -eq 'without') { $firstRun } else { $secondRun }
    $withRunMetric = @($metrics.runs | Where-Object run_id -eq $withRunId)[0]
    $withoutRunMetric = @($metrics.runs | Where-Object run_id -eq $withoutRunId)[0]
    $pairRows += [pscustomobject]@{
        withRun = $withRunId
        withoutRun = $withoutRunId
        withScore = [double]$runScores[$withRunId]
        withoutScore = [double]$runScores[$withoutRunId]
        difference = [Math]::Round(([double]$runScores[$withRunId] - [double]$runScores[$withoutRunId]), 2)
        withMinutes = [Math]::Round(([double]$withRunMetric.wall_seconds / 60.0), 2)
        withoutMinutes = [Math]::Round(([double]$withoutRunMetric.wall_seconds / 60.0), 2)
        withTokens = [long]$withRunMetric.candidate_all_session_tokens
        withoutTokens = [long]$withoutRunMetric.candidate_all_session_tokens
        withTools = [long]$withRunMetric.candidate_all_session_tool_calls
        withoutTools = [long]$withoutRunMetric.candidate_all_session_tool_calls
        withOperatorTurns = [int]$withRunMetric.operator_turns
        withoutOperatorTurns = [int]$withoutRunMetric.operator_turns
    }
}

function Get-GapLabels {
    param([object[]]$Verdicts)
    $gapText = (@($Verdicts | ForEach-Object { @($_.criticalGaps) }) -join ' ').ToLowerInvariant()
    $labels = [Collections.Generic.List[string]]::new()
    if ($gapText -match 'mutual|combined|format conflict|formatted output|json output') { $labels.Add('flag 冲突校验') }
    if ($gapText -match 'paginat|first page|field page') { $labels.Add('多页字段定义') }
    if ($gapText -match 'carriage|cr character|cr/lf|multiline|newline') { $labels.Add('CR/LF 规范化') }
    if ($gapText -match 'help.*example|repeated.*example') { $labels.Add('帮助示例') }
    if ($gapText -match 'ambig.*sort|deterministic.*order|stable.*order') { $labels.Add('歧义候选排序') }
    if ($labels.Count -eq 0) { return '无' }
    return ($labels -join '、')
}

function Add-ReportLines {
    param([Collections.Generic.List[string]]$Target, [string[]]$Lines)
    foreach ($line in $Lines) { $Target.Add($line) }
}

$reportLines = [Collections.Generic.List[string]]::new()
Add-ReportLines $reportLines @(
    '# Workflow Arena forced-bootstrap v9：macOS 协议复现报告',
    '',
    '## 直接答案',
    '',
    '这次做的不是“装上插件跑一下”的演示，而是一个 **3 对随机配对、单任务、条件盲化评分** 的受控复现。实验问题是：在固定代码基线、任务、模型、推理强度、权限、停止规则和评分标准时，强制向 Codex 送达并要求执行完整 Superpowers 工作流，能否让最终产品更完整地满足隐藏行为契约。',
    '',
    ("结果是：Treatment（With）平均盲评分 **{0:N2}**，Control（Without）为 **{1:N2}**，本样本平均差 **+{2:N2} 分**；三对差值分别为 **{3}**，方向全部一致。" -f
        $withMean, $withoutMean, ($withMean - $withoutMean), (($pairedDifferences | ForEach-Object { '+{0:N1}' -f $_ }) -join '、')),
    '',
    '这个差值主要不是来自基本表格输出——两组在“端到端表格行为”上都拿到 15/15——而是来自 Control 反复遗漏的隐藏边界：字段定义分页、flag 冲突、名称歧义诊断、CR/LF 规范化和错误安全。其中“查询路径与分页”一项的组间差最大，为 **+7.00/15**。六条 focused tests 全部通过，说明仅看测试绿灯会掩盖这些契约缺口。',
    '',
    ("但 Treatment 的代价也很高：平均活动墙钟时间是 Control 的 **{0:N2} 倍**，candidate token **{1:N2} 倍**，工具调用 **{2:N2} 倍**，candidate credits **{3:N2} 倍**；把 operator 也计入执行成本后是 **{4:N2} 倍**。所以本实验支持的是「在这个固定任务上，以显著更多资源换取更完整实现」，不支持「Superpowers 普遍、更快或更便宜」这种说法。" -f
        $wallRatio, $tokenRatio, $toolRatio, $candidateCreditRatio, $executionCreditRatio),
    '',
    '## 实验问题与估计对象',
    '',
    '实验的估计对象是 **被随机分配到 forced-bootstrap Superpowers 工作流包的总效果**，不是插件安装本身，也不是 brainstorming、planning、TDD、review 或 verification 任一单项技能的独立效果。主分析按冻结 condition 保留 run-02，因此更接近 assignment / intention-to-treat 的样本比较，而不是只挑“完美遵循流程”的轨迹。',
    '',
    '- **固定不变：** `cli/cli` baseline 与 oracle、同一用户任务、`gpt-5.6-terra/high`、最多 4 个子代理、禁网候选环境、GT operator 规则、20M soft cap、120 分钟、rubric 和停止规则。',
    '- **Treatment：** 固定版本 Superpowers 的项目内 skill 文件，加 developer bootstrap；第一步强制读取 brainstorming，并要求形成设计、计划、TDD、任务/分支 review 和最终验证证据。',
    '- **Control：** 收到相同任务、基线、模型和一般工具能力，但看不到 Superpowers、项目内 skill 或 bootstrap。',
    '',
    '因此，报告中的分差应读作：**被分配并送达这套复合工作流后，在本任务、本模型采样和本次服务状态下观察到的样本内产品分差。** Treatment 的实际依从性并不完美，尤其 run-02 没有完成标记和最终 verification skill read；这在主结果中保留，而不是事后剔除。',
    '',
    '真相源：[实验配置](../experiment.json)、[协议](../protocol.md)、[Treatment bootstrap](../state/treatment-bootstrap.md)、[端口清单](port-manifest.json)。',
    '',
    '## 固定任务与隐藏行为契约',
    '',
    '候选要修改 GitHub CLI 的 `gh project item-list`，增加可重复的 `--field` / `--field-id` 列，同时保持原有输出兼容。公开任务故意没有展开全部边界；盲评依据的隐藏契约还要求：',
    '',
    '- 两类 flag 及格式化输出冲突要给出明确错误；',
    '- 名称解析大小写不敏感，歧义候选和 ID 要稳定、可行动地呈现；',
    '- 只有需要时才翻取后续字段定义页，但需要时必须拿全；',
    '- 表格必须按字段 ID 对齐，缺失值留空，并正确渲染多种 project field 类型；',
    '- 多行文本要遵守 CR/LF 规范化，解析或分页失败不能输出误导性部分结果。',
    '',
    '100 分 rubric 分成 CLI 15、解析 15、查询/分页 15、渲染 25、端到端表格 15、安全/可维护性 15。测试日志只影响验证置信度，不直接加分。详见 [任务](../task.md)、[隐藏契约](../ground-truth/contract.md) 和 [评分规则](../ground-truth/rubric.md)。',
    '',
    '## 随机配对、probe gate 与隔离',
    '',
    '六条候选轨迹组成三对：01/02、03/04、05/06。每对用安全随机数冻结为一个 With、一个 Without；实际映射是 01 Without / 02 With、03 With / 04 Without、05 Without / 06 With。Pair 1 先作为执行器 probe；隔离和 harness 通过后，它保留为正式样本，再并发启动后两对。它不是额外 pilot，也没有被排除。',
    '',
    '每条候选使用独立 actor home、独立 Git common directory、无 remote 的单 synthetic-commit 仓库。匿名评审包只包含任务、隐藏契约、rubric、限定目录的产品 diff、测试日志和必要 baseline 上下文，不包含 condition、trajectory、设计文档、operator 记录或 run ID。',
    '',
    '## GT operator 与信息路径',
    '',
    '两组都被允许向同一个 GT operator 询问行为要求。Operator 可读隐藏契约和 oracle，但只能回答“产品应如何表现”，不能透露实现。实际 Treatment 三条轨迹分别发生 **11、7、3** 个 operator turn；Control 三条均为 **0**。',
    '',
    '这意味着组间能力政策相同，但实际获得的信息量并不相同：强制设计与审批流程诱发了更多澄清。因而 +17.33 分包含“工作流促使候选主动发现需求”的中介效果，不能改写成“双方已经掌握完全相同信息后，插件单独改善了编码推理”。Operator 边界见 [operator guide](../ground-truth/operator-guide.md)。',
    '',
    '## 产品结果与依据',
    '',
    '| Run | Condition | Stop | 两次盲评分 | 均分 | Operator turns | Focused test | 评审识别的主要缺口 |',
    '|---|---|---|---:|---:|---:|---|---|'
)
foreach ($run in @($metrics.runs | Sort-Object run_id)) {
    $candidate = $candidateRows | Where-Object run -eq $run.run_id
    $testLog = Join-Path $Root "runs/$($run.run_id)/tests.log"
    $testStatus = if ((Get-Content -Raw -LiteralPath $testLog) -match 'EXIT_CODE:\s*0') { 'pass' } else { 'fail' }
    $scoreText = ($candidate.scores -join ' / ')
    $gapLabels = Get-GapLabels @($candidate.verdicts)
    $reportLines.Add(("| [{0}](../runs/{0}/state.json) | {1} | {2} | {3} | {4:N1} | {5} | [{6}](../runs/{0}/tests.log) | {7} |" -f
        $run.run_id, $run.condition, $run.raw_status, $scoreText, $candidate.mean, $run.operator_turns, $testStatus, $gapLabels))
}
Add-ReportLines $reportLines @(
    '',
    '三对不是只有组均值同向，而是每一对都同向：',
    '',
    '| With / Without | 分数 | 配对差 | 墙钟分钟 | Candidate tokens | Tool calls | Operator turns |',
    '|---|---:|---:|---:|---:|---:|---:|'
)
foreach ($pairRow in $pairRows) {
    $reportLines.Add(("| {0} / {1} | {2:N1} / {3:N1} | +{4:N1} | {5:N2} / {6:N2} | {7:N0} / {8:N0} | {9} / {10} | {11} / {12} |" -f
        $pairRow.withRun, $pairRow.withoutRun, $pairRow.withScore, $pairRow.withoutScore, $pairRow.difference,
        $pairRow.withMinutes, $pairRow.withoutMinutes, $pairRow.withTokens, $pairRow.withoutTokens,
        $pairRow.withTools, $pairRow.withoutTools, $pairRow.withOperatorTurns, $pairRow.withoutOperatorTurns))
}
Add-ReportLines $reportLines @(
    '',
    '按 rubric 维度汇总 12 份 verdict 后，分差的位置更清楚：',
    '',
    '| Rubric 维度 | 满分 | With 均分 | Without 均分 | 差值 |',
    '|---|---:|---:|---:|---:|'
)
foreach ($dimensionRow in $dimensionRows) {
    $reportLines.Add(("| {0} | {1} | {2:N2} | {3:N2} | {4:+0.00;-0.00;0.00} |" -f
        $dimensionRow.name, $dimensionRow.maxScore, $dimensionRow.withMean, $dimensionRow.withoutMean, $dimensionRow.difference))
}
Add-ReportLines $reportLines @(
    '',
    '最强证据不是单个高分，而是三层证据互相吻合：',
    '',
    '1. **配对结果：** 三对分别 +18.0、+16.5、+17.5，没有某一对单独驱动结论。',
    '2. **缺口模式：** 三条 Control 都被评审指出字段定义分页、flag 冲突或 CR/LF 等隐藏边界；Treatment 的剩余扣分只集中在帮助示例和一条 CR 处理细节。',
    '3. **轨迹机制：** Treatment 留下 design/plan、技能读取、review 与 operator 记录；例如 run-06 的 review 发现了 exported client signature 兼容性和完整首字段页后的分页缺陷，并在最终 diff 前修正。',
    '',
    'run-02 是重要的反例边界：它在冻结 token cap 处停止，`implementation_complete=false`，没有输出协议要求的精确完成标记，轨迹中也没有读到 mandatory `verification-before-completion/SKILL.md`；但当时产品 diff 仍被两位盲评各打 100。这里必须把“现有产品质量”“流程依从性”和“资源是否触顶”分开报告，不能用 100 分掩盖停止状态。',
    '',
    ("作为敏感性分析，如果排除 run-02，只比较两条 completed Treatment 与三条 Control，Treatment 均分为 **{0:N2}**，样本差仍为 **+{1:N2}**；但这会破坏原始 3 对完整配对，只能说明主结果不是完全由 run-02 的 100 分造成，不能替代预注册主分析。" -f $completedWithMean, $completedOnlyDifference),
    '',
    '## 盲评可靠性',
    '',
    ("每位匿名候选由两个全新、plugin-free、read-only 的 `gpt-5.6-terra/high` session 评分，共 12 次。每个候选的产品分取两次均值。两次评分的绝对差平均为 **{0:N2}** 分，最大 **{1:N0}** 分；With 的三条均完全一致，Without 的分歧为 3–7 分。" -f $judgeDifferenceMean, $judgeDifferenceMax),
    '',
    '这说明自动 rubric 在本批材料上有一定重复性，但不是语义完全一致：Candidate-B 两份 verdict 都是 99 分且指出同一帮助缺口，`overallValidation` 却分别为 Contradicted 和 Verified。两个 session 还共享同一模型家族、prompt、rubric 和材料，不能视为两个独立外部评审群体，更不能替代未执行的人类盲评。评分包和汇总见 [匿名汇总](../evaluation/anonymous-summary.json)、[deblinded 汇总](../evaluation/deblinded-summary.json) 及 [judge schema](../evaluation/judge-output.schema.json)。',
    '',
    '## 资源成本与质量—成本权衡',
    '',
    '| Condition | n | 盲评分 | 活动墙钟/条 | Candidate tokens/条 | Tools/条 | Candidate credits/条 | Operator credits/条 |',
    '|---|---:|---:|---:|---:|---:|---:|---:|',
    ("| With | 3 | {0:N2} | {1:N2} min | {2:N0} | {3:N1} | {4:N2} | {5:N2} |" -f $withMean, $withMetrics.wallMinutes, $withMetrics.candidateTokens, $withMetrics.candidateTools, $withMetrics.candidateCredits, $withMetrics.operatorCredits),
    ("| Without | 3 | {0:N2} | {1:N2} min | {2:N0} | {3:N1} | {4:N2} | {5:N2} |" -f $withoutMean, $withoutMetrics.wallMinutes, $withoutMetrics.candidateTokens, $withoutMetrics.candidateTools, $withoutMetrics.candidateCredits, $withoutMetrics.operatorCredits),
    '',
    ("全流程重建的归因消耗为 **{0:N0} tokens**，按冻结费率估算为 **{1:N2} credits**：candidate {2:N2}、operator {3:N2}、judge {4:N2} credits；candidate tool calls 合计 {5:N0}。12 次 judge 另归因 {6:N0} tokens / {7:N2} estimated credits，模型活动时间合计 {8:N2} 分钟。这些 credits 是协议费率估算，不是账户账单。" -f
        $allTokensTotal, $allCreditsTotal, $candidateCreditsTotal, $operatorCreditsTotal, $judgeCredits, $candidateToolsTotal,
        $judgeTokens, $judgeCredits, ($judgeSeconds / 60.0)),
    '',
    '因此这不是效率实验的胜利：Treatment 的质量更高，但用时、token、工具调用和 credits 都明显更高。实验没有提供美元换算，也没有证明这些额外成本在别的任务上仍然值得。',
    '',
    '## 与 Windows 正式 v9 的对照',
    '',
    '已发布 Windows v9 的结果是 With 100.00、Without 79.67，样本差 +20.33；本次 macOS 复现是 99.00、81.67，差 +17.33。方向一致，Treatment 也同样表现出更高成本。',
    '',
    '这可以称为一次**方向一致的描述性复现**：任务、冻结输入、模型 slug、effort、配对和评分规则相同，而主机、shell/process adapter、模型采样和当时服务状态不同。不能称为 Windows 字节级复现，也不能因为两个差值接近就断言存在稳定的 17–20 分总体效应。历史基线见 [Windows v9 final report](../../../campaigns/forced-bootstrap-v9/reports/final-report.md)。',
    '',
    '## 预注册与实际执行差异',
    '',
    '以下偏差不改变两组的对称性，但会影响复现解释，必须公开：',
    '',
    '1. `experiment.json` 与 protocol 顶部修订规定 20M / 120 分钟；protocol 后半仍残留 300k / 60 分钟旧文案。实际执行状态使用前者，本报告以 `experiment.json` 和 run state 为权威源。',
    '2. protocol 写 candidate approval policy 为 `never`；实际为支持多代理使用了 `on-request + auto_review`。两组一致，因此不是明显组间混杂，但属于实现偏差。',
    '3. 原协议设想人类 + Codex 盲评；本次按用户选择没有人类评审，而是每位候选两次新 Codex session。',
    '4. Treatment 的原生 skill catalog 因 CLI 兼容路径被禁用；实际生效的是 developer bootstrap 加项目内 skill 文件的 shell 读取。',
    '5. macOS adapter 使用 POSIX 路径、Darwin ARM64 可执行文件与 `/bin/zsh -lc`，属于协议语义移植，不是 Windows 运行时逐字节复现。',
    '',
    '## 证据索引',
    '',
    '- [metrics.json](metrics.json) / [metrics.csv](metrics.csv)：每条 run 的停止状态、token、时间、工具和 credits；报告所有资源数字由此重建。',
    '- [condition map](../state/condition-map.json) / [blind map](../state/blind-map.json)：冻结分组和匿名标签；用于证明评分时 condition 与产品包分离。',
    '- [product-code diff manifest](product-code-diff-manifest.json)：评分 diff 只覆盖产品目录，并记录哈希。',
    '- [run state 与 tests](../runs/run-01/state.json)：每条轨迹的状态、命令、产品 diff 和 focused-test 日志；上方运行表提供六条直接链接。',
    '- [12 份 judge 结果](../evaluation/results)：逐维分数、理由、证据和 critical gaps；匿名/去盲汇总可从它们重建。',
    '- [port manifest](port-manifest.json) / [preflight](../state/preflight.json)：版本 pin、主机适配、隔离和离线基线检查。',
    '',
    '## 边界与验证',
    '',
    '- **已确认：** 3 个 With 与 3 个 Without 的正式产品轨迹；三对分差同向；每位候选两份 schema-valid 自动盲评；六条 focused tests 均有 `EXIT_CODE: 0`；评分产品 diff 无 condition 字段。',
    '- **统计边界：** 实验单位仍是同一任务上的三个随机化区组。三对全正的最简单精确符号翻转检验，单侧最小 p=0.125、双侧 p=0.25，不能宣称传统意义上的统计显著。',
    '- **停止与依从性边界：** run-02 在 turn boundary 触发 soft cap；父计数器为 31,552,656，去重后的 all-session 归因是 18,153,178。它没有完成标记或 mandatory final-verification skill read，仍按冻结规则作为 capped product result 接受盲评，没有因产品状态重跑。',
    '- **尝试边界：** 正式运行前有一次 pair-1 launcher 中断，零完成 turn，保留在 `invalidated/`；之后在相同冻结 condition 下用全新 worktree/home 重备。',
    '- **评审边界：** 没有人类盲评；两位自动 judge 与 candidate 同模型家族，不能排除共同模型偏差或 rubric ceiling。',
    '- **平台边界：** macOS ARM64 的路径、进程和 shell 适配与 Windows 不同；托管模型和服务行为即使 slug 不变也可能随时间变化。',
    '- **验证边界：** focused tests 全过但无法覆盖完整隐藏契约；run-03/run-04 的 Go 回执为 cached，候选内部更广检查不一致，离线 capsule 没有 `golangci-lint`，也没有为无关 Scope All 自测获取额外 baseline。',
    '- **结论边界：** 可以说 forced-bootstrap 工作流分配在这一个 Go CLI 任务的本次样本中对应更高的隐藏契约覆盖，同时显著增加成本；不能推广到所有任务、语言、模型，也不能把效果拆给某个 skill、插件安装或纯粹的编码推理。'
)

$reportPath = Join-Path $Root 'reports/reproduction-report.md'
$reportLines | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
$scanPaths = @(
    Get-ChildItem -LiteralPath (Join-Path $Root 'reports') -File -Recurse
    Get-Item -LiteralPath $anonymousPath
    Get-Item -LiteralPath $deblindedPath
)
foreach ($scanPath in $scanPaths) {
    $scanText = Get-Content -Raw -LiteralPath $scanPath.FullName
    if ($scanText -match '/Users/' -or $scanText -match '/private/var/' -or
        $scanText -match '(?i)[A-Z]:\\Users\\|auth\.json|api[_-]?key|secret[_-]?key') {
        throw "Sensitive or machine-specific content leaked into $($scanPath.FullName)"
    }
}

Write-Output "Wrote formal reproduction summaries and report: $reportPath"
