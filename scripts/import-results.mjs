#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "..");
const sourceRoot = resolve(process.argv[2] || join(repositoryRoot, "..", "workflow-arena"));

const mappings = [
  ["without", "run-01", "forced-bootstrap-v9-macos", "Candidate-E", null],
  ["without", "run-04", "forced-bootstrap-v9-macos", "Candidate-C", null],
  ["without", "run-05", "forced-bootstrap-v9-macos", "Candidate-F", null],
  ["slim", "slim-01", "slim-plan-on-v9-macos", "Candidate-B", null],
  ["slim", "slim-02", "slim-plan-on-v9-macos", "Candidate-A", null],
  ["slim", "slim-03", "slim-plan-on-v9-macos", "Candidate-C", null],
  ["requirement-loop", "loop-02", "slim-loops-v9-macos", "Candidate-D", "pair-01"],
  ["requirement-loop", "loop-03", "slim-loops-v9-macos", "Candidate-E", "pair-02"],
  ["requirement-loop", "loop-05", "slim-loops-v9-macos", "Candidate-B", "pair-03"],
  ["requirement-review-loops", "loop-01", "slim-loops-v9-macos-rerun-loop01", "Candidate-A", "pair-01"],
  ["requirement-review-loops", "loop-04", "slim-loops-v9-macos", "Candidate-C", "pair-02"],
  ["requirement-review-loops", "loop-06", "slim-loops-v9-macos", "Candidate-A", "pair-03"],
  ["full", "run-02", "forced-bootstrap-v9-macos", "Candidate-D", null],
  ["full", "run-03", "forced-bootstrap-v9-macos", "Candidate-B", null],
  ["full", "run-06", "forced-bootstrap-v9-macos", "Candidate-A", null],
].map(([condition, run, capsule, candidate, pair]) => ({ condition, run, capsule, candidate, pair }));

const expectedMeans = {
  without: 81.6667,
  slim: 83.1667,
  "requirement-loop": 97.6667,
  "requirement-review-loops": 99.5,
  full: 99,
};

function readJson(path) { return JSON.parse(readFileSync(path, "utf8")); }
function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}
function sha256(path) { return createHash("sha256").update(readFileSync(path)).digest("hex"); }
function copy(source, target) { mkdirSync(dirname(target), { recursive: true }); copyFileSync(source, target); }
function capsulePath(name) { return join(sourceRoot, "reproductions", name); }
function publicPath(...parts) { return join(repositoryRoot, ...parts); }
function sourcePath(mapping, ...parts) { return join(capsulePath(mapping.capsule), ...parts); }

function sanitizeString(value) {
  return value
    .replaceAll(/\/Users\/[^/\s)]+\/code\/CCB\/workflow-arena\/reproductions\/[^/\s)]+\//g, "")
    .replaceAll(/\/Users\/[^/\s)]+/g, "<local-user>")
    .replaceAll(/\/private\/var\/[^\s)]+/g, "<local-temp>")
    .replaceAll(/\/var\/folders\/[^\s)]+/g, "<local-temp>");
}

function sanitize(value) {
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === "object") {
    const output = {};
    for (const [key, nested] of Object.entries(value)) {
      if (/threadid|rollout|sessionfile/i.test(key)) continue;
      output[key] = sanitize(nested);
    }
    return output;
  }
  return typeof value === "string" ? sanitizeString(value) : value;
}

function readJsonLines(path) {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean).map(line => sanitize(JSON.parse(line)));
}

function readTrajectorySnapshot() {
  const path = join(sourceRoot, "reproductions", "forced-bootstrap-v9-macos", "trajectory-comparison", "app", "trajectory-data.ts");
  let text = readFileSync(path, "utf8");
  text = text.replace(/^\/\*[^]*?\*\/\s*/, "").replace(/^export const trajectoryData = /, "").replace(/ as const;\s*$/, "");
  return JSON.parse(text);
}

function compactTrajectory(run) {
  let evidenceIndex = 0;
  const scrubInterval = interval => {
    const sourceEvidenceCount = Array.isArray(interval.evidence) ? interval.evidence.length : 0;
    const { evidence: _evidence, ...rest } = interval;
    evidenceIndex += 1;
    return { ...rest, evidenceId: `event-${String(evidenceIndex).padStart(3, "0")}`, sourceEvidenceCount };
  };
  return {
    schemaVersion: 1,
    source: "derived from native Codex timestamps and last_token_usage; inherited fork prefixes removed",
    classifierBoundary: "stage labels and interval boundaries are derived; actor role, tool use, timestamps, and token usage are source facts",
    ...run,
    wallTimeline: run.wallTimeline.map(scrubInterval),
    laneTimeline: run.laneTimeline.map(scrubInterval),
  };
}

function metricsRow(mapping) {
  const metricsPath = sourcePath(mapping, "reports", "metrics.json");
  const effectivePath = existsSync(metricsPath)
    ? metricsPath
    : join(capsulePath("slim-loops-v9-macos"), "reports", "metrics.json");
  const metrics = readJson(effectivePath);
  const row = metrics.runs.find(item => item.run_id === mapping.run);
  if (!row) throw new Error(`Missing metrics row for ${mapping.capsule}/${mapping.run}`);
  return sanitize(row);
}

function verdictScore(verdict) {
  const candidates = [verdict.score, verdict.totalScore, verdict.total_score, verdict.total, verdict.overall_score];
  const value = candidates.find(item => typeof item === "number");
  if (typeof value !== "number") throw new Error("Verdict has no numeric total score");
  return value;
}

const trajectory = readTrajectorySnapshot();
const manifestRuns = [];
const metricsRuns = [];

for (const mapping of mappings) {
  const target = publicPath("results", mapping.condition, mapping.run);
  const runSource = sourcePath(mapping, "runs", mapping.run);
  copy(join(runSource, "tests.log"), join(target, "tests.log"));
  copy(join(runSource, "product-code.diff"), join(target, "product.diff"));
  writeJson(join(target, "state.json"), sanitize(readJson(join(runSource, "state.json"))));

  const decisions = {
    operator: readJsonLines(join(runSource, "operator-decisions.jsonl")),
    design: readJsonLines(join(runSource, "design-decisions.jsonl")),
    review: readJsonLines(join(runSource, "review-decisions.jsonl")),
  };
  if (Object.values(decisions).some(items => items.length)) writeJson(join(target, "decisions.json"), decisions);

  const trajectoryRun = trajectory.runs.find(item => item.id === mapping.run &&
    (mapping.run !== "loop-01" || item.condition === "reviewLoops"));
  if (!trajectoryRun) throw new Error(`Missing compact trajectory for ${mapping.run}`);
  writeJson(join(target, "trajectory.json"), compactTrajectory(trajectoryRun));

  const scores = [];
  for (const replicate of [1, 2]) {
    const source = sourcePath(mapping, "evaluation", "results", `judge-${String(replicate).padStart(2, "0")}`, mapping.candidate, "judge.final.json");
    const verdict = sanitize(readJson(source));
    scores.push(verdictScore(verdict));
    writeJson(join(target, "judges", `judge-${String(replicate).padStart(2, "0")}.json`), verdict);
  }

  const metric = metricsRow(mapping);
  const meanScore = scores.reduce((sum, score) => sum + score, 0) / scores.length;
  const judgePackageDiff = sourcePath(mapping, "evaluation", "candidates", mapping.candidate, "product.diff");
  const productDiffSha256 = sha256(join(target, "product.diff"));
  if (!existsSync(judgePackageDiff) || sha256(judgePackageDiff) !== productDiffSha256) {
    throw new Error(`Judge package diff mismatch for ${mapping.run}`);
  }
  metricsRuns.push({
    ...metric,
    condition: mapping.condition,
    run: mapping.run,
    pair: mapping.pair,
    scores,
    meanScore,
    deduplicatedTokens: trajectoryRun.tokenSummary.total,
    trajectoryToolCalls: trajectoryRun.toolCalls,
  });
  manifestRuns.push({
    condition: mapping.condition,
    run: mapping.run,
    pair: mapping.pair,
    cohort: mapping.capsule,
    sourceCandidate: mapping.candidate,
    status: "canonical",
    scoreN: 2,
    scores,
    meanScore,
    productDiffSha256,
    judgePackageDiffSha256: sha256(judgePackageDiff),
  });
}

const supersededMapping = { condition: "requirement-review-loops", run: "loop-01", capsule: "slim-loops-v9-macos", candidate: "Candidate-F", pair: "pair-01" };
const supersededTarget = publicPath("superseded", "loop-01-original");
const supersededSource = sourcePath(supersededMapping, "runs", "loop-01");
copy(join(supersededSource, "tests.log"), join(supersededTarget, "tests.log"));
copy(join(supersededSource, "product-code.diff"), join(supersededTarget, "product.diff"));
writeJson(join(supersededTarget, "state.json"), sanitize(readJson(join(supersededSource, "state.json"))));
const supersededScores = [];
for (const replicate of [1, 2]) {
  const verdict = sanitize(readJson(sourcePath(supersededMapping, "evaluation", "results", `judge-${String(replicate).padStart(2, "0")}`, "Candidate-F", "judge.final.json")));
  supersededScores.push(verdictScore(verdict));
  writeJson(join(supersededTarget, "judges", `judge-${String(replicate).padStart(2, "0")}.json`), verdict);
}

const canonicalLoop = manifestRuns.find(item => item.run === "loop-01" && item.status === "canonical");
const replacement = {
  schemaVersion: 1,
  canonical: canonicalLoop,
  superseded: {
    condition: supersededMapping.condition,
    run: supersededMapping.run,
    pair: supersededMapping.pair,
    cohort: supersededMapping.capsule,
    sourceCandidate: supersededMapping.candidate,
    status: "superseded",
    scores: supersededScores,
    meanScore: supersededScores.reduce((sum, score) => sum + score, 0) / supersededScores.length,
    productDiffSha256: sha256(join(supersededTarget, "product.diff")),
  },
  sameProductArtifact: false,
  pooled: false,
  causalClaim: false,
  note: "The user-approved canonical view replaces the original loop-01 product run; the original diff and verdicts remain separately auditable.",
};
writeJson(publicPath("superseded", "replacement.json"), replacement);

const groupMetrics = Object.entries(expectedMeans).map(([condition, expectedMean]) => {
  const rows = metricsRuns.filter(row => row.condition === condition);
  const scores = rows.flatMap(row => row.scores);
  return {
    condition,
    n: rows.length,
    scoreN: scores.length,
    meanScore: scores.reduce((sum, score) => sum + score, 0) / scores.length,
    expectedMean,
    meanWallSeconds: rows.reduce((sum, row) => sum + row.wall_seconds, 0) / rows.length,
    meanTreatmentTokens: rows.reduce((sum, row) => sum + row.deduplicatedTokens, 0) / rows.length,
    meanToolCalls: rows.reduce((sum, row) => sum + row.trajectoryToolCalls, 0) / rows.length,
    meanCredits: rows.reduce((sum, row) => sum + row.estimated_cost, 0) / rows.length,
  };
});
writeJson(publicPath("data", "metrics.json"), { schemaVersion: 1, groups: groupMetrics, runs: metricsRuns });
const csvHeader = "condition,run,pair,status,score_1,score_2,mean_score,wall_seconds,deduplicated_tokens,trajectory_tool_calls,estimated_credits";
const csvRows = metricsRuns.map(row => [row.condition, row.run, row.pair || "", row.raw_status, ...row.scores, row.meanScore, row.wall_seconds, row.deduplicatedTokens, row.trajectoryToolCalls, row.estimated_cost].join(","));
writeFileSync(publicPath("data", "metrics.csv"), `${[csvHeader, ...csvRows].join("\n")}\n`);

const artifactHashes = {};
for (const item of manifestRuns) {
  const base = publicPath("results", item.condition, item.run);
  for (const name of ["state.json", "tests.log", "product.diff", "trajectory.json", "judges/judge-01.json", "judges/judge-02.json", "decisions.json"]) {
    const path = join(base, name);
    if (existsSync(path)) artifactHashes[relative(repositoryRoot, path)] = sha256(path);
  }
}
for (const name of ["state.json", "tests.log", "product.diff", "judges/judge-01.json", "judges/judge-02.json"]) {
  const path = join(supersededTarget, name);
  artifactHashes[relative(repositoryRoot, path)] = sha256(path);
}
for (const name of ["data/metrics.json", "data/metrics.csv", "superseded/replacement.json"]) {
  const path = publicPath(name);
  artifactHashes[name] = sha256(path);
}
writeJson(publicPath("data", "manifest.json"), {
  schemaVersion: 1,
  sourceRepositoryCommit: "0b87a36de85494b15b9fe9991c55fdeeb1dcf713",
  taskBaselineCommit: "ae66a1c02e08366858f3070664f493afbe0cdf18",
  taskOracleCommit: "efe3f165dd297c85fff11473dbf586f2d39fbf86",
  taskOracleTree: "b4539ca014121861158af022e743c494436f1b1f",
  canonicalRuns: manifestRuns,
  superseded: replacement.superseded,
  replacement: "superseded/replacement.json",
  pairingBoundary: "Only the two loop conditions were contemporaneously randomized; canonical pair-01 includes a later post-hoc replacement and all cross-batch comparisons are descriptive.",
  artifactHashes,
});

console.log(`Imported ${manifestRuns.length} canonical runs, ${manifestRuns.length * 2} verdicts, and one superseded run.`);
