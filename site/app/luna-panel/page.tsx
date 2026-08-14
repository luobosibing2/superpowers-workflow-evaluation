import Link from "next/link";
import panelData from "../luna-panel-data.json";

const repositoryRoot = "https://github.com/luobosibing2/superpowers-workflow-evaluation";

const tasks = [
  { key: "cli_item_list_fields", short: "CLI fields", label: "GitHub CLI 字段列" },
  { key: "eslint_preserve_caught_error", short: "ESLint", label: "ESLint caught error" },
  { key: "pytest_plugin_entry_points", short: "pytest plugin", label: "pytest 插件入口" },
  { key: "pytest_addini_type_expressions", short: "pytest addini", label: "pytest addini 类型" },
  { key: "bat_sanitize", short: "bat sanitize", label: "bat 路径清洗" },
  { key: "sqlmodel_field_constraints", short: "SQLModel", label: "SQLModel 字段约束" },
  { key: "axum_custom_executor", short: "Axum", label: "Axum executor" },
  { key: "prometheus_utf8_negotiation", short: "Prometheus", label: "Prometheus UTF-8" },
] as const;

const workflowMeta = {
  "mattpocock-grill-me": { id: "grill", name: "Grill Me", eyebrow: "需求决策循环", color: "#d85b77" },
  "superpowers-6.1.1": { id: "superpowers", name: "Superpowers Full", eyebrow: "完整 SDLC workflow", color: "#7957d5" },
  "matrixspec-profiled-f7c4911": { id: "matrix", name: "MatrixSpec L0", eyebrow: "状态机 + 独立 reviewer", color: "#d58b29" },
  "fission-openspec": { id: "openspec", name: "OpenSpec core", eyebrow: "proposal → apply", color: "#0e9aaa" },
  "ponytail-16f2980": { id: "ponytail", name: "Ponytail", eyebrow: "单体完整规则集", color: "#3274dc" },
} as const;

function leadingCount(value: string) {
  return Number(value.split("/")[0]);
}

const workflows = panelData.matrix.map((raw) => {
  const row = raw as unknown as Record<string, string | number | null>;
  const capability = String(row.capability) as keyof typeof workflowMeta;
  const meta = workflowMeta[capability];
  if (!meta) throw new Error(`Unknown Luna workflow capability: ${capability}`);
  return {
    ...meta,
    score: Number(row.macro_mean),
    completed: leadingCount(String(row.workflow_completed)),
    tests: leadingCount(String(row.focused_tests_passed)),
    minutes: Number(row.avg_minutes_per_run),
    tokens: Number(row.avg_candidate_tokens_m_per_run),
    credits: Number(row.avg_terra_equivalent_credits_per_run),
    decisions: Number(row.avg_operator_decisions_per_run),
    scores: tasks.map((task) => Number(row[task.key])),
  };
}).sort((left, right) => right.score - left.score);

function fmt(value: number) {
  return Number.isInteger(value) ? value.toFixed(0) : value.toFixed(2);
}

function fmtLargeTokens(value: number) {
  return value >= 1_000_000_000 ? `${(value / 1_000_000_000).toFixed(3)}B` : `${(value / 1_000_000).toFixed(2)}M`;
}

export default function LunaPanelPage() {
  const maxTokens = Math.max(...workflows.map((workflow) => workflow.tokens));
  const maxMinutes = Math.max(...workflows.map((workflow) => workflow.minutes));

  return (
    <main className="luna-page">
      <header className="detail-hero luna-hero" id="top">
        <nav>
          <Link href="/" className="brand">WA / TRACE 09</Link>
          <div><a href="#answer">结论</a><a href="#matrix">任务矩阵</a><a href="#grill">Grill Me</a><a href="#runs">运行状态</a><a href={repositoryRoot}>源码</a></div>
        </nav>
        <div className="detail-hero-copy luna-hero-copy">
          <span>WORKFLOW ARENA · LUNA/HIGH · 5 WORKFLOWS · 8 TASKS</span>
          <h1>同一批任务，<br /><em>五种技能工作流。</em></h1>
          <p>这是 Workflow Arena 的 Luna 五工作流、八任务横评面板：比较产品分、精确测试、workflow 完成率和候选侧资源，把五种方法放在同一组任务尺度上观察。</p>
          <div className="luna-method-strip"><span>WORKFLOW ARENA</span><span>候选 Luna/high</span><span>Operator + Judge Terra/high</span><span>每格 n=3</span></div>
        </div>
        <div className="metrics luna-metrics">
          <div className="metric"><span>候选运行</span><strong>{panelData.runs}</strong><p>5 workflows × 8 tasks × 3</p></div>
          <div className="metric"><span>自动盲评分</span><strong>{panelData.blindJudgments}</strong><p>每条 run 两个 score</p></div>
          <div className="metric"><span>Focused tests</span><strong>{panelData.focusedTestsPassed} / {panelData.runs}</strong><p>compact 表中的通过标志</p></div>
          <div className="metric"><span>终态</span><strong>{panelData.statusCounts.completed} · {panelData.statusCounts["protocol-failed"]} · {panelData.statusCounts["token-limit"]}</strong><p>completed / protocol-failed / token-limit</p></div>
        </div>
      </header>

      <section className="section luna-answer" id="answer">
        <div className="section-title split"><div><span>01 / DIRECT ANSWER</span><h2>Grill Me 当前领跑，但这不是“通用冠军”证明</h2></div><p>宏均分是八个 task cell 等权平均；每格只有三条。</p></div>
        <div className="luna-answer-grid">
          <article className="luna-primary-finding"><span>质量 / 成本同时看</span><strong>92.14</strong><h3>Grill Me · 23/24 tests</h3><p>平均 5.85M candidate token、18.50 分钟；在当前面板中分数与精确测试通过数最高。</p></article>
          <article><b>Full 不是最高分</b><p>Superpowers Full 为 89.64、21/24 tests，但平均 32.99M token 和 48.38 分钟，约为 Grill Me 的 5.64× token、2.62× 时间。</p></article>
          <article><b>流程完成不能被分数替代</b><p>MatrixSpec L0 得分 86.71、19/24 tests，但 workflow 只完成 11/24；协议失败必须单列。</p></article>
          <article><b>没有同期 Bare</b><p>该面板不能回答“相比原生 Luna 提升多少”，也不能与本站 Terra 单任务五组直接相减。</p></article>
        </div>
      </section>

      <section className="section luna-ranking" id="ranking">
        <div className="section-title"><span>02 / QUALITY × COST</span><h2>五种工作流的发布结果</h2><p>Score、tests 和 workflow completion 是不同终点；token、时间和 credits 只描述候选侧计算负担。</p></div>
        <div className="luna-rank-list">
          {workflows.map((workflow, index) => (
            <article key={workflow.id}>
              <div className="luna-rank-id"><span>{String(index + 1).padStart(2, "0")}</span><i style={{ background: workflow.color }} /></div>
              <div className="luna-rank-name"><small>{workflow.eyebrow}</small><h3>{workflow.name}</h3><p>{workflow.completed}/24 workflow · {workflow.tests}/24 tests · {workflow.decisions.toFixed(2)} operator decisions/run</p></div>
              <div className="luna-score"><span>宏均分</span><b>{workflow.score.toFixed(2)}</b></div>
              <div className="luna-mini-bars">
                <div><span>Token</span><i><b style={{ width: `${workflow.tokens / maxTokens * 100}%`, background: workflow.color }} /></i><strong>{workflow.tokens.toFixed(2)}M</strong></div>
                <div><span>时间</span><i><b style={{ width: `${workflow.minutes / maxMinutes * 100}%`, background: workflow.color }} /></i><strong>{workflow.minutes.toFixed(2)}m</strong></div>
                <div><span>Credits</span><i><b style={{ width: `${workflow.credits / 324.64 * 100}%`, background: workflow.color }} /></i><strong>{workflow.credits.toFixed(2)}</strong></div>
              </div>
            </article>
          ))}
        </div>
      </section>

      <section className="section luna-matrix-section" id="matrix">
        <div className="section-title split"><div><span>03 / TASK MATRIX</span><h2>不是每个任务都有相同排序</h2></div><p>每个单元格是三条 run 的 mean score，再按八个任务等权求宏均分。</p></div>
        <div className="luna-table-wrap">
          <table className="luna-matrix">
            <thead><tr><th>Workflow</th>{tasks.map((task) => <th key={task.key} title={task.label}>{task.short}</th>)}<th>Macro</th></tr></thead>
            <tbody>{workflows.map((workflow) => <tr key={workflow.id}><th><i style={{ background: workflow.color }} />{workflow.name}</th>{workflow.scores.map((score, index) => <td key={tasks[index].key}><span style={{ opacity: Math.max(.35, score / 100) }}>{fmt(score)}</span></td>)}<td><strong>{workflow.score.toFixed(2)}</strong></td></tr>)}</tbody>
          </table>
        </div>
        <div className="luna-task-notes">
          <p><b>稳定高分区：</b>CLI、pytest plugin 与 Axum 上，多数 workflow 都能达到较高分；流程差异更容易体现在资源和完成状态。</p>
          <p><b>分化区：</b>ESLint 和 Prometheus 上差距最大。Grill Me 的 ESLint 为 99.67，但 Prometheus 仍只有 70.83；单一宏均分会隐藏任务敏感性。</p>
        </div>
      </section>

      <section className="section luna-grill" id="grill">
        <div className="section-title"><span>04 / WHAT IS GRILL ME</span><h2>本体很小，实验 treatment 比 Skill 本身更完整</h2></div>
        <div className="luna-grill-grid">
          <article><span>01</span><h3><code>/grill-me</code> wrapper</h3><p>显式入口，原始内容只是启动一个 <code>/grilling</code> session；它禁止模型自动调用。</p></article>
          <article><span>02</span><h3><code>grilling</code> primitive</h3><p>沿决策树一次问一个问题，每题给推荐答案；可查事实自己探索，产品决策交给用户。</p></article>
          <article><span>03</span><h3>Workflow Arena adapter</h3><p>强制 operator marker、多轮 GT 回答和实施前共享理解审批；批准后才允许原生实现与验证。</p></article>
        </div>
        <div className="luna-flow"><i>探索事实</i><b>→</b><i>一次一个决策</i><b>→</b><i>Operator 回答</i><b>→</b><i>共享理解获批</i><b>→</b><i>单 Agent 实现 / 验证</i></div>
        <p className="notice">它没有 Full Superpowers 的正式 spec、writing-plans、TDD、任务拆分、子代理实施或独立 review loop。当前结果测量的是“两个窄 Skill + harness 强制的 GT 决策闭环”，不能归因于一行 prompt。</p>
      </section>

      <section className="section luna-runs" id="runs">
        <div className="section-title"><span>05 / EXECUTION STATUS</span><h2>产品质量、精确测试和协议可靠性必须并列</h2></div>
        <div className="luna-status-grid">
          <article className="completed"><strong>{panelData.statusCounts.completed}</strong><span>workflow completed</span><i style={{ width: `${panelData.statusCounts.completed / panelData.runs * 100}%` }} /></article>
          <article className="failed"><strong>{panelData.statusCounts["protocol-failed"]}</strong><span>protocol failed</span><i style={{ width: `${panelData.statusCounts["protocol-failed"] / panelData.runs * 100}%` }} /></article>
          <article className="capped"><strong>{panelData.statusCounts["token-limit"]}</strong><span>token limit</span><i style={{ width: `${panelData.statusCounts["token-limit"] / panelData.runs * 100}%` }} /></article>
          <article className="tested"><strong>{panelData.focusedTestsPassed}</strong><span>focused-test flags passed</span><i style={{ width: `${panelData.focusedTestsPassed / panelData.runs * 100}%` }} /></article>
        </div>
        <div className="luna-role-grid">
          <div><span>Candidate + subagents</span><b>{fmtLargeTokens(panelData.roleTokens.candidate_and_subagents.tokens)}</b><small>{fmtLargeTokens(panelData.roleTokens.candidate_and_subagents.tokensPerUnit)} token / run</small></div>
          <div><span>GT operator</span><b>{fmtLargeTokens(panelData.roleTokens.ground_truth_operator.tokens)}</b><small>{fmtLargeTokens(panelData.roleTokens.ground_truth_operator.tokensPerUnit)} token / run</small></div>
          <div><span>Matrix reviewer</span><b>{fmtLargeTokens(panelData.roleTokens.matrix_reviewer.tokens)}</b><small>{panelData.roleTokens.matrix_reviewer.units} reviewer units</small></div>
          <div><span>Blind judges</span><b>{fmtLargeTokens(panelData.roleTokens.blind_judge.tokens)}</b><small>{panelData.roleTokens.blind_judge.units} judgments</small></div>
        </div>
        <div className="luna-failure-note"><b>MatrixSpec 的 12 条协议失败</b><p>9 条是独立 reviewer 修改产品文件，另有 review 尝试耗尽、无效 stage verdict、以及 review 前创建 full baseline 文档各 1 条。报告保留这些失败，没有用高盲评分覆盖流程终态。</p></div>
      </section>

      <footer><span>Workflow Arena · Luna workflow panel · 120 runs</span><span className="footer-links"><Link href="/">本站五方法实验</Link><a href={repositoryRoot}>源码</a><a href="https://github.com/luobosibing2/superpowers-slim">Superpowers Slim</a></span><span>Workflow Arena · 5 workflows · 8 tasks</span></footer>
    </main>
  );
}
