[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$scope = @('pkg/cmd/project/item-list', 'pkg/cmd/project/shared/queries')

function Get-CompleteDiff {
    param([string]$Worktree, [string]$Base, [string[]]$Paths)
    $lines = @(& git -C $Worktree diff --binary $Base -- @Paths)
    if ($LASTEXITCODE -ne 0) { throw "git diff failed in $Worktree" }
    $untracked = @(& git -C $Worktree ls-files --others --exclude-standard -- @Paths)
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $Worktree" }
    foreach ($relative in @($untracked | Sort-Object)) {
        $newFileDiff = @(& git -C $Worktree diff --binary --no-index -- /dev/null $relative)
        if ($LASTEXITCODE -notin @(0, 1)) { throw "git no-index diff failed for $relative in $Worktree" }
        $lines += $newFileDiff
    }
    return ,$lines
}

function Invoke-SelfTest {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("freeze-diff-$([guid]::NewGuid().ToString('n'))")
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $temp 'pkg/cmd/project/item-list') | Out-Null
        & git -C $temp init --quiet
        & git -C $temp config user.email 'selftest@example.invalid'
        & git -C $temp config user.name 'selftest'
        'package itemlist' | Set-Content -LiteralPath (Join-Path $temp 'pkg/cmd/project/item-list/tracked.go') -Encoding utf8NoBOM
        & git -C $temp add .
        & git -C $temp commit --quiet -m base
        $base = (& git -C $temp rev-parse HEAD).Trim()
        'package itemlist' | Set-Content -LiteralPath (Join-Path $temp 'pkg/cmd/project/item-list/new_file.go') -Encoding utf8NoBOM
        $diff = (Get-CompleteDiff $temp $base @('pkg/cmd/project/item-list')) -join "`n"
        if ($diff -notmatch 'new_file\.go' -or $diff -notmatch 'new file mode') { throw 'Complete diff omitted an untracked file.' }
        'freeze product diff self-test passed.'
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

$experiment = Get-Content -Raw -LiteralPath (Join-Path $Root 'experiment.json') | ConvertFrom-Json
$manifest = [ordered]@{ schemaVersion = 2; frozenAtUtc = [DateTime]::UtcNow.ToString('o'); scope = $scope; includesUntracked = $true; runs = @() }

foreach ($run in @($experiment.runIds | ForEach-Object { [string]$_ })) {
    $worktree = Join-Path $Root "runs\worktrees\$run"
    $base = (& git -C $worktree rev-list --max-parents=0 HEAD).Trim()
    if (-not $base) { throw "No frozen root commit for $run" }
    $lines = Get-CompleteDiff $worktree $base $scope
    $path = Join-Path $Root "runs\$run\product-code.diff"
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $path -Destination (Join-Path $Root "runs\$run\product.diff") -Force
    $changedFiles = @(& git -C $worktree diff --name-only $base -- @scope)
    $changedFiles += @(& git -C $worktree ls-files --others --exclude-standard -- @scope)
    @($changedFiles | Sort-Object -Unique) | Set-Content -LiteralPath (Join-Path $Root "runs\$run\git-diff-stat.txt") -Encoding utf8NoBOM
    $text = [IO.File]::ReadAllText($path)
    if ($text -match '(?i)superpowers|docs/superpowers|condition|slim-0[1-3]') { throw "Condition leak in $path" }
    $manifest.runs += [ordered]@{
        run = $run
        base = $base
        bytes = (Get-Item $path).Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        files = @($changedFiles | Sort-Object -Unique).Count
        untrackedFilesIncluded = @(& git -C $worktree ls-files --others --exclude-standard -- @scope).Count
    }
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'reports\product-code-diff-manifest.json') -Encoding utf8NoBOM
'Frozen condition-neutral product-code diffs.'
