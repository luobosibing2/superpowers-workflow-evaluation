[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$errors = [Collections.Generic.List[string]]::new()
$ignorePath = Join-Path $workspace '.gitignore'
$ignoreRules = if (Test-Path -LiteralPath $ignorePath) { @(Get-Content -LiteralPath $ignorePath | ForEach-Object { $_.Trim() }) } else { @() }
$isGitRepository = $false
$gitRoot = (& git -C $workspace rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $gitRoot) {
    $isGitRepository = [IO.Path]::GetFullPath($gitRoot) -eq [IO.Path]::GetFullPath($workspace)
}

function Test-Ignored([string]$Path) {
    if ($isGitRepository) {
        & git -C $workspace check-ignore --quiet --no-index -- $Path
        if ($LASTEXITCODE -eq 0) { return $true }
        # A directory-only rule such as /runs/ does not match a nonexistent
        # directory path. Probe a child without creating anything on disk.
        $probe = Join-Path $Path '.workflow-arena-ignore-probe'
        & git -C $workspace check-ignore --quiet --no-index -- $probe
        return $LASTEXITCODE -eq 0
    }
    $relative = [IO.Path]::GetRelativePath($workspace, $Path).Replace('\','/')
    if ($relative -match '(^|/)(auth\.json|credentials\.json)$') { return 'auth.json' -in $ignoreRules -or 'credentials.json' -in $ignoreRules }
    if ($relative -match '\.private\.json$') { return '*.private.json' -in $ignoreRules }
    $top = $relative.Split('/')[0]
    return "/$top/" -in $ignoreRules
}

$forbiddenNames = @('auth.json','credentials.json')
$roots = @('evaluation','state','runs','campaigns','candidates','tools','baselines','ground-truth')
$searchRoots = @('evaluation' | Where-Object { Test-Path -LiteralPath (Join-Path $workspace $_) })
if ($isGitRepository) {
    foreach ($tracked in @(& git -C $workspace ls-files)) {
        if ([IO.Path]::GetFileName($tracked) -in $forbiddenNames -or $tracked -like '*.private.json') {
            $errors.Add("Sensitive file is already tracked: $tracked")
        }
    }
}
if ($searchRoots.Count -and (Get-Command rg -ErrorAction SilentlyContinue)) {
    $matches = @(& rg --files --hidden --no-ignore -g 'auth.json' -g 'credentials.json' -g '*.private.json' @searchRoots 2>$null)
    foreach ($relativePath in $matches) {
        $file = [IO.Path]::GetFullPath((Join-Path $workspace $relativePath))
        if (-not (Test-Ignored $file)) { $errors.Add("Sensitive file is not ignored: $file") }
    }
}
else {
    foreach ($relativeRoot in $searchRoots) {
        $root = Join-Path $workspace $relativeRoot
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $forbiddenNames -or $_.Name -like '*.private.json' })) {
            if (-not (Test-Ignored $file.FullName)) { $errors.Add("Sensitive file is not ignored: $($file.FullName)") }
        }
    }
}

foreach ($relative in @('candidates','tools','baselines','runs','state','.scratch','ground-truth','fixtures')) {
    $path = Join-Path $workspace $relative
    if (-not (Test-Ignored $path)) { $errors.Add("Generated/external root is not ignored: $relative") }
}
$requiredCampaignRules = @(
    '/campaigns/**/runs/', '/campaigns/**/state/', '/campaigns/**/fixtures/',
    '/campaigns/**/evaluation/candidates*/', '/campaigns/**/evaluation/results*/',
    '/campaigns/**/evaluation/.judge-homes*/', '/campaigns/**/evaluation/stale-*/',
    '/campaigns/**/evaluation/rejected/', '/campaigns/**/ground-truth/reference/'
)
foreach ($rule in $requiredCampaignRules) {
    if ($rule -notin $ignoreRules) { $errors.Add("Missing campaign ignore rule: $rule") }
}

$absolutePathHits = @(Get-ChildItem (Join-Path $workspace 'engine'),(Join-Path $workspace 'packs'),(Join-Path $workspace 'experiments'),(Join-Path $workspace 'scripts') -Recurse -File -Include *.ps1,*.json,*.md |
    Select-String -Pattern '[A-Za-z]:\\Users\\' -ErrorAction SilentlyContinue)
foreach ($hit in $absolutePathHits) { $errors.Add("Machine-specific absolute path: $($hit.Path):$($hit.LineNumber)") }

# Scan exactly the files Git would publish. Report only the rule and location so
# an accidental credential is never echoed into terminal logs.
$publishableFiles = @(
    if ($isGitRepository) {
        & git -C $workspace ls-files --cached --others --exclude-standard
    }
    else {
        Get-ChildItem -LiteralPath $workspace -Recurse -Force -File |
            ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($workspace, $_.FullName).Replace('\','/')
                if (-not (Test-Ignored $_.FullName)) { $relative }
            }
    }
)
$secretPatterns = [ordered]@{
    'private-key' = '-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----'
    'github-token' = '\bgh[pousr]_[A-Za-z0-9_]{20,}\b'
    'openai-key' = '\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b'
    'aws-access-key' = '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
    'google-api-key' = '\bAIza[0-9A-Za-z_-]{30,}\b'
    'slack-token' = '\bxox[baprs]-[A-Za-z0-9-]{10,}\b'
    'stripe-live-key' = '\b[rs]k_live_[A-Za-z0-9]{16,}\b'
}
foreach ($relativePath in $publishableFiles) {
    $file = Join-Path $workspace $relativePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    try {
        $lineNumber = 0
        foreach ($line in [IO.File]::ReadLines($file)) {
            $lineNumber++
            foreach ($entry in $secretPatterns.GetEnumerator()) {
                if ($line -match $entry.Value) {
                    $errors.Add("Possible $($entry.Key) in publishable file: ${relativePath}:$lineNumber")
                }
            }
        }
    }
    catch [Text.DecoderFallbackException] {
        # Binary files are checked separately by the publish-size policy.
    }
}

if ($errors.Count) { throw ($errors -join [Environment]::NewLine) }
[pscustomobject]@{ valid=$true; checkedRoots=$roots; publishableFiles=$publishableFiles.Count; secretPatternHits=0; absolutePathHits=0 }
