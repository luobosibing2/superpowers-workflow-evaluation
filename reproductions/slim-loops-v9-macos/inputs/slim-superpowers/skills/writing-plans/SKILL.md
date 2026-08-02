---
name: writing-plans
description: Use when stable requirements must be converted into a decision-complete plan for a substantial multi-step change.
---

# Writing Plans

## Purpose

Produce a plan another engineer or agent can execute without inventing product or
architecture decisions. Match detail to risk; a plan is not a ritual.

## Preconditions

- The intended outcome and acceptance criteria are known.
- Discoverable repository facts have been inspected.
- Material design choices are settled or explicitly recorded as assumptions.

Do not use for simple answers, research-only exploration, one-line changes, or
tasks whose implementation path is already obvious.

## Plan Contract

Start with the goal and a short architecture summary. Include these sections when
they materially apply:

### Global Constraints

Record project-wide limits such as compatibility, dependencies, naming, security,
performance, migration, rollout, and repository conventions.

### Tasks

Each task must define:

- **Outcome:** the observable result.
- **Ownership:** the subsystem or files affected.
- **Interfaces:** APIs, schemas, commands, files, prompts, or user-visible behavior
  created or changed.
- **Implementation:** the chosen approach and important edge cases.
- **Verification:** commands or scenarios and their expected results.

Group work by independently verifiable outcomes. Do not force arbitrary
two-minute steps, full source listings, per-task commits, or reviewer gates.

## Execution Boundary

The plan does not choose an execution engine. The root Codex agent and active
user/repository policy decide whether work is performed inline or delegated.
Planning does not itself authorize delegation or Git writes.

Keep plans in the conversation by default. Write a plan file only when the user or
repository requires a durable artifact. End with assumptions and unresolved risks;
if a high-impact decision remains unresolved, ask before finalizing the plan.
