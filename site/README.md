# Five-method experiment dashboard

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

## Verify

```bash
npm ci
npm test
npm run lint
```

The rendered-HTML tests lock the five groups, 15 unique runs, fixed means,
replacement boundary, research questions, public source links, and social
preview asset. The npm package is private to prevent registry publication; Sites
access control is configured separately at deployment time.
