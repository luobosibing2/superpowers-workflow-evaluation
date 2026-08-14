import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request(`http://localhost${path}`, { headers: { accept: "text/html" } }), {
    ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) },
  }, { waitUntil() {}, passThroughOnException() {} });
}

test("server-renders all five groups and fifteen runs", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<html lang="zh-CN">/i);
  assert.match(html, /<title>Workflow Arena 工作流评测<\/title>/i);
  assert.match(html, /Full With/);
  assert.match(html, /Slim With/);
  assert.match(html, /Requirement Loop/);
  assert.match(html, /Requirement \+ Review Loops/);
  assert.match(html, /Without/);
  assert.match(html, /slim-01/);
  assert.match(html, /slim-03/);
  assert.match(html, /run-01/);
  assert.match(html, /run-06/);
  assert.match(html, /81\.67 · 83\.17 · 97\.67 · 99\.50 · 99\.00/);
  assert.match(html, /ΔFeedback/);
  assert.match(html, /loop-01/);
  assert.match(html, /loop-06/);
  assert.match(html, /\+1\.83/);
  assert.match(html, /posthoc rerun/);
  assert.match(html, /本次追加/);
  assert.match(html, /714,362/);
  assert.match(html, /三个问题，三条可审计证据链/);
  assert.match(html, /Full Superpowers 相比较原生 Codex/);
  assert.match(html, /Verified verdict/);
  assert.match(html, /需求闭环和定向代码审查/);
  assert.match(html, /Superpowers 新增 token 主要花在/);
  assert.match(html, /三条 Full 都进入 98–100 分/);
  assert.match(html, /最大的质量跃升发生在/);
  assert.match(html, /95\.3% 的新增量表现为 cached input/);
  assert.match(html, /coordinate/);
  assert.match(html, /cached input/);
  assert.match(html, /14\.50/);
  assert.match(html, /97\.67/);
  assert.match(html, /需求上下文不完整的 CLI 任务/);
  assert.match(html, /打开完整场景分析/);
  assert.match(html, /coordination-definition/);
  assert.match(html, /https:\/\/github\.com\/luobosibing2\/superpowers-workflow-evaluation/);
  assert.match(html, /https:\/\/github\.com\/luobosibing2\/superpowers-slim/);
  assert.match(html, /fa07307f/);
  assert.match(html, /五种工作流，八个真实任务/);
  assert.match(html, /href="\/luna-panel"/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape|react-loading-skeleton/i);
});

test("generated data encodes the five-group descriptive boundary", async () => {
  const [generated, page, layout, hosting] = await Promise.all([
    readFile(new URL("../app/trajectory-data.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../.openai/hosting.json", import.meta.url), "utf8"),
  ]);
  assert.equal((generated.match(/"id": "(?:run|slim|loop)-\d\d"/g) ?? []).length, 15);
  assert.equal((generated.match(/"scoreN": 2/g) ?? []).length, 15);
  assert.match(generated, /"scoreStatus": "supplemental-posthoc-blind-judged"/);
  assert.doesNotMatch(generated, /"score": null/);
  assert.match(generated, /"scoreMean": 83\.16666666666667/);
  assert.match(generated, /"inheritedForkTokenRecordsRemoved": 20/);
  assert.match(generated, /loop-01 后由独立 rerun 替换 canonical score\/trajectory/);
  assert.match(generated, /"scoreMean": 99\.5/);
  assert.match(generated, /"scoreStatus": "posthoc-rerun-replacement-blind-judged"/);
  assert.match(generated, /"reviewer":/);
  assert.match(generated, /"scoreN": 2/);
  assert.match(generated, /"research":/);
  assert.match(generated, /"estimatedCreditsMean": 182\.96706266666664/);
  assert.match(generated, /"verifiedVerdicts": 3/);
  assert.match(generated, /"fullyVerifiedRuns": 1/);
  assert.match(generated, /"deltaTokens": 5234854\.333333333/);
  assert.match(generated, /"shareOfDelta": 0\.9528091008365346/);
  assert.match(page, /wallShareMean/);
  assert.match(page, /laneTimeline/);
  assert.match(page, /requirementLoop/);
  assert.match(page, /reviewLoops/);
  assert.match(page, /ScoreResourceChart/);
  assert.match(page, /AcceptanceChart/);
  assert.match(page, /TokenAttributionChart/);
  assert.match(layout, /\/og\.png/);
  assert.match(hosting, /"project_id"/);
  assert.doesNotMatch(generated, /rollout-.*\.jsonl|\/Users\/|\/var\/folders\//);
  await access(new URL("../public/og.png", import.meta.url));
  await assert.rejects(access(new URL("../app/_sites-preview", import.meta.url)));
});

test("scenario and per-condition pages expose the task analysis", async () => {
  const taskResponse = await render("/task");
  assert.equal(taskResponse.status, 200);
  const taskHtml = await taskResponse.text();
  assert.match(taskHtml, /需求上下文不完整/);
  assert.match(taskHtml, /原始需求摘要/);
  assert.match(taskHtml, /字段分页/);
  assert.match(taskHtml, /Without/);
  assert.match(taskHtml, /独立实验页/);
  assert.match(taskHtml, /四方法提交 fa07307f/);

  const experimentResponse = await render("/experiments/without");
  assert.equal(experimentResponse.status, 200);
  const experimentHtml = await experimentResponse.text();
  assert.match(experimentHtml, /原生直接执行/);
  assert.match(experimentHtml, /focused Go tests/);
  assert.match(experimentHtml, /32\.7/);
  assert.match(experimentHtml, /coordinate/);
});

test("Luna panel renders the Workflow Arena five-workflow evidence", async () => {
  const [publishedData, siteData] = await Promise.all([
    readFile(new URL("../../data/luna-skill-panel-v1/capability-task-score-matrix.json", import.meta.url), "utf8"),
    readFile(new URL("../app/luna-panel-data.json", import.meta.url), "utf8"),
  ]);
  assert.equal(siteData, publishedData);
  const response = await render("/luna-panel");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /WORKFLOW ARENA/);
  assert.match(html, /五种技能工作流/);
  assert.match(html, />120</);
  assert.match(html, />240</);
  assert.match(html, /Grill Me/);
  assert.match(html, /Superpowers Full/);
  assert.match(html, /MatrixSpec L0/);
  assert.match(html, /OpenSpec core/);
  assert.match(html, /Ponytail/);
  assert.match(html, /92\.14/);
  assert.match(html, /89\.64/);
  assert.match(html, /23\/24/);
  assert.match(html, /completed \/ protocol-failed \/ token-limit/);
  assert.match(html, /1\.602B/);
  assert.match(html, /没有同期 Bare/);
  assert.doesNotMatch(html, /EXTERNAL PANEL|EVIDENCE BOUNDARY|现在可以验证|仍然不能验证|来源固定|来源仓|raw sessions|repository license|cyijun\/workflow-arena/i);
});
