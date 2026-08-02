# Preregistered protocol: forced-bootstrap campaign

> v9 artifact-bridge correction: v8 let the operator see the complete candidate
> message, but Superpowers sometimes asks the user to review a spec or plan by
> file path without repeating its contents. Because candidate and operator use
> isolated worktrees, v9 attaches the latest candidate spec for design/spec
> questions and the latest plan for plan questions. It never attaches product
> source or historical implementation details. v1-v8 remain excluded.

> v8 operator-context correction: v7 showed that the runner sent only the text
> after `OPERATOR_QUESTION`, so a GT operator could not see the design placed
> earlier in the same candidate message and could not perform a real design
> review. v8 sends the complete candidate final message plus the parsed question
> to the same read-only GT operator. No GT, prompt, treatment, model, cap, or
> product setting otherwise changes. v1-v7 remain excluded from primary analysis.

> v7 completion-budget correction: v6 passed treatment adoption, but its 300k
> cumulative-token stop truncated With during mandatory multi-turn design
> approval while single-turn controls kept running. v7 applies a common 20M
> soft cap and 120-minute wall limit to both conditions so complete trajectories
> can finish. The higher bounds are stopping rules, not targets; observed use is
> still measured. Treatment delivery is otherwise byte-for-byte unchanged.
> v1-v6 remain probe/runner evidence and are excluded from primary analysis.

> v6 project-install correction: v5 finally entered the intended workflow, but
> automatic safety review rejected reading the installed skill outside the Git
> worktree. v6 copies the pinned `skills/` directory into `.superpowers/` in
> each With worktree and excludes it through that run's private Git metadata.
> Treatment files are therefore repository-local, visible to the agent, absent
> from the product diff, and unavailable in Without. v1-v5 remain excluded.

> v5 transport correction: v4 reached the intended bootstrap construction but
> Windows rejected the With command at the `codex.cmd` batch wrapper's command
> length limit. v5 calls the native `codex.exe` from the same 0.145.0 package.
> This changes no prompt or model setting and avoids the batch transport limit.
> v1-v4 probes remain excluded.

> v4 delivery correction: the pinned plugin remains installed in every With
> run, but all 14 native Superpowers catalog entries are disabled for the
> session because the current CLI rejects native `skill` output items. The
> developer bootstrap instead requires shell-based reads of the same installed,
> pinned SKILL.md files. v4 is the first campaign eligible for the primary
> comparison; v1-v3 were stopped at their probe gates and remain runner evidence.

> v3 runner correction: v2 proved that the developer bootstrap reached the
> actual process, but Codex CLI 0.145.0 aborted when the model emitted a native
> skill invocation (`此时不应有 skill。`). v3 uses the documented file-backed
> skill surface directly: invoking a skill means reading its complete installed
> `SKILL.md` with a shell tool, announcing it, and following it. The first With
> action must read `brainstorming/SKILL.md`; native `skill` items are forbidden.
> v1 and v2 probe candidates remain excluded from analysis.

> Runner correction: campaign v1 was stopped during its probe pair when the
> prompt check and execution argument builders diverged; the bootstrap was
> verified by preflight but accidentally dropped from the actual `codex exec`
> command. No v1 candidate is analyzed. v2 fixes the single argument-order bug
> and starts from new homes and worktrees.

> 2026-07-24 addendum: the earlier plugin-only With arm did not load or
> follow `using-superpowers`; it is excluded from the primary comparison.
> This campaign starts six fresh, contemporaneous candidates from the same
> frozen baseline. The With arm adds the pinned upstream
> `using-superpowers/SKILL.md`, its Codex tool mapping, and a thin harness
> adapter through Codex `developer_instructions`. A run is a valid With only
> if the expanded bootstrap is present in `prompt-input` and its trajectory
> enters brainstorming before implementation, produces a written design and
> plan, and uses TDD, review, and final verification. Merely exposing the
> skill catalog is treatment failure.

## Question

At fixed task, source baseline, model, reasoning effort, permissions, operator
knowledge, and stopping rules, does Superpowers improve Codex's development
trajectory and final deliverability?

Primary outcome: blind product score against `ground-truth/rubric.md`.

Secondary outcomes: completion status, verified behavior, wall-clock time,
candidate turns, tool calls, token use, and estimated API-equivalent cost.

## Frozen task

- Repository: `cli/cli` (GitHub's official CLI).
- Baseline source commit: `ae66a1c02e08366858f3070664f493afbe0cdf18`.
- Historical oracle commit: `efe3f165dd297c85fff11473dbf586f2d39fbf86`.
- Historical change: PR 13823, "Add named field columns to gh project item-list".
- Agent-visible request: `task.md`.
- Hidden behavior oracle: `ground-truth/contract.md` plus the oracle checkout.

The baseline is exported from the source repository and reinitialized as one
new root commit with no remote. Candidate agents cannot inspect upstream Git
history, the historical PR, the oracle commit, or sibling runs.

## Conditions

The only intended condition difference is plugin availability:

- Without: Codex without Superpowers.
- With: the same Codex with `superpowers@superpowers-dev` 6.1.1 loaded from the
  project-local checkout pinned at
  `d884ae04edebef577e82ff7c4e143debd0bbec99`.

Both conditions use:

- model `gpt-5.6-terra`;
- reasoning effort `high`;
- workspace-write sandbox;
- approval policy `never`;
- command network disabled;
- web search disabled;
- Superpowers optional visual telemetry disabled;
- no repository remote and only one synthetic Git commit;
- the same prompt, dependency cache, subagent rights, operator policy, and
  limits.

Candidate subagents, when used, are also pinned to `gpt-5.6-terra/high`, with
at most four concurrent child threads per run.

User-level configuration is ignored. Each run receives a separate
`CODEX_HOME`; Superpowers is installed only into the three With homes.

## Runs and parallelization

There are three matched pairs, six candidate trajectories total. Conditions
are randomly assigned within anonymous run IDs and frozen in
`state/condition-map.json` before execution.

Pair 1 is the protocol probe. If both runs pass isolation checks and no harness
failure occurs, they count toward the 3+3 result. Pairs 2 and 3 then run in
parallel. The orchestrator also supports all three pairs concurrently, but the
default limits candidate concurrency to four to reduce throttling.

Every candidate run has a separate read-only GT operator session. Operator
work can run concurrently with other candidates. Candidate and operator usage
are recorded and reported separately.

## Operator boundary

The operator represents the feature developer and may inspect the complete GT
reference project, historical tests, behavior contract, and review evidence.
This is deliberately richer than a finite answer-baseline document so that
unanticipated but legitimate questions can be answered accurately.

The operator may:

- answer candidate-initiated requirement questions;
- review a candidate-submitted proposal or design when asked;
- reject a design that contradicts or omits observable GT behavior;
- state that an unspecified choice is implementation-defined.

The operator may not:

- reveal historical file paths, symbols, code, patches, or test bodies;
- suggest an implementation architecture unless the requirement itself
  constrains it;
- proactively inspect candidate code or volunteer an implementation defect;
- provide an implementation-phase code review.

All questions and exact answers are appended to the run's
`operator-decisions.jsonl`. The same operator prompt, model, reasoning effort,
and reference package are used for both conditions.

## Interaction contract

Candidates may work autonomously or ask the operator. A candidate that needs
input ends its turn with `OPERATOR_QUESTION:`. A completed candidate ends with
`IMPLEMENTATION_COMPLETE`. The orchestrator resumes the same candidate thread
after each operator answer.

Superpowers-driven design checkpoints are normal candidate-initiated operator
interactions, not extra intervention. Without runs have the same right to ask
for clarification or design approval.

## Limits and invalid runs

- Soft candidate token cap: 300,000 total reported tokens per trajectory.
- Wall-clock cap: 60 minutes per trajectory, including operator waits.
- A single turn may cross the soft token cap; no further turn is started.
- Harness crashes, authentication failures, unavailable model errors, broken
  isolation, or external rate limits invalidate a run rather than scoring it
  as a product failure.
- Test failures caused by candidate code are product evidence, not harness
  invalidation.
- Invalid runs are rerun under the same frozen condition and labeled as reruns.

## Frozen evidence

Each run stores:

- candidate and operator JSONL streams;
- exact prompts and operator answers;
- timestamps and process exit status;
- model usage from every completed turn;
- command/tool events;
- final Git status, diff, diff stat, and commit log;
- focused and broad test output;
- Superpowers prompt-visibility proof for With runs and absence proof for
  Without runs;
- archived design/spec/plan files produced during the run.

Product diffs exclude experiment configuration and separately identify
process-only planning documents.

## Metrics

Candidate metrics:

- wall-clock duration and model-active duration when observable;
- total turns and operator-question count;
- tool calls by type and total;
- input, cached-input, output, and reasoning-output tokens;
- subagent activity and usage when emitted in the parent evidence;
- estimated Codex credits using the frozen official rate table;
- changed product files, additions, deletions, commits, and test commands.

Operator and judge tokens/credits are separate experimental overhead. Dollar
cost is not inferred from subscription credits unless the platform exposes a
valid conversion.

## Evaluation

Candidate identities and conditions are replaced with random labels before
review. Judges receive the frozen task, GT contract, rubric, anonymous product
diff, required source context, and verification outputs. They do not receive
condition labels or agent self-assessments.

- Judge 1: human blind review.
- Judge 2: a fresh fixed-prompt Codex blind review.

Requirement score and validation status are separate. Tests affect confidence,
not points by themselves.

The report must distinguish product results, process observations, and causal
limits. A 3+3 single-task experiment supports a task-specific conclusion, not
a universal claim about Superpowers.
