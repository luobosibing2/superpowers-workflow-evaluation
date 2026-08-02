import { trajectoryData as data } from "../../trajectory-data";
import Link from "next/link";

const methods = ["without", "slim", "requirementLoop", "reviewLoops", "with"] as const;
type Condition = (typeof methods)[number];

const descriptions: Record<Condition, { title: string; question: string; path: string[]; evidence: string; caveat: string }> = {
  without: {
    title: "Without · 原生直接执行",
    question: "公开目标明确，但隐藏规格没有被强制转成设计清单时，原生 Codex 会怎么做？",
    path: ["读取仓库与现有实现", "直接修改 product code / tests", "运行 focused Go tests", "根据失败继续调试或收尾"],
    evidence: "三条 run 平均 32.7 次 tool calls、2.08M dedup token、81.67 分；requirements / plan 阶段没有独立 gate，root lane 占主导。",
    caveat: "没有 operator 澄清和独立 review，不等于没有测试；focused-test 日志存在且通过，但它不能覆盖全部 hidden contract。",
  },
  slim: {
    title: "Slim With · 一次澄清与 Plan-on",
    question: "一次外部行为问答和一个计划入口，能否以很小的成本补足原生路径？",
    path: ["第一动作读取 brainstorming", "询问一次外部行为问题", "读取 writing-plans 并形成计划", "同一 session 原生实施、按需 debug、完成前 verify"],
    evidence: "三条 run 平均 34.7 次 tool calls、2.27M dedup token、83.17 分；相对 Without 只增加 +1.50 分。",
    caveat: "这是历史追加批次，不能和 Requirement Loop 当作同期随机对照；没有 Full 的 TDD、spec commit、子代理或独立 reviewer gate。",
  },
  requirementLoop: {
    title: "Requirement Loop · 多轮需求澄清",
    question: "把一次提问升级为直到行为设计获批的多轮闭环，能否让候选覆盖隐藏规格？",
    path: ["探索仓库上下文", "OPERATOR_QUESTION / OPERATOR_ANSWER 反复进行", "DESIGN_REVIEW_REQUEST", "DESIGN_CHANGES_REQUIRED 或 DESIGN_APPROVED", "获批后才读取 writing-plans 并修改产品"],
    evidence: "三条 run 平均 37.7 次 tool calls、2.87M dedup token、97.67 分；相对历史 Slim 的描述性增量为 +14.50。",
    caveat: "Slim → Requirement Loop 是跨批次描述性差值，不能单独识别多轮澄清的因果效应。",
  },
  reviewLoops: {
    title: "Requirement + Review Loops · 需求闭环加独立 review",
    question: "在已经批准设计的前提下，再反复 review / 修复，是否还能稳定提高产品质量？",
    path: ["完成 Requirement Loop 并取得 DESIGN_APPROVED", "实现、测试并发送 REVIEW_READY", "独立 reviewer 返回 critical / major / minor findings", "candidate 修复、重测、重新 REVIEW_READY", "无 critical / major 后 REVIEW_APPROVED，再 final verify"],
    evidence: "三条 run 平均 60.3 次 tool calls、4.88M dedup token、99.50 分；canonical review 轮数为 1、2、2，strict Verified 为 4/6 verdict。",
    caveat: "loop-01 是用户批准的 posthoc rerun 替换，整体 ΔFeedback +1.83 只能作描述性汇总；并非固定一次 review。",
  },
  with: {
    title: "Full With · 完整 Superpowers 复合流程",
    question: "当设计、任务拆分、多代理、测试、review 和最终验证全部联动时，增加的质量是否值得资源？",
    path: ["brainstorming 与行为设计 / spec", "writing-plans 与任务拆分", "parent 派发 child agents 并等待结果", "实现、TDD / focused tests、review / 修复", "verification-before-completion 与完成 gate"],
    evidence: "三条 run 平均 244 次 tool calls、15.87M dedup token、99.00 分；Full − Without 的新增 token 最大阶段代理是 coordinate（37.9%）。",
    caveat: "run-02 在 token cap 截止但得分 100，说明产品分、流程完成状态和 hidden acceptance proxy 不能合并成一个结论。",
  },
};

function fmtTokens(value: number) { return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(2)}M` : `${Math.round(value / 1_000)}K`; }
function fmtDuration(value: number) { const minutes = Math.floor(value / 60); return `${minutes}:${String(Math.round(value % 60)).padStart(2, "0")}`; }

export function generateStaticParams() { return methods.map((condition) => ({ condition })); }

export default async function ExperimentPage({ params }: { params: Promise<{ condition: string }> }) {
  const resolved = await params;
  const condition = methods.includes(resolved.condition as Condition) ? resolved.condition as Condition : "without";
  const group = data.groups[condition];
  const info = descriptions[condition];
  const runs = data.runs.filter((run) => run.condition === condition);
  const stageRows = Object.entries(group.stageShareMean).sort(([, a], [, b]) => b - a).slice(0, 6);
  return (
    <main className="detail-page experiment-page">
      <header className={`detail-hero experiment-hero ${condition}`}><nav><Link href="/" className="brand">WA / TRACE 09</Link><div><Link href="/task">场景分析</Link><Link href="/">首页</Link><a href="#trace">本组轨迹</a></div></nav><div className="detail-hero-copy"><span>{data.conditions[condition].label} · EXPERIMENT DETAIL</span><h1>{info.title}</h1><p>{info.question}</p></div></header>
      <section className="detail-section experiment-summary"><div className="detail-kicker">01 / 结果快照</div><div className="experiment-metrics"><div><span>盲评分</span><b>{group.scoreMean?.toFixed(2)}</b></div><div><span>tool calls / 条</span><b>{group.toolCallsMean.toFixed(1)}</b></div><div><span>dedup token / 条</span><b>{fmtTokens(group.tokenMean)}</b></div><div><span>墙钟 / 条</span><b>{fmtDuration(group.wallMeanSeconds)}</b></div></div><p className="experiment-evidence"><b>证据：</b>{info.evidence}</p><p className="experiment-caveat"><b>边界：</b>{info.caveat}</p></section>
      <section className="detail-section"><div className="detail-kicker">02 / 作业路径</div><h2>这个条件具体要求候选做什么？</h2><ol className="path-steps">{info.path.map((step, index) => <li key={step}><b>{String(index + 1).padStart(2, "0")}</b><span>{step}</span></li>)}</ol></section>
      <section className="detail-section"><div className="detail-kicker">03 / 阶段与 actor</div><h2>时间 / token 的主要落点</h2><div className="experiment-stage-grid">{stageRows.map(([stage, share]) => <div key={stage}><span>{data.stages.find((item) => item.id === stage)?.label ?? stage}</span><b>{(share * 100).toFixed(1)}%</b><i style={{ width: `${share * 100}%`, background: data.stages.find((item) => item.id === stage)?.color }} /></div>)}</div><p className="detail-intro">阶段是可见动作分类器的派生标签。Full 页面中的 coordinate 具体包括 <code>spawn_agent</code>、<code>wait_agent</code>、<code>followup_task</code>、<code>send_message</code>、worktree / approval / guardian 等过程动作，不等同于“模型在思考”。</p></section>
      <section className="detail-section" id="trace"><div className="detail-kicker">04 / 本组 run</div><h2>每条轨迹的真实状态</h2><div className="experiment-runs">{runs.map((run) => <article key={run.id}><div><span>{run.id}</span><b>{run.score === null ? "未评审" : Number(run.score).toFixed(1)}</b></div><dl><div><dt>墙钟</dt><dd>{fmtDuration(run.wallSeconds)}</dd></div><div><dt>Token</dt><dd>{fmtTokens(run.tokenSummary.total)}</dd></div><div><dt>tool calls</dt><dd>{run.toolCalls}</dd></div><div><dt>Operator</dt><dd>{run.operatorTurns}</dd></div><div><dt>需求审批</dt><dd>{run.designApprovalRounds ?? "—"}</dd></div><div><dt>Review / 修复</dt><dd>{run.reviewRounds} / {run.reviewFixRounds}</dd></div><div><dt>状态</dt><dd>{run.status}</dd></div><div><dt>首次 mutation</dt><dd>+{fmtDuration(run.firstMutationSeconds)}</dd></div></dl><Link href="/#timeline">在总时间线中定位 →</Link></article>)}</div></section>
      <section className="detail-evidence detail-section"><div className="detail-kicker">05 / 回到问题</div><h2>把本组放回五组比较</h2><p>这张子页解释“这条方法怎么走”；首页的三个研究问题再回答质量—成本、需求 / review 阶梯和 token 归因。</p><Link className="detail-button" href="/#questions">返回首页三问 →</Link></section>
    </main>
  );
}
