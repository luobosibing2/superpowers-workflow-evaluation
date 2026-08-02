[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Run','Freeze','Audit','Judge','Summarize')][string]$Action,
    [Parameter(Mandatory)][string]$ExperimentPath,
    [Parameter(Mandatory)][string]$PlanPath,
    [string]$InternalRunId,
    [string]$InternalCandidate,
    [int]$JudgeReplicate = 0,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness.ps1')

$parameters = @{
    ExperimentPath = $ExperimentPath
    PlanPath = $PlanPath
    InternalRunId = $InternalRunId
    InternalCandidate = $InternalCandidate
    JudgeReplicate = $JudgeReplicate
    Resume = $Resume.IsPresent
    DriverPath = $MyInvocation.MyCommand.Path
}

switch ($Action) {
    'Prepare' { Invoke-MatrixSpecPrepare @parameters }
    'Run' { Invoke-MatrixSpecRun @parameters }
    'Freeze' { Invoke-MatrixSpecFreeze @parameters }
    'Audit' { Invoke-MatrixSpecAudit @parameters }
    'Judge' { Invoke-MatrixSpecJudge @parameters }
    'Summarize' { Invoke-MatrixSpecSummarize @parameters }
}
