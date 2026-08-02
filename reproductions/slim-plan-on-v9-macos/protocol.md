## 直接答案

This capsule adds three later, non-contemporaneous `Slim With` candidate runs to
the completed macOS v9 reproduction. It does not modify or rerun the six frozen
Full With / Without candidates and does not perform new blind judging.

The treatment is the complete local Codex Slim profile: brainstorming and
writing-plans before product edits, native Codex execution afterwards,
systematic-debugging only when a real failure occurs, and
verification-before-completion before the completion claim. It is not a pure
brainstorming ablation.

## Frozen inputs

- Task, baseline, oracle, focused tests, model, effort, limits, sandbox, and GT
  operator policy match `forced-bootstrap-v9-macos`.
- The Slim plugin input is version `6.1.1+codex.20260714153248`, sourced from
  local commit `fa07307f3dbf7822fb3077587fbde649b0aa66ed`.
- Exactly four skills are exposed. Full-workflow skills such as TDD,
  requesting-code-review, executing-plans, or subagent-driven-development are
  absent.

## Codex 0.145.0 adapter

Codex 0.145.0 is retained for comparability. The plugin is installed in each
candidate home for provenance, but its native skill entries are disabled because
this CLI cannot consume the model's native `skill` item. A frozen developer
adapter tells the candidate to read the exact installed skill files with `cat`.
This is a forced-adoption port of the Slim profile, not a measurement of passive
plugin discoverability.

The candidate must read brainstorming before repository exploration and
writing-plans before editing product code. Planning does not authorize or force
TDD, review, delegation, worktree creation, or a particular execution engine.

## Runs and stopping

`slim-01` is the probe. If it has no harness, authentication, model, isolation,
or rate-limit failure, `slim-02` and `slim-03` run concurrently. Each run has a
20M soft token cap, a 120-minute wall-clock cap, and at most four child agents.
Infrastructure-invalid attempts are retained and replaced with a fresh isolated
attempt under the same run ID. Product failures are outcomes and are not rerun.

## Evidence and comparison

The capsule freezes raw JSONL, actor homes, operator decisions, process timing,
product diff, commands, tests, and summary metrics. No judge sessions or product
scores are created. The combined website compares the three conditions only on
trajectory and resource use. Because Slim runs occur later and are not randomized
against the old six, all three-way comparisons are descriptive.

## 边界与验证

Preflight must prove the pins, four-skill whitelist, disabled native skill
entries, absence of the full bootstrap, Git isolation, candidate offline
workspace permissions, operator read-only permissions, and an offline focused
baseline test. Post-run adoption checks must bind each required skill read to raw
trajectory evidence and verify that no removed workflow skill was injected.
