## 直接答案

本仓库归档了
[`cyijun/workflow-arena@c746e58`](https://github.com/cyijun/workflow-arena/tree/c746e58bf850bd9bc8326f2172383a28841b2364/reports/luna-skill-panel-v1)
发布的 Luna skill-panel v1 事实型结果表。该实验不是本仓库五方法实验的追加批次：它用
`gpt-5.6-luna` candidate 在八个任务上横向比较五种工作流，而本仓库用
`gpt-5.6-terra/high` 在一个 CLI 任务上分析 Superpowers 的机制阶梯。两套分数不能合并，也不能直接计算因果差值。

归档数据、逐文件哈希和来源边界见
[`data/luna-skill-panel-v1/`](../data/luna-skill-panel-v1/)。

## 实验回答什么

该面板比较以下五种工作流：Superpowers 6.1.1 Full、Grill Me、OpenSpec
Core、Ponytail Full 和 MatrixSpec L0。每种工作流运行八个任务，每个
workflow-task cell 有三个重复：

```text
5 workflows × 8 tasks × 3 replicates = 120 candidate runs
120 runs × 2 blind-judge scores = 240 score values
```

Candidate 模型是 `gpt-5.6-luna`，GT operator 和两次自动盲评使用
`gpt-5.6-terra`。八个任务覆盖 CLI 字段扩展、ESLint caught-error、pytest
插件入口与 `addini` 类型、bat 路径清洗、SQLModel 字段约束、Axum executor
和 Prometheus UTF-8 协商。

这个设计适合观察工作流在不同任务上的质量、完成率、精确测试和资源差异。由于面板里没有同期 Bare/Without arm，它不能回答“这些工作流相对原生 Luna 提升了多少”。

## 发布结果

下表来自
[`capability-task-score-matrix.json`](../data/luna-skill-panel-v1/capability-task-score-matrix.json)：

| 工作流 | 八任务宏均分 | Workflow completed | Focused tests passed | 平均分钟/run | 平均 candidate token/run |
|---|---:|---:|---:|---:|---:|
| Superpowers 6.1.1 Full | 89.64 | 24/24 | 21/24 | 48.38 | 32.99M |
| Grill Me | 92.14 | 24/24 | 23/24 | 18.50 | 5.85M |
| OpenSpec Core | 72.00 | 24/24 | 16/24 | 13.62 | 5.51M |
| Ponytail Full | 70.19 | 24/24 | 14/24 | 9.25 | 3.17M |
| MatrixSpec L0 | 86.71 | 11/24 | 19/24 | 41.24 | 21.05M |

120 条轨迹的终态是：107 条 `completed`、12 条 `protocol-failed`、1 条
`token-limit`；93/120 条记录的 focused-test 标志为通过。MatrixSpec 的
12 条协议失败由九次 reviewer 修改产品文件、一次 review 尝试耗尽、一次无效
stage verdict 和一次 review 前创建 full baseline 文档组成。

这些数字支持的窄结论是：在这个 Luna、八任务、小样本面板中，Grill Me 的发布宏均分和精确测试通过数最高，同时平均 candidate token 和时间明显低于 Full Superpowers；Superpowers 的 workflow 完成率稳定，但平均资源最高；MatrixSpec 的产品测试并非最差，却有明显协议完成问题。它们是描述性观察，不证明某一工作流在其他模型、任务或运行批次中普遍更好。

## 可复核内容

运行以下命令可以确定性验证导入文件及其已发布汇总：

```bash
node scripts/audit-luna-panel.mjs
```

审计会验证：

- 四个导入文件与固定提交来源哈希一致；
- 120 个唯一 task/run、五个工作流、八个任务和每 cell 三个重复；
- 每条 run 有两个分数，共 240 个 blind-judge score values；
- `107/12/1` 终态分布和 `93/120` focused-test 通过标志；
- 从逐 run 分数重建五个 workflow-task 矩阵和宏均分；
- 40 条 economics cell、candidate/operator/judge 模型和来源提交。

## 边界与验证

来源仓库在固定提交没有声明 repository license。因此这里只逐字节归档并归因公开的事实型 CSV/JSON 表，不复制来源 `report.html`、设计说明或报告表达文本，本仓库 MIT 许可证也不主张覆盖这些来源记录。

更重要的是，来源 Git 仓没有发布 raw actor sessions、逐 run 产品 diff、focused-test 日志或 240 份独立 verdict 文件。这里能验证的是每条 compact row 中的两项 judge score、测试通过标志和汇总算术，不能从公开证据独立复核 judge schema、代码改动、实际测试输出或 treatment adoption 的原始轨迹。原报告把成本称为 Terra-equivalent credits；它是代理口径，不是 Luna 的真实账单。

本次归档没有重跑 candidate、operator 或 judge，也没有改变本仓库原有 15 条 canonical run、30 份 verdict 或五方法结论。
