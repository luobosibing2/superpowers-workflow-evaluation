[CmdletBinding()]
param([string]$Experiment = (Join-Path (Split-Path -Parent $PSScriptRoot) 'experiments\cli-fields-superpowers\experiment.json'))

$invoke = Join-Path $PSScriptRoot 'invoke-experiment.ps1'
$validation = & $invoke -Experiment $Experiment -Action Validate -PassThru
if (-not $validation.valid -or $validation.runs -ne 12 -or $validation.arms -ne 4) { throw 'Manifest validation self-test failed.' }
$plan = & $invoke -Experiment $Experiment -Action Plan -PassThru
if (@($plan.rows).Count -ne 12) { throw 'Plan size self-test failed.' }
if (@($plan.rows.runId | Sort-Object -Unique).Count -ne 12) { throw 'Run ID uniqueness self-test failed.' }
if (@($plan.rows | Where-Object { $_.capability -eq 'superpowers' }).Count -ne 9) { throw 'Capability arm expansion self-test failed.' }
$dry = & $invoke -Experiment $Experiment -Action All -DryRun -PassThru
if (($dry.actions -join ',') -ne 'Prepare,Run,Freeze,Audit,Judge,Summarize') { throw 'Lifecycle ordering self-test failed.' }
$installer = Join-Path $PSScriptRoot 'install-capability.ps1'
$installed = & $installer -Experiment $Experiment -Arm C10 -Worktree (Join-Path $PSScriptRoot '..\.scratch\validate-only') -ValidateOnly -PassThru
if (-not $installed.valid -or $installed.treatment -ne 'brainstorming') { throw 'Capability dispatch self-test failed.' }
$bare = & $installer -Experiment $Experiment -Arm C00 -Worktree (Join-Path $PSScriptRoot '..\.scratch\validate-only') -ValidateOnly -PassThru
if (-not $bare.skipped) { throw 'Bare-arm capability self-test failed.' }
'engine self-test passed'
