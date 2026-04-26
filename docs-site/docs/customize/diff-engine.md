---
sidebar_position: 4
---

# Diff engine

## Change object equality

By default, `Test-ObjectEqual` serializes both objects to JSON and compares the strings. You can modify this to ignore certain fields or compare property-by-property.

Edit `src/diff.ps1` lines 54-65:

```powershell
function Test-ObjectEqual {
    param($Left, $Right)
    # Default: full JSON comparison
    # To ignore a field, remove it before comparing:
    $l = $Left | Select-Object -ExcludeProperty lastModifiedDateTime
    $r = $Right | Select-Object -ExcludeProperty lastModifiedDateTime
    return (ConvertTo-Json $l -Depth 10 -Compress) -eq (ConvertTo-Json $r -Depth 10 -Compress)
}
```

## Change the assignment key

The assignment key determines how old and new assignments are matched. Edit `Get-AssignmentKey` in `src/diff.ps1`:

```powershell
# Default for Directory Roles:
$key = "$principalId|$directoryScopeId"

# To also include roleDefinitionId (for multi-role scenarios):
$key = "$principalId|$directoryScopeId|$roleDefinitionId"
```

## Change how removed entities are detected

By default, a role or group is considered removed if its folder no longer appears in the current fetch. To change the comparison (for example, match by display name instead of slug):

Edit `Get-RemovedEntities` in `src/diff.ps1`.

## Change removed entity severity

By default, removed entities (roles or groups that disappear from the tenant) are classified as High. To change this:

Edit `Get-RemovedEntities` in `src/diff.ps1`:

```powershell
$severity = "Medium"  # was "High"
```
