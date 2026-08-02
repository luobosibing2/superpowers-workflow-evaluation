# Five-method evaluation protocol

## Question

For one underspecified GitHub CLI feature task, compare native Codex execution
with progressively stronger requirement and review workflows while holding the
task, code baseline, evaluator contract, model configuration, and execution
limits fixed.

## Common execution contract

- Model: `gpt-5.6-terra`, reasoning effort `high`.
- Candidate soft cap: 20,000,000 treatment tokens.
- Wall-clock cap: 120 minutes.
- Maximum child agents: four.
- Candidate workspaces: independent Git common directories, one synthetic base
  commit, no remotes, no sibling visibility, and no intended network access.
- Focused test: `go test ./pkg/cmd/project/item-list ./pkg/cmd/project/shared/queries`.
- Product scope: `pkg/cmd/project/item-list` and
  `pkg/cmd/project/shared/queries`.

## Requirement information

The public task intentionally leaves behavior boundaries underspecified. A GT
operator may answer only external, observable behavior questions using the
frozen contract. It must not reveal implementation paths, symbols, tests,
patches, or the oracle.

`Without` does not force a clarification. `Slim` forces one clarification before
planning. Both loop conditions require the candidate to submit a complete
behavior design and continue clarification or revision until the operator emits
`DESIGN_APPROVED`. Product mutation is forbidden before that marker.

## Targeted review

Only `requirement-review-loops` adds an independent targeted reviewer around the
Slim implementation. Each reviewer is fresh, plugin-free, read-only, and sees
the public task, approved design, operator answers, current scoped diff, relevant
baseline source, and test logs. It does not see the hidden contract, rubric,
oracle, condition, other candidates, or candidate internal trajectory.

Critical or major findings require another candidate repair/test/review round.
The loop stops at `REVIEW_APPROVED` or the common resource cap. Minor findings
do not block approval.

## Full workflow

`Full` uses the pinned Superpowers 6.1.1 composite workflow, including design,
planning, task decomposition, implementation, testing, review, repair, and final
verification behaviors. It is a bundled treatment, not a single-skill test.

## Blind judging

Every candidate product diff is scored twice by fresh, read-only, plugin-free
judge sessions using the same 100-point rubric. Judge packages exclude condition
names, run IDs, trajectories, plans, workflow paths, and historical scores.
Product score is the mean of the two schema-valid verdicts. Human blind judging
was not performed.

## Inference boundary

Full versus Without was randomized within three historical matched pairs. The
two loop conditions began as three later matched pairs, but the approved
post-hoc replacement of `loop-01` means the updated six-run loop summary is
descriptive rather than a complete contemporaneous causal estimate. Comparisons
involving historical Slim or Full are cross-batch and descriptive only.
