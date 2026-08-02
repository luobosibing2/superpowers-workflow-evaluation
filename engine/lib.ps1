Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing JSON file: $Path" }
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-Json([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-Property($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    $property.Value
}

function Resolve-PathFrom([string]$Base, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Cannot resolve an empty path.' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function Expand-Pattern([string]$Pattern, [string]$Arm, [int]$Replicate) {
    $Pattern.Replace('{arm}', $Arm).Replace('{replicate}', [string]$Replicate).Replace('{replicate:00}', $Replicate.ToString('00'))
}

function Get-ExperimentContext([string]$ExperimentPath) {
    $resolvedExperiment = (Resolve-Path -LiteralPath $ExperimentPath).Path
    $experiment = Read-Json $resolvedExperiment
    $experimentDirectory = Split-Path -Parent $resolvedExperiment
    $workspace = Resolve-PathFrom $experimentDirectory ([string](Get-Property $experiment 'workspaceRoot' '../..'))
    $taskPath = Resolve-PathFrom $experimentDirectory ([string](Get-Property $experiment 'taskPack'))
    $task = Read-Json $taskPath
    $capabilities = [ordered]@{}
    $capabilityRefs = Get-Property $experiment 'capabilities'
    if ($null -ne $capabilityRefs) {
        foreach ($property in $capabilityRefs.PSObject.Properties) {
            $path = Resolve-PathFrom $experimentDirectory ([string]$property.Value)
            $capabilities[$property.Name] = [pscustomobject]@{ path = $path; manifest = (Read-Json $path) }
        }
    }
    [pscustomobject]@{
        experimentPath = $resolvedExperiment
        experimentDirectory = $experimentDirectory
        workspace = $workspace
        experiment = $experiment
        taskPath = $taskPath
        task = $task
        capabilities = $capabilities
    }
}

function New-RunPlan($Context) {
    $experiment = $Context.experiment
    $defaultReplicates = [int](Get-Property $experiment 'replicates' 1)
    $rows = @()
    foreach ($arm in @($experiment.arms)) {
        $armId = [string](Get-Property $arm 'id')
        $replicates = [int](Get-Property $arm 'replicates' $defaultReplicates)
        $runPattern = [string](Get-Property $arm 'runIdPattern' '{arm}-r{replicate:00}')
        $trajectoryPattern = [string](Get-Property $arm 'trajectoryPattern' $runPattern)
        foreach ($replicate in 1..$replicates) {
            $rows += [pscustomobject][ordered]@{
                runId = Expand-Pattern $runPattern $armId $replicate
                arm = $armId
                replicate = $replicate
                trajectory = Expand-Pattern $trajectoryPattern $armId $replicate
                stage = [string](Get-Property $arm 'stage' 'final')
                prompt = [string](Get-Property $arm 'prompt' 'task')
                capability = [string](Get-Property $arm 'capability' '')
                treatment = [string](Get-Property $arm 'treatment' '')
                factors = Get-Property $arm 'factors' ([pscustomobject]@{})
            }
        }
    }
    [pscustomobject][ordered]@{
        schemaVersion = 1
        experimentId = [string]$experiment.id
        taskPack = [string]$Context.task.id
        model = Get-Property $experiment 'model'
        reasoningEffort = Get-Property $experiment 'reasoningEffort'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        rows = $rows
    }
}

function Get-AssetPaths($Value) {
    if ($null -eq $Value) { return }
    if ($Value -is [string]) { return ,$Value }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        foreach ($item in $Value) { Get-AssetPaths $item }
        return
    }
    foreach ($property in $Value.PSObject.Properties) { Get-AssetPaths $property.Value }
}

function Test-Experiment($Context) {
    $errors = [Collections.Generic.List[string]]::new()
    $experiment = $Context.experiment
    $task = $Context.task
    if ([int](Get-Property $experiment 'schemaVersion' 0) -ne 1) { $errors.Add('experiment.schemaVersion must be 1.') }
    if ([string]::IsNullOrWhiteSpace([string](Get-Property $experiment 'id'))) { $errors.Add('experiment.id is required.') }
    if ([string]::IsNullOrWhiteSpace([string](Get-Property $task 'id'))) { $errors.Add('task pack id is required.') }
    if (@($experiment.arms).Count -eq 0) { $errors.Add('At least one arm is required.') }

    $plan = New-RunPlan $Context
    $duplicateRuns = @($plan.rows | Group-Object runId | Where-Object Count -gt 1)
    if ($duplicateRuns.Count) { $errors.Add("Duplicate run IDs: $(($duplicateRuns.Name) -join ', ')") }
    foreach ($arm in @($experiment.arms)) {
        $id = [string](Get-Property $arm 'id')
        if ($id -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { $errors.Add("Invalid arm id: $id") }
        $alias = [string](Get-Property $arm 'capability' '')
        if (-not $alias) { continue }
        if (-not $Context.capabilities.Contains($alias)) { $errors.Add("Arm '$id' references unknown capability '$alias'."); continue }
        $treatment = [string](Get-Property $arm 'treatment' '')
        $treatments = Get-Property $Context.capabilities[$alias].manifest 'treatments'
        if (-not $treatment -or $null -eq $treatments.PSObject.Properties[$treatment]) { $errors.Add("Arm '$id' references unknown treatment '$alias/$treatment'.") }
    }

    foreach ($asset in @(Get-AssetPaths (Get-Property $task 'assets'))) {
        $path = Resolve-PathFrom $Context.workspace ([string]$asset)
        if (-not (Test-Path -LiteralPath $path)) { $errors.Add("Missing task asset: $asset") }
    }
    $runtime = Get-Property $task 'runtime'
    $pythonRuntime = Get-Property $runtime 'python'
    if ($null -ne $pythonRuntime) {
        $requirements = Resolve-PathFrom $Context.workspace ([string](Get-Property $pythonRuntime 'requirements'))
        $target = Resolve-PathFrom $Context.workspace ([string](Get-Property $pythonRuntime 'target'))
        if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) { $errors.Add("Missing Python runtime lock: $requirements") }
        if (-not (Test-Path -LiteralPath (Join-Path $target 'Scripts\python.exe') -PathType Leaf)) { $errors.Add("Missing prepared Python runtime: $target") }
    }
    foreach ($archive in @(Get-Property $runtime 'archives' @())) {
        $archivePath = Resolve-PathFrom $Context.workspace ([string]$archive.path)
        if (-not (Test-Path -LiteralPath $archivePath -PathType Container)) { $errors.Add("Missing restored runtime directory: $archivePath") }
    }
    foreach ($link in @(Get-Property $runtime 'links' @())) {
        $target = Resolve-PathFrom $Context.workspace ([string]$link.target)
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { $errors.Add("Missing runtime link target: $target") }
    }
    $source = Resolve-PathFrom $Context.workspace ([string]$task.source.checkout)
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { $errors.Add("Missing task source checkout: $source") }
    elseif (Test-Path -LiteralPath (Join-Path $source '.git')) {
        $head = (& git -C $source rev-parse HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $head -ne [string]$task.source.commit) { $errors.Add("Task source HEAD mismatch: expected $($task.source.commit), got $head") }
        if (@(& git -C $source status --porcelain 2>$null).Count) { $errors.Add("Task source checkout is dirty: $source") }
    }
    $reference = Get-Property $task 'reference'
    $referencePathValue = [string](Get-Property (Get-Property $task 'assets') 'reference' '')
    if ($null -eq $reference -or [string]::IsNullOrWhiteSpace([string](Get-Property $reference 'commit')) -or [string]::IsNullOrWhiteSpace([string](Get-Property $reference 'tree'))) {
        $errors.Add('Task pack must pin the Ground Truth reference commit and tree.')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($referencePathValue)) {
        $referencePath = Resolve-PathFrom $Context.workspace $referencePathValue
        if (-not (Test-Path -LiteralPath (Join-Path $referencePath '.git'))) { $errors.Add("Ground Truth reference is not a Git checkout: $referencePath") }
        else {
            $referenceTree = (& git -C $referencePath rev-parse 'HEAD^{tree}' 2>$null | Out-String).Trim()
            if ($referenceTree -ne [string]$reference.tree) { $errors.Add("Ground Truth reference tree mismatch: expected $($reference.tree), got $referenceTree") }
            if (@(& git -C $referencePath status --porcelain 2>$null).Count) { $errors.Add("Ground Truth reference checkout is dirty: $referencePath") }
        }
    }
    $baseline = Get-Property $task 'baseline'
    if ($null -eq $baseline) { $errors.Add('Task pack must declare a sealed baseline.') }
    else {
        $baselinePath = Resolve-PathFrom $Context.workspace ([string]$baseline.checkout)
        if (-not (Test-Path -LiteralPath $baselinePath -PathType Container)) { $errors.Add("Missing sealed baseline: $baselinePath") }
        else {
            $baselineHead = (& git -C $baselinePath rev-parse HEAD 2>$null | Out-String).Trim()
            $commitCount = (& git -C $baselinePath rev-list --count HEAD 2>$null | Out-String).Trim()
            $remotes = @(& git -C $baselinePath remote 2>$null)
            if ($baselineHead -ne [string]$baseline.commit) { $errors.Add("Sealed baseline HEAD mismatch: expected $($baseline.commit), got $baselineHead") }
            if ($commitCount -ne '1') { $errors.Add("Sealed baseline exposes $commitCount commits.") }
            if ($remotes.Count) { $errors.Add("Sealed baseline has Git remotes: $($remotes -join ', ')") }
        }
    }
    foreach ($entry in $Context.capabilities.Values) {
        $manifest = $entry.manifest
        $checkout = Resolve-PathFrom $Context.workspace ([string]$manifest.source.checkout)
        if (-not (Test-Path -LiteralPath $checkout -PathType Container)) { $errors.Add("Missing capability checkout: $checkout"); continue }
        $head = (& git -C $checkout rev-parse HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $head -ne [string]$manifest.source.commit) { $errors.Add("Capability '$($manifest.id)' HEAD mismatch: expected $($manifest.source.commit), got $head") }
        if (@(& git -C $checkout status --porcelain 2>$null).Count) { $errors.Add("Capability '$($manifest.id)' checkout is dirty: $checkout") }
        $installer = Resolve-PathFrom (Split-Path -Parent $entry.path) ([string](Get-Property $manifest 'installer'))
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { $errors.Add("Missing capability installer: $installer") }
    }
    $isolation = Get-Property $task 'isolation'
    if (-not [bool](Get-Property $isolation 'requireSingleCommit' $false)) { $errors.Add('Task pack must require a single-commit candidate baseline.') }
    if (-not [bool](Get-Property $isolation 'requireNoRemotes' $false)) { $errors.Add('Task pack must require no candidate Git remotes.') }
    if ([bool](Get-Property $isolation 'networkDuringRun' $true)) { $errors.Add('Task pack must disable network during runs.') }
    $driver = Resolve-PathFrom $Context.experimentDirectory ([string](Get-Property $experiment 'driver'))
    if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) { $errors.Add("Missing experiment driver: $driver") }
    if ($errors.Count) { throw ($errors -join [Environment]::NewLine) }
    [pscustomobject][ordered]@{
        valid = $true
        experiment = $experiment.id
        task = $task.id
        arms = @($experiment.arms).Count
        runs = @($plan.rows).Count
        capabilities = @($Context.capabilities.Keys)
        driver = $driver
    }
}
