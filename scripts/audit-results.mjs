#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const manifest = JSON.parse(readFileSync(join(root, "data", "manifest.json"), "utf8"));
const metrics = JSON.parse(readFileSync(join(root, "data", "metrics.json"), "utf8"));
const schema = JSON.parse(readFileSync(join(root, "evaluation", "judge-output.schema.json"), "utf8"));
const errors = [];
const expectedMeans = new Map([
  ["without", 81.6667], ["slim", 83.1667], ["requirement-loop", 97.6667],
  ["requirement-review-loops", 99.5], ["full", 99],
]);

function hash(path) { return createHash("sha256").update(readFileSync(path)).digest("hex"); }
function score(verdict) { return [verdict.score, verdict.totalScore, verdict.total_score, verdict.total, verdict.overall_score].find(value => typeof value === "number"); }
function walk(path) {
  const output = [];
  for (const name of readdirSync(path)) {
    const child = join(path, name);
    if ([".git", "node_modules", "dist", ".next", ".vinext", ".wrangler", "__pycache__"].includes(name)) continue;
    if (statSync(child).isDirectory()) output.push(...walk(child)); else output.push(child);
  }
  return output;
}

if (manifest.canonicalRuns.length !== 15) errors.push(`canonical run count=${manifest.canonicalRuns.length}`);
if (new Set(manifest.canonicalRuns.map(run => `${run.condition}/${run.run}`)).size !== 15) errors.push("canonical run IDs are not unique");
if (Object.keys(schema.properties || {}).length === 0) errors.push("judge schema is empty");

let verdictCount = 0;
let passingTests = 0;
const verifiedVerdicts = Object.fromEntries([...expectedMeans.keys()].map(condition => [condition, 0]));
const fullyVerifiedRuns = Object.fromEntries([...expectedMeans.keys()].map(condition => [condition, 0]));
for (const run of manifest.canonicalRuns) {
  const base = join(root, "results", run.condition, run.run);
  const test = readFileSync(join(base, "tests.log"), "utf8");
  if (/EXIT_CODE:\s*0/.test(test)) passingTests += 1; else errors.push(`${run.run} focused test is not exit 0`);
  if (hash(join(base, "product.diff")) !== run.productDiffSha256) errors.push(`${run.run} diff hash mismatch`);
  const observedScores = [];
  const observedValidation = [];
  for (const replicate of [1, 2]) {
    const path = join(base, "judges", `judge-${String(replicate).padStart(2, "0")}.json`);
    if (!existsSync(path)) { errors.push(`${run.run} missing judge ${replicate}`); continue; }
    const verdict = JSON.parse(readFileSync(path, "utf8"));
    const total = score(verdict);
    if (typeof total !== "number" || total < 0 || total > 100) errors.push(`${run.run} judge ${replicate} invalid total`);
    if (!Array.isArray(verdict.dimensions) || verdict.dimensions.length === 0) errors.push(`${run.run} judge ${replicate} missing dimensions`);
    const dimensionTotal = (verdict.dimensions || []).reduce((sum, item) => sum + item.score, 0);
    const maximumTotal = (verdict.dimensions || []).reduce((sum, item) => sum + item.maxScore, 0);
    if (dimensionTotal !== total || maximumTotal !== 100) errors.push(`${run.run} judge ${replicate} dimension sum mismatch`);
    observedScores.push(total);
    observedValidation.push(verdict.overallValidation);
    if (verdict.overallValidation === "Verified") verifiedVerdicts[run.condition] += 1;
    verdictCount += 1;
  }
  if (JSON.stringify(observedScores) !== JSON.stringify(run.scores)) errors.push(`${run.run} manifest score mismatch`);
  if (observedValidation.length === 2 && observedValidation.every(value => value === "Verified")) fullyVerifiedRuns[run.condition] += 1;
}
if (verdictCount !== 30) errors.push(`verdict count=${verdictCount}`);
if (passingTests !== 15) errors.push(`passing focused tests=${passingTests}`);
const expectedVerified = { without: 0, slim: 0, "requirement-loop": 0, "requirement-review-loops": 4, full: 3 };
for (const [condition, count] of Object.entries(expectedVerified)) {
  if (verifiedVerdicts[condition] !== count) errors.push(`${condition} Verified verdicts=${verifiedVerdicts[condition]}`);
}
const stateStatuses = manifest.canonicalRuns.map(run => JSON.parse(readFileSync(join(root, "results", run.condition, run.run, "state.json"), "utf8")).status);
if (stateStatuses.filter(status => status === "completed").length !== 14 || stateStatuses.filter(status => status === "token_cap").length !== 1) {
  errors.push(`canonical status distribution=${stateStatuses.join(",")}`);
}

for (const [condition, expected] of expectedMeans) {
  const scores = manifest.canonicalRuns.filter(run => run.condition === condition).flatMap(run => run.scores);
  const mean = scores.reduce((sum, value) => sum + value, 0) / scores.length;
  if (scores.length !== 6 || Math.abs(mean - expected) > 0.0001) errors.push(`${condition} mean=${mean} scoreN=${scores.length}`);
  const row = metrics.groups.find(group => group.condition === condition);
  if (!row || Math.abs(row.meanScore - mean) > 1e-9) errors.push(`${condition} metrics mismatch`);
}

const replacement = JSON.parse(readFileSync(join(root, manifest.replacement), "utf8"));
if (replacement.canonical.scores.join(",") !== "100,100" || replacement.superseded.scores.join(",") !== "94,93" || replacement.pooled !== false) errors.push("loop-01 replacement relation is invalid");
if (manifest.canonicalRuns.find(run => run.run === "loop-01").cohort !== "slim-loops-v9-macos-rerun-loop01") errors.push("canonical loop-01 is not the rerun");

for (const [path, expected] of Object.entries(manifest.artifactHashes)) {
  const absolute = join(root, path);
  if (!existsSync(absolute) || hash(absolute) !== expected) errors.push(`artifact hash mismatch: ${path}`);
}

const forbiddenPath = /\/Users\/[A-Za-z0-9._-]+\/|\/private\/var\/[^\s"']+|\/var\/folders\/[^\s"']+/;
const forbiddenName = /(^|\/)(auth\.json|[^/]*\.sqlite(?:-wal|-shm)?)$/i;
for (const file of walk(root)) {
  const relative = file.slice(root.length + 1);
  if (forbiddenName.test(relative)) errors.push(`forbidden file: ${relative}`);
  const size = statSync(file).size;
  if (size >= 90 * 1024 * 1024) errors.push(`oversized file: ${relative}`);
  if (size <= 10 * 1024 * 1024 && !/\.(png|ico)$/i.test(file)) {
    const text = readFileSync(file, "utf8");
    if (/^(results|data|superseded|docs|site)\//.test(relative) && forbiddenPath.test(text)) {
      errors.push(`absolute local path: ${relative}`);
    }
  }
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
writeFileSync(join(root, "data", "audit-results.json"), `${JSON.stringify({
  schemaVersion: 1,
  valid: true,
  canonicalRuns: 15,
  canonicalVerdicts: 30,
  verdictStructureAndDimensionSumsValid: 30,
  focusedTestsExitZero: 15,
  canonicalDiffsMatchJudgePackages: 15,
  supersededRuns: 1,
  supersededVerdicts: 2,
  statusDistribution: { completed: 14, tokenCap: 1 },
  scoreMeans: Object.fromEntries(expectedMeans),
  verifiedVerdicts,
  fullyVerifiedRuns,
  sensitiveFiles: 0,
  absolutePublicationPaths: 0,
}, null, 2)}\n`);
console.log("audit-results passed: 15 canonical runs, 30 verdicts, 15 focused tests, 5 score means, 1 superseded run");
