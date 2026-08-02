[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$config = Get-Content -Raw -LiteralPath (Join-Path $Root 'experiment.json') | ConvertFrom-Json
$source = Join-Path $Root $config.sourceCheckout
$superpowers = Join-Path $Root $config.superpowersCheckout
$output = Join-Path $Root 'ground-truth/evidence'
New-Item -ItemType Directory -Force -Path $output | Out-Null

function Write-Utf8([string]$Path, [string[]]$Content) {
    [IO.File]::WriteAllText($Path, ($Content -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

if ((git -C $source cat-file -t $config.baselineCommit) -ne 'commit') {
    throw "Missing baseline commit $($config.baselineCommit)"
}
if ((git -C $source cat-file -t $config.oracleCommit) -ne 'commit') {
    throw "Missing oracle commit $($config.oracleCommit)"
}
if ((git -C $superpowers rev-parse HEAD) -ne $config.superpowersCommit) {
    throw 'Superpowers checkout no longer matches the frozen commit'
}

$issue = & gh issue view 13816 --repo cli/cli --json number,title,body,url,state,author,createdAt,updatedAt,comments
$pr = & gh pr view 13823 --repo cli/cli --json number,title,body,url,state,author,createdAt,updatedAt,mergedAt,mergeCommit,additions,deletions,changedFiles,files,commits,reviews,statusCheckRollup
$reviewComments = & gh api repos/cli/cli/pulls/13823/comments --paginate --slurp
$oracleDiff = & git -C $source diff --binary $config.baselineCommit $config.oracleCommit

Write-Utf8 (Join-Path $output 'issue-13816.json') $issue
Write-Utf8 (Join-Path $output 'pr-13823.json') $pr
Write-Utf8 (Join-Path $output 'review-comments.json') $reviewComments
Write-Utf8 (Join-Path $output 'oracle.diff') $oracleDiff

$files = Get-ChildItem -LiteralPath $output -File | Where-Object Name -ne 'manifest.json'
$manifest = [ordered]@{
    frozenAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceRepo = $config.sourceRepo
    baselineCommit = $config.baselineCommit
    oracleCommit = $config.oracleCommit
    superpowersCommit = $config.superpowersCommit
    files = @($files | Sort-Object Name | ForEach-Object {
        [ordered]@{
            name = $_.Name
            bytes = $_.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        }
    })
}
Write-Utf8 (Join-Path $output 'manifest.json') @($manifest | ConvertTo-Json -Depth 5)

Write-Output "Frozen evidence: $output"
