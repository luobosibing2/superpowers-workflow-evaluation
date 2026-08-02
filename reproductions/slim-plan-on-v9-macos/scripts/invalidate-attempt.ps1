[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$Reason,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$experiment = Get-Content -Raw -LiteralPath (Join-Path $Root 'experiment.json') | ConvertFrom-Json
if ($RunId -notin @($experiment.runIds | ForEach-Object { [string]$_ })) { throw "Unknown run id: $RunId" }

$runDir = Join-Path $Root "runs/$RunId"
$worktree = Join-Path $Root "runs/worktrees/$RunId"
$runBase = Join-Path $Root "state/run-bases/$RunId"
$actorHomes = Join-Path $Root "state/codex-homes/$RunId"
if (-not (Test-Path -LiteralPath $runDir -PathType Container)) { throw "Run attempt is absent: $runDir" }

$invalidRoot = Join-Path $Root 'invalidated'
New-Item -ItemType Directory -Force -Path $invalidRoot | Out-Null
$attemptNumber = @(Get-ChildItem -LiteralPath $invalidRoot -Directory -Filter "$RunId-attempt-*" -ErrorAction SilentlyContinue).Count + 1
$attemptDir = Join-Path $invalidRoot ("{0}-attempt-{1:d2}" -f $RunId, $attemptNumber)
New-Item -ItemType Directory -Path $attemptDir | Out-Null

if (Test-Path -LiteralPath $worktree -PathType Container) {
    $diffPath = Join-Path $runDir 'partial.diff'
    $diffArguments = @('-C',$worktree,'diff','--binary',"--output=$diffPath")
    & git @diffArguments
    if ($LASTEXITCODE -ne 0) { throw 'Unable to freeze the partial product diff.' }
    @(& git -C $worktree status --porcelain=v2) | Set-Content -LiteralPath (Join-Path $runDir 'partial-status.txt') -Encoding utf8NoBOM
}

$statePath = Join-Path $runDir 'state.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $state.status = 'invalid_attempt'
    $state | Add-Member -NotePropertyName invalidReason -NotePropertyValue $Reason -Force
    $invalidatedAt = [DateTime]::UtcNow.ToString('o')
    $state | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue $invalidatedAt -Force
    $state | Add-Member -NotePropertyName endedAtUtc -NotePropertyValue $invalidatedAt -Force
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
}

Move-Item -LiteralPath $runDir -Destination (Join-Path $attemptDir 'run')
if (Test-Path -LiteralPath $actorHomes -PathType Container) { Move-Item -LiteralPath $actorHomes -Destination (Join-Path $attemptDir 'codex-homes') }
if (Test-Path -LiteralPath $worktree -PathType Container) {
    & git -C $runBase worktree remove --force $worktree
    if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the invalid worktree.' }
}
if (Test-Path -LiteralPath $runBase -PathType Container) { Move-Item -LiteralPath $runBase -Destination (Join-Path $attemptDir 'run-base') }

[ordered]@{
    schemaVersion = 1
    runId = $RunId
    status = 'invalid_attempt'
    invalidatedAtUtc = [DateTime]::UtcNow.ToString('o')
    reason = $Reason
    freshEnvironmentRequired = $true
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $attemptDir 'attempt.json') -Encoding utf8NoBOM

Write-Output "Invalid attempt preserved: $attemptDir"
