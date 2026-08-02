## 直接答案

这次实验做的不是“装了 Superpowers 再看一次分数”，而是在同一项需求不完整的
GitHub CLI 任务上，冻结 baseline、oracle、公开 prompt、隐藏行为合同、rubric、
模型、effort、token/time cap 和两次盲评规则，只改变代理获得需求信息、计划和
实现反馈的方式。最终发布 5 组、15 条 canonical candidate 轨迹、30 份独立
自动盲评和 15 份 focused-test 日志。

最重要的三个判断是：

1. Full 相比 Without 的均分从 81.67 提高到 99.00，但平均资源从 2.08M token、
   8:36、32.67 次工具调用和 24.44 credits，提高到 15.87M、40:24、244 次和
   182.97 credits。质量增量存在，成本增幅更大。
2. 需求闭环是本任务最明显的质量跃迁：Slim 到 Requirement Loop 为 +14.50 分；
   再加入独立 review loop 为 +1.83 分。Full 相比该组为 -0.50 分，因此本样本不
   支持“剩余 Full 流程仍提供稳定质量增益”。前后两项涉及跨批次或 replacement，
   只能描述，不能宣称因果。
3. Full 相比 Without 新增约 13.80M token。阶段归因中协调占 37.9%，实现占
   28.6%，review 占 16.5%；actor 归因中 root 占 53.3%、child 占 42.3%。新增
   token 的 95.3% 是 cached input。它说明上下文传输非常重，但 cached input
   不能被解释成“95.3% 都是无效重复读取”。

## 场景：需求说明有目标，但没有完整规格

公开需求的中文摘要是：为 `gh project item-list` 增加可重复的 `--field <name>`
和 `--field-id <id>`，让用户在默认表格后追加所选项目字段；字段名称不区分大小写，
字段 ID 精确匹配，保持请求顺序和重复项，未知或歧义选择应给出可操作错误，并在
不选择字段时保持现有输出。

公开说明没有列全实际验收边界。冻结行为合同还要求：两种选择参数互斥；它们与
所有显式 JSON/format/jq/template 输出冲突；只有选择字段时才补取全部字段定义页；
分页失败不能打印部分表格；列值必须按字段 ID 而不是名称或位置匹配；歧义 ID 的
排序必须确定；number、date、iteration、milestone、labels、users、reviewers、
pull requests、repository 等类型各有明确显示规则；所有单元格必须去除 CR 并将
换行替换为空格。完整公开输入见[任务](../experiments/five-method/task.md)、
[行为合同](../experiments/five-method/ground-truth/contract.md)和
[rubric](../experiments/five-method/ground-truth/rubric.md)。

Without 的典型路径是搜索现有代码和测试实践，直接实现，再运行 focused test。
三条 run 平均使用 32.67 次工具调用、2.08M 去重 token 和 8:36 墙钟。它们的
focused tests 全部通过，但两位 judge 对三条 run 的 `overallValidation` 全部是
`Contradicted`；常见遗漏正是选择参数冲突、完整字段分页、确定性诊断和安全渲染。
因此原生路径能完成“看起来合理且包测试通过”的实现，却没有可靠补齐未公开规格。

Full 的路径先通过 brainstorming 与 operator 多轮补齐行为边界，形成设计、spec
和计划，再以子代理实施、测试、review、修复和 verification 完成。它的三条 run
平均 244 次工具调用、15.87M token 和 40:24；均分达到 99.00，但仍只有 3/6 judge
verdict 的 `overallValidation` 为 `Verified`，并非每条 run 都在两次评审中可靠通过。

## 五组结果

下表的 token 是从原始 rollout `last_token_usage` 重建、去掉继承 fork 前缀后的
per-run 均值；tools 包含 parent、child、guardian、operator 和 targeted reviewer
各泳道的可见调用。credits 按冻结 pricing 计算，不换算美元。

| 方法 | n / scoreN | 盲评分 | 时间 | token | tools | credits |
|---|---:|---:|---:|---:|---:|---:|
| Without | 3 / 6 | 81.67 | 8:36 | 2.08M | 32.67 | 24.44 |
| Slim | 3 / 6 | 83.17 | 9:10 | 2.27M | 34.67 | 28.65 |
| Requirement Loop | 3 / 6 | 97.67 | 11:27 | 2.87M | 37.67 | 43.49 |
| Requirement + Review Loops | 3 / 6 | 99.50 | 20:44 | 4.88M | 60.33 | 85.33 |
| Full | 3 / 6 | 99.00 | 40:24 | 15.87M | 244.00 | 182.97 |

所有数值都可由 [metrics.json](../data/metrics.json)、每条 run 的
`trajectory.json` 和两份 verdict 重建；数量与哈希由
[`audit-results.mjs`](../scripts/audit-results.mjs)验证。

## 问题一：Full 相比原生 Codex 改变了什么

Full 相比 Without：

| 指标 | Without | Full | 差值 / 倍数 |
|---|---:|---:|---:|
| 产品分 | 81.67 | 99.00 | +17.33 分 |
| 墙钟 | 8:36 | 40:24 | +31:47，4.69× |
| 去重 token | 2.08M | 15.87M | +13.80M，7.64× |
| 工具调用 | 32.67 | 244.00 | +211.33，7.47× |
| credits | 24.44 | 182.97 | +158.53，7.49× |

这说明 Full 在本任务中几乎消除了 rubric 分数缺口，但代价是约 7.5 倍 token、工具
调用和 credits，以及约 4.7 倍墙钟。不能据此说任何任务都会有相同收益，因为样本
只有一项 CLI 需求，每组三次。

“工作流走完后隐藏验收是否可靠通过”的答案是否定的。15/15 focused tests 都是
exit 0，但严格读取 judge 的 `overallValidation === Verified` 时：Without 0/6、
Slim 0/6、Requirement Loop 0/6、Review Loops 4/6、Full 3/6。两次 verdict 都
Verified 的 run，Review Loops 和 Full 都只有 1/3。这里没有独立 hidden integration
test，所以也不能把 judge 的 Verified 当成真正二元发布门；能确认的是 focused test
显著不足以替代隐藏行为合同审查。

## 问题二：需求闭环、review loop 与 Full 剩余流程

相邻阶梯的描述如下：

| 比较 | 分数 | token | 时间 | tools | credits | 证据边界 |
|---|---:|---:|---:|---:|---:|---|
| Slim → Requirement Loop | +14.50 | +0.60M | +2:17 | +3.00 | +14.85 | 跨批次描述性 |
| Requirement → Review Loops | +1.83 | +2.00M | +9:17 | +22.67 | +41.84 | 原设计同期配对；pair-01 后换为独立 rerun，canonical 整体仅描述性 |
| Review Loops → Full | -0.50 | +11.00M | +19:40 | +183.67 | +97.63 | 跨批次、复合流程描述性 |

需求闭环的运行不是固定问三次或五次，而是 candidate 提问、operator 按冻结合同
指出遗漏、candidate 修订设计，直到 `DESIGN_APPROVED`。它将未公开需求从外部
行为层注入，而不提供代码、文件路径或实现架构。在这个任务里，它以相对小的资源
增量对应最大的分数增量。

review-loop 组在同样获批设计后增加 fresh、只读 reviewer。reviewer 只能看到公开
任务、已批准设计、问答、当前 scoped diff、baseline 与测试日志；发现 critical/major
问题就要求修复并重审。它进一步逼近满分，但平均增加 2.00M token、9:17 和 41.84
credits。比如 canonical `loop-04` 第一轮指出共享字段查询行为被意外改变、分页失败和
多种值渲染缺少测试；修复后第二轮通过，证据见
[decisions.json](../results/requirement-review-loops/loop-04/decisions.json)。

Full 在均分上没有超过 review-loop 组，因此不能声称 spec commit、TDD、任务拆分、
多代理实施和多层 review 在本任务上继续带来稳定分数收益。合理结论只是：这些流程
显著增加了过程和上下文成本，在更大或更复杂任务上是否换来可靠性，需要新的同期
随机任务集验证。

## 问题三：Full 新增 token 花在哪里

Full 相比 Without 新增 13.80M token。互斥阶段分类的分布为：

| 阶段 | 新增 token | 占增量 |
|---|---:|---:|
| 协调 | 5.23M | 37.9% |
| 实现 | 3.94M | 28.6% |
| Review | 2.27M | 16.5% |
| 计划 | 0.79M | 5.7% |
| 测试 / 调试 | 0.75M | 5.4% |
| 需求 / 设计 | 0.52M | 3.8% |
| Operator | 0.18M | 1.3% |
| 探索 | 0.11M | 0.8% |

这里“协调”专指主代理派发子任务、等待子代理、follow-up、汇总结果、动作审批和
guardian 往返；不包含一般代码探索，也不把 targeted reviewer 算成协调。它是
分类器派生阶段，不代表模型内部认知状态。

按 actor 泳道看，新增 token 中 root 占 53.3%、child 占 42.3%、guardian 占
3.1%、operator 占 1.3%。按 token 构成看，cached input 占 95.3%，uncached input
占 4.2%，reasoning 和其他 output 合计不到 0.5%。证据支持的回答是：Full 增量
不是主要花在单纯写代码；最大的单项是协调，其次是实现和 review，root 与 child
共同承担绝大多数成本。cached input 很高说明长上下文被反复传输或命中缓存，但
现有日志不能逐 token 区分“重复读取”“派发上下文”“等待后的续接”和“结果汇总”，
所以不能把 cached input 直接命名为浪费。

## loop-01 replacement

Requirement + Review Loops 的 `loop-01` 原始产品 run 得分 94/93，均值 93.5。
用户批准用一次完全独立 rerun 的新产品 diff 和两份 100/100 verdict 替换 canonical
视图。两者不是同一产品 artifact，不能合并平均；原始 diff、测试、状态和 verdict
仍在 [`superseded/loop-01-original`](../superseded/loop-01-original/)，关系由
[`replacement.json`](../superseded/replacement.json)明确记录。replacement 发生后，
pair-01 不再是同期执行，所以新两组 canonical 的整体差值只作描述性汇总。

## 边界与验证

已确认事实：五组各 3 条 canonical run；每条 2 份 verdict；15 份 focused-test
日志全部 exit 0；产品 diff 与对应匿名 judge package 的 diff hash 15/15 一致；
五组分数可从 30 份 verdict 重建；状态分布是 14 completed + 1 token_cap，其中
Full `run-02` 保留 token_cap 原始状态。确定性结果见
[audit-results.json](../data/audit-results.json)。

未覆盖范围：没有人类盲评，没有独立 hidden integration test，没有多个任务或多个
模型；自动 judge 仍可能有采样偏差。Full/Without、历史 Slim 和后加 loop cohort
不是统一同期五臂随机实验；loop-01 又经过 post-hoc replacement。因此只有原始新
loop 两组的设计具有 matched-pair 基础，而 canonical replacement 后连 pair-01
也只能描述性对齐。任何“工作流导致了 X 分提升”的表述都超出证据。

平台边界：这是固定任务和模型参数的 Darwin ARM64 协议等价复现，不是 Windows
字节级复现。原始 rollout 时间与 token 是过程事实；阶段、首次 mutation、动作类别
和协调占比由公开分类规则派生。最小验证路径是运行 `node scripts/audit-results.mjs`，
再从 [`data/manifest.json`](../data/manifest.json)进入每条 state、tests、diff、trajectory
和两份 verdict。
