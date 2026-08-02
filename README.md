# Superpowers Workflow Evaluation

> **在线实验报告：** [打开五种方法、15 条轨迹的可视化网站](https://workflow-arena-trace-v9.zhangyc970514.chatgpt.site)
>
> **实验驱动的开源实现：** [`luobosibing2/superpowers-slim`](https://github.com/luobosibing2/superpowers-slim)
> 根据本仓库观察到的质量收益、token 成本和流程冗余持续优化，目标是在保留需求澄清、计划、调试、完成前验证和按需代码审查能力的同时，减少完整工作流的额外开销。
> 本实验实际测试的是四方法提交 [`fa07307f`](https://github.com/luobosibing2/superpowers-slim/commit/fa07307f3dbf7822fb3077587fbde649b0aa66ed)；后续优化版本不应被表述为已经由这 15 条轨迹直接验证。

这是一个针对编码代理工作流的证据型实验仓库。它比较同一项 GitHub CLI
需求在五种工作流下的产品质量、时间、token、工具调用和过程结构，而不是只看
“插件是否被加载”。

## 直接结论

五组自动盲评分均值为：

| 方法 | 分数 | 平均时间 | 平均去重 token | 平均工具调用 | 平均 credits |
|---|---:|---:|---:|---:|---:|
| Without | 81.67 | 8:36 | 2.08M | 32.67 | 24.44 |
| Slim | 83.17 | 9:10 | 2.27M | 34.67 | 28.65 |
| Requirement Loop | 97.67 | 11:27 | 2.87M | 37.67 | 43.49 |
| Requirement + Review Loops | 99.50 | 20:44 | 4.88M | 60.33 | 85.33 |
| Full | 99.00 | 40:24 | 15.87M | 244.00 | 182.97 |

在这个单任务、每组三次运行的样本中，最明显的质量跃迁来自把一次澄清升级为
持续到 `DESIGN_APPROVED` 的需求闭环。增加独立 review loop 后，均分再提高
1.83 分，但资源成本继续明显上升。Full 相比 review-loop 组没有更高均分，却
多使用约 11.00M token 和 19:40 墙钟时间。跨批次差值和 post-hoc replacement
不能当作因果估计；完整限定见[中文主报告](docs/report.md)。

## 实验问题

1. 完整 Superpowers 相比原生 Codex，质量与资源消耗如何变化，隐藏行为验收能否可靠通过？
2. 需求闭环和独立 review loop 分别带来多少质量与成本变化，Full 是否还有稳定增益？
3. Full 新增 token 主要花在实现、上下文传输，还是主代理与子代理的协调？

## 任务与 treatment

公开任务要求为 `gh project item-list` 增加可重复的 `--field` 与 `--field-id`
选择，并保持兼容性。公开 prompt 没有列全参数冲突、字段分页、名称歧义、按 ID
匹配、各类字段渲染和表格安全等隐藏行为边界；这些由冻结合同和 rubric 评审。

五种方法按以下阶梯比较：

```text
Without -> Slim -> Requirement Loop -> Requirement + Review Loops -> Full
```

Slim treatment 固定在
[`luobosibing2/superpowers-slim@fa07307f`](https://github.com/luobosibing2/superpowers-slim/commit/fa07307f3dbf7822fb3077587fbde649b0aa66ed)，
只含 brainstorming、writing-plans、systematic-debugging 和
verification-before-completion。当前五方法版本 `8607c8c` 新增的 `code-review`
不属于本实验已测 treatment。

## 证据入口

- [结论与边界](docs/report.md)
- [英文摘要](docs/summary.en.md)
- [canonical manifest](data/manifest.json)
- [重建指标](data/metrics.json)
- [确定性审计结果](data/audit-results.json)
- [15 条公开结果](results/)
- [loop-01 replacement 关系](superseded/replacement.json)
- [五组实验定义](experiments/five-method/README.md)
- [macOS 复现入口](run.ps1)
- [Dashboard 源码](site/)；部署版本位于 [workflow-arena-trace-v9](https://workflow-arena-trace-v9.zhangyc970514.chatgpt.site/)

运行公开数据审计：

```bash
node scripts/audit-results.mjs
```

审计锁定 15 条 canonical run、30 份 verdict、15 份 `EXIT_CODE: 0` 的
focused-test 日志、五组分数和 loop-01 replacement；同时扫描凭据、SQLite、
绝对本机路径和大文件。

## 许可证

本仓库原创框架、文档和网站使用 MIT。第三方任务、固定输入和生成的产品 diff
保留各自来源与许可证边界，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
