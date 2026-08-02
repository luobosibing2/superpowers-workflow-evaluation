# Forced-bootstrap v9 macOS reproduction

This capsule reproduces the completed `campaigns/forced-bootstrap-v9`
experiment on macOS ARM64 without modifying the frozen campaign. The formal
v9 task, model, reasoning effort, source pins, treatment, matched-pair design,
20M candidate soft cap, 120-minute wall limit, and judge rubric are unchanged.

The adapter changes only host mechanics:

- PowerShell paths resolve on POSIX;
- candidate verification commands run through `/bin/zsh`;
- the treatment reads project-local skills with `cat`;
- Codex CLI 0.145.0 is installed under `.runtime/`;
- the source and oracle repositories are acquired at their public pins.

Generated state, credentials, worktrees, sessions, judge packages, and reports
are ignored by Git.

## Commands

Run from the repository root:

```powershell
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Bootstrap
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Validate
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Prepare
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Preflight
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Run
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Judge
pwsh -NoProfile -File ./reproductions/forced-bootstrap-v9-macos/run.ps1 -Action Summarize
```

`-Action All` executes the same lifecycle in order. `-Resume` reuses completed
run or judge evidence and resumes interrupted Codex threads. The orchestrator
keeps the v9 probe gate: pair 1 must finish without harness failure or timeout
before pairs 2 and 3 start.

## Experimental boundary

This is a protocol-equivalent macOS port, not a byte-for-byte reproduction of
the original Windows host. Hosted-model sampling and service changes can alter
patches, scores, time, and token use. Human blind review is intentionally left
unfilled; two fresh Codex blind judges are run for every anonymous candidate,
matching the completed v9 automated evaluation.
