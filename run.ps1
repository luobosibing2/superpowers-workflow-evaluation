[CmdletBinding()]
param(
    [ValidateSet('Bootstrap','Validate','Prepare','Preflight','Run','Judge','Summarize','All')]
    [string]$Action = 'Validate',
    [ValidateSet('full-vs-without','slim','slim-loops')]
    [string]$Cohort = 'full-vs-without',
    [switch]$Resume,
    [ValidateRange(1, 4)][int]$JudgeMaxParallel = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cohortDirectory = switch ($Cohort) {
    'full-vs-without' { 'forced-bootstrap-v9-macos' }
    'slim' { 'slim-plan-on-v9-macos' }
    'slim-loops' { 'slim-loops-v9-macos' }
}
$driver = Join-Path $PSScriptRoot "reproductions/$cohortDirectory/run.ps1"
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) {
    throw "Missing cohort driver: $driver"
}

& $driver -Action $Action -Resume:$Resume -JudgeMaxParallel $JudgeMaxParallel
if ($LASTEXITCODE -ne 0) { throw "Cohort driver failed: $Cohort / $Action" }
