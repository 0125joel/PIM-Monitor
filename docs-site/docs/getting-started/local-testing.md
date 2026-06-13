---
sidebar_position: 3
description: Run PIM Monitor locally against a real tenant without committing changes. Validate your setup before deploying to a pipeline.
---

# Local Testing

Test the scripts locally before deploying to Azure DevOps.

## Prerequisites

- PowerShell 7.0+
- Az PowerShell module (`Install-Module Az` or `winget install Microsoft.AzurePowerShell`)
- Tenant admin or PIM admin (to consent to the application)

## Run the scan manually

Open a PowerShell 7 terminal and navigate to the repo root:

```powershell
Set-Location C:\path\to\PIM-Monitor
```

Then authenticate and run the scan:

```powershell
# Authenticate interactively (opens browser)
Connect-AzAccount -Tenant "<your-tenant-id>"

# Run the scan (token acquisition is handled inside the script)
./src/Scan-PimState.ps1
```

The script will:
1. Fetch Directory Roles, PIM Groups, and lookups from Graph API
2. Compare against existing inventory (if any)
3. Write new JSON files to `inventory/`
4. Log changes to stdout

Expected output:

```
[2026-04-20T15:30:00Z] PIM Monitor scan starting
[2026-04-20T15:30:01Z] Acquiring Graph API access token
[2026-04-20T15:30:02Z] Fetching Directory Roles
  Found 87 role definitions
  Processing: Global Administrator (global-administrator)
    Permanent: 2 | Eligible: 5 | Active: 1
  ...
[2026-04-20T15:31:00Z] Scan summary:
  Total changes: 12
  High:   3
  Medium: 7
  Low:    2
[2026-04-20T15:31:01Z] PIM Monitor scan complete
```

## Verify inventory files

```powershell
Get-ChildItem inventory/
Get-ChildItem inventory/directory-roles/global-administrator/
Get-Content inventory/directory-roles/global-administrator/definition.json | Select-Object -First 20
```

You should see JSON files for each role, group, and lookup entity.

## Run twice to see diff detection

Run the scan a second time:

```powershell
./src/Scan-PimState.ps1
```

If nothing changed:

```
[2026-04-20T15:35:00Z] PIM Monitor scan complete
```

If something changed, the detected changes and their severity appear in the output.

## Check git state (optional)

If you have a git repo initialized locally:

```powershell
git status
git diff inventory/
```

This shows what changed since the last commit, which is the same comparison the pipeline will run.

## Troubleshooting

---

### `#Requires -Version 7.0` fails

You are running Windows PowerShell 5.x (the version built into Windows). Install PowerShell 7+:

- **Windows:** `winget install Microsoft.PowerShell` or `choco install pwsh`
- **macOS:** `brew install powershell`
- **Linux:** [PowerShell installation docs](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)

Make sure you launch `pwsh` (PowerShell 7), not `powershell` (Windows PowerShell 5).

---

### `Cannot find path` for `helpers.ps1`

Run the script from the repo root, not from a subdirectory:

```powershell
# Correct - run from repo root
./src/Scan-PimState.ps1

# Wrong - will fail to find sibling modules
Set-Location src
./Scan-PimState.ps1
```

---

### `Get-AzAccessToken` fails

- Run `Connect-AzAccount -Tenant "<your-tenant-id>"` first
- Verify that `Get-AzContext` shows the correct tenant after connecting
- Check that your account has PIM read permissions in the tenant

---

### `InvalidAuthenticationToken` / `IDX14102` error from Graph API

Az.Accounts 3.0+ (shipped with Az 12+) returns the token as a `SecureString` instead of a plain string. The scan script handles this automatically via `NetworkCredential` unwrapping. If you call `Get-AzAccessToken` manually outside the script and pass the token directly, convert it first:

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
$token = if ($rawToken -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $rawToken).Password
} else { $rawToken }
```

---

### `401 Unauthorized` from Graph API

The app registration is missing one or more required permissions, or admin consent was not granted.

- See [Prerequisites](./prerequisites.md) for the full permission list
- In the Azure portal, go to the app registration > **API permissions** and verify all permissions show **Granted**

---

## Next

Once local testing works, proceed to [Deployment](./installation.md).
