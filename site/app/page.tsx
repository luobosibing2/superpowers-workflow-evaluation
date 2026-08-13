"use client";

import { useMemo, useState } from "react";
import { trajectoryData } from "./trajectory-data";

const data = trajectoryData;
const conditionOrder = ["without", "slim", "requirementLoop", "reviewLoops", "with"] as const;
const laneOrder = ["root", "child", "guardian", "operator", "reviewer"] as const;

type Run = (typeof data.runs)[number];

const stageById = Object.fromEntries(data.stages.map((stage) => [stage.id, stage])) as Record<string, (typeof data.stages)[number]>;
const laneMeta = {
  root: { label: "Parent", color: "#3b82f6" },
  child: { label: "Child", color: "#f97352" },
  guardian: { label: "Guardian", color: "#6f7f99" },
  operator: { label: "Operator", color: "#e65383" },
  reviewer: { label: "Targeted reviewer", color: "#d58b29" },
} as const;

function fmtTokens(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(0)}K`;
  return Math.round(value).toLocaleString("zh-CN");
}

function fmtDuration(seconds: number) {
  const rounded = Math.max(0, Math.round(seconds));
  const minutes = Math.floor(rounded / 60);
  return `${minutes}:${String(rounded % 60).padStart(2, "0")}`;
}

function fmtClock(iso: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date(iso));
}

function clockAt(run: Run, seconds: number) {
  return fmtClock(new Date(Date.parse(run.start) + seconds * 1000).toISOString());
}

function pct(value: number) {
  return `${Math.max(0, value * 100).toFixed(1)}%`;
}

function fmtCredits(value: number) {
  return `${value.toFixed(2)} cr`;
}

function fmtSigned(value: number, digits = 2) {
  return `${value >= 0 ? "+" : "−"}${Math.abs(value).toFixed(digits)}`;
}

function conditionLabel(condition: string) {
  return data.conditions[condition as keyof typeof data.conditions]?.label ?? condition;
}

function EvidenceMetricBar({ label, value, max, display, color }: { label: string; value: number; max: number; display: string; color: string }) {
  return (
    <div className="evidence-metric">
      <div><span>{label}</span><b>{display}</b></div>
      <div className="evidence-track"><i style={{ width: `${max ? Math.max(0, Math.min(100, value / max * 100)) : 0}%`, background: color }} /></div>
    </div>
  );
}

function ScoreResourceChart() {
  const rows = data.research.scoreResource;
  const maxTokens = Math.max(...rows.map((row) => row.tokenMean));
  const maxWall = Math.max(...rows.map((row) => row.wallMeanSeconds));
  const maxCredits = Math.max(...rows.map((row) => row.estimatedCreditsMean ?? 0));
  return (
    <div className="research-chart">
      <div className="research-chart-head"><span>方法</span><span>Score</span><span>执行 credits</span><span>dedup token / run</span><span>墙钟</span></div>
      {rows.map((row) => (
        <div className={`research-row ${row.condition}`} key={row.condition}>
          <strong>{conditionLabel(row.condition)}</strong>
          <EvidenceMetricBar label="score" value={row.scoreMean ?? 0} max={100} display={row.scoreMean === null ? "—" : row.scoreMean.toFixed(2)} color={data.conditions[row.condition].accent} />
          <EvidenceMetricBar label="credits" value={row.estimatedCreditsMean ?? 0} max={maxCredits} display={row.estimatedCreditsMean === null ? "—" : fmtCredits(row.estimatedCreditsMean)} color="#e65383" />
          <EvidenceMetricBar label="tokens" value={row.tokenMean} max={maxTokens} display={fmtTokens(row.tokenMean)} color="#6f7f99" />
          <EvidenceMetricBar label="wall" value={row.wallMeanSeconds} max={maxWall} display={fmtDuration(row.wallMeanSeconds)} color="#21a67a" />
        </div>
      ))}
      <small className="chart-footnote">Score 是每 run 两次 blind judge 的均值；credits 是 candidate/operator/reviewer 的 execution credits，judge credits 不计入；token 是去 fork 继承后的轨迹总量。</small>
    </div>
  );
}

function AcceptanceChart() {
  return (
    <div className="acceptance-chart">
      <div className="subchart-title"><span>严格验证代理</span><b>Verified verdict / 完全 Verified run</b></div>
      {data.research.acceptance.map((row) => (
        <div className="acceptance-row" key={row.condition}>
          <strong>{conditionLabel(row.condition)}</strong>
          <div className="acceptance-track"><i style={{ width: `${row.totalVerdicts ? row.verifiedRate * 100 : 0}%`, background: data.conditions[row.condition].accent }} /><span>{row.verifiedVerdicts}/{row.totalVerdicts}</span></div>
          <b>{row.fullyVerifiedRuns}/{row.runCount} runs</b>
        </div>
      ))}
      <small className="chart-footnote">口径：judge.final.json 的 overallValidation === Verified；这不是协议定义的独立 hidden integration gate。完全通过要求同一 run 的两次 verdict 都 Verified 且无 critical/major gap。</small>
    </div>
  );
}

function LadderChart() {
  const maxCredits = Math.max(...data.research.ladder.map((row) => Math.abs(row.creditsDelta)));
  const maxTokens = Math.max(...data.research.ladder.map((row) => Math.abs(row.tokenDelta)));
  return (
    <div className="ladder-chart">
      {data.research.ladder.map((row) => (
        <div className="ladder-row" key={`${row.from}-${row.to}`}>
          <div className="ladder-label"><b>{conditionLabel(row.from)} → {conditionLabel(row.to)}</b><small>{row.scope}</small></div>
          <div className="ladder-deltas">
            <span className={row.scoreDelta >= 0 ? "positive" : "negative"}>Score <b>{fmtSigned(row.scoreDelta)}</b></span>
            <span>credits <b>{fmtSigned(row.creditsDelta)}</b></span>
            <span>tokens <b>{fmtSigned(row.tokenDelta / 1_000_000, 2)}M</b></span>
            <span>wall <b>{fmtSigned(row.wallDeltaSeconds, 0)}s</b></span>
          </div>
          <div className="ladder-bars"><i style={{ width: `${Math.abs(row.creditsDelta) / maxCredits * 100}%`, background: row.scoreDelta >= 0 ? "#e65383" : "#9aa3b2" }} /><i style={{ width: `${Math.abs(row.tokenDelta) / maxTokens * 100}%`, background: "#6f7f99" }} /></div>
        </div>
      ))}
      <div className="ladder-legend"><span><i style={{ background: "#e65383" }} />credits 增量</span><span><i style={{ background: "#6f7f99" }} />token 增量（各自归一化）</span></div>
    </div>
  );
}

function TokenDeltaBars({ title, rows, labelFor, color }: { title: string; rows: readonly { deltaTokens: number; shareOfDelta: number; [key: string]: unknown }[]; labelFor: (row: { [key: string]: unknown }) => string; color: string }) {
  const max = Math.max(...rows.map((row) => Math.max(0, row.deltaTokens)));
  return (
    <div className="token-delta-group">
      <div className="subchart-title"><span>{title}</span><b>Full − Without</b></div>
      {rows.map((row, index) => (
        <div className="token-delta-row" key={`${title}-${labelFor(row)}-${index}`}>
          <strong>{labelFor(row)}</strong>
          <div className="token-delta-track"><i style={{ width: `${max ? Math.max(0, row.deltaTokens) / max * 100 : 0}%`, background: color }} /><span>{fmtSigned(row.deltaTokens / 1_000_000, 2)}M · {pct(row.shareOfDelta)}</span></div>
        </div>
      ))}
    </div>
  );
}

function TokenAttributionChart() {
  const attribution = data.research.tokenAttribution;
  const laneLabels: Record<string, string> = { root: "Parent", child: "Child", guardian: "Guardian", operator: "Operator", reviewer: "Reviewer" };
  const compositionLabels: Record<string, string> = { cached: "Cached input", uncachedInput: "Uncached input", reasoning: "Reasoning", otherOutput: "Other output" };
  return (
    <div className="token-attribution-chart">
      <div className="attribution-total">Full 相比 Without 每条 run 多 <strong>{fmtTokens(attribution.totalDeltaTokens)}</strong> token</div>
      <div className="coordination-definition"><b>“协调”不是代码实现的同义词</b><p>本分析把主 Agent 的 <code>spawn_agent</code>、<code>wait_agent</code>、<code>followup_task</code>、<code>send_message</code>、代理结果汇总、worktree / approval / guardian 安全动作归到 coordinate。它是“派发—等待—收集—决策”的过程代理；一个协调片段里可能同时带有上下文传输和实现决策，不能把它解释成单一语义动作。</p></div>
      <TokenDeltaBars title="按互斥阶段" rows={attribution.stage} labelFor={(row) => stageById[String(row.stage)]?.label ?? String(row.stage)} color="#f97352" />
      <TokenDeltaBars title="按 actor 泳道" rows={attribution.lane} labelFor={(row) => laneLabels[String(row.lane)] ?? String(row.lane)} color="#6f7f99" />
      <TokenDeltaBars title="按 usage 构成" rows={attribution.composition} labelFor={(row) => compositionLabels[String(row.key)] ?? String(row.key)} color="#3b82f6" />
      <small className="chart-footnote">{attribution.definitions.stage} {attribution.definitions.composition}</small>
    </div>
  );
}

function ScenarioTeaser() {
  const methods = ["without", "slim", "requirementLoop", "reviewLoops", "with"] as const;
  const paths: Record<(typeof methods)[number], string> = {
    without: "探索现有代码 → 直接修改 → 运行测试 / 修复",
    slim: "一次 Operator 澄清 → 读取 writing-plans → 原生实施与验证",
    requirementLoop: "多轮提问 → 设计审批 → 计划 → 原生实施",
    reviewLoops: "需求审批 → 实现 / 测试 → reviewer 反馈 → 修复 / 复审",
    with: "设计 / spec → 任务计划 → 多代理实施 → review / 修复 → verification",
  };
  return (
    <section className="section scenario-teaser" id="scenario">
      <div className="section-title split"><div><span>SCENARIO 01 / TASK ANALYSIS</span><h2>需求上下文不完整的 CLI 任务</h2></div><a className="text-link" href="/task">打开完整场景分析 →</a></div>
      <div className="scenario-summary"><div><b>原始需求摘要</b><p>改进 <code>gh project item-list</code>，支持按可读字段名或 field ID 重复选择项目字段，保持兼容，并把无效、歧义、分页、按 ID 对齐和多种字段值渲染做完整。</p></div><div><b>真正的难点</b><p>公开 prompt 没有逐条列出隐藏规格；候选必须决定是否搜索、提问、形成设计、派发实现和审查，最终由隐藏 contract 检查边界。</p></div></div>
      <div className="scenario-methods">{methods.map((condition) => { const group = data.groups[condition]; return <article key={condition} className={condition}><span>{data.conditions[condition].label}</span><h3>{paths[condition]}</h3><dl><div><dt>分数</dt><dd>{group.scoreMean?.toFixed(2)}</dd></div><div><dt>工具 / 条</dt><dd>{group.toolCallsMean.toFixed(1)}</dd></div><div><dt>Token / 条</dt><dd>{fmtTokens(group.tokenMean)}</dd></div></dl><a href={`/experiments/${condition}`}>看该实验作业路径 →</a></article>; })}</div>
    </section>
  );
}

function Metric({ label, value, note }: { label: string; value: string; note: string }) {
  return <div className="metric"><span>{label}</span><strong>{value}</strong><p>{note}</p></div>;
}

function NormalizedBar({ parts, label }: { parts: { key: string; label: string; value: number; color: string }[]; label: string }) {
  const total = parts.reduce((sum, part) => sum + part.value, 0);
  return (
    <div className="bar" role="img" aria-label={label}>
      {parts.filter((part) => part.value > 0).map((part) => (
        <i
          key={part.key}
          style={{ width: `${(part.value / total) * 100}%`, background: part.color }}
          title={`${part.label}: ${((part.value / total) * 100).toFixed(1)}%`}
        />
      ))}
    </div>
  );
}

function Legend({ items }: { items: { key: string; label: string; color: string }[] }) {
  return <div className="legend">{items.map((item) => <span key={item.key}><i style={{ background: item.color }} />{item.label}</span>)}</div>;
}

function scoreText(run: Run) {
  return run.score === null ? "未评审" : Number(run.score).toFixed(1);
}

function checkpointText(value: string | null) {
  return value ? fmtClock(value) : "—";
}

function GroupBars({ mode }: { mode: "stage" | "lane" | "composition" }) {
  const stageLegend = data.stages.map((stage) => ({ key: stage.id, label: stage.label, color: stage.color }));
  const laneLegend = laneOrder.map((lane) => ({ key: lane, label: laneMeta[lane].label, color: laneMeta[lane].color }));
  const compositionLegend = [
    { key: "cached", label: "Cached input", color: "#3b82f6" },
    { key: "uncachedInput", label: "Uncached input", color: "#8b5cf6" },
    { key: "reasoning", label: "Reasoning output", color: "#f97352" },
    { key: "otherOutput", label: "Other output", color: "#21a67a" },
  ];
  const legend = mode === "stage" ? stageLegend : mode === "lane" ? laneLegend : compositionLegend;

  return (
    <div className="group-bars">
      {conditionOrder.map((condition) => {
        const group = data.groups[condition];
        const source = mode === "stage" ? group.stageShareMean : mode === "lane" ? group.laneShareMean : group.compositionShareMean;
        const parts = legend.map((item) => ({ ...item, value: Number(source[item.key as keyof typeof source]) }));
        return (
          <div className={`group-bar ${condition}`} key={condition}>
            <div><b>{data.conditions[condition].label}</b><span>每条 run 平均 · {fmtTokens(group.tokenMean)} / run</span></div>
            <NormalizedBar parts={parts} label={`${data.conditions[condition].label} token distribution`} />
            <small>pooled total {fmtTokens(group.pooledTokens)}</small>
          </div>
        );
      })}
      <Legend items={legend} />
    </div>
  );
}

function WallBars() {
  const legend = data.stages.map((stage) => ({ key: stage.id, label: stage.label, color: stage.color }));
  return (
    <div className="group-bars wall-bars">
      {conditionOrder.map((condition) => {
        const group = data.groups[condition];
        const parts = legend.map((item) => ({ ...item, value: Number(group.wallShareMean[item.key as keyof typeof group.wallShareMean]) }));
        return (
          <div className={`group-bar ${condition}`} key={condition}>
            <div><b>{data.conditions[condition].label}</b><span>per-run 平均墙钟占比 · 平均 {fmtDuration(group.wallMeanSeconds)}</span></div>
            <NormalizedBar parts={parts} label={`${data.conditions[condition].label} wall-clock stage distribution`} />
          </div>
        );
      })}
      <Legend items={legend} />
    </div>
  );
}

function RunSummary({ run }: { run: Run }) {
  return (
    <div className="run-head">
        <div><span>{data.conditions[run.condition].label}</span><h3>{run.id}</h3></div>
        <dl>
          <div><dt>分数</dt><dd>{scoreText(run)}</dd></div>
          <div><dt>墙钟</dt><dd>{fmtDuration(run.wallSeconds)}</dd></div>
          <div><dt>Token</dt><dd>{fmtTokens(run.tokenSummary.total)}</dd></div>
          <div><dt>首改</dt><dd>+{fmtDuration(run.firstMutationSeconds)}</dd></div>
          <div><dt>设计获批</dt><dd>{checkpointText(run.designApprovedAt)}</dd></div>
          <div><dt>首个 Review Ready</dt><dd>{checkpointText(run.firstReviewReadyAt)}</dd></div>
          <div><dt>Review 通过</dt><dd>{checkpointText(run.reviewApprovedAt)}</dd></div>
        </dl>
      </div>
  );
}

function RunTimeline({ run, selected, onSelect }: { run: Run; selected: string | null; onSelect: (key: string) => void }) {
  return (
    <article className={`timeline-card ${run.condition}`}>
      <RunSummary run={run} />
      <div className="wall-strip" aria-label={`${run.id} wall timeline`}>
        {run.wallTimeline.map((segment, index) => (
          <i key={index} style={{ left: pct(segment.startSeconds / run.wallSeconds), width: pct((segment.endSeconds - segment.startSeconds) / run.wallSeconds), background: stageById[segment.stage].color }} title={`${stageById[segment.stage].label} ${clockAt(run, segment.startSeconds)}–${clockAt(run, segment.endSeconds)}`} />
        ))}
      </div>
      <div className="axis"><span>0:00</span><span>{fmtDuration(run.wallSeconds / 2)}</span><span>{fmtDuration(run.wallSeconds)}</span></div>
      <div className="lanes">
        {laneOrder.map((lane) => {
          const segments = run.laneTimeline.map((segment, index) => ({ segment, index })).filter(({ segment }) => segment.laneGroup === lane);
          return (
            <div className="lane" key={lane}>
              <b>{laneMeta[lane].label}</b>
              <div className="lane-track">
                {segments.map(({ segment, index }) => {
                  const key = `${run.id}:${index}`;
                  return <button
                    key={key}
                    className={selected === key ? "selected" : ""}
                    onClick={() => onSelect(key)}
                    style={{ left: pct(segment.startSeconds / run.wallSeconds), width: pct(Math.max(0.004, (segment.endSeconds - segment.startSeconds) / run.wallSeconds)), background: stageById[segment.stage].color }}
                    aria-label={`${stageById[segment.stage].label}, ${segment.label}, ${segment.confidence}`}
                    title={`${segment.label} · ${segment.confidence} · ${segment.evidence[0]}`}
                  />;
                })}
              </div>
            </div>
          );
        })}
      </div>
      <div className="run-foot"><span>{run.operatorTurns} operator 回合</span><span>{run.toolCalls} tool calls</span><span>{Object.values(run.sessionCounts).reduce((sum, count) => sum + count, 0)} sessions</span></div>
    </article>
  );
}

export default function Home() {
  const [tokenMode, setTokenMode] = useState<"stage" | "lane" | "composition">("stage");
  const [traceIndex, setTraceIndex] = useState(0);
  const [selected, setSelected] = useState<string | null>(null);
  const selectedRuns = useMemo(() => data.traceSets[traceIndex].runs.map((id) => data.runs.find((run) => run.id === id)!), [traceIndex]);
  const selectedDetail = useMemo(() => {
    if (!selected) return null;
    const [runId, rawIndex] = selected.split(":");
    const run = data.runs.find((candidate) => candidate.id === runId);
    const segment = run?.laneTimeline[Number(rawIndex)];
    return run && segment ? { run, segment } : null;
  }, [selected]);

  const full = data.groups.with;
  const slim = data.groups.slim;
  const without = data.groups.without;
  const requirement = data.groups.requirementLoop;
  const reviewLoops = data.groups.reviewLoops;

  return (
    <main className="home-page">
      <header className="hero" id="top">
        <nav><a href="#top" className="brand">WA / TRACE 09</a><div><a href="/luna-panel">Luna 横评</a><a href="#shape">方法</a><a href="#scenario">场景</a><a href="#distribution">分布</a><a href="#timeline">轨迹</a><a href="#questions">问题</a><a href="#boundary">边界</a><a href="https://github.com/luobosibing2/superpowers-workflow-evaluation">源码</a></div></nav>
        <div className="hero-copy">
          <div>
            <span className="kicker">WORKFLOW ARENA · gpt-5.6-terra/high · macOS</span>
            <h1>同一个任务，<br /><em>五种工作方式。</em></h1>
            <p>十五条 native Codex rollout 被还原成可点击的阶段、墙钟与 actor 泳道：从 Without、一次澄清的 Slim，到需求闭环、需求加 review 闭环，再到 Full。</p>
          </div>
          <aside><b>读图先看这里</b><p><strong>Requirement Loop</strong> 与 <strong>Review Loops</strong> 原本是本次追加的同期随机三对；loop-01 后来按用户批准的独立 rerun 更新为 100/100，因此 pair-01 不再与另外两对处于同一执行窗口。历史 Slim、Full、Without 仍是先前批次，只作描述性对照。</p><small>时间与 token 来自原始 rollout；替换后的 paired ΔFeedback 为 +1.83 分，仅作更新后的描述性汇总。</small></aside>
        </div>
        <div className="metrics">
          <Metric label="盲评分" value={`${without.scoreMean?.toFixed(2)} · ${slim.scoreMean?.toFixed(2)} · ${requirement.scoreMean?.toFixed(2)} · ${reviewLoops.scoreMean?.toFixed(2)} · ${full.scoreMean?.toFixed(2)}`} note="Without / Slim / Req Loop / Review Loops / Full；均为 scoreN=2" />
          <Metric label="平均墙钟" value={`${fmtDuration(without.wallMeanSeconds)} · ${fmtDuration(slim.wallMeanSeconds)} · ${fmtDuration(requirement.wallMeanSeconds)} · ${fmtDuration(reviewLoops.wallMeanSeconds)} · ${fmtDuration(full.wallMeanSeconds)}`} note="五组均按每条 run 求平均" />
          <Metric label="平均 TOKEN / RUN" value={`${fmtTokens(without.tokenMean)} · ${fmtTokens(slim.tokenMean)} · ${fmtTokens(requirement.tokenMean)} · ${fmtTokens(reviewLoops.tokenMean)} · ${fmtTokens(full.tokenMean)}`} note="去除 fork 继承 usage；reviewer 计入 Review Loops treatment" />
          <Metric label="平均首次改产品" value={`${fmtDuration(without.firstMutationMeanSeconds)} · ${fmtDuration(slim.firstMutationMeanSeconds)} · ${fmtDuration(requirement.firstMutationMeanSeconds)} · ${fmtDuration(reviewLoops.firstMutationMeanSeconds)} · ${fmtDuration(full.firstMutationMeanSeconds)}`} note="顺序同上；需求闭环会把首次 mutation 推后" />
        </div>
      </header>

      <section className="section">
        <div className="luna-panel-teaser">
          <div className="lead"><span>NEW · EXTERNAL LUNA PANEL</span><h2>五种工作流，八个真实任务</h2><p>新增 120 条 Luna/high candidate compact 结果：Grill Me、Superpowers、MatrixSpec、OpenSpec 与 Ponytail 的质量、精确测试、完成状态和资源横评。</p><a href="/luna-panel">打开多任务横评 →</a></div>
          <div><b>92.14</b><p>Grill Me 宏均分</p><small>23/24 focused-test flags</small></div>
          <div><b>89.64</b><p>Superpowers Full</p><small>32.99M candidate token / run</small></div>
          <div><b>120</b><p>candidate runs</p><small>5 workflows × 8 tasks × 3</small></div>
        </div>
      </section>

      <section className="section" id="shape">
        <div className="section-title"><span>01 / METHOD SHAPE</span><h2>把 Full 的两个机制增量拆成相邻阶梯</h2></div>
        <div className="method-grid">
          <article className="without"><span>WITHOUT</span><h3>短线直接做</h3><div className="flow"><i>探索</i><i>实现</i><i>测试 / 修复</i><i>完成</i></div><p>{data.conditions.without.description}</p></article>
          <article className="slim"><span>SLIM WITH</span><h3>澄清 + Plan-on</h3><div className="flow"><i>探索</i><i>Operator 澄清</i><i>计划</i><i>原生实施</i><i>验证</i></div><p>{data.conditions.slim.description}</p></article>
          <article className="requirementLoop"><span>REQUIREMENT LOOP</span><h3>多轮需求闭环</h3><div className="flow"><i>探索</i><i>多轮提问</i><i>设计获批</i><i>计划</i><i>原生实施</i></div><p>{data.conditions.requirementLoop.description}</p></article>
          <article className="reviewLoops"><span>REVIEW LOOPS</span><h3>需求 + 实现反馈</h3><div className="flow"><i>需求获批</i><i>实现 / 测试</i><i>独立 review</i><i>修复</i><i>复审通过</i></div><p>{data.conditions.reviewLoops.description}</p></article>
          <article className="with"><span>FULL WITH</span><h3>完整 gate 与反馈环</h3><div className="flow"><i>设计 / GT</i><i>Spec + plan</i><i>多代理实施</i><i>独立 review</i><i>修复 / verify</i></div><p>{data.conditions.with.description}</p></article>
        </div>
      </section>

      <ScenarioTeaser />

      <section className="section" id="distribution">
        <div className="section-title split"><div><span>02 / PHASE DISTRIBUTION</span><h2>时间花在哪里</h2></div><p>主口径：每条 run 先归一化，再对组三条求平均。</p></div>
        <WallBars />
      </section>

      <section className="section token-section">
        <div className="section-title split"><div><span>03 / TOKEN DISTRIBUTION</span><h2>Token 被什么阶段、什么 actor 消耗</h2></div><div className="switch"><button className={tokenMode === "stage" ? "active" : ""} onClick={() => setTokenMode("stage")}>按阶段</button><button className={tokenMode === "lane" ? "active" : ""} onClick={() => setTokenMode("lane")}>按 actor</button><button className={tokenMode === "composition" ? "active" : ""} onClick={() => setTokenMode("composition")}>按构成</button></div></div>
        <GroupBars mode={tokenMode} />
      </section>

      <section className="section timeline-section" id="timeline">
        <div className="section-title split"><div><span>04 / FIVE-WAY TRACE</span><h2>什么时候由谁做了什么</h2></div><div className="switch">{data.traceSets.map((trace, index) => <button key={trace.id} className={traceIndex === index ? "active" : ""} onClick={() => { setTraceIndex(index); setSelected(null); }}>{trace.label}</button>)}</div></div>
        <p className="notice">每个 TRACE 纵向展示五种方法的阶段比例轴。Requirement Loop 与 Review Loops 的 pair-02/03 保留同期随机配对；pair-01 的 loop-01 分数和轨迹来自后续独立 rerun，因此整组三对只作更新后的描述性对齐。历史 Without、Slim、Full 仅作跨批次描述性对齐。Review Loops 的 Targeted reviewer 单独显示。</p>
        <div className="timeline-grid">{selectedRuns.map((run) => <RunTimeline key={run.id} run={run} selected={selected} onSelect={setSelected} />)}</div>
        {selectedDetail && <aside className="drawer"><div><span>{selectedDetail.run.id} · {stageById[selectedDetail.segment.stage].label}</span><h3>{selectedDetail.segment.label}</h3><p>{clockAt(selectedDetail.run, selectedDetail.segment.startSeconds)}–{clockAt(selectedDetail.run, selectedDetail.segment.endSeconds)} · {fmtDuration(selectedDetail.segment.endSeconds - selectedDetail.segment.startSeconds)}</p></div><dl><div><dt>Actor</dt><dd>{selectedDetail.segment.lane}</dd></div><div><dt>分类置信度</dt><dd>{selectedDetail.segment.confidence}</dd></div><div><dt>原始证据</dt><dd><code>{selectedDetail.segment.evidence.join(" · ")}</code></dd></div></dl></aside>}
      </section>

      <section className="section questions" id="questions">
        <div className="section-title"><span>05 / THREE RESEARCH QUESTIONS</span><h2>三个问题，三条可审计证据链</h2><p>把“分数更高”“验收可靠”“token 花在哪里”拆开回答；所有图都标明是原始 usage、盲评代理还是分类器派生。</p></div>
        <div className="question-stack">
          <article className="question-card">
            <div className="question-heading"><b>Q1</b><div><h3>Full Superpowers 相比较原生 Codex，质量和资源如何变化？隐藏验收能稳定通过吗？</h3><p>Full With 的分数跃升，但不是免费提升；高分也不能替代独立的 hidden acceptance gate。</p></div></div>
            <ScoreResourceChart />
            <AcceptanceChart />
            <div className="analysis-detail-grid">
              <article><span>01 / 产品质量</span><h4>三条 Full 都进入 98–100 分，和 Without 的 80.5–82.5 分区间没有重叠</h4><p>Full 的三条 run 分别是 <b>100 / 99 / 98</b>，Without 是 <b>82 / 82.5 / 80.5</b>。组均值从 81.67 提升到 99.00，增加 17.33 分。这个结果说明完整流程在本任务上显著减少了行为规格遗漏；但每组只有三条，且不是同期随机批次，所以它是强描述性证据，不是总体因果效应估计。</p></article>
              <article><span>02 / 资源交换</span><h4>质量提升对应约 7.6 倍 token、4.7 倍时间和 7.5 倍执行 credits</h4><p>每条 run 的平均消耗从 <b>{fmtTokens(without.tokenMean)} → {fmtTokens(full.tokenMean)}</b>，墙钟从 <b>{fmtDuration(without.wallMeanSeconds)} → {fmtDuration(full.wallMeanSeconds)}</b>，工具调用从 <b>{without.toolCallsMean.toFixed(1)} → {full.toolCallsMean.toFixed(0)}</b>，execution credits 从 <b>{fmtCredits(without.estimatedCreditsMean ?? 0)} → {fmtCredits(full.estimatedCreditsMean ?? 0)}</b>。因此 Full 的优势不是“同样预算下免费变好”，而是用更多上下文、实施、协调和审查换取更完整的产品行为。</p></article>
              <article><span>03 / 逐 run 验收</span><h4>100 分也不等于流程和隐藏验收都稳定通过</h4><p><b>run-02</b> 两份 verdict 都是 Verified、得分 100，但最终状态是 token cap；<b>run-03</b> 只有 1/2 Verified；<b>run-06</b> 是 0/2 Verified，仍得到 98 分。Full 合计只有 <b>3/6 Verified verdict、1/3 双 Verified run</b>。这说明 rubric 总分是在衡量产品质量，而 <code>overallValidation</code> 是另一种严格代理；两者相关，却不能互相替代。</p></article>
            </div>
            <p className="question-conclusion"><strong>结论：</strong>Full 99.00 对 Without 81.67（+17.33），但平均墙钟约 4.69×、dedup token 7.64×、execution credits 7.49×、tool calls 7.47×。严格 Verified 代理只有 3/6 个 Full verdict、1/3 个 run 两次均 Verified；因此本样本支持“更高质量 / 更高资源”，不支持“隐藏验收稳定必过”。Full 的 run-02 虽两次 Verified 且得分 100，却在 token cap 截止，不能把分数当作流程完整性的证明。</p>
          </article>

          <article className="question-card">
            <div className="question-heading"><b>Q2</b><div><h3>需求闭环和定向代码审查分别带来多少收益？Full 还能继续稳定增益吗？</h3><p>这里的“审查”按实际协议是独立 reviewer 反复修复到无 critical/major，而不是人为固定一次。</p></div></div>
            <LadderChart />
            <div className="analysis-detail-grid">
              <article><span>01 / 需求闭环</span><h4>最大的质量跃升发生在“把需求问完整并获批”这一步</h4><p>Slim → Requirement Loop 的均分变化是 <b>83.17 → 97.67（+14.50）</b>。三条 Requirement run 分别问了 1、2、2 个定向问题，并经历 5、4、4 次设计审批请求；首次产品修改平均从 Slim 的 <b>+{fmtDuration(slim.firstMutationMeanSeconds)}</b> 推迟到 <b>+{fmtDuration(requirement.firstMutationMeanSeconds)}</b>。代价是每条多 <b>0.60M token、2:17 墙钟、3 次工具调用和 14.85 credits</b>。证据更支持“补齐隐藏行为边界带来主要收益”，而不是“多写计划本身带来收益”。</p></article>
              <article><span>02 / Review 闭环</span><h4>审查的收益较小、成本较高，而且不是每条都正向</h4><p>Requirement → Review Loops 的更新后均值是 <b>+1.83 分</b>，同时每条多 <b>2.00M token、9:17 墙钟、22.7 次工具调用和 41.84 credits</b>。三个对齐差值分别为 <b>+4.00、−1.50、+3.00</b>：loop-01 一轮 review 后无 major fix，loop-04 和 loop-06 各两轮并各修复一次。review 能发现并修复实现问题，但效果取决于初始实现和 finding，并非机械地每条加分。</p></article>
              <article><span>03 / Full 剩余流程</span><h4>加入 spec、TDD、多代理与更多 gate 后，没有观察到继续增分</h4><p>Review Loops → Full 的均分是 <b>99.50 → 99.00（−0.50）</b>，却再增加约 <b>11.00M token、19:40 墙钟、183.7 次工具调用和 97.63 credits</b>。这不能证明 Full 的剩余流程“有害”：两组来自不同批次，Full 还包含多个同时变化的机制；它只能说明在当前单任务、小样本和接近满分的天花板下，没有看到稳定的额外质量收益。</p></article>
            </div>
            <p className="question-conclusion"><strong>结论：</strong>历史 Slim → Requirement Loop 的描述性增量是 +14.50 分，约多 24.95% 墙钟、26.53% token、51.83% credits；Requirement Loop → Review Loops 再增加 +1.83 分，却多 81.10% 墙钟、69.68% token、96.20% credits。Review Loops → Full 分数反而 −0.50，资源再增加约 95% 墙钟、226% token、114% credits；所以在这批小样本里，没有观察到 Full 在两个机制之后仍提供稳定质量增益。Slim→Requirement 是跨批次描述性比较，Review 的 pair-01 还被 posthoc rerun 替换，不能写成完整因果效应。</p>
          </article>

          <article className="question-card">
            <div className="question-heading"><b>Q3</b><div><h3>Superpowers 新增 token 主要花在实现、重复读上下文，还是主 Agent 与子 Agent 的协调？</h3><p>阶段、actor、usage 构成是三种互补切片，不把它们相加成一个“归因总和”。</p></div></div>
            <TokenAttributionChart />
            <div className="analysis-detail-grid">
              <article><span>01 / 按动作阶段</span><h4>最大增量是协调，其次才是实现和 review</h4><p>Full 相比 Without 每条多 <b>{fmtTokens(data.research.tokenAttribution.totalDeltaTokens)}</b> token。分类器把其中 <b>5.23M（37.9%）</b>归到 coordinate，<b>3.94M（28.6%）</b>归到 implement，<b>2.27M（16.5%）</b>归到 review；计划、测试、需求分别占 5.7%、5.4%、3.8%。所以新增 token 并非主要只花在“多写代码”，而是大量花在派发、等待后的续接、结果吸收和决策同步。</p></article>
              <article><span>02 / 按 Actor</span><h4>主 Agent 仍是最大消费者，但子 Agent 已承担超过四成增量</h4><p>root 增加 <b>7.36M（53.3%）</b>，child 增加 <b>5.83M（42.3%）</b>，两者合计 <b>95.6%</b>；guardian 与 operator 合计约 4.4%。这说明 Full 的成本不是某个 reviewer actor 单独造成，而是主 Agent 保留全局上下文、子 Agent 各自执行任务，再由主 Agent 回收结果的组合成本。</p></article>
              <article><span>03 / 按 Usage 构成</span><h4>95.3% 的新增量表现为 cached input，但它不是“重复读文件”的直接计数</h4><p>增量里 cached input 为 <b>13.14M（95.28%）</b>，uncached input 为 <b>0.59M（4.24%）</b>，reasoning 与其他 output 合计不足 0.5%。这说明成本主要随长上下文和会话续接累积，而不是最终输出文本；但 API usage 只告诉我们输入是否命中缓存，无法逐 token 区分“重复读取代码”“给子 Agent 传上下文”还是“汇总后继续推理”。</p></article>
            </div>
            <p className="question-conclusion"><strong>结论：</strong>Full−Without 的新增 {fmtTokens(data.research.tokenAttribution.totalDeltaTokens)} token 中，阶段代理最大的是 coordinate {pct(data.research.tokenAttribution.stage.find((row) => row.stage === "coordinate")?.shareOfDelta ?? 0)}，其次 implement {pct(data.research.tokenAttribution.stage.find((row) => row.stage === "implement")?.shareOfDelta ?? 0)}、review {pct(data.research.tokenAttribution.stage.find((row) => row.stage === "review")?.shareOfDelta ?? 0)}；actor 视图中 root + child 合计约 95.6%。cached input 增量约 {pct(data.research.tokenAttribution.composition.find((row) => row.key === "cached")?.shareOfDelta ?? 0)}，只能作为上下文传输 / 缓存代理，不能直接证明模型语义上重复读了哪些文件。现有 raw tool evidence 支持“有派发、等待、follow-up、结果汇总”，但不能逐 token 拆成 dispatch、wait、summary。</p>
          </article>
        </div>
        <p className="question-source">证据入口：公开仓库的 <a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/tree/main/results">15 条 canonical results</a>、<a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/blob/main/data/metrics.json">metrics.json</a>、<a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/blob/main/superseded/replacement.json">loop-01 replacement</a> 与每条 run 的两份 verdict。详细边界见<a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/blob/main/docs/report.md">主报告</a>。</p>
      </section>

      <section className="section">
        <div className="section-title"><span>06 / FIFTEEN RUNS</span><h2>平均值背后的十五条轨迹</h2></div>
        <div className="run-grid">{data.runs.map((run) => <article key={run.id} className={run.condition}><div><span>{data.conditions[run.condition].label}</span><h3>{run.id}</h3><b>{scoreText(run)}</b></div><dl><div><dt>墙钟</dt><dd>{fmtDuration(run.wallSeconds)}</dd></div><div><dt>Token</dt><dd>{fmtTokens(run.tokenSummary.total)}</dd></div><div><dt>首次改产品</dt><dd>+{fmtDuration(run.firstMutationSeconds)}</dd></div><div><dt>Operator</dt><dd>{run.operatorTurns}</dd></div><div><dt>需求 Q</dt><dd>{run.designQuestions ?? "—"}</dd></div><div><dt>设计轮数</dt><dd>{run.designApprovalRounds ?? "—"}</dd></div><div><dt>Review / 修复</dt><dd>{run.reviewRounds} / {run.reviewFixRounds}</dd></div><div><dt>Reviewer</dt><dd>{run.reviewerTurns}</dd></div><div><dt>设计获批</dt><dd>{checkpointText(run.designApprovedAt)}</dd></div><div><dt>首个 Review Ready</dt><dd>{checkpointText(run.firstReviewReadyAt)}</dd></div><div><dt>Review 通过</dt><dd>{checkpointText(run.reviewApprovedAt)}</dd></div><div><dt>Tool calls</dt><dd>{run.toolCalls}</dd></div><div><dt>scoreN</dt><dd>{run.scoreN ?? "—"}</dd></div><div><dt>状态</dt><dd>{run.status}</dd></div></dl></article>)}</div>
      </section>

      <section className="section findings">
        <div className="section-title"><span>07 / WHAT THIS CAN SHOW</span><h2>这是机制比较，不是第三臂因果结论</h2></div>
        <div className="finding-grid"><article><b>01</b><h3>需求闭环确实增加了前置轮次</h3><p>Requirement Loop 三条分别经历 5、4、4 次设计审批请求；对应的 operator 问题数为 1、2、2，首次产品修改都发生在 DESIGN_APPROVED 之后。</p></article><article><b>02</b><h3>Review Loops 的实际轮数并不固定</h3><p>当前 canonical 数据中 loop-01 经历 1 轮 reviewer、loop-04/06 各 2 轮；rerun 的首轮没有 critical/major，仅保留 1 个 minor，因此按 gate 直接通过。</p></article><article><b>03</b><h3>成本要分均值与 pooled</h3><p>页面以 per-run 平均占比为主，pooled totals 只显示绝对总体；Review Loops 的 reviewer token 计入其 treatment。</p></article><article><b>04</b><h3>替换后的 ΔFeedback 只能描述</h3><p>更新后的 pair-level 值为 +4.00、−1.50、+3.00，均值 +1.83；其中 pair-01 来自 posthoc rerun，不把它当作完整同期随机效果。</p></article></div>
      </section>

      <section className="section boundary" id="boundary">
        <div className="section-title"><span>08 / EVIDENCE BOUNDARY</span><h2>原始事实与派生判断分开看</h2></div>
        <div className="boundary-grid"><div><h3>原始 rollout 事实</h3><ul><li>session parent / child 树与 actor role</li><li>UTC timestamp 与工具动作</li><li><code>last_token_usage</code> 单次调用增量</li><li>operator turn、focused-test log 与最终状态</li></ul></div><div><h3>分类器派生</h3><ul>{data.audit.boundaries.map((item) => <li key={item}>{item}</li>)}</ul></div><aside><span>FORK DEDUPE</span><b>−{data.audit.inheritedForkTokensRemoved.toLocaleString("en-US")} token</b><p>{data.audit.note}</p></aside></div>
      </section>

      <footer><span>Workflow Arena · 5 local methods + external Luna panel</span><span className="footer-links"><a href="/luna-panel">Luna 横评</a><a href="https://github.com/luobosibing2/superpowers-workflow-evaluation">源码</a><a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/blob/main/docs/report.md">报告</a><a href="https://github.com/luobosibing2/superpowers-slim">Superpowers Slim</a><a href="https://github.com/luobosibing2/superpowers-slim/commit/fa07307f3dbf7822fb3077587fbde649b0aa66ed">已测 fa07307f</a></span><span>Native rollouts · Asia/Shanghai · generated {new Date(data.generatedAt).toLocaleString("zh-CN", { timeZone: "Asia/Shanghai" })}</span></footer>
    </main>
  );
}
