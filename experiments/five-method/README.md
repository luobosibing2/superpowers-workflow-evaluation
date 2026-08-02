# Five-method Superpowers workflow comparison

This experiment asks how coding-agent product quality, resource use, and work
allocation change as workflow mechanisms are added around the same GitHub CLI
task.

The fixed method order is:

```text
Without
  -> Slim
  -> Slim + Requirement Loop
  -> Slim + Requirement + Review Loops
  -> Full Superpowers
```

Every condition uses the same task baseline, oracle, model slug, reasoning
effort, focused test, 20M treatment soft cap, and 120-minute wall-clock cap.
The later conditions change requirement feedback and review behavior; they do
not form one contemporaneous five-arm randomization.

## Superpowers Slim provenance

The Slim conditions tested four scoped methods from
[`luobosibing2/superpowers-slim`](https://github.com/luobosibing2/superpowers-slim)
at commit
[`fa07307f`](https://github.com/luobosibing2/superpowers-slim/commit/fa07307f3dbf7822fb3077587fbde649b0aa66ed):

- brainstorming
- writing-plans
- systematic-debugging
- verification-before-completion

The repository's later commit `8607c8c` adds `code-review`. That fifth method was
not present in the tested Slim revision and must not be retroactively treated as
part of the experiment.

## Frozen inputs

- [`task.md`](task.md): public task shown to candidates.
- [`ground-truth/contract.md`](ground-truth/contract.md): evaluator behavior contract.
- [`ground-truth/rubric.md`](ground-truth/rubric.md): 100-point blind-judge rubric.
- [`ground-truth/operator-guide.md`](ground-truth/operator-guide.md): allowed GT operator answers.
- [`evaluation/`](evaluation/): judge and targeted-review prompts and schemas.
- [`experiment.json`](experiment.json): common pins and method definitions.

Results, score tables, and conclusions are intentionally absent from this
experiment-definition layer.
