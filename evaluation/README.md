# Blind evaluation

`state/blind-map.json` is frozen before judging and must not be included in a
judge input. Prepare anonymous packages without model calls:

```powershell
./scripts/run-blind-judge.ps1 -PrepareOnly
```

Run the six independent model judges, two at a time:

```powershell
./scripts/run-blind-judge.ps1 -MaxParallel 2
```

Each v2 package contains the frozen task, behavior contract, rubric, anonymous
product diff, test evidence, and the minimum shared baseline source needed to
follow unchanged helpers. Results land under
`evaluation/results/Candidate-*`.

The original diff-only packages and results are retained under the
`*-v1-diff-only` directories. V1 is not protocol-valid because the missing
baseline context caused static misclassification; only v2 is used for the
formal result.
