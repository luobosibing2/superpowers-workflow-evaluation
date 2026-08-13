# Luna skill-panel v1 factual dataset

This directory republishes a public factual Luna five-workflow result panel.
The fixed source commit, source path, byte-for-byte hashes and import boundary
are recorded in [`provenance.json`](./provenance.json).

Included:

- [`run-metrics.csv`](./run-metrics.csv): 120 compact candidate-run rows;
- [`capability-task-economics.csv`](./capability-task-economics.csv): 40
  workflow-task aggregate rows;
- [`capability-task-score-matrix.csv`](./capability-task-score-matrix.csv) and
  [`capability-task-score-matrix.json`](./capability-task-score-matrix.json):
  the published five-workflow aggregate;
- deterministic validation in
  [`../../scripts/audit-luna-panel.mjs`](../../scripts/audit-luna-panel.mjs).

Not included:

- the source repository's HTML report or prose reports;
- raw actor sessions, per-run product diffs, focused-test logs, or individual
  blind-judge verdict files, because those are not present in the public source
  repository at the pinned commit.

The source repository did not declare a repository license at the pinned
commit. These tables are republished as attributed factual experiment records;
no source prose or source code is asserted to be relicensed by this repository's
MIT license.
