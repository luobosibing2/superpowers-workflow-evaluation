# macOS reproduction drivers

The three directories in this folder preserve the execution boundaries of the
three experiment cohorts. Runtime checkouts, actor homes, run state, judge homes,
and generated reports are intentionally ignored.

Use the repository entry point:

```powershell
./run.ps1 -Cohort full-vs-without -Action Validate
./run.ps1 -Cohort slim -Action Validate
./run.ps1 -Cohort slim-loops -Action Validate
```

`All` performs `Bootstrap`, `Validate`, `Prepare`, `Preflight`, `Run`, `Judge`,
and `Summarize` in that order. The pinned Codex 0.145.0 executable, source
checkouts, candidate worktrees, authentication copies, and raw actor sessions
remain local runtime material and must not be committed.
