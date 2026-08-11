import { trajectoryData as data } from "../trajectory-data";
import Link from "next/link";

const methods = ["without", "slim", "requirementLoop", "reviewLoops", "with"] as const;

const methodAnalysis = {
  without: {
    title: "原生直接执行",
    route: "探索现有实践 → 修改产品 → focused test / 调试 → 交付",
    description: "候选没有被要求先做 GT 澄清或写计划，主要依靠公开 prompt、仓库现状和自己的判断补规格。这里不是“完全不测试”：三条 run 都留下 focused-test 日志；只是没有独立需求审批，也没有独立 reviewer 闭环。",
    missing: "容易把字段分页、flag 冲突、歧义诊断、按 field ID 对齐和多值渲染等隐藏边界当成实现细节，而不是先列为行为契约。",
  },
  slim: {
    title: "Slim：一次澄清 + Plan-on",
    route: "brainstorming → 一次 Operator 问答 → writing-plans → 同一 session 实施 / debug / verify",
    description: "它把一次外部行为澄清和计划前置，但不强制 Full 的 spec commit、TDD、子代理或独立 review；之后由同一 Codex session 原生完成。",
    missing: "比 Without 多一个需求入口，但并不保证会循环追问到所有字段边界都获批。",
  },
  requirementLoop: {
    title: "Requirement Loop：多轮设计获批",
    route: "探索 → OPERATOR_QUESTION / ANSWER 循环 → DESIGN_REVIEW_REQUEST → DESIGN_APPROVED → plan → 实施",
    description: "candidate 不能在设计获批前修改产品；operator 只补充外部可观察行为、指出遗漏或标记 implementation-defined，不提供代码、路径或实现架构。",
    missing: "把隐含规格变成明确的行为设计，重点覆盖 flag 冲突、名称 / ID 解析、分页安全、值渲染与失败时不输出误导性结果。",
  },
  reviewLoops: {
    title: "Requirement + Review Loops：需求闭环再加独立反馈",
    route: "同 Requirement Loop → REVIEW_READY → reviewer findings → 修复 / 重测 → REVIEW_APPROVED → final verify",
    description: "独立 reviewer 只看公开任务、获批设计、问答、当前 diff、测试日志和必要 baseline；看不到 hidden contract、rubric、oracle、condition 或其他轨迹。",
    missing: "把“已经理解需求”与“当前代码确实满足获批设计”分开检查；本次 canonical 轮数是 1、2、2，而不是固定一次。",
  },
  with: {
    title: "Full Superpowers：完整复合流程",
    route: "brainstorming / spec → writing-plans → 任务拆分 / 多代理 → TDD / 实现 → 多层 review / 修复 → verification",
    description: "Full 是技能驱动的复合 treatment，不是单独某一个 skill。它把设计、计划、子代理协调、独立 review 和完成验证都纳入同一条流程；轮数由实际轨迹决定。",
    missing: "资源显著增加，且 run-02 在 token cap 截止却拿到 100 分，说明产品分、流程依从性和隐藏验收代理必须分开读。",
  },
} as const;

function fmtTokens(value: number) {
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(2)}M` : `${Math.round(value / 1_000)}K`;
}

function fmtSeconds(value: number) {
  const minutes = Math.floor(value / 60);
  return `${minutes}:${String(Math.round(value % 60)).padStart(2, "0")}`;
}

export default function TaskPage() {
  return (
    <main className="detail-page">
      <header className="detail-hero">
        <nav><Link href="/" className="brand">WA / TRACE 09</Link><div><Link href="/">首页</Link><Link href="/luna-panel">Luna 横评</Link><a href="#brief">需求</a><a href="#paths">作业路径</a><a href="#comparison">比较</a></div></nav>
        <div className="detail-hero-copy"><span>SCENARIO 01 · TASK ANALYSIS</span><h1>需求上下文不完整，<em>CLI 行为必须自己补齐。</em></h1><p>这不是抽象的“插件好不好”问题，而是一个公开目标明确、隐藏行为规格分散在 contract 里的 GitHub CLI 改动任务。</p></div>
      </header>

      <section className="detail-section" id="brief">
        <div className="detail-kicker">01 / 原始需求摘要</div>
        <h2>公开 prompt 说了什么？还没说什么？</h2>
        <div className="brief-grid"><blockquote>改进 <code>gh project item-list</code>，让用户不用先查 opaque field ID，就能通过可读字段名选择额外表格列；同时支持等价的重复 <code>--field-id</code> 形式，保持既有用法兼容，错误必须可行动，最后在本地完成验证。</blockquote><div><h3>中文摘要</h3><p>用户要的是“给项目 item-list 增加可选字段列”。真正需要补齐的不是一个 flag，而是从解析、查询、分页、按 ID 映射，到各种 GitHub Project 字段值渲染的一整条行为链。</p><p>公开 prompt 还要求候选不要联网、不要恢复上游历史、只把当前仓库当工作区；如果需要产品信息，必须以 <code>OPERATOR_QUESTION</code> 结束。</p></div></div>
        <div className="contract-grid"><article><b>输入与兼容</b><p><code>--field</code> 可重复且保持请求顺序；<code>--field-id</code> 等价；二者不可混用，和显式 JSON / formatted 输出冲突。</p></article><article><b>解析与诊断</b><p>名称大小写不敏感；显示 canonical name；未知或歧义选择要列出可行动的候选和稳定的 ID。</p></article><article><b>查询与分页</b><p>正常路径复用 item-list 已返回的 field definitions；只有需要且还有下一页时才补齐连接；失败不能先打印误导性半张表。</p></article><article><b>值与安全</b><p>按 field node ID 对齐；文本、数字、select、date、iteration、milestone、labels、PR、users 等都要人类可读，CR/LF 不能破坏表格。</p></article></div>
      </section>

      <section className="detail-section" id="paths">
        <div className="detail-kicker">02 / 五条实际作业路径</div>
        <h2>同一场景，不同方法把时间花在哪里？</h2>
        <p className="detail-intro">下表先给可审计的 per-run 均值，再解释每条路径实际增加了什么。点击方法名可打开该实验的独立页面。</p>
        <div className="path-list">{methods.map((condition) => { const group = data.groups[condition]; const analysis = methodAnalysis[condition]; return <article className={`path-card ${condition}`} key={condition}><div className="path-card-head"><div><span>{data.conditions[condition].label}</span><h3>{analysis.title}</h3></div><Link href={`/experiments/${condition}`}>独立实验页 →</Link></div><p className="path-route">{analysis.route}</p><dl><div><dt>盲评分</dt><dd>{group.scoreMean?.toFixed(2)}</dd></div><div><dt>tool calls / 条</dt><dd>{group.toolCallsMean.toFixed(1)}</dd></div><div><dt>dedup token / 条</dt><dd>{fmtTokens(group.tokenMean)}</dd></div><div><dt>墙钟 / 条</dt><dd>{fmtSeconds(group.wallMeanSeconds)}</dd></div></dl><p>{analysis.description}</p><p><b>对需求覆盖的影响：</b>{analysis.missing}</p></article>; })}</div>
      </section>

      <section className="detail-section" id="comparison">
        <div className="detail-kicker">03 / 直接比较</div>
        <h2>差异不是“有没有写代码”，而是“什么时候把行为契约显式化”</h2>
        <div className="comparison-table"><div className="comparison-row comparison-header"><b>观察点</b><b>Without</b><b>Superpowers treatment</b><b>结果证据</b></div><div className="comparison-row"><b>需求信息</b><span>公开 prompt + 仓库探索，未强制 GT 闭环</span><span>一次或多轮 operator 澄清；Full 还形成 spec / design / plan</span><span>Requirement Loop 97.67，Without 81.67</span></div><div className="comparison-row"><b>实现反馈</b><span>测试 / 调试留在主 session，没独立 reviewer gate</span><span>Review Loops 独立 reviewer 循环；Full 还带多层 review / 修复</span><span>Review Loops 99.50；Full 99.00</span></div><div className="comparison-row"><b>资源结构</b><span>root 为主，平均 32.7 tool calls / 2.08M token</span><span>Full 有 child、guardian、operator 与大量 coordination</span><span>Full 244 tool calls / 15.87M token；coordinate 是最大增量阶段</span></div><div className="comparison-row"><b>隐藏验收</b><span>0/6 strict Verified verdict</span><span>Full 3/6，Review Loops 4/6；完全双判定通过均为 1/3 run</span><span>高分不等于可靠的二元验收通过</span></div></div>
      </section>

      <section className="detail-section detail-evidence">
        <div className="detail-kicker">04 / 证据与边界</div>
        <h2>这页的结论从哪里来？</h2>
        <ul><li>公开 prompt / hidden contract / rubric：新仓库的 <a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/tree/main/experiments/five-method">冻结实验输入</a>。</li><li>每条轨迹的时间、阶段、actor、去 fork token：<a href="https://github.com/luobosibing2/superpowers-workflow-evaluation/tree/main/results">15 条 canonical results</a> 中的 compact trajectory；原始 actor homes 和完整 JSONL 不公开。</li><li>盲评分和 Verified 代理：每条 run 两份 <code>judge.final.json</code>；Verified 不是协议定义的独立 integration gate。</li><li>阶段标签是分类器派生。尤其 coordinate 只表示可见的派发、等待、follow-up、审批、guardian/worktree 等过程动作，不是服务端直接给出的语义 token 归因。</li><li>Slim treatment 固定于 <a href="https://github.com/luobosibing2/superpowers-slim/commit/fa07307f3dbf7822fb3077587fbde649b0aa66ed">四方法提交 fa07307f</a>；后续五方法版本新增的 <code>code-review</code> 不属于本次 treatment。</li></ul><Link className="detail-button" href="/">返回首页看三条核心问题 →</Link>
      </section>
    </main>
  );
}
