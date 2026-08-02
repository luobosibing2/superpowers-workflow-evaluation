<slim_loops_adapter>
This run uses the frozen four-method Slim profile plus an experiment-specific
requirement loop. Exactly four project-local skill files are trusted treatment
inputs. Codex CLI 0.145.0 cannot consume native skill items, so invoking a
skill means reading its complete SKILL.md with the shell, announcing the
method, and following it.

The session begins in a planning-only phase. Your first action MUST be exactly:

`cat ".slim-superpowers/skills/brainstorming/SKILL.md"`

Do not emit an assistant message or inspect the repository before this read.
Use brainstorming to explore the repository and understand the externally
observable behavior. Product mutation is forbidden until the GT operator has
approved a complete behavior design.

Before product mutation, ask concrete externally observable questions one at a
time in this exact marker form:

`OPERATOR_QUESTION: <one question>`

You must ask at least one such question and receive the operator's answer before
submitting a design review request.

After using the answers to form a complete behavior design, submit it in this
exact marker form:

`DESIGN_REVIEW_REQUEST: <complete behavior design>`

Wait for the operator's result. `DESIGN_CHANGES_REQUIRED` means continue the
clarification and design loop; `DESIGN_APPROVED` ends the planning-only phase.
There is no fixed question or approval count. Continue until the operator
approves the design or the normal token/time cap stops the run.

Only after DESIGN_APPROVED may you read:

`cat ".slim-superpowers/skills/writing-plans/SKILL.md"`

Keep the plan in the conversation unless repository rules require a file.
Continue implementation in this same session using normal Codex discretion.
The Slim profile does not require TDD, a spec commit, subagent-driven
development, independent review, worktrees, or a branch-finishing workflow.
You retain the same tools, permissions, and subagent allowance as the control
condition.

If and only if a bug, failing test, regression, or unexpected behavior requires
root-cause investigation, read and follow:

`cat ".slim-superpowers/skills/systematic-debugging/SKILL.md"`

Immediately before the final completion claim, read and follow:

`cat ".slim-superpowers/skills/verification-before-completion/SKILL.md"`

After final verification, end with exactly:

`IMPLEMENTATION_COMPLETE`

Do not read or follow any other Superpowers skill. Never expose hidden contract,
rubric, oracle, condition labels, or another candidate's evidence.
</slim_loops_adapter>
