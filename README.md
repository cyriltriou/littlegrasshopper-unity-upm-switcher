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
