[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$manifest = [ordered]@{ frozenAtUtc = [DateTime]::UtcNow.ToString('o'); scope = @('pkg/cmd/project/item-list', 'pkg/cmd/project/shared/queries'); runs = @() }

foreach ($run in 'run-01','run-02','run-03','run-04','run-05','run-06') {
    $worktree = Join-Path $Root "runs\worktrees\$run"
    $base = (& git -C $worktree rev-list --max-parents=0 HEAD).Trim()
    if (-not $base) { throw "No frozen root commit for $run" }
    $lines = & git -C $worktree diff --binary $base -- pkg/cmd/project/item-list pkg/cmd/project/shared/queries
    if ($LASTEXITCODE -ne 0) { throw "git diff failed for $run" }
    $path = Join-Path $Root "runs\$run\product-code.diff"
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $text = [IO.File]::ReadAllText($path)
    if ($text -match '(?i)superpowers|docs/superpowers|condition|run-0[1-6]') { throw "Condition leak in $path" }
    $manifest.runs += [ordered]@{
        run = $run
        base = $base
        bytes = (Get-Item $path).Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    }
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'reports\product-code-diff-manifest.json') -Encoding utf8NoBOM
'Frozen condition-neutral product-code diffs.'
