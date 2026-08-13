# Workflow evaluation dashboard

This is the final static dashboard snapshot for the public experiment dataset in
the repository root. It renders five methods and 15 canonical runs:

```text
Without -> Slim -> Requirement Loop -> Requirement + Review Loops -> Full
```

Every run has two blind-judge scores. Canonical `loop-01` is the approved
independent rerun (100/100); the original 94/93 evidence remains under
[`../superseded/loop-01-original`](../superseded/loop-01-original).

The checked-in `app/trajectory-data.ts` is an audited publication snapshot.
Its run values come from [`../results`](../results) and
[`../data/manifest.json`](../data/manifest.json); the website does not overwrite
the report or canonical evidence.

The separate `/luna-panel` route republishes a provenance-labelled view of a
public Luna compact-results panel: five workflows, eight tasks, three runs per
cell, 120 candidate runs and 240 blind judgments.
It is a cross-project descriptive panel, not another arm in the local 15-run
experiment. Its source repository does not publish the raw run evidence needed
for per-run diff, test-log, verdict or trajectory reconstruction. The page reads
`app/luna-panel-data.json`, whose byte equality with the published root matrix is
locked by the rendered-HTML test.

## Verify

```bash
npm ci
npm test
npm run lint
```

The rendered-HTML tests lock the five local groups, 15 unique runs, fixed means,
replacement boundary, Luna panel totals and boundaries, research questions,
public source links, and social preview asset. The npm package is private to
prevent registry publication; Sites access control is configured separately at
deployment time.
