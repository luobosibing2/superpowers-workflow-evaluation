[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Run','Freeze','Audit','Judge','Summarize')][string]$Action,
    [Parameter(Mandatory)][string]$ExperimentPath,
    [Parameter(Mandatory)][string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$experiment = Get-Content -Raw -LiteralPath $ExperimentPath | ConvertFrom-Json
$experimentDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $ExperimentPath)
$workspace = [IO.Path]::GetFullPath((Join-Path $experimentDirectory ([string]$experiment.workspaceRoot)))
$campaign = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$experiment.driverConfig.campaignRoot)))
$scripts = Join-Path $campaign 'scripts'
foreach ($name in @('preflight.ps1','prepare.ps1','run-specs.ps1','run-candidates.ps1','audit-treatment.ps1','run-blind-judge.ps1','summarize-ablation.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $scripts $name) -PathType Leaf)) { throw "Missing migrated campaign script: $name" }
}
if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { throw "Missing compiled plan: $PlanPath" }

switch ($Action) {
    'Prepare' {
        if (-not (Test-Path -LiteralPath (Join-Path $campaign 'state\preparation.json'))) {
            & (Join-Path $scripts 'preflight.ps1') -Root $campaign
            & (Join-Path $scripts 'prepare.ps1') -Root $campaign
        }
    }
    'Run' {
        if (-not (Test-Path -LiteralPath (Join-Path $campaign 'reports\product-state-manifest.json'))) {
            & (Join-Path $scripts 'run-specs.ps1') -Root $campaign
            & (Join-Path $scripts 'run-candidates.ps1') -Root $campaign
        }
    }
    'Freeze' {
        $manifest = Join-Path $campaign 'reports\product-state-manifest.json'
        if (-not (Test-Path -LiteralPath $manifest)) { throw 'Run completed without a frozen product-state manifest.' }
    }
    'Audit' {
        if (-not (Test-Path -LiteralPath (Join-Path $campaign 'reports\treatment-audit.json'))) {
            & (Join-Path $scripts 'audit-treatment.ps1') -Root $campaign
        }
    }
    'Judge' {
        $results = @(Get-ChildItem -LiteralPath (Join-Path $campaign 'evaluation\results') -Filter 'judge.final.json' -File -Recurse -ErrorAction SilentlyContinue)
        if ($results.Count -lt 24) { & (Join-Path $scripts 'run-blind-judge.ps1') -Root $campaign -Resume }
    }
    'Summarize' {
        if (-not (Test-Path -LiteralPath (Join-Path $campaign 'reports\ablation-summary.json'))) {
            & (Join-Path $scripts 'summarize-ablation.ps1') -Root $campaign
        }
    }
}
[pscustomobject]@{ action=$Action; campaign=$campaign; status='complete_or_already_complete' }
