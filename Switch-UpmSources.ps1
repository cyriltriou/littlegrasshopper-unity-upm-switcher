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

# ---------------------------------------------------------------------------
# Text I/O: keep the file's encoding (UTF-8, with or without BOM) and its line
# endings. The JSON files are edited in place as text, never re-serialized.
# ---------------------------------------------------------------------------

function Read-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = 0
    if ($hasBom) { $offset = 3 }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return [pscustomobject]@{
        Text   = $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
        HasBom = $hasBom
    }
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][bool]$HasBom
    )

    $encoding = New-Object System.Text.UTF8Encoding($HasBom)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

# ---------------------------------------------------------------------------
# Minimal JSON scanner: locates members of an object with their character
# offsets, so a single value can be replaced without touching anything else.
# ---------------------------------------------------------------------------

function Skip-JsonWhitespace {
    param([string]$Text, [int]$Index)

    while ($Index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$Index])) { $Index++ }
    return $Index
}

function Skip-JsonString {
    param([string]$Text, [int]$Index)

    # $Text[$Index] is the opening quote; returns the index after the closing quote.
    $i = $Index + 1
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq [char]'\') { $i += 2; continue }
        if ($c -eq [char]'"') { return $i + 1 }
        $i++
    }
    throw "Unterminated JSON string at offset $Index"
}

function Skip-JsonValue {
    param([string]$Text, [int]$Index)

    $c = $Text[$Index]
    if ($c -eq [char]'"') { return Skip-JsonString -Text $Text -Index $Index }

    if ($c -eq [char]'{' -or $c -eq [char]'[') {
        $depth = 0
        $i = $Index
        while ($i -lt $Text.Length) {
            $c = $Text[$i]
            if ($c -eq [char]'"') { $i = Skip-JsonString -Text $Text -Index $i; continue }
            if ($c -eq [char]'{' -or $c -eq [char]'[') { $depth++ }
            elseif ($c -eq [char]'}' -or $c -eq [char]']') {
                $depth--
                if ($depth -eq 0) { return $i + 1 }
            }
            $i++
        }
        throw "Unterminated JSON object or array at offset $Index"
    }

    # number, true, false, null
    $i = $Index
    while ($i -lt $Text.Length -and ",}] `t`r`n".IndexOf($Text[$i]) -lt 0) { $i++ }
    if ($i -eq $Index) { throw "Unexpected character '$c' at offset $Index" }
    return $i
}

function Get-JsonObjectMembers {
    param([string]$Text, [int]$OpenIndex)

    if ($Text[$OpenIndex] -ne [char]'{') { throw "Expected '{' at offset $OpenIndex" }

    $members = New-Object System.Collections.Generic.List[object]
    $i = Skip-JsonWhitespace -Text $Text -Index ($OpenIndex + 1)
    if ($Text[$i] -eq [char]'}') {
        return [pscustomobject]@{ OpenIndex = $OpenIndex; CloseIndex = $i; Members = $members }
    }

    while ($true) {
        if ($Text[$i] -ne [char]'"') { throw "Expected a key at offset $i" }
        $keyStart = $i
        $keyEnd = Skip-JsonString -Text $Text -Index $i

        $i = Skip-JsonWhitespace -Text $Text -Index $keyEnd
        if ($Text[$i] -ne [char]':') { throw "Expected ':' at offset $i" }
        $valueStart = Skip-JsonWhitespace -Text $Text -Index ($i + 1)
        $valueEnd = Skip-JsonValue -Text $Text -Index $valueStart

        $members.Add([pscustomobject]@{
            Name       = $Text.Substring($keyStart + 1, $keyEnd - $keyStart - 2)
            KeyStart   = $keyStart
            ValueStart = $valueStart
            ValueEnd   = $valueEnd
        })

        $i = Skip-JsonWhitespace -Text $Text -Index $valueEnd
        if ($Text[$i] -eq [char]',') {
            $i = Skip-JsonWhitespace -Text $Text -Index ($i + 1)
            continue
        }
        if ($Text[$i] -eq [char]'}') {
            return [pscustomobject]@{ OpenIndex = $OpenIndex; CloseIndex = $i; Members = $members }
        }
        throw "Expected ',' or '}' at offset $i"
    }
}

function Get-DependenciesObject {
    param([string]$Text, [string]$FileLabel)

    $root = Skip-JsonWhitespace -Text $Text -Index 0
    $rootObject = Get-JsonObjectMembers -Text $Text -OpenIndex $root
    $deps = $rootObject.Members | Where-Object { $_.Name -eq "dependencies" } | Select-Object -First 1
    if ($null -eq $deps) {
        throw "No 'dependencies' object found in $FileLabel"
    }
    if ($Text[$deps.ValueStart] -ne [char]'{') {
        throw "'dependencies' is not an object in $FileLabel"
    }
    return Get-JsonObjectMembers -Text $Text -OpenIndex $deps.ValueStart
}

function Get-LineStart {
    param([string]$Text, [int]$Index)

    # Start of the line holding $Index if only whitespace precedes it on that line, else $Index itself.
    if ($Index -eq 0) { return 0 }
    $lineStart = $Text.LastIndexOf([char]10, $Index - 1) + 1
    if ($Text.Substring($lineStart, $Index - $lineStart).Trim().Length -eq 0) { return $lineStart }
    return $Index
}

function ConvertTo-JsonStringLiteral {
    param([string]$Value)

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"' { $null = $sb.Append('\"') }
            '\' { $null = $sb.Append('\\') }
            default {
                if ([int]$ch -lt 0x20) { $null = $sb.Append(('\u{0:x4}' -f [int]$ch)) }
                else { $null = $sb.Append($ch) }
            }
        }
    }
    $null = $sb.Append('"')
    return $sb.ToString()
}

function Set-ManifestDependency {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $deps = Get-DependenciesObject -Text $Text -FileLabel "manifest.json"
    $literal = ConvertTo-JsonStringLiteral -Value $Value
    $member = $deps.Members | Where-Object { $_.Name -eq $PackageName } | Select-Object -First 1

    if ($null -ne $member) {
        if ($Text[$member.ValueStart] -ne [char]'"') {
            throw "Dependency '$PackageName' in manifest.json is not a string value"
        }
        $oldLiteral = $Text.Substring($member.ValueStart, $member.ValueEnd - $member.ValueStart)
        $oldValue = (ConvertFrom-Json -InputObject ('{"v":' + $oldLiteral + '}')).v
        $newText = $Text.Substring(0, $member.ValueStart) + $literal + $Text.Substring($member.ValueEnd)
        return [pscustomobject]@{ Text = $newText; OldValue = [string]$oldValue }
    }

    # Not present yet: insert a new line at its alphabetical place (Unity keeps dependencies sorted),
    # copying the indentation and the line ending already used by the file.
    if ($deps.Members.Count -eq 0) {
        throw "manifest.json has an empty 'dependencies' object; add '$PackageName' once from the Package Manager"
    }

    $newline = "`n"
    if ($Text.Contains("`r`n")) { $newline = "`r`n" }

    $first = $deps.Members[0]
    $firstLineStart = Get-LineStart -Text $Text -Index $first.KeyStart
    $indent = $Text.Substring($firstLineStart, $first.KeyStart - $firstLineStart)
    $entry = (ConvertTo-JsonStringLiteral -Value $PackageName) + ": " + $literal

    $next = $deps.Members | Where-Object { [string]::CompareOrdinal($_.Name, $PackageName) -gt 0 } | Select-Object -First 1
    if ($null -ne $next) {
        $at = Get-LineStart -Text $Text -Index $next.KeyStart
        if ($at -eq $next.KeyStart) {
            $insert = $entry + ", "
        }
        else {
            $insert = $indent + $entry + "," + $newline
        }
        $newText = $Text.Substring(0, $at) + $insert + $Text.Substring($at)
    }
    else {
        $last = $deps.Members[$deps.Members.Count - 1]
        $insert = "," + $newline + $indent + $entry
        $newText = $Text.Substring(0, $last.ValueEnd) + $insert + $Text.Substring($last.ValueEnd)
    }

    return [pscustomobject]@{ Text = $newText; OldValue = $null }
}

function Remove-LockDependency {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    # Returns the text without the top-level entry of $PackageName, or $null if there is none.
    $deps = Get-DependenciesObject -Text $Text -FileLabel "packages-lock.json"
    $index = -1
    for ($k = 0; $k -lt $deps.Members.Count; $k++) {
        if ($deps.Members[$k].Name -eq $PackageName) { $index = $k; break }
    }
    if ($index -lt 0) { return $null }

    $member = $deps.Members[$index]
    if ($index -lt $deps.Members.Count - 1) {
        # Remove from the entry's line up to the next entry's line (trailing comma included).
        $start = Get-LineStart -Text $Text -Index $member.KeyStart
        $end = Get-LineStart -Text $Text -Index $deps.Members[$index + 1].KeyStart
    }
    elseif ($index -gt 0) {
        # Last entry: remove the comma that ends the previous entry, up to the end of this entry.
        $start = $deps.Members[$index - 1].ValueEnd
        $end = $member.ValueEnd
    }
    else {
        # Only entry.
        $start = $deps.OpenIndex + 1
        $end = $member.ValueEnd
    }

    return $Text.Substring(0, $start) + $Text.Substring($end)
}

# ---------------------------------------------------------------------------
# Config and paths
# ---------------------------------------------------------------------------

function Get-OptionalProperty {
    param($Object, [string]$Name)

    # StrictMode throws on a missing property: optional config keys go through here.
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FileDependencyValue {
    param(
        [Parameter(Mandatory = $true)][string]$PackagesDir,
        [Parameter(Mandatory = $true)][string]$LocalPath
    )

    $fromFullPath = [System.IO.Path]::GetFullPath($PackagesDir)
    $toFullPath = [System.IO.Path]::GetFullPath($LocalPath)

    # Different drives (or UNC roots): no relative path exists, write an absolute one (file:D:/...).
    $fromRoot = [System.IO.Path]::GetPathRoot($fromFullPath)
    $toRoot = [System.IO.Path]::GetPathRoot($toFullPath)
    if (-not [string]::Equals($fromRoot, $toRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "file:" + $toFullPath.TrimEnd([char[]]@('\', '/')).Replace("\", "/")
    }

    if (-not $fromFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fromFullPath += [System.IO.Path]::DirectorySeparatorChar
    }
    $fromUri = New-Object System.Uri($fromFullPath)
    $toUri = New-Object System.Uri($toFullPath)
    $relativePath = [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()).Replace("\", "/")
    if (-not ($relativePath.StartsWith("./") -or $relativePath.StartsWith("../"))) {
        $relativePath = "./$relativePath"
    }
    return "file:$relativePath"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$configRaw = Get-Content -Raw -Encoding UTF8 -Path $ConfigPath
$config = ConvertFrom-Json -InputObject $configRaw

if ($null -eq (Get-OptionalProperty $config "profiles") -or @($config.profiles).Count -eq 0) {
    throw "No profiles found in config: $ConfigPath"
}

$selectedProfile = $null
if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    $selectedProfile = $config.profiles | Where-Object { $_.name -eq $Profile } | Select-Object -First 1
    if ($null -eq $selectedProfile) {
        throw "Profile '$Profile' not found in $ConfigPath"
    }
}
elseif (@($config.profiles).Count -eq 1) {
    $selectedProfile = @($config.profiles)[0]
}
else {
    $available = ($config.profiles | ForEach-Object { $_.name }) -join ", "
    throw "Multiple profiles found. Specify -Profile. Available: $available"
}

$effectiveProjectPath = $ProjectPath
if ([string]::IsNullOrWhiteSpace($effectiveProjectPath)) {
    $effectiveProjectPath = Get-OptionalProperty $selectedProfile "projectPath"
}
if ([string]::IsNullOrWhiteSpace($effectiveProjectPath)) {
    throw "Project path is required. Set profile.projectPath in config or pass -ProjectPath"
}

$manifestPath = Join-Path -Path $effectiveProjectPath -ChildPath "Packages\manifest.json"
if (-not (Test-Path -Path $manifestPath)) {
    throw "manifest.json not found at: $manifestPath"
}

if ($null -eq (Get-OptionalProperty $selectedProfile "packages") -or @($selectedProfile.packages).Count -eq 0) {
    throw "No packages declared in profile '$($selectedProfile.name)'"
}

$selectedPackages = @($selectedProfile.packages)
if ($null -ne $Package -and $Package.Count -gt 0) {
    # With "powershell -File", "-Package a,b" arrives as the single string "a,b": split it.
    $packageSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Package) {
        foreach ($name in ($p -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($name)) { $null = $packageSet.Add($name.Trim()) }
        }
    }

    $selectedPackages = @($selectedPackages | Where-Object { $packageSet.Contains($_.name) })
    if ($selectedPackages.Count -eq 0) {
        $requested = $Package -join ", "
        throw "No package matched -Package values: $requested"
    }
}

$packagesDir = Join-Path -Path $effectiveProjectPath -ChildPath "Packages"
$lockPath = Join-Path -Path $effectiveProjectPath -ChildPath "Packages\packages-lock.json"

$manifestFile = Read-TextFile -Path $manifestPath
$manifestText = $manifestFile.Text

$updates = @()
foreach ($pkg in $selectedPackages) {
    if ([string]::IsNullOrWhiteSpace((Get-OptionalProperty $pkg "name"))) {
        throw "A package entry is missing 'name' in profile '$($selectedProfile.name)'"
    }

    $targetValue = $null
    if ($Mode -eq "file") {
        if ([string]::IsNullOrWhiteSpace((Get-OptionalProperty $pkg "localPath"))) {
            throw "Package '$($pkg.name)' is missing localPath"
        }

        $localPath = [System.IO.Path]::GetFullPath($pkg.localPath)
        if (-not (Test-Path -Path $localPath)) {
            throw "Local path does not exist for package '$($pkg.name)': $localPath"
        }

        $targetValue = Get-FileDependencyValue -PackagesDir $packagesDir -LocalPath $localPath
    }
    else {
        if ([string]::IsNullOrWhiteSpace((Get-OptionalProperty $pkg "gitUrl"))) {
            throw "Package '$($pkg.name)' is missing gitUrl"
        }

        $gitRef = Get-OptionalProperty $pkg "gitRef"
        if ([string]::IsNullOrWhiteSpace($gitRef)) {
            $gitRef = "main"
        }

        $targetValue = "$($pkg.gitUrl)#$gitRef"
    }

    $result = Set-ManifestDependency -Text $manifestText -PackageName $pkg.name -Value $targetValue
    if ($null -eq $result.OldValue) {
        $status = "added"
        $manifestText = $result.Text
    }
    elseif ($result.OldValue -ceq $targetValue) {
        $status = "unchanged"
    }
    else {
        $status = "changed"
        $manifestText = $result.Text
    }

    $updates += [pscustomobject]@{
        Package  = $pkg.name
        Status   = $status
        OldValue = $result.OldValue
        NewValue = $targetValue
    }
}

# Safety net: the edited text must still be valid JSON and carry the expected values.
$check = ConvertFrom-Json -InputObject $manifestText
foreach ($u in $updates) {
    if ($check.dependencies.PSObject.Properties[$u.Package].Value -cne $u.NewValue) {
        throw "Internal error: '$($u.Package)' does not have the expected value after edit; nothing written"
    }
}

$updates | Format-List | Out-String | Write-Host

$manifestChanged = $manifestText -cne $manifestFile.Text
if (-not $manifestChanged) {
    Write-Host "manifest.json already up to date: $manifestPath"
}
elseif ($DryRun) {
    Write-Host "DryRun: manifest.json would be updated at $manifestPath"
}
else {
    Write-TextFile -Path $manifestPath -Text $manifestText -HasBom $manifestFile.HasBom
    Write-Host "Updated $manifestPath"
}

if ($CleanLock) {
    if (-not (Test-Path -Path $lockPath)) {
        Write-Host "packages-lock.json not found: $lockPath"
    }
    else {
        $lockFile = Read-TextFile -Path $lockPath
        $lockText = $lockFile.Text
        $removed = @()
        foreach ($pkg in $selectedPackages) {
            $newLockText = Remove-LockDependency -Text $lockText -PackageName $pkg.name
            if ($null -ne $newLockText) {
                $lockText = $newLockText
                $removed += $pkg.name
            }
        }

        if ($removed.Count -eq 0) {
            Write-Host "No matching entries to remove from packages-lock.json"
        }
        else {
            $lockCheck = ConvertFrom-Json -InputObject $lockText
            foreach ($name in $removed) {
                if ($lockCheck.dependencies.PSObject.Properties.Name -contains $name) {
                    throw "Internal error: '$name' still in packages-lock.json after edit; nothing written"
                }
            }

            if ($DryRun) {
                Write-Host "DryRun: would remove lock entries: $($removed -join ', ')"
            }
            else {
                Write-TextFile -Path $lockPath -Text $lockText -HasBom $lockFile.HasBom
                Write-Host "Removed lock entries: $($removed -join ', ')"
            }
        }
    }
}

Write-Host "Done. Let Unity refresh packages (or reopen project)."
