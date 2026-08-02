# Slim loop v9 macOS add-on

这是对已冻结 v9、Slim 和 Without 结果的追加实验，不重跑、不修改历史九条轨迹。新胶囊运行两个同期随机配对条件：

- `slim-requirement-loop`：Slim 四方法 + 多轮 GT 需求澄清/设计审批；
- `slim-requirement-review-loops`：相同需求审批 + 独立 reviewer 多轮 review/修复至无 critical/major。

每个条件 3 条 candidate，固定 3 个 matched pairs；每条 candidate 做两次新的匿名盲评，共 12 次 judge，不做人类盲评。review-loop 的 treatment token 是 candidate 与 reviewer 合计，operator 和 judge 单列。

```powershell
./run.ps1 -Action Bootstrap
./run.ps1 -Action Validate
./run.ps1 -Action Prepare
./run.ps1 -Action Preflight
./run.ps1 -Action Run
./run.ps1 -Action Judge
./run.ps1 -Action Summarize
```

`-Action All` 按同样顺序执行；`-Resume` 只续接未完成 actor 回合。运行前必须通过精确 Codex 0.145.0、认证、模型、隔离和离线 baseline gate；失败时不能静默切换模型或参数。

关键交付物：`state/condition-map.json`、`state/port-manifest.json`、`reports/metrics.json`、`reports/loops-summary.json`、`reports/loops-report.md`、每条 run 的 `design-decisions.jsonl`、`review-decisions.jsonl`、`reviews/`、完整 tracked+untracked product diff 和 focused-test log。
