#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const dataDir = join(root, "data", "luna-skill-panel-v1");
const errors = [];

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted) {
      if (character === '"' && text[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        field += character;
      }
    } else if (character === '"') {
      quoted = true;
    } else if (character === ",") {
      row.push(field);
      field = "";
    } else if (character === "\n") {
      row.push(field.replace(/\r$/, ""));
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += character;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field.replace(/\r$/, ""));
    rows.push(row);
  }
  const [headers, ...records] = rows;
  return records.filter(record => record.some(value => value !== "")).map(record =>
    Object.fromEntries(headers.map((header, index) => [header, record[index] ?? ""])),
  );
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function round2(value) {
  const scaled = value * 100;
  const floor = Math.floor(scaled);
  const fraction = scaled - floor;
  if (Math.abs(fraction - 0.5) < 1e-9) return (floor % 2 === 0 ? floor : floor + 1) / 100;
  return Math.round(scaled) / 100;
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function expect(condition, message) {
  if (!condition) errors.push(message);
}

const provenance = JSON.parse(readFileSync(join(dataDir, "provenance.json"), "utf8"));
expect(provenance.sourceRepository === "https://github.com/cyijun/workflow-arena", "source repository mismatch");
expect(provenance.sourceBranch === "feature/linux-tmux", "source branch mismatch");
expect(provenance.sourceCommit === "c746e58bf850bd9bc8326f2172383a28841b2364", "source commit mismatch");
expect(provenance.sourcePath === "reports/luna-skill-panel-v1", "source path mismatch");
expect(provenance.sourceLicenseDeclaredAtPinnedCommit === false, "source license boundary changed");
expect(provenance.rawEvidencePublishedBySource === false, "raw-evidence boundary changed");
for (const [name, expectedHash] of Object.entries(provenance.files)) {
  expect(sha256(join(dataDir, name)) === expectedHash, `hash mismatch: ${name}`);
}

const runs = parseCsv(readFileSync(join(dataDir, "run-metrics.csv"), "utf8"));
const economics = parseCsv(readFileSync(join(dataDir, "capability-task-economics.csv"), "utf8"));
const aggregateCsv = parseCsv(readFileSync(join(dataDir, "capability-task-score-matrix.csv"), "utf8"));
const aggregate = JSON.parse(readFileSync(join(dataDir, "capability-task-score-matrix.json"), "utf8"));

const expectedTasks = [
  "axum-custom-executor",
  "bat-sanitize",
  "cli-item-list-fields",
  "eslint-preserve-caught-error",
  "prometheus-utf8-negotiation",
  "pytest-addini-type-expressions",
  "pytest-plugin-entry-points",
  "sqlmodel-field-constraints",
];
const expectedTools = ["grill-me", "matrixspec-lite-l0", "openspec", "ponytail", "superpowers"];
const expectedMacroMeans = new Map([
  ["superpowers", 89.64],
  ["grill-me", 92.14],
  ["openspec", 72.0],
  ["ponytail", 70.19],
  ["matrixspec-lite-l0", 86.71],
]);
const capabilityToTool = new Map([
  ["superpowers-6.1.1", "superpowers"],
  ["mattpocock-grill-me", "grill-me"],
  ["fission-openspec", "openspec"],
  ["ponytail-16f2980", "ponytail"],
  ["matrixspec-profiled-f7c4911", "matrixspec-lite-l0"],
]);

expect(runs.length === 120, `run count=${runs.length}`);
expect(new Set(runs.map(row => `${row.task}/${row.run_id}`)).size === 120, "task/run IDs are not unique");
expect(JSON.stringify([...new Set(runs.map(row => row.task))].sort()) === JSON.stringify(expectedTasks), "task set mismatch");
expect(JSON.stringify([...new Set(runs.map(row => row.tool))].sort()) === JSON.stringify(expectedTools), "workflow set mismatch");

let judgeScores = 0;
let focusedTestsPassed = 0;
const statuses = {};
const cells = new Map();
for (const row of runs) {
  const scores = JSON.parse(row.judge_scores);
  expect(Array.isArray(scores) && scores.length === 2, `${row.task}/${row.run_id} judge score count`);
  expect(scores.every(score => Number.isFinite(score) && score >= 0 && score <= 100), `${row.task}/${row.run_id} invalid judge score`);
  judgeScores += scores.length;
  expect(Math.abs(mean(scores) - Number(row.mean_score)) < 1e-9, `${row.task}/${row.run_id} mean score mismatch`);
  statuses[row.status] = (statuses[row.status] ?? 0) + 1;
  if (row.focused_tests_passed === "True") focusedTestsPassed += 1;
  else expect(row.focused_tests_passed === "False", `${row.task}/${row.run_id} invalid focused-test value`);
  const key = `${row.tool}/${row.task}`;
  const cell = cells.get(key) ?? [];
  cell.push(Number(row.mean_score));
  cells.set(key, cell);
}

expect(judgeScores === 240, `blind judge score count=${judgeScores}`);
expect(statuses.completed === 107, `completed=${statuses.completed ?? 0}`);
expect(statuses["protocol-failed"] === 12, `protocol-failed=${statuses["protocol-failed"] ?? 0}`);
expect(statuses["token-limit"] === 1, `token-limit=${statuses["token-limit"] ?? 0}`);
expect(Object.values(statuses).reduce((sum, value) => sum + value, 0) === 120, "unexpected terminal status");
expect(focusedTestsPassed === 93, `focused tests passed=${focusedTestsPassed}`);
expect(cells.size === 40, `workflow-task cell count=${cells.size}`);
for (const [key, values] of cells) expect(values.length === 3, `${key} replicate count=${values.length}`);

expect(aggregate.runs === 120, `aggregate runs=${aggregate.runs}`);
expect(aggregate.blindJudgments === 240, `aggregate blind judgments=${aggregate.blindJudgments}`);
expect(aggregate.focusedTestsPassed === 93, `aggregate focused tests=${aggregate.focusedTestsPassed}`);
expect(JSON.stringify(aggregate.statusCounts) === JSON.stringify({ completed: 107, "protocol-failed": 12, "token-limit": 1 }), "aggregate status mismatch");
expect(aggregate.candidateModel === "gpt-5.6-luna", "candidate model mismatch");
expect(aggregate.operatorModel === "gpt-5.6-terra", "operator model mismatch");
expect(aggregate.judgeModel === "gpt-5.6-terra", "judge model mismatch");
expect(aggregate.allTreatmentsAdopted === true, "published adoption aggregate is not true");
expect(Array.isArray(aggregate.matrix) && aggregate.matrix.length === 5, `aggregate matrix rows=${aggregate.matrix?.length}`);
expect(aggregateCsv.length === 5, `aggregate CSV rows=${aggregateCsv.length}`);
expect(economics.length === 40, `economics rows=${economics.length}`);
expect(economics.every(row => Number(row.n) === 3), "economics replicate count mismatch");

for (const row of aggregate.matrix) {
  const tool = capabilityToTool.get(row.capability);
  expect(Boolean(tool), `unknown aggregate capability=${row.capability}`);
  if (!tool) continue;
  const cellMeans = expectedTasks.map(task => round2(mean(cells.get(`${tool}/${task}`))));
  const rebuiltMacroMean = round2(mean(cellMeans));
  const expectedMacroMean = expectedMacroMeans.get(tool);
  expect(rebuiltMacroMean === expectedMacroMean, `${tool} rebuilt macro mean=${rebuiltMacroMean}`);
  expect(Number(row.macro_mean) === expectedMacroMean, `${tool} JSON macro mean=${row.macro_mean}`);
  const csvRow = aggregateCsv.find(candidate => candidate.capability === row.capability);
  expect(Boolean(csvRow), `${row.capability} missing aggregate CSV row`);
  if (csvRow) expect(Number(csvRow.macro_mean) === expectedMacroMean, `${tool} CSV macro mean=${csvRow.macro_mean}`);
  for (const [index, task] of expectedTasks.entries()) {
    const field = task.replaceAll("-", "_");
    const cellMean = cellMeans[index];
    expect(Number(row[field]) === cellMean, `${tool}/${task} JSON cell mean=${row[field]}`);
    if (csvRow) expect(Number(csvRow[field]) === cellMean, `${tool}/${task} CSV cell mean=${csvRow[field]}`);
    const economicsRow = economics.find(candidate => candidate.capability === row.capability && candidate.task === field);
    expect(Boolean(economicsRow), `${tool}/${task} missing economics row`);
    if (economicsRow) {
      expect(Number(economicsRow.score) === cellMean, `${tool}/${task} economics score=${economicsRow.score}`);
      const sourceRows = runs.filter(candidate => candidate.tool === tool && candidate.task === task);
      const cellTestPasses = sourceRows.filter(candidate => candidate.focused_tests_passed === "True").length;
      expect(Number(economicsRow.tests_passed) === cellTestPasses, `${tool}/${task} economics tests=${economicsRow.tests_passed}`);
    }
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}

console.log(JSON.stringify({
  valid: true,
  provenance: {
    repository: provenance.sourceRepository,
    commit: provenance.sourceCommit,
    filesVerified: Object.keys(provenance.files).length,
  },
  design: { workflows: 5, tasks: 8, replicatesPerCell: 3, runs: 120 },
  blindJudgeScores: 240,
  statusCounts: statuses,
  focusedTestsPassed: "93/120",
  macroMeans: Object.fromEntries(expectedMacroMeans),
  evidenceBoundary: "aggregate-only; raw sessions, diffs, test logs, and verdict files are not published by the source repository",
}, null, 2));
