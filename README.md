# littlegrasshopper-unity-upm-switcher

Central PowerShell tool to switch Unity custom packages between:

- `file:` (local development)
- `git` (distribution / pinned refs)

It updates `Packages/manifest.json` in the studio's Unity projects, one line per package.

## Files

- `Switch-UpmSources.ps1`: main script (Windows PowerShell 5.1)
- `upm-switcher.config.json`: where the projects and packages live, plus optional profiles

## Quick start

Run from this repository root:

```powershell
# Where does each game stand? (read-only)
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Status

# Back to file: to work on a package, in every game that uses it through git
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode file -Package com.littlegrasshopper.testcampaign

# New tag pushed: move every game that uses the package through git to the latest tag
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode git -Package com.littlegrasshopper.testcampaign -DryRun
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode git -Package com.littlegrasshopper.testcampaign

# Switch a game that is on file: today (named explicitly), to a given ref
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode git -Package com.littlegrasshopper.testcampaign -Project Fairground -Ref v0.1.0

# Profiles still work
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode file -Profile UnderTheSkin -DryRun
```

## Which projects are switched

- `-Profile <name>`: the profile's project (or `-ProjectPath`), the profile's packages (or the `-Package` subset).
- `-ProjectPath <path> -Package <names>`: that project only.
- `-Package <names> -Project <names>`: those projects under `projectsRoot`.
- `-Package <names>` alone: every project under `projectsRoot` that **already uses the package through git**.
  Projects on `file:` are left alone, so a bump never pulls a game out of local development.

## Which git ref

`-Ref`, else the entry's `gitRef` in the config, else the **latest version tag of the local package
repository** (`v1.0.0` ranks above `v1.0.0-preview.1`), else `main`. The URL is `gitUrl`, else the
local repository's `origin` remote.

Before writing anything in git mode, the script checks with `git ls-remote` that the ref exists on
the remote (a tag created but not pushed would make Unity fail). `-SkipRemoteCheck` bypasses it.

## Parameters

- `-Status` report packages (latest tag, unpushed commits) and projects (source, ref, newer tag available)
- `-Mode file|git` (required unless `-Status`)
- `-Package <name1,name2>` packages to switch (also filters `-Status`)
- `-Project <name1,name2>` project folder names under `projectsRoot`
- `-Profile <name>` profile from config
- `-ProjectPath <path>` a project path (overrides the profile's)
- `-Ref <tag|branch>` git ref to use
- `-CleanLock` remove the switched packages' entries from `packages-lock.json`
- `-SkipRemoteCheck` do not check the ref on the remote
- `-DryRun` preview without writing files

## Config format

`upm-switcher.config.json`:

```json
{
  "projectsRoot": "D:/Unity",
  "packagesRoot": "D:/Unity/WorkspaceCustomPackages",
  "packagePrefix": "com.littlegrasshopper.",
  "excludeProjects": ["_*", "*_tmp"],
  "packages": [
    {
      "name": "com.kinema.vr",
      "localPath": "D:/Unity/WorkspaceCustomPackages/kinema/Packages/com.kinema.vr",
      "repoPath": "D:/Unity/WorkspaceCustomPackages/kinema",
      "gitUrl": "https://github.com/3dnxstudio/kinema.git?path=/Packages/com.kinema.vr"
    }
  ],
  "profiles": [
    {
      "name": "UnderTheSkin",
      "projectPath": "D:/Unity/UnderTheSkin",
      "packages": [ { "name": "com.littlegrasshopper.testcampaign" } ]
    }
  ]
}
```

- Package catalog: every folder of `packagesRoot` whose name starts with `packagePrefix` and holds a
  `package.json` (the package name is read from it). `packages` adds to or overrides that catalog:
  use it for a package outside the prefix, or one that sits in a subfolder of its repository
  (`repoPath` is then the repository, read for tags and push state; `gitUrl` keeps UPM's `?path=`).
- Projects: every folder of `projectsRoot` with a `Packages/manifest.json`, minus `excludeProjects`
  (wildcards; `_*` by default, which skips the package host projects).
- A profile entry can give just a `name`; `localPath`, `gitUrl` and `gitRef` then come from the catalog.
  Set `gitRef` only to pin a ref; leave it out to follow the latest tag.

## Notes

- Only the value of each switched package changes in `manifest.json`: formatting, key order,
  encoding (UTF-8 with or without BOM) and line endings are kept, so a switch is a one-line diff.
  A package missing from `dependencies` is inserted at its alphabetical place.
- `-CleanLock` removes the package's top-level entry from `packages-lock.json` and leaves the
  rest of the file as it is; Unity regenerates the entry on the next resolve.
- In `file` mode the path is written relative to `Packages/` (`file:../../...`) when the project
  and the package are on the same drive, and absolute (`file:D:/...`) when they are not.
- Unity may auto-refresh after manifest changes; if not, reopen the project.
