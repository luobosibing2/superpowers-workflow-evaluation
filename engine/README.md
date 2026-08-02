# Pack-based experiment engine

This layer keeps historical campaigns immutable and separates future work into:

- `packs/tasks/<task>/task.json`: repository, frozen inputs, Ground Truth, tests, product diff scope, and isolation policy.
- `packs/capabilities/<capability>/capability.json`: pinned source, project-local installer, treatments, activation, and adoption evidence.
- `experiments/<experiment>/experiment.json`: model, arms, factors, replicates, and lifecycle driver.

## Commands

```powershell
$exp = '.\experiments\cli-fields-superpowers\experiment.json'
.\engine\invoke-experiment.ps1 -Experiment $exp -Action Validate
.\engine\invoke-experiment.ps1 -Experiment $exp -Action Plan
.\engine\invoke-experiment.ps1 -Experiment $exp -Action All -DryRun
.\engine\invoke-experiment.ps1 -Experiment $exp -Action All
```

`All` runs `Prepare -> Run -> Freeze -> Audit -> Judge -> Summarize`. The driver is the only task/workflow-specific executable boundary and receives `-Action`, `-ExperimentPath`, and `-PlanPath`.

Drivers install the arm's declared treatment through the generic dispatcher:

```powershell
.\engine\install-capability.ps1 -Experiment $exp -Arm superpowers-full -Worktree $worktree
```

Bare arms are skipped; treated arms resolve the pinned pack installer and
treatment without capability-specific logic in the driver.

Acquisition is intentionally outside candidate execution: use `gh` to populate the task and capability source checkouts, pin their commits, then let `Prepare` create single-commit, no-remote run bases. Candidate execution must remain network-disabled.

For a new experiment, add one task manifest, one capability manifest plus installer, and one small lifecycle driver. Reuse this engine; do not copy historical campaign scripts unless the new workflow genuinely needs a custom multi-turn protocol.
