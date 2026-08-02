## 直接答案

这套胶囊隔离两个机制增量，而不是声称复制完整 Full workflow：在相同 Slim 四技能和同一任务上，第一组把一次候选提问升级为多轮 GT 澄清直到 `DESIGN_APPROVED`；第二组再增加独立 reviewer 的多轮 `REVIEW_READY → REVIEW_CHANGES_REQUIRED → 修复 → REVIEW_READY`，直到 `REVIEW_APPROVED`。

## Frozen inputs

- task、baseline/oracle、GT contract、rubric、focused test、`gpt-5.6-terra/high`、Codex `0.145.0`、20M soft cap、120 分钟和最多 4 个 child agents 与 v9/Slim 相同；
- Slim 输入固定为 `6.1.1+codex.20260714153248`、commit `fa07307f3dbf7822fb3077587fbde649b0aa66ed`，仅暴露 brainstorming、writing-plans、systematic-debugging、verification-before-completion；
- Codex 0.145.0 不处理原生 skill item，因此项目内使用可审计的 exact shell-read adapter；这不是被动 plugin discoverability 测量；
- reviewer 不接触 hidden contract、rubric、oracle、condition、其他候选或历史分数。

## Runs and stopping

`loop-01`/`loop-02` 是 probe pair；通过认证、模型、隔离和 harness gate 后，剩余两对最多四条并发。六个 run 在 `Prepare` 时冻结为三对，每对恰有一条 requirement-only 和一条 review-loop。基础设施失败保留 invalid attempt 并用全新 home/worktree 重跑；candidate 产品或测试失败保留为实验结果。

需求 loop 没有人为轮数上限，只在 operator 明确批准或原 token/time cap 到达时结束。review loop 也没有固定一次 review；有 critical/major 就必须修复和复审，无 critical/major 才能完成。Requirement-only 不允许独立 reviewer。

## Evidence and comparison

每条 run 保存 candidate/operator/reviewer JSONL、marker、设计审批、review findings、每轮前后 diff hash、命令、测试和状态。完整 product diff 同时包含 tracked 与 scoped untracked 文件。`metrics.json/csv` 以 actor 和 token 类型保存成本；`loops-summary.json` 还保存设计问题数、审批轮数、review 轮数和 findings。

主比较是新三对的 `ΔFeedback = Requirement + Review Loops − Requirement Loop`，可做 paired 描述统计。历史 Slim、Full、Without 只作为跨批次参考；不能从它们与新组的差值宣称因果。最终五组网站顺序为 `Without → Slim → Requirement Loop → Requirement + Review Loops → Full`。

## 边界与验证

Bootstrap/Validate/Prepare/Preflight 必须全部通过才允许模型运行；精确 Codex、认证、模型或离线依赖不满足时停止。候选 homes、operator/reviewer homes、raw JSONL、state 和 condition map 只保留在 ignored capsule，不进入报告或网站。发布前必须扫描 secrets、认证文件、绝对本机路径、hidden condition 和 reviewer transcript 泄漏，并确认历史九条数据零漂移。
