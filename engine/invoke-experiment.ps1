[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Experiment,
    [ValidateSet('Validate','Plan','Prepare','Run','Freeze','Audit','Judge','Summarize','All')][string]$Action = 'Plan',
    [switch]$DryRun,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$context = Get-ExperimentContext $Experiment
$validation = Test-Experiment $context
$plan = New-RunPlan $context

if ($Action -eq 'Validate') { $result = $validation }
elseif ($Action -eq 'Plan') { $result = $plan }
else {
    $actions = if ($Action -eq 'All') { @('Prepare','Run','Freeze','Audit','Judge','Summarize') } else { @($Action) }
    $driver = Resolve-PathFrom $context.experimentDirectory ([string]$context.experiment.driver)
    if ($DryRun) {
        $result = [pscustomobject][ordered]@{
            valid = $true
            dryRun = $true
            experiment = $context.experiment.id
            driver = $driver
            actions = $actions
            runCount = @($plan.rows).Count
            runs = $plan.rows
        }
    }
    else {
        $stateRoot = Resolve-PathFrom $context.workspace ([string](Get-Property $context.experiment 'stateRoot' "state/framework/$($context.experiment.id)"))
        $planPath = Join-Path $stateRoot 'plan.json'
        Write-Json $planPath $plan
        $executed = @()
        foreach ($step in $actions) {
            & $driver -Action $step -ExperimentPath $context.experimentPath -PlanPath $planPath
            if ($LASTEXITCODE -ne 0) { throw "Driver action failed: $step" }
            $executed += $step
        }
        $result = [pscustomobject][ordered]@{ valid = $true; dryRun = $false; experiment = $context.experiment.id; actions = $executed; plan = $planPath }
    }
}

if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
