# Superpowers Workflow Evaluation — English summary

This repository publishes a five-method, 15-run evaluation of coding-agent
workflow controls on one underspecified GitHub CLI feature. Every candidate was
blind-judged twice under the same frozen task, behavioral contract, rubric,
model, reasoning effort, baseline, and product-diff scope.

Mean blind scores were 81.67 (native Codex), 83.17 (Slim), 97.67 (Slim plus a
requirement-approval loop), 99.50 (the same requirement loop plus independent
review-and-repair loops), and 99.00 (Full Superpowers). Full used 15.87M
deduplicated tokens and 40:24 per run, versus 2.08M and 8:36 for native Codex.

The largest observed quality jump was between Slim and the requirement loop:
+14.50 points for +0.60M tokens and +2:17. Adding review loops yielded another
+1.83 points for +2.00M tokens and +9:17. Full did not improve the mean over the
review-loop group on this task, while adding about 11.00M tokens and 19:40.
These are descriptive differences: cohorts were executed at different times,
and canonical loop-01 is a user-approved post-hoc independent rerun.

All 15 focused test logs exited zero, yet strict blind-judge `Verified` labels
were 0/6, 0/6, 0/6, 4/6, and 3/6 across the five methods. Passing focused tests
therefore did not establish compliance with the hidden behavioral contract.

Of Full's 13.80M-token increase over native Codex, 37.9% was classified as
coordination, 28.6% as implementation, and 16.5% as review. Root and child-agent
lanes accounted for 53.3% and 42.3% of the increase. Cached input represented
95.3% of the token delta, which is evidence of heavy context transport—not proof
that the same share was semantically redundant reading.

See the [Chinese report](report.md), [canonical manifest](../data/manifest.json),
and [deterministic audit](../scripts/audit-results.mjs) for evidence and limits.
