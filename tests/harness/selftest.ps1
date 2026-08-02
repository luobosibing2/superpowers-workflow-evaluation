[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$loops = Join-Path $root 'reproductions/slim-loops-v9-macos/scripts'

& (Join-Path $loops 'orchestrate.ps1') -Root (Join-Path $root 'reproductions/slim-loops-v9-macos') -SelfTest
& (Join-Path $loops 'audit-adoption.ps1') -Root (Join-Path $root 'reproductions/slim-loops-v9-macos') -SelfTest
& (Join-Path $loops 'freeze-product-code-diffs.ps1') -Root (Join-Path $root 'reproductions/slim-loops-v9-macos') -SelfTest
& (Join-Path $loops 'run-blind-judge.ps1') -Root (Join-Path $root 'reproductions/slim-loops-v9-macos') -SelfTest

Write-Output 'macOS harness self-tests passed'
