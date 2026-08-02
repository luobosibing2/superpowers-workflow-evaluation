#!/usr/bin/env python3
import argparse
import json
from datetime import datetime
from pathlib import Path
from statistics import mean


def load(path: Path):
    return json.loads(path.read_text())


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def round4(value: float) -> float:
    return round(value, 4)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    reports = root / "reports"
    evaluation = root / "evaluation"
    metrics = load(reports / "metrics.json")
    adoption = load(reports / "adoption.json")
    blind_map = load(root / "state/blind-map.json")
    audit = load(evaluation / "judge-audit.json")
    if audit.get("status") != "passed" or audit.get("judgeSessions") != 6:
        raise SystemExit("judge audit must pass before summarization")

    metrics_by_run = {row["run_id"]: row for row in metrics["runs"]}
    adoption_by_run = {row["run_id"]: row for row in adoption["runs"]}
    candidate_rows = []
    dimension_scores = {}
    for entry in sorted(blind_map["candidates"], key=lambda row: row["candidate"]):
        candidate = entry["candidate"]
        run_id = entry["run"]
        verdicts = [
            load(evaluation / "results" / f"judge-{replicate:02d}" / candidate / "judge.final.json")
            for replicate in (1, 2)
        ]
        scores = [verdict["totalScore"] for verdict in verdicts]
        for verdict in verdicts:
            for dimension in verdict["dimensions"]:
                dimension_scores.setdefault(dimension["name"], {"maxScore": dimension["maxScore"], "scores": []})["scores"].append(dimension["score"])
        candidate_rows.append(
            {
                "candidate": candidate,
                "run": run_id,
                "condition": "slim",
                "scores": scores,
                "meanScore": round4(mean(scores)),
                "verdicts": verdicts,
            }
        )

    group_mean = round4(mean(row["meanScore"] for row in candidate_rows))
    anonymous = {
        "schemaVersion": 1,
        "status": "supplemental-posthoc-condition-hidden-product-code-diff",
        "judgeReplicates": 2,
        "humanJudge": "not-performed",
        "candidates": [
            {"candidate": row["candidate"], "scores": row["scores"], "mean": row["meanScore"]}
            for row in candidate_rows
        ],
    }
    write_json(evaluation / "anonymous-summary.json", anonymous)

    historical = load(root.parent / "forced-bootstrap-v9-macos" / "evaluation/deblinded-summary.json")["groups"]
    full_mean = historical["with"]["meanScore"]
    without_mean = historical["without"]["meanScore"]
    deblinded = {
        "schemaVersion": 1,
        "status": "supplemental-posthoc-deblinded",
        "mapping": [
            {
                "candidate": row["candidate"],
                "run": row["run"],
                "condition": "slim",
                "scores": row["scores"],
                "meanScore": row["meanScore"],
            }
            for row in candidate_rows
        ],
        "groups": {
            "slim": {"n": 3, "meanScore": group_mean},
            "historicalFullWith": {"n": 3, "meanScore": full_mean},
            "historicalWithout": {"n": 3, "meanScore": without_mean},
            "descriptiveSlimMinusFull": round4(group_mean - full_mean),
            "descriptiveSlimMinusWithout": round4(group_mean - without_mean),
        },
        "pairedEffect": None,
        "pairedEffectReason": "Slim is a later, non-contemporaneous add-on and was not randomized as a third arm.",
    }
    write_json(evaluation / "deblinded-summary.json", deblinded)

    metadata_rows = []
    for replicate in (1, 2):
        for candidate in sorted(row["candidate"] for row in candidate_rows):
            metadata_rows.append(load(evaluation / "results" / f"judge-{replicate:02d}" / candidate / "metadata.json"))
    judge_input = sum(row["usage"]["inputTokens"] for row in metadata_rows)
    judge_cached = sum(row["usage"]["cachedInputTokens"] for row in metadata_rows)
    judge_output = sum(row["usage"]["outputTokens"] for row in metadata_rows)
    judge_tokens = sum(row["usage"]["totalTokens"] for row in metadata_rows)
    judge_duration_sum = round(sum(row["durationSeconds"] for row in metadata_rows), 3)
    first_start = min(datetime.fromisoformat(row["startedAtUtc"].replace("Z", "+00:00")) for row in metadata_rows)
    last_end = max(datetime.fromisoformat(row["endedAtUtc"].replace("Z", "+00:00")) for row in metadata_rows)
    judge_elapsed = round((last_end - first_start).total_seconds(), 3)
    rates = metrics["rates_per_million"]
    judge_credits = round(
        ((judge_input - judge_cached) * rates["input"] + judge_cached * rates["cached_input"] + judge_output * rates["output"]) / 1_000_000,
        6,
    )
    judge_summary = {
        "schemaVersion": 1,
        "status": "complete",
        "model": "gpt-5.6-terra",
        "reasoningEffort": "high",
        "codexVersion": "0.145.0",
        "judgeSessions": 6,
        "judgeReplicatesPerRun": 2,
        "humanJudge": "not-performed",
        "inputTokens": judge_input,
        "cachedInputTokens": judge_cached,
        "uncachedInputTokens": judge_input - judge_cached,
        "outputTokens": judge_output,
        "totalTokens": judge_tokens,
        "summedSessionSeconds": judge_duration_sum,
        "elapsedSeconds": judge_elapsed,
        "estimatedCredits": judge_credits,
        "audit": "judge-audit.json",
    }
    write_json(evaluation / "judge-summary.json", judge_summary)

    candidate_only_runs = []
    current_runs = []
    scores_by_run = {row["run"]: row for row in candidate_rows}
    for run_id in sorted(metrics_by_run):
        metric = metrics_by_run[run_id]
        adoption_row = adoption_by_run[run_id]
        state = load(root / "runs" / run_id / "state.json")
        focused_codes = [row["exitCode"] for row in state.get("focusedTests", [])]
        base = {
            "run_id": run_id,
            "condition": "slim",
            "raw_status": metric["raw_status"],
            "adoption_valid": adoption_row["valid"],
            "operator_turns": metric["operator_turns"],
            "wall_seconds": metric["wall_seconds"],
            "candidate_protocol_tokens": metric["candidate_all_session_tokens"],
            "operator_tokens": metric["operator_input_tokens"] + metric["operator_output_tokens"],
            "end_to_end_protocol_tokens": metric["candidate_all_session_tokens"] + metric["operator_input_tokens"] + metric["operator_output_tokens"],
            "candidate_tool_calls": metric["candidate_all_session_tool_calls"],
            "focused_tests_recorded": bool(metric["tests_exists"] and focused_codes),
            "focused_tests_passed": bool(focused_codes and all(code == 0 for code in focused_codes)),
            "estimated_credits": metric["estimated_cost"],
            "product_files_changed": metric["product_files_changed"],
        }
        candidate_only_runs.append({**base, "review_status": "not-judged-at-candidate-freeze", "score": None})
        score_row = scores_by_run[run_id]
        current_runs.append(
            {
                **base,
                "review_status": "supplemental-posthoc-blind-judged",
                "judge_scores": score_row["scores"],
                "score": score_row["meanScore"],
            }
        )

    execution_candidate_tokens = sum(row["candidate_protocol_tokens"] for row in current_runs)
    execution_operator_tokens = sum(row["operator_tokens"] for row in current_runs)
    execution_tokens = execution_candidate_tokens + execution_operator_tokens
    execution_credits = round(sum(row["estimated_credits"] for row in current_runs), 6)
    common = {
        "schemaVersion": 2,
        "condition": "slim",
        "runCount": 3,
        "adoptionValidCount": sum(row["adoption_valid"] for row in current_runs),
        "meanWallSeconds": round(mean(row["wall_seconds"] for row in current_runs), 3),
        "meanProtocolCandidateTokens": round(mean(row["candidate_protocol_tokens"] for row in current_runs)),
        "totalProtocolCandidateTokens": execution_candidate_tokens,
        "totalProtocolOperatorTokens": execution_operator_tokens,
        "totalProtocolEndToEndTokens": execution_tokens,
        "totalEstimatedExecutionCredits": execution_credits,
        "focusedTestPassCount": sum(row["focused_tests_passed"] for row in current_runs),
        "tokenBoundary": "Protocol summary only; the combined trajectory extractor supplies fork-prefix-corrected native execution totals.",
    }
    candidate_only = {
        **common,
        "snapshot": "candidate-stage-before-judge-amendment",
        "reviewStatus": "not-judged-at-candidate-freeze",
        "score": None,
        "runs": candidate_only_runs,
    }
    write_json(reports / "candidate-only-summary.json", candidate_only)
    slim_summary = {
        **common,
        "reviewStatus": "supplemental-posthoc-blind-judged",
        "score": group_mean,
        "historicalReference": {
            "fullWith": full_mean,
            "without": without_mean,
            "slimMinusFull": round4(group_mean - full_mean),
            "slimMinusWithout": round4(group_mean - without_mean),
            "comparison": "descriptive-only",
        },
        "judge": judge_summary,
        "allInProtocolTokens": execution_tokens + judge_tokens,
        "allInEstimatedCredits": round(execution_credits + judge_credits, 6),
        "runs": current_runs,
    }
    write_json(reports / "slim-summary.json", slim_summary)

    run_rows = "\n".join(
        f"| {row['run_id']} | {row['judge_scores'][0]} | {row['judge_scores'][1]} | {row['score']:.1f} | {row['wall_seconds']:.1f} | {row['end_to_end_protocol_tokens']:,} | {row['estimated_credits']:.3f} |"
        for row in current_runs
    )
    dimensions = [
        {
            "name": name,
            "max": value["maxScore"],
            "mean": round4(mean(value["scores"])),
        }
        for name, value in dimension_scores.items()
    ]
    dimension_rows = "\n".join(f"| {row['name']} | {row['mean']:.2f} / {row['max']} |" for row in dimensions)
    report = f"""## 直接答案

这次补评给三条 Slim With 候选各运行了两次新的匿名 Codex judge，共 6 次。Slim 的产品均分是 **{group_mean:.2f}/100**：`slim-01` 为 84.0，`slim-02` 为 79.0，`slim-03` 为 86.5。相同 rubric 下，历史 Full With 是 99.00，历史 Without 是 81.67；因此 Slim 比历史 Without 高 **{group_mean - without_mean:+.2f}**，比历史 Full With 低 **{group_mean - full_mean:+.2f}**。

最重要的结论不是“Slim 明显胜过 Without”，而是：**Slim 在这三条后续样本里的平均质量与历史 Without 接近，远低于 Full With；它用接近 Without 的时间和 token 成本，没有保留 Full With 在正式 v9 中的高分优势。** 这个比较是描述性的，不是三臂随机因果实验：Slim 晚两天运行，judge 也是候选冻结后追加的后补评审。

| Run | Judge 1 | Judge 2 | 均分 | 候选墙钟秒 | Candidate + operator token | 执行 Credits |
|---|---:|---:|---:|---:|---:|---:|
{run_rows}

## 实验到底做了什么

候选阶段保持原 v9 的任务、baseline、oracle、GT operator、`gpt-5.6-terra/high`、20M soft cap、120 分钟和最多 4 个 child agents。第三组 treatment 是本机 Superpowers Slim 的四方法配置：先 brainstorming 和一次需求澄清，再 writing-plans，然后由同一 Codex session 原生实施；遇到真实失败才 systematic-debugging，完成前 verification-before-completion。它不是纯 brainstorming 单项消融，也不是完整 Full Superpowers pipeline。

原计划明确“不盲评”。三条候选、diff、测试和 adoption evidence 冻结后，用户在 2026-07-31 追加授权评分；[judge amendment](../evaluation/judge-amendment.md) 保留了这条时间边界。评分没有重跑候选，也没有改变原 Full/Without 六条轨迹及其 12 份历史 verdict。

每条 Slim 通过 secure-random map 匿名为 Candidate A-C。每个 judge 只能看到 task、contract、rubric、限定产品 diff、focused-test 日志和三份 baseline 上下文；使用新的独立 Codex 0.145.0 home、`gpt-5.6-terra/high`、read-only、禁网、无已安装插件。第一轮三条完成后才启动第二轮。

## 依据是什么

1. [匿名汇总](../evaluation/anonymous-summary.json) 记录 A-C 各两次分数；[去盲汇总](../evaluation/deblinded-summary.json) 才把匿名标签映射回 `slim-01..03`。
2. [judge audit](../evaluation/judge-audit.json) 验证 6/6 verdict 符合冻结 schema、6 个 thread ID 唯一、第二轮晚于第一轮、匿名包与 final verdict 均无 treatment/run/绝对路径泄漏，raw 命令没有观察到父目录或 sibling 访问。
3. [judge summary](../evaluation/judge-summary.json) 冻结本次评分的模型、版本、token、耗时和 credits。6 次 judge 共使用 {judge_tokens:,} token，累计 session 时间 {judge_duration_sum:.1f} 秒，按实际并发计算的端到端 elapsed 为 {judge_elapsed:.1f} 秒，估算 {judge_credits:.6f} frozen credits。
4. 修复后的 [product diff manifest](product-code-diff-manifest.json) 明确包含 untracked product files；三份完整 patch 均可在干净 baseline 上 `git apply --check`。`slim-02` 补入 1 个新测试文件，`slim-03` 补入 1 个实现文件和 1 个测试文件，候选轨迹本身未重跑。
5. 三条 focused test 都 exit 0，但 blind judge 仍识别出 hidden contract 缺口。这正说明 focused test 只能作为验证证据，不能代替 rubric 分数。

## 分数为什么不是更高

| Rubric 维度 | Slim 六份 verdict 平均 |
|---|---:|
{dimension_rows}

最稳定的共同缺口是 **Query path and pagination：三条候选都只有 8/15**。六份 verdict 一致指出：实现没有在请求额外字段时完整获取后续 field-definition pages，或仍受 100 个字段上限约束。其次是诊断确定性、格式化输出冲突和多行值归一化；不同 run 的具体缺口不同。End-to-end table behavior 六份都给满分，说明三条都接通了基本命令路径、表头和值的对应关系，但没有完整覆盖隐藏契约的边角行为。

两次 judge 的 run 内差值分别是 2、2、1 分，平均绝对差 1.67 分；说明同模型重复评审在总分上较稳定。但它们共享同一模型家族、prompt、rubric、账号与相近服务时点，不等于两个独立外部评审群体。

## 成本与三组对照

三条 Slim candidate + operator 共 {execution_tokens:,} protocol token、{execution_credits:.6f} credits；追加 judge 再使用 {judge_tokens:,} token、{judge_credits:.6f} credits。全链路合计 {execution_tokens + judge_tokens:,} protocol token、{execution_credits + judge_credits:.6f} credits。候选平均墙钟 {mean(row['wall_seconds'] for row in current_runs):.1f} 秒，轨迹网页另用 native rollout 和 fork-prefix 去重口径比较执行阶段 token，不把 judge token混入候选轨迹。

本样本的质量/成本图景是：Slim 的执行成本与 Without 同量级，质量均分只高 1.50；Full With 的执行成本显著更高，但历史均分高 15.83。样本只有每组 3 条且 Slim 非同期，因此不能据此估计一般任务上的成本收益率，更不能把差异归因到某一个 Slim skill。

## 边界与验证

- 已确认：3 条正式 Slim 轨迹均 completed、adoption valid、focused test 通过；6 份补充 verdict 有效，组均分 {group_mean:.2f}。
- 已确认：旧 Full With / Without 的六条候选、12 份 verdict 和历史均分仍是 99.00 / 81.67，没有重跑或修改。
- 评审边界：这是 candidate 冻结后的 post-hoc 自动盲评，不是预注册评分步骤；没有执行人类盲评。
- 推断边界：Slim 是后续追加组，不是同期随机第三臂；`+1.50` 和 `-15.83` 只能作为描述性差值，不能报告 paired effect 或因果 treatment effect。
- 隔离边界：judge 使用 read-only cwd 与明确禁止越界的 prompt；raw 命令审计未观察到越界，但这不是 OS 容器级的父目录不可见证明。raw JSONL 含 `pwd` 产生的本机绝对路径，因此不进入公开报告或网站。
- 最小复核路径：先读 [amendment](../evaluation/judge-amendment.md)，再核对 [audit](../evaluation/judge-audit.json)、[anonymous summary](../evaluation/anonymous-summary.json)、[deblinded summary](../evaluation/deblinded-summary.json) 和 6 份 [raw verdict](../evaluation/results)，最后用 [metrics](metrics.json) 重算成本。
"""
    (reports / "slim-report.md").write_text(report)
    print(f"Slim judged summary written: mean={group_mean:.4f}, sessions=6")


if __name__ == "__main__":
    main()
