[CmdletBinding()]
param(
    [ValidateSet('Public','All')][string]$Scope = 'Public',
    [switch]$SkipOpenSpecBuild,
    [switch]$SkipRuntimeSetup,
    [switch]$SkipTaskDependencyFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }

function Read-Manifests([string]$Root, [string]$Name) {
    Get-ChildItem -LiteralPath (Join-Path $workspace $Root) -Directory |
        ForEach-Object {
            $path = Join-Path $_.FullName $Name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            }
        }
}

function Invoke-Git([string[]]$Arguments) {
    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git failed: git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
}

function Resolve-RepositoryUrl([string]$Repository) {
    if ($Repository -match '^https://') { return $Repository }
    if ($Repository -match '^[^/]+/[^/]+$') { return "https://github.com/$Repository.git" }
    throw "Repository must be an HTTPS Git URL or a GitHub owner/name pair: $Repository"
}

function Set-PinnedCheckout([string]$Repository, [string]$Checkout, [string]$Commit) {
    $target = [IO.Path]::GetFullPath((Join-Path $workspace $Checkout))
    $repositoryUrl = Resolve-RepositoryUrl $Repository
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) { throw "Checkout path is not a Git repository: $target" }
        if (@(& git -C $target status --porcelain 2>$null).Count) { throw "Refusing to change dirty checkout: $target" }
    }
    else {
        [IO.Directory]::CreateDirectory($target) | Out-Null
        Invoke-Git @('-C',$target,'init','--quiet')
    }

    $origin = (& git -C $target remote get-url origin 2>$null | Out-String).Trim()
    if (-not $origin) {
        Invoke-Git @('-C',$target,'remote','add','origin',$repositoryUrl)
    }
    elseif ($origin -ne $repositoryUrl) {
        Invoke-Git @('-C',$target,'remote','set-url','origin',$repositoryUrl)
    }

    $head = (& git -C $target rev-parse HEAD 2>$null | Out-String).Trim()
    if ($head -ne $Commit) {
        Invoke-Git @('-C',$target,'fetch','--quiet','--depth','1','origin',$Commit)
        Invoke-Git @('-C',$target,'checkout','--quiet','--detach','FETCH_HEAD')
    }
    $head = (& git -C $target rev-parse HEAD 2>$null | Out-String).Trim()
    if ($head -ne $Commit) { throw "Pinned checkout mismatch at $target`: expected $Commit, got $head" }
    [pscustomobject]@{ kind='public'; checkout=$Checkout.Replace('\','/'); commit=$head }
}

function Set-IsolatedBaseline($Task) {
    $source = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$Task.source.checkout)))
    $target = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$Task.baseline.checkout)))
    $commit = [string]$Task.source.commit
    if ([string]$Task.baseline.commit -ne $commit -or [string]$Task.baseline.sourceCommit -ne $commit) {
        throw "Baseline for $($Task.id) must use its pinned public source commit."
    }

    if (-not (Test-Path -LiteralPath $target)) {
        [IO.Directory]::CreateDirectory($target) | Out-Null
        Invoke-Git @('-C',$target,'init','--quiet')
        Invoke-Git @('-C',$target,'fetch','--quiet','--depth','1',"https://github.com/$([string]$Task.repository).git",$commit)
        Invoke-Git @('-C',$target,'checkout','--quiet','--detach','FETCH_HEAD')
    }
    if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) { throw "Baseline is not a Git checkout: $target" }

    $head = (& git -C $target rev-parse HEAD 2>$null | Out-String).Trim()
    $sourceTree = (& git -C $source rev-parse 'HEAD^{tree}' 2>$null | Out-String).Trim()
    $baselineTree = (& git -C $target rev-parse 'HEAD^{tree}' 2>$null | Out-String).Trim()
    if ($head -ne $commit) { throw "Baseline commit mismatch at $target`: expected $commit, got $head" }
    if ($baselineTree -ne $sourceTree) { throw "Baseline tree does not match the pinned public source: $target" }
    if (@(& git -C $target status --porcelain 2>$null).Count) { throw "Baseline checkout is dirty: $target" }
    if (@(& git -C $target remote 2>$null).Count) { throw "Baseline checkout has remotes: $target" }
    if ([int]((& git -C $target rev-list --count HEAD 2>$null | Out-String).Trim()) -ne 1) {
        throw "Baseline exposes more than one commit: $target"
    }
    [pscustomobject]@{ kind='baseline'; checkout=([string]$Task.baseline.checkout).Replace('\','/'); commit=$head }
}

function Set-PinnedReference($Task) {
    $target = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$Task.assets.reference)))
    $commit = [string]$Task.reference.commit
    if (-not (Test-Path -LiteralPath $target)) {
        [IO.Directory]::CreateDirectory($target) | Out-Null
        Invoke-Git @('-C',$target,'init','--quiet')
        Invoke-Git @('-C',$target,'fetch','--quiet','--depth','1',"https://github.com/$([string]$Task.repository).git",$commit)
        Invoke-Git @('-C',$target,'checkout','--quiet','--detach','FETCH_HEAD')
    }
    if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) { throw "Reference is not a Git checkout: $target" }
    $head = (& git -C $target rev-parse HEAD 2>$null | Out-String).Trim()
    $tree = (& git -C $target rev-parse 'HEAD^{tree}' 2>$null | Out-String).Trim()
    if ($head -ne $commit) { throw "Reference commit mismatch at $target`: expected $commit, got $head" }
    if ($tree -ne [string]$Task.reference.tree) { throw "Reference tree mismatch at $target" }
    if (@(& git -C $target status --porcelain 2>$null).Count) { throw "Reference checkout is dirty: $target" }
    [pscustomobject]@{ kind='reference'; checkout=([string]$Task.assets.reference).Replace('\','/'); commit=$head }
}

function Initialize-CapabilityRuntimes {
    foreach ($capability in @(Read-Manifests 'packs\capabilities' 'capability.json' | Sort-Object id)) {
        $runtimeProperty = $capability.PSObject.Properties['runtime']
        if ($null -eq $runtimeProperty) { continue }
        $nodeProperty = $runtimeProperty.Value.PSObject.Properties['node']
        if ($null -eq $nodeProperty) { continue }
        $nodeRuntime = $nodeProperty.Value
        $checkout = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$capability.source.checkout)))
        $requiredPaths = @($nodeRuntime.requiredPaths | ForEach-Object { Join-Path $checkout ([string]$_) })
        if ($requiredPaths.Count -and @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) { continue }
        if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw "Node.js and npm are required for $($capability.id)."
        }
        $lockfile = Join-Path $checkout ([string]$nodeRuntime.lockfile)
        if (-not (Test-Path -LiteralPath $lockfile -PathType Leaf)) { throw "Missing capability runtime lockfile: $lockfile" }
        Push-Location -LiteralPath $checkout
        try {
            & npm ci --ignore-scripts --no-audit --no-fund | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed for $($capability.id)." }
        }
        finally { Pop-Location }
        foreach ($required in $requiredPaths) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Capability runtime input is missing after install: $required" }
        }
        if (@(& git -C $checkout status --porcelain 2>$null).Count) { throw "Capability runtime setup dirtied checkout: $checkout" }
    }
}

function Initialize-PythonRuntimes {
    $configured = @{}
    foreach ($task in @(Read-Manifests 'packs\tasks' 'task.json' | Sort-Object id)) {
        $runtimeProperty = $task.PSObject.Properties['runtime']
        if ($null -eq $runtimeProperty) { continue }
        $pythonProperty = $runtimeProperty.Value.PSObject.Properties['python']
        if ($null -eq $pythonProperty) { continue }
        $python = $pythonProperty.Value
        $target = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$python.target)))
        $requirements = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$python.requirements)))
        if ($configured.ContainsKey($target)) {
            if ($configured[$target] -ne $requirements) { throw "Conflicting Python runtime locks for $target" }
            continue
        }
        $configured[$target] = $requirements
        $pythonExe = Join-Path $target 'Scripts\python.exe'
        if (Test-Path -LiteralPath $pythonExe -PathType Leaf) { continue }
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw 'uv is required to create pinned Python runtimes.' }
        & uv venv --python ([string]$python.version) $target | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Could not create Python runtime: $target" }
        & uv pip sync --python $pythonExe $requirements | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Could not synchronize Python runtime: $target" }
    }
}

function Initialize-NodeRuntimes {
    foreach ($task in @(Read-Manifests 'packs\tasks' 'task.json' | Sort-Object id)) {
        $runtimeProperty = $task.PSObject.Properties['runtime']
        if ($null -eq $runtimeProperty) { continue }
        $nodeProperty = $runtimeProperty.Value.PSObject.Properties['node']
        if ($null -eq $nodeProperty) { continue }
        $nodeRuntime = $nodeProperty.Value
        $baseline = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$task.baseline.checkout)))
        if (Test-Path -LiteralPath (Join-Path $baseline 'node_modules\mocha\bin\mocha.js') -PathType Leaf) { continue }
        if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-Command npm -ErrorAction SilentlyContinue)) {
            throw "Node.js and npm are required for $($task.id)."
        }
        $nodeVersion = (& node --version | Out-String).Trim().TrimStart('v')
        $npmVersion = (& npm --version | Out-String).Trim()
        if ($nodeVersion -ne [string]$nodeRuntime.version) { throw "$($task.id) requires Node.js $($nodeRuntime.version), got $nodeVersion." }
        if ($npmVersion -ne [string]$nodeRuntime.npmVersion) { throw "$($task.id) requires npm $($nodeRuntime.npmVersion), got $npmVersion." }
        $lockfile = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$nodeRuntime.lockfile)))
        if (-not (Test-Path -LiteralPath $lockfile -PathType Leaf)) { throw "Missing Node runtime lockfile: $lockfile" }
        $baselineLockfile = Join-Path $baseline 'package-lock.json'
        $removeInjectedLock = -not (Test-Path -LiteralPath $baselineLockfile -PathType Leaf)
        if (-not $removeInjectedLock -and (Get-FileHash -LiteralPath $baselineLockfile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $lockfile -Algorithm SHA256).Hash) {
            throw "Baseline lockfile conflicts with task runtime lock: $baselineLockfile"
        }
        if ($removeInjectedLock) { Copy-Item -LiteralPath $lockfile -Destination $baselineLockfile }
        Push-Location -LiteralPath $baseline
        try {
            & npm ci --package-lock=true --ignore-scripts --no-audit --no-fund | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed for $($task.id)." }
        }
        finally {
            Pop-Location
            if ($removeInjectedLock -and (Test-Path -LiteralPath $baselineLockfile -PathType Leaf)) {
                Remove-Item -LiteralPath $baselineLockfile -Force
            }
        }
        if (@(& git -C $baseline status --porcelain 2>$null).Count) { throw "Node dependency setup dirtied baseline: $baseline" }
    }
}

function Initialize-LanguageCaches {
    foreach ($task in @(Read-Manifests 'packs\tasks' 'task.json' | Sort-Object id)) {
        $baseline = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$task.baseline.checkout)))
        if (Test-Path -LiteralPath (Join-Path $baseline 'Cargo.lock') -PathType Leaf) {
            if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw "cargo is required for $($task.id)." }
            & cargo fetch --locked --manifest-path (Join-Path $baseline 'Cargo.toml') | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "cargo fetch failed for $($task.id)." }
        }
        if (Test-Path -LiteralPath (Join-Path $baseline 'go.mod') -PathType Leaf) {
            if (-not (Get-Command go -ErrorAction SilentlyContinue)) { throw "go is required for $($task.id)." }
            & go -C $baseline mod download | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "go mod download failed for $($task.id)." }
        }
    }
}

function Initialize-ReproductionLayout {
    $layoutPath = Join-Path $workspace 'reproduction-layout.json'
    if (-not (Test-Path -LiteralPath $layoutPath -PathType Leaf)) { throw "Missing reproduction layout: $layoutPath" }
    $layout = Get-Content -Raw -LiteralPath $layoutPath | ConvertFrom-Json
    foreach ($junction in @($layout.junctions)) {
        $source = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$junction.source)))
        $target = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$junction.target)))
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Missing junction source: $source" }
        if (Test-Path -LiteralPath $target) { continue }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    }
}

$results = @()
if ($Scope -in @('Public','All')) {
    foreach ($task in @(Read-Manifests 'packs\tasks' 'task.json' | Sort-Object id)) {
        $results += Set-PinnedCheckout ([string]$task.repository) ([string]$task.source.checkout) ([string]$task.source.commit)
        $results += Set-IsolatedBaseline $task
        $results += Set-PinnedReference $task
    }
    foreach ($capability in @(Read-Manifests 'packs\capabilities' 'capability.json' | Sort-Object id)) {
        $results += Set-PinnedCheckout ([string]$capability.source.repository) ([string]$capability.source.checkout) ([string]$capability.source.commit)
    }
}

$openSpec = Join-Path $workspace 'tools\openspec'
if (-not $SkipOpenSpecBuild -and (Test-Path -LiteralPath $openSpec) -and -not (Test-Path -LiteralPath (Join-Path $openSpec 'dist'))) {
    if (-not (Get-Command corepack -ErrorAction SilentlyContinue)) { throw 'Corepack is required to build the pinned OpenSpec checkout.' }
    $openSpecPackage = Get-Content -Raw -LiteralPath (Join-Path $openSpec 'package.json') | ConvertFrom-Json
    $packageManager = [string]$openSpecPackage.packageManager
    if ($packageManager -notmatch '^pnpm@[0-9]+\.[0-9]+\.[0-9]+$') { throw "Unsupported OpenSpec package manager pin: $packageManager" }
    & corepack $packageManager --dir $openSpec install --frozen-lockfile | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'OpenSpec dependency installation failed.' }
    & corepack $packageManager --dir $openSpec run build | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'OpenSpec build failed.' }
}

if ($Scope -eq 'All') { Initialize-ReproductionLayout }
if ($Scope -eq 'All' -and -not $SkipRuntimeSetup) {
    Initialize-CapabilityRuntimes
    Initialize-PythonRuntimes
    Initialize-NodeRuntimes
}
if ($Scope -eq 'All' -and -not $SkipTaskDependencyFetch) { Initialize-LanguageCaches }

[pscustomobject]@{
    valid = $true
    scope = $Scope
    checkouts = $results.Count
    entries = $results
}
