<slim_superpowers_adapter>
This run uses the frozen Codex Slim profile. Exactly four project-local skill
files are trusted treatment inputs. Codex CLI 0.145.0 cannot consume native
skill items, so invoking a skill means reading its complete SKILL.md with the
shell, announcing the method, and following it.

The session begins in a planning-only phase (Plan mode for purposes of the
installed Slim skills). Product mutation is not authorized during this phase.
This is a substantial Plan-on feature task. Your first action MUST be exactly:

`cat ".slim-superpowers/skills/brainstorming/SKILL.md"`

Do not emit an assistant message or inspect the repository first. Apply that
method to inspect project context, identify material decisions, ask the GT
operator behavior questions when needed, compare two or three approaches when
a real tradeoff exists, and settle a decision-complete design.

This experiment specifically measures a clarification-first path. Before
reading `writing-plans`, you MUST end a turn with exactly one concrete,
externally observable behavior question in this form:

`OPERATOR_QUESTION: <one question>`

Wait for `OPERATOR_ANSWER` and use it to settle the design. Do not replace this
required clarification with an assumption, a rhetorical question, or a request
about internal code structure.

Before changing product code, read and follow:

`cat ".slim-superpowers/skills/writing-plans/SKILL.md"`

Keep the plan in the conversation unless repository rules require a file. Once
brainstorming is complete and writing-plans has produced a decision-complete
plan, the planning-only phase ends. Continue implementation in this same session
using normal Codex discretion. The Slim profile does not require TDD, a design
document, a plan file, commits, subagents, independent review, worktrees, or a
branch-finishing workflow. You retain the same tools, permissions, and
subagent allowance as the control condition.

If and only if a bug, failing test, regression, or unexpected behavior requires
root-cause investigation, read and follow:

`cat ".slim-superpowers/skills/systematic-debugging/SKILL.md"`

Immediately before claiming completion, read and follow:

`cat ".slim-superpowers/skills/verification-before-completion/SKILL.md"`

Do not read or follow any other Superpowers skill. Whenever you need a behavior
answer or material design approval, end the turn with exactly:
OPERATOR_QUESTION: <one question or approval request>

After implementation and fresh verification are complete, end with exactly:
IMPLEMENTATION_COMPLETE
</slim_superpowers_adapter>
