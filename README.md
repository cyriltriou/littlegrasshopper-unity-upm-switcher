# littlegrasshopper-unity-upm-switcher

Central PowerShell tool to switch Unity custom packages between:

- `file:` (local development)
- `git` (distribution / pinned refs)

It updates `Packages/manifest.json` in target Unity projects.

## Files

- `Switch-UpmSources.ps1`: main script
- `upm-switcher.config.json`: profiles and package mapping

## Quick start

Run from this repository root:

```powershell
# Preview what would change
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode file -Profile RogueliteSurvivor -DryRun

# Switch to local file mode
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode file -Profile RogueliteSurvivor -CleanLock

# Switch to git mode
powershell -ExecutionPolicy Bypass -File .\Switch-UpmSources.ps1 -Mode git -Profile RogueliteSurvivor -CleanLock
```

## Parameters

- `-Mode file|git` (required)
- `-Profile <name>` profile from config
- `-ProjectPath <path>` override profile project path
- `-Package <name1,name2>` optional subset of packages to switch
- `-CleanLock` remove selected packages from `packages-lock.json`
- `-DryRun` preview without writing files

## Config format

`upm-switcher.config.json`:

```json
{
  "profiles": [
    {
      "name": "RogueliteSurvivor",
      "projectPath": "D:/Unity/RogueliteSurvivor",
      "packages": [
        {
          "name": "com.littlegrasshopper.tools.codecksbacklog",
          "localPath": "D:/Unity/WorkspaceCustomPackages/com.littlegrasshopper.tools.codecksbacklog",
          "gitUrl": "https://github.com/<owner>/com.littlegrasshopper.tools.codecksbacklog.git",
          "gitRef": "main"
        }
      ]
    }
  ]
}
```

## Notes

- In `file` mode, package source of truth is the external repository path (`localPath`).
- In `git` mode, package source of truth is the package git repository at the selected `gitRef`.
- Unity may auto-refresh after manifest changes; if not, reopen the project.
- Only the value of each switched package changes in `manifest.json`: formatting, key order,
  encoding (UTF-8 with or without BOM) and line endings are kept, so a switch is a one-line diff.
  A package missing from `dependencies` is inserted at its alphabetical place.
- `-CleanLock` removes the package's top-level entry from `packages-lock.json` and leaves the
  rest of the file as it is; Unity regenerates the entry on the next resolve.
- In `file` mode the path is written relative to `Packages/` (`file:../../...`) when the project
  and the package are on the same drive, and absolute (`file:D:/...`) when they are not.
- `gitRef` is optional (defaults to `main`). `-Package a,b` also works through `powershell -File`.
