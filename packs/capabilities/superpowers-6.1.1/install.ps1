[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Treatment,
    [string]$WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'capability.json') | ConvertFrom-Json
$treatmentConfig = $manifest.treatments.PSObject.Properties[$Treatment]
if ($null -eq $treatmentConfig) { throw "Unknown Superpowers treatment: $Treatment" }
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot ([string]$manifest.source.checkout)))
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Missing frozen capability source: $sourceRoot" }
$head = (& git -C $sourceRoot rev-parse HEAD 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne [string]$manifest.source.commit) { throw "Capability source HEAD mismatch: $head" }

$worktreeRoot = [IO.Path]::GetFullPath($Worktree).TrimEnd('\')
$installRoot = [IO.Path]::GetFullPath((Join-Path $worktreeRoot ([string]$manifest.installRoot)))
if (-not $installRoot.StartsWith($worktreeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Capability install target escapes the worktree.' }
foreach ($copy in @($treatmentConfig.Value.copy)) {
    $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot ([string]$copy.source)))
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing treatment source: $source" }
    $target = if ([string]$copy.target) { Join-Path $installRoot ([string]$copy.target) } else { $installRoot }
    if (-not $ValidateOnly) {
        if (Test-Path -LiteralPath $target) { throw "Treatment target already exists: $target" }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Recurse
    }
}
if (-not $ValidateOnly) {
    $record = [ordered]@{ capability=$manifest.id; treatment=$Treatment; sourceCommit=$head; installedAtUtc=[DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText((Join-Path $worktreeRoot '.experiment-capability.json'), (($record | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{ valid=$true; capability=$manifest.id; treatment=$Treatment; sourceCommit=$head; validateOnly=$ValidateOnly.IsPresent }
