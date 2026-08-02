# Slim Plan-on v9 macOS add-on

This is an additive, non-contemporaneous trajectory experiment for the completed
`forced-bootstrap-v9-macos` reproduction. It runs three Slim With candidates and
does not rerun or edit the original six candidates.

```powershell
./run.ps1 -Action Bootstrap
./run.ps1 -Action Validate
./run.ps1 -Action Prepare
./run.ps1 -Action Preflight
./run.ps1 -Action Run
./run.ps1 -Action Judge
./run.ps1 -Action Summarize
```

`All` preserves the originally approved no-judge candidate lifecycle. After the
three candidates were frozen, the user authorized a separate `Judge` amendment;
`Judge -Resume` validates and reuses complete verdicts.

The supplemental judge layer gives each Slim candidate two fresh condition-hidden
Codex sessions using the frozen v9 rubric. This adds a descriptively comparable
product score, but not a randomized three-arm causal contrast. See
[`evaluation/judge-amendment.md`](evaluation/judge-amendment.md).
