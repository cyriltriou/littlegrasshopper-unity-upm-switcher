param(
    [ValidateSet("file", "git")]
    [string]$Mode,
    [switch]$Status,

    [string]$ConfigPath = "",
    [string]$Profile,
    [string]$ProjectPath,
    [string[]]$Project,
    [string[]]$Package,
    [string]$Ref,

    [switch]$CleanLock,
    [switch]$SkipRemoteCheck,
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
# Config, package catalog and projects
# ---------------------------------------------------------------------------

function Get-OptionalProperty {
    param($Object, [string]$Name)

    # StrictMode throws on a missing property: optional config keys go through here.
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Split-NameList {
    param([string[]]$Values)

    # With "powershell -File", "-Package a,b" arrives as the single string "a,b": split it.
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        foreach ($name in ($value -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($name)) { $name.Trim() }
        }
    }
}

function ConvertTo-NormalizedPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/')).Replace("\", "/")
}

function Invoke-Git {
    param([string]$RepoPath, [string[]]$Arguments)

    # Native stderr must not turn into terminating errors under $ErrorActionPreference = "Stop" (PowerShell 5.1).
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ([string]::IsNullOrWhiteSpace($RepoPath)) { $output = & git @Arguments 2>$null }
        else { $output = & git -C $RepoPath @Arguments 2>$null }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = @($output | ForEach-Object { [string]$_ }) }
}

$script:RepoInfoCache = @{}

function Get-PackageRepoInfo {
    param([string]$LocalPath)

    if ($script:RepoInfoCache.ContainsKey($LocalPath)) { return $script:RepoInfoCache[$LocalPath] }

    $info = [pscustomobject]@{
        Exists    = (Test-Path -Path $LocalPath)
        IsGit     = $false
        Origin    = $null
        LatestTag = $null
        Ahead     = $null
        Dirty     = $false
    }

    if ($info.Exists) {
        $top = Invoke-Git -RepoPath $LocalPath -Arguments @("rev-parse", "--show-toplevel")
        # The package folder must be the repository root, not a folder inside another repository.
        if ($top.ExitCode -eq 0 -and $top.Output.Count -gt 0 -and
            [string]::Equals((ConvertTo-NormalizedPath $top.Output[0]), (ConvertTo-NormalizedPath $LocalPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            $info.IsGit = $true

            $origin = Invoke-Git -RepoPath $LocalPath -Arguments @("remote", "get-url", "origin")
            if ($origin.ExitCode -eq 0 -and $origin.Output.Count -gt 0) { $info.Origin = $origin.Output[0].Trim() }

            # Highest version tag; "-suffix" tags (v1.0.0-preview.1) sort before the release (v1.0.0).
            $tags = Invoke-Git -RepoPath $LocalPath -Arguments @("-c", "versionsort.suffix=-", "tag", "--list", "--sort=-v:refname")
            $info.LatestTag = $tags.Output | Where-Object { $_ -match '^v?\d' } | Select-Object -First 1

            $ahead = Invoke-Git -RepoPath $LocalPath -Arguments @("rev-list", "--count", "@{u}..HEAD")
            if ($ahead.ExitCode -eq 0 -and $ahead.Output.Count -gt 0) { $info.Ahead = [int]$ahead.Output[0] }

            $status = Invoke-Git -RepoPath $LocalPath -Arguments @("status", "--porcelain")
            $info.Dirty = $status.Output.Count -gt 0
        }
    }

    $script:RepoInfoCache[$LocalPath] = $info
    return $info
}

function New-PackageEntry {
    param([string]$Name)

    return [pscustomobject]@{ name = $Name; localPath = $null; gitUrl = $null; gitRef = $null }
}

function Resolve-PackageEntry {
    param([hashtable]$Catalog, $Entry)

    # Catalog values, overridden by the fields the entry sets (profile entries may give only a name).
    $name = Get-OptionalProperty $Entry "name"
    if ([string]::IsNullOrWhiteSpace($name)) { throw "A package entry in the config is missing 'name'" }

    $resolved = New-PackageEntry -Name $name
    if ($Catalog.ContainsKey($name)) {
        foreach ($key in @("localPath", "gitUrl", "gitRef")) { $resolved.$key = $Catalog[$name].$key }
    }
    foreach ($key in @("localPath", "gitUrl", "gitRef")) {
        $value = Get-OptionalProperty $Entry $key
        if (-not [string]::IsNullOrWhiteSpace($value)) { $resolved.$key = $value }
    }
    return $resolved
}

function Get-PackageCatalog {
    param($Config)

    # 1. Every folder of packagesRoot (matching packagePrefix) that holds a package.json.
    # 2. Entries of the top-level "packages" array add to or override what was found.
    $catalog = @{}
    $packagesRoot = Get-OptionalProperty $Config "packagesRoot"
    $prefix = Get-OptionalProperty $Config "packagePrefix"

    if (-not [string]::IsNullOrWhiteSpace($packagesRoot) -and (Test-Path -Path $packagesRoot)) {
        foreach ($dir in @(Get-ChildItem -Path $packagesRoot -Directory)) {
            if (-not [string]::IsNullOrWhiteSpace($prefix) -and
                -not $dir.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $packageJson = Join-Path -Path $dir.FullName -ChildPath "package.json"
            if (-not (Test-Path -Path $packageJson)) { continue }

            $name = Get-OptionalProperty (Get-Content -Raw -Encoding UTF8 -Path $packageJson | ConvertFrom-Json) "name"
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $entry = New-PackageEntry -Name $name
            $entry.localPath = ConvertTo-NormalizedPath $dir.FullName
            $catalog[$name] = $entry
        }
    }

    $declared = Get-OptionalProperty $Config "packages"
    if ($null -ne $declared) {
        foreach ($item in @($declared)) {
            $resolved = Resolve-PackageEntry -Catalog $catalog -Entry $item
            $catalog[$resolved.name] = $resolved
        }
    }

    return $catalog
}

function Get-StudioProjects {
    param($Config)

    $root = Get-OptionalProperty $Config "projectsRoot"
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Set 'projectsRoot' in the config to work across projects" }
    if (-not (Test-Path -Path $root)) { throw "projectsRoot not found: $root" }

    $excludes = Get-OptionalProperty $Config "excludeProjects"
    if ($null -eq $excludes) { $excludes = @("_*") }

    foreach ($dir in @(Get-ChildItem -Path $root -Directory | Sort-Object Name)) {
        if (-not (Test-Path -Path (Join-Path -Path $dir.FullName -ChildPath "Packages\manifest.json"))) { continue }

        $excluded = $false
        foreach ($pattern in @($excludes)) {
            if ($dir.Name -like $pattern) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName }
    }
}

function Get-ManifestDependencies {
    param([string]$ProjectPath)

    $manifest = Get-Content -Raw -Encoding UTF8 -Path (Join-Path -Path $ProjectPath -ChildPath "Packages\manifest.json") | ConvertFrom-Json
    $result = @{}
    $deps = Get-OptionalProperty $manifest "dependencies"
    if ($null -ne $deps) {
        foreach ($property in $deps.PSObject.Properties) { $result[$property.Name] = [string]$property.Value }
    }
    return $result
}

function Get-DependencySource {
    param([string]$Value)

    if ($Value.StartsWith("file:")) {
        return [pscustomobject]@{ Kind = "file"; Url = $Value.Substring(5); Ref = $null }
    }
    if ($Value -match '^(git\+)?(https?|ssh|git)://' -or $Value -match '^git@' -or $Value -match '\.git([#?]|$)') {
        $hash = $Value.LastIndexOf("#")
        if ($hash -ge 0) {
            return [pscustomobject]@{ Kind = "git"; Url = $Value.Substring(0, $hash); Ref = $Value.Substring($hash + 1) }
        }
        return [pscustomobject]@{ Kind = "git"; Url = $Value; Ref = $null }
    }
    return [pscustomobject]@{ Kind = "registry"; Url = $null; Ref = $Value }
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

function Get-GitTarget {
    param($Pkg, [string]$ExplicitRef)

    $url = $Pkg.gitUrl
    $info = $null
    if (-not [string]::IsNullOrWhiteSpace($Pkg.localPath)) { $info = Get-PackageRepoInfo -LocalPath $Pkg.localPath }
    if ([string]::IsNullOrWhiteSpace($url) -and $null -ne $info) { $url = $info.Origin }
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Package '$($Pkg.name)' has no gitUrl and its local repository has no 'origin' remote"
    }

    # -Ref, then gitRef from the config, then the latest version tag of the local repository, then main.
    $ref = $ExplicitRef
    $refSource = "-Ref"
    if ([string]::IsNullOrWhiteSpace($ref)) { $ref = $Pkg.gitRef; $refSource = "config gitRef" }
    if ([string]::IsNullOrWhiteSpace($ref) -and $null -ne $info) { $ref = $info.LatestTag; $refSource = "latest local tag" }
    if ([string]::IsNullOrWhiteSpace($ref)) { $ref = "main"; $refSource = "default, no tag found" }

    return [pscustomobject]@{ Name = $Pkg.name; Url = $url; Ref = $ref; RefSource = $refSource; Value = "$url#$ref" }
}

function Test-RemoteRef {
    param([string]$Url, [string]$Ref)

    if ($Ref -match '^[0-9a-f]{7,40}$') { return $true }  # commit hash: ls-remote cannot tell

    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = "0"
    try {
        $result = Invoke-Git -RepoPath "" -Arguments @("ls-remote", "--exit-code", $Url, "refs/tags/$Ref", "refs/heads/$Ref")
    }
    finally {
        $env:GIT_TERMINAL_PROMPT = $previousPrompt
    }

    if ($result.ExitCode -eq 0) { return $true }
    if ($result.ExitCode -eq 2) { return $false }
    throw "git ls-remote failed for $Url (exit code $($result.ExitCode)). Check access, or pass -SkipRemoteCheck"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

function Show-Status {
    param($Config, [hashtable]$Catalog, [string[]]$PackageFilter)

    $names = @($Catalog.Keys | Sort-Object)
    if ($PackageFilter.Count -gt 0) { $names = @($names | Where-Object { $PackageFilter -contains $_ }) }

    $packageRows = foreach ($name in $names) {
        $pkg = $Catalog[$name]
        $repo = "-"
        $latest = $null
        if (-not [string]::IsNullOrWhiteSpace($pkg.localPath)) {
            $info = Get-PackageRepoInfo -LocalPath $pkg.localPath
            $latest = $info.LatestTag
            if (-not $info.Exists) { $repo = "local folder missing" }
            elseif (-not $info.IsGit) { $repo = "not a git repository" }
            elseif ($null -eq $info.Origin) { $repo = "no remote" }
            elseif ($null -eq $info.Ahead) { $repo = "no upstream branch" }
            elseif ($info.Ahead -gt 0) { $repo = "$($info.Ahead) commit(s) not pushed" }
            else { $repo = "pushed" }
            if ($info.Dirty) { $repo += ", uncommitted changes" }
        }
        $tagText = "-"
        if ($latest) { $tagText = $latest }
        [pscustomobject]@{ Package = $name; "Latest tag" = $tagText; "Local repository" = $repo }
    }

    Write-Host "Packages"
    @($packageRows) | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host

    $projectRows = foreach ($proj in @(Get-StudioProjects -Config $Config)) {
        $deps = Get-ManifestDependencies -ProjectPath $proj.Path
        $packagesDir = Join-Path -Path $proj.Path -ChildPath "Packages"
        foreach ($name in @($deps.Keys | Sort-Object)) {
            if ($names -notcontains $name) { continue }

            $pkg = $Catalog[$name]
            $source = Get-DependencySource -Value $deps[$name]
            $ref = "-"
            $note = ""

            if ($source.Kind -eq "git") {
                $latest = $null
                if (-not [string]::IsNullOrWhiteSpace($pkg.localPath)) { $latest = (Get-PackageRepoInfo -LocalPath $pkg.localPath).LatestTag }
                if ($source.Ref) { $ref = $source.Ref }
                if ($null -eq $source.Ref) { $note = "no ref: follows the default branch" }
                elseif ($latest -and $source.Ref -eq $latest) { $note = "latest tag" }
                elseif ($latest -and $source.Ref -match '^v?\d') { $note = "newer tag available: $latest" }
            }
            elseif ($source.Kind -eq "file") {
                $target = $source.Url
                if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path -Path $packagesDir -ChildPath $target }
                if (-not [string]::IsNullOrWhiteSpace($pkg.localPath) -and
                    -not [string]::Equals((ConvertTo-NormalizedPath $target), (ConvertTo-NormalizedPath $pkg.localPath), [System.StringComparison]::OrdinalIgnoreCase)) {
                    $note = "other folder: $($source.Url)"
                }
            }
            else {
                $ref = $source.Ref
            }

            [pscustomobject]@{ Project = $proj.Name; Package = $name; Source = $source.Kind; Ref = $ref; Note = $note }
        }
    }

    Write-Host "Projects ($(Get-OptionalProperty $Config 'projectsRoot'))"
    if (@($projectRows).Count -eq 0) { Write-Host "  No project references these packages." }
    else { @($projectRows) | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host }
}

# ---------------------------------------------------------------------------
# Switch one project
# ---------------------------------------------------------------------------

function Update-Project {
    param(
        [string]$ProjectLabel,
        [string]$ProjectPath,
        [object[]]$Targets,
        [bool]$CleanLockEntries,
        [bool]$IsDryRun
    )

    # $Targets: objects with Name and Value (the new manifest value).
    $manifestPath = Join-Path -Path $ProjectPath -ChildPath "Packages\manifest.json"
    $lockPath = Join-Path -Path $ProjectPath -ChildPath "Packages\packages-lock.json"
    if (-not (Test-Path -Path $manifestPath)) { throw "manifest.json not found at: $manifestPath" }

    Write-Host "== $ProjectLabel"

    $manifestFile = Read-TextFile -Path $manifestPath
    $manifestText = $manifestFile.Text

    $updates = @()
    foreach ($target in $Targets) {
        $result = Set-ManifestDependency -Text $manifestText -PackageName $target.Name -Value $target.Value
        if ($null -eq $result.OldValue) {
            $status = "added"
            $manifestText = $result.Text
        }
        elseif ($result.OldValue -ceq $target.Value) {
            $status = "unchanged"
        }
        else {
            $status = "changed"
            $manifestText = $result.Text
        }

        $updates += [pscustomobject]@{
            Package  = $target.Name
            Status   = $status
            OldValue = $result.OldValue
            NewValue = $target.Value
        }
    }

    # Safety net: the edited text must still be valid JSON and carry the expected values.
    $check = ConvertFrom-Json -InputObject $manifestText
    foreach ($u in $updates) {
        if ($check.dependencies.PSObject.Properties[$u.Package].Value -cne $u.NewValue) {
            throw "Internal error: '$($u.Package)' does not have the expected value after edit; nothing written"
        }
    }

    $updates | Format-List | Out-String -Width 4096 | Write-Host

    if ($manifestText -ceq $manifestFile.Text) {
        Write-Host "manifest.json already up to date: $manifestPath"
    }
    elseif ($IsDryRun) {
        Write-Host "DryRun: manifest.json would be updated at $manifestPath"
    }
    else {
        Write-TextFile -Path $manifestPath -Text $manifestText -HasBom $manifestFile.HasBom
        Write-Host "Updated $manifestPath"
    }

    if (-not $CleanLockEntries) { return }

    if (-not (Test-Path -Path $lockPath)) {
        Write-Host "packages-lock.json not found: $lockPath"
        return
    }

    $lockFile = Read-TextFile -Path $lockPath
    $lockText = $lockFile.Text
    $removed = @()
    foreach ($target in $Targets) {
        $newLockText = Remove-LockDependency -Text $lockText -PackageName $target.Name
        if ($null -ne $newLockText) {
            $lockText = $newLockText
            $removed += $target.Name
        }
    }

    if ($removed.Count -eq 0) {
        Write-Host "No matching entries to remove from packages-lock.json"
        return
    }

    $lockCheck = ConvertFrom-Json -InputObject $lockText
    foreach ($name in $removed) {
        if ($lockCheck.dependencies.PSObject.Properties.Name -contains $name) {
            throw "Internal error: '$name' still in packages-lock.json after edit; nothing written"
        }
    }

    if ($IsDryRun) {
        Write-Host "DryRun: would remove lock entries: $($removed -join ', ')"
    }
    else {
        Write-TextFile -Path $lockPath -Text $lockText -HasBom $lockFile.HasBom
        Write-Host "Removed lock entries: $($removed -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -Raw -Encoding UTF8 -Path $ConfigPath | ConvertFrom-Json
$catalog = Get-PackageCatalog -Config $config
$packageNames = @(Split-NameList -Values $Package)
$projectNames = @(Split-NameList -Values $Project)

foreach ($name in $packageNames) {
    if (-not $catalog.ContainsKey($name) -and [string]::IsNullOrWhiteSpace($Profile)) {
        throw "Unknown package '$name'. Known: $((@($catalog.Keys) | Sort-Object) -join ', ')"
    }
}

if ($Status) {
    Show-Status -Config $config -Catalog $catalog -PackageFilter $packageNames
    return
}

if ([string]::IsNullOrWhiteSpace($Mode)) {
    throw "Specify -Mode file|git, or -Status"
}

# Jobs: one per project, each with the package entries to switch.
$jobs = @()

if (-not [string]::IsNullOrWhiteSpace($Profile) -or -not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $entries = @()
    $effectiveProjectPath = $ProjectPath

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $profiles = Get-OptionalProperty $config "profiles"
        $selectedProfile = $null
        if ($null -ne $profiles) { $selectedProfile = @($profiles) | Where-Object { $_.name -eq $Profile } | Select-Object -First 1 }
        if ($null -eq $selectedProfile) { throw "Profile '$Profile' not found in $ConfigPath" }

        if ([string]::IsNullOrWhiteSpace($effectiveProjectPath)) { $effectiveProjectPath = Get-OptionalProperty $selectedProfile "projectPath" }
        $profilePackages = Get-OptionalProperty $selectedProfile "packages"
        if ($null -eq $profilePackages -or @($profilePackages).Count -eq 0) { throw "No packages declared in profile '$Profile'" }
        $entries = @(@($profilePackages) | ForEach-Object { Resolve-PackageEntry -Catalog $catalog -Entry $_ })

        if ($packageNames.Count -gt 0) {
            $entries = @($entries | Where-Object { $packageNames -contains $_.name })
            if ($entries.Count -eq 0) { throw "No package of profile '$Profile' matched -Package values: $($packageNames -join ', ')" }
        }
    }
    else {
        if ($packageNames.Count -eq 0) { throw "With -ProjectPath and no -Profile, name the packages with -Package" }
        $entries = @($packageNames | ForEach-Object { $catalog[$_] })
    }

    if ([string]::IsNullOrWhiteSpace($effectiveProjectPath)) {
        throw "Project path is required. Set profile.projectPath in config or pass -ProjectPath"
    }
    $jobs += [pscustomobject]@{ Label = $effectiveProjectPath; Path = $effectiveProjectPath; Entries = $entries }
}
else {
    if ($packageNames.Count -eq 0) {
        throw "Name the packages with -Package (add -Project to choose the projects), or use -Profile"
    }
    $entries = @($packageNames | ForEach-Object { $catalog[$_] })
    $projList = @(Get-StudioProjects -Config $config)

    if ($projectNames.Count -gt 0) {
        foreach ($name in $projectNames) {
            $match = $projList | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($null -eq $match) { throw "Project '$name' not found under projectsRoot (or excluded). Known: $(($projList | ForEach-Object { $_.Name }) -join ', ')" }
            $jobs += [pscustomobject]@{ Label = $match.Name; Path = $match.Path; Entries = $entries }
        }
    }
    else {
        # Default targets: projects that already use the package through git. Projects on file: are left alone.
        foreach ($proj in $projList) {
            $deps = Get-ManifestDependencies -ProjectPath $proj.Path
            $projectEntries = @($entries | Where-Object { $deps.ContainsKey($_.name) -and (Get-DependencySource -Value $deps[$_.name]).Kind -eq "git" })
            if ($projectEntries.Count -gt 0) {
                $jobs += [pscustomobject]@{ Label = $proj.Name; Path = $proj.Path; Entries = $projectEntries }
            }
        }
        if ($jobs.Count -eq 0) {
            Write-Host "No project uses $($packageNames -join ', ') through git. Name the projects with -Project to switch them."
            return
        }
    }
}

# Git mode: resolve each package's URL and ref once, and check the ref exists on the remote before writing anything.
$gitTargets = @{}
if ($Mode -eq "git") {
    foreach ($entry in @($jobs | ForEach-Object { $_.Entries } | Sort-Object name -Unique)) {
        $target = Get-GitTarget -Pkg $entry -ExplicitRef $Ref
        Write-Host "$($target.Name) -> #$($target.Ref) ($($target.RefSource))"
        if (-not $SkipRemoteCheck) {
            if (-not (Test-RemoteRef -Url $target.Url -Ref $target.Ref)) {
                throw "'$($target.Ref)' not found on $($target.Url) (not pushed?). Nothing written. Push the tag, or pass -SkipRemoteCheck"
            }
        }
        $gitTargets[$entry.name] = $target
    }
    Write-Host ""
}

foreach ($job in $jobs) {
    $packagesDir = Join-Path -Path $job.Path -ChildPath "Packages"
    $targets = foreach ($entry in $job.Entries) {
        if ($Mode -eq "git") {
            [pscustomobject]@{ Name = $entry.name; Value = $gitTargets[$entry.name].Value }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($entry.localPath)) { throw "Package '$($entry.name)' is missing localPath" }
            $localPath = [System.IO.Path]::GetFullPath($entry.localPath)
            if (-not (Test-Path -Path $localPath)) { throw "Local path does not exist for package '$($entry.name)': $localPath" }
            [pscustomobject]@{ Name = $entry.name; Value = (Get-FileDependencyValue -PackagesDir $packagesDir -LocalPath $localPath) }
        }
    }

    Update-Project -ProjectLabel $job.Label -ProjectPath $job.Path -Targets @($targets) -CleanLockEntries $CleanLock.IsPresent -IsDryRun $DryRun.IsPresent
}

Write-Host "Done. Let Unity refresh packages (or reopen project)."
