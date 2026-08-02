[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Experiment,
    [Parameter(Mandatory)][string]$Arm,
    [Parameter(Mandatory)][string]$Worktree,
    [switch]$ValidateOnly,
    [switch]$PassThru
)

. (Join-Path $PSScriptRoot 'lib.ps1')
$context = Get-ExperimentContext $Experiment
$null = Test-Experiment $context
$matches = @($context.experiment.arms | Where-Object { [string]$_.id -eq $Arm })
if ($matches.Count -ne 1) { throw "Expected one arm named '$Arm', found $($matches.Count)." }
$armConfig = $matches[0]
$alias = [string](Get-Property $armConfig 'capability' '')
if (-not $alias) {
    $result = [pscustomobject]@{ skipped=$true; arm=$Arm; reason='arm has no capability' }
}
else {
    $entry = $context.capabilities[$alias]
    $installer = Resolve-PathFrom (Split-Path -Parent $entry.path) ([string]$entry.manifest.installer)
    $result = & $installer -Worktree $Worktree -Treatment ([string]$armConfig.treatment) -WorkspaceRoot $context.workspace -ValidateOnly:$ValidateOnly
}
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 8
