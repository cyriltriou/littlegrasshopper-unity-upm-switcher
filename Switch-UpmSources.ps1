param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("file", "git")]
    [string]$Mode,

    [string]$ConfigPath = "",
    [string]$Profile,
    [string]$ProjectPath,
    [string[]]$Package,

    [switch]$CleanLock,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "upm-switcher.config.json"
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content + "`n", $utf8NoBom)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$FromPath,
        [Parameter(Mandatory = $true)][string]$ToPath
    )

    $fromFullPath = [System.IO.Path]::GetFullPath($FromPath)
    if (-not $fromFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fromFullPath += [System.IO.Path]::DirectorySeparatorChar
    }

    $toFullPath = [System.IO.Path]::GetFullPath($ToPath)

    $fromUri = New-Object System.Uri($fromFullPath)
    $toUri = New-Object System.Uri($toFullPath)

    $relativeUri = $fromUri.MakeRelativeUri($toUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace("\", "/")
}

function Ensure-DependenciesProperty {
    param([Parameter(Mandatory = $true)]$Manifest)

    if ($null -eq $Manifest.dependencies) {
        $Manifest | Add-Member -MemberType NoteProperty -Name dependencies -Value ([pscustomobject]@{}) -Force
    }
}

function Set-DependencyValue {
    param(
        [Parameter(Mandatory = $true)]$DependenciesObject,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $DependenciesObject | Add-Member -MemberType NoteProperty -Name $PackageName -Value $Value -Force
}

function Remove-LockEntries {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][string[]]$PackageNames,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )

    if (-not (Test-Path -Path $LockPath)) {
        Write-Host "packages-lock.json not found: $LockPath"
        return
    }

    $lockRaw = Get-Content -Raw -Path $LockPath
    $lock = ConvertFrom-Json -InputObject $lockRaw
    if ($null -eq $lock.dependencies) {
        Write-Host "No dependencies section found in packages-lock.json"
        return
    }

    $removed = @()
    foreach ($packageName in $PackageNames) {
        if ($lock.dependencies.PSObject.Properties.Name -contains $packageName) {
            $null = $lock.dependencies.PSObject.Properties.Remove($packageName)
            $removed += $packageName
        }
    }

    if ($removed.Count -eq 0) {
        Write-Host "No matching entries to remove from packages-lock.json"
        return
    }

    if ($IsDryRun) {
        Write-Host "DryRun: would remove lock entries: $($removed -join ', ')"
        return
    }

    $lockJson = ConvertTo-Json -InputObject $lock -Depth 64
    Write-Utf8NoBom -Path $LockPath -Content $lockJson
    Write-Host "Removed lock entries: $($removed -join ', ')"
}

if (-not (Test-Path -Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$configRaw = Get-Content -Raw -Path $ConfigPath
$config = ConvertFrom-Json -InputObject $configRaw

if ($null -eq $config.profiles -or $config.profiles.Count -eq 0) {
    throw "No profiles found in config: $ConfigPath"
}

$selectedProfile = $null
if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    $selectedProfile = $config.profiles | Where-Object { $_.name -eq $Profile } | Select-Object -First 1
    if ($null -eq $selectedProfile) {
        throw "Profile '$Profile' not found in $ConfigPath"
    }
}
elseif ($config.profiles.Count -eq 1) {
    $selectedProfile = $config.profiles[0]
}
else {
    $available = ($config.profiles | ForEach-Object { $_.name }) -join ", "
    throw "Multiple profiles found. Specify -Profile. Available: $available"
}

$effectiveProjectPath = $ProjectPath
if ([string]::IsNullOrWhiteSpace($effectiveProjectPath)) {
    $effectiveProjectPath = $selectedProfile.projectPath
}
if ([string]::IsNullOrWhiteSpace($effectiveProjectPath)) {
    throw "Project path is required. Set profile.projectPath in config or pass -ProjectPath"
}

$manifestPath = Join-Path -Path $effectiveProjectPath -ChildPath "Packages\manifest.json"
if (-not (Test-Path -Path $manifestPath)) {
    throw "manifest.json not found at: $manifestPath"
}

if ($null -eq $selectedProfile.packages -or $selectedProfile.packages.Count -eq 0) {
    throw "No packages declared in profile '$($selectedProfile.name)'"
}

$selectedPackages = @($selectedProfile.packages)
if ($null -ne $Package -and $Package.Count -gt 0) {
    $packageSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Package) {
        $null = $packageSet.Add($p)
    }

    $selectedPackages = @($selectedPackages | Where-Object { $packageSet.Contains($_.name) })
    if ($selectedPackages.Count -eq 0) {
        $requested = $Package -join ", "
        throw "No package matched -Package values: $requested"
    }
}

$packagesDir = Join-Path -Path $effectiveProjectPath -ChildPath "Packages"
$lockPath = Join-Path -Path $effectiveProjectPath -ChildPath "Packages\packages-lock.json"

$manifestRaw = Get-Content -Raw -Path $manifestPath
$manifest = ConvertFrom-Json -InputObject $manifestRaw
Ensure-DependenciesProperty -Manifest $manifest

$updates = @()
foreach ($pkg in $selectedPackages) {
    if ([string]::IsNullOrWhiteSpace($pkg.name)) {
        throw "A package entry is missing 'name' in profile '$($selectedProfile.name)'"
    }

    $targetValue = $null
    if ($Mode -eq "file") {
        if ([string]::IsNullOrWhiteSpace($pkg.localPath)) {
            throw "Package '$($pkg.name)' is missing localPath"
        }

        $localPath = [System.IO.Path]::GetFullPath($pkg.localPath)
        if (-not (Test-Path -Path $localPath)) {
            throw "Local path does not exist for package '$($pkg.name)': $localPath"
        }

        $relativePath = Get-RelativePath -FromPath $packagesDir -ToPath $localPath
        if (-not ($relativePath.StartsWith("./") -or $relativePath.StartsWith("../"))) {
            $relativePath = "./$relativePath"
        }

        $targetValue = "file:$relativePath"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($pkg.gitUrl)) {
            throw "Package '$($pkg.name)' is missing gitUrl"
        }

        $gitRef = $pkg.gitRef
        if ([string]::IsNullOrWhiteSpace($gitRef)) {
            $gitRef = "main"
        }

        $targetValue = "$($pkg.gitUrl)#$gitRef"
    }

    $oldValue = $null
    if ($manifest.dependencies.PSObject.Properties.Name -contains $pkg.name) {
        $oldValue = $manifest.dependencies.PSObject.Properties[$pkg.name].Value
    }

    Set-DependencyValue -DependenciesObject $manifest.dependencies -PackageName $pkg.name -Value $targetValue
    $updates += [pscustomobject]@{
        Package = $pkg.name
        OldValue = $oldValue
        NewValue = $targetValue
    }
}

if ($DryRun) {
    Write-Host "DryRun: manifest.json would be updated at $manifestPath"
    $updates | Format-Table -AutoSize | Out-String | Write-Host
}
else {
    $manifestJson = ConvertTo-Json -InputObject $manifest -Depth 64
    Write-Utf8NoBom -Path $manifestPath -Content $manifestJson
    Write-Host "Updated $manifestPath"
    $updates | Format-Table -AutoSize | Out-String | Write-Host
}

if ($CleanLock) {
    $packageNames = $selectedPackages | ForEach-Object { $_.name }
    Remove-LockEntries -LockPath $lockPath -PackageNames $packageNames -IsDryRun:$DryRun.IsPresent
}

Write-Host "Done. Let Unity refresh packages (or reopen project)."
