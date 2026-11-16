#requires -Version 7.0
<#
.SYNOPSIS
    Writes the built-in Entra directory role definitions as one JSON file per role.

.DESCRIPTION
    Built-in role definitions are identical in every tenant, so the snapshot holds no tenant data:
    only roles with isBuiltIn = true, never custom roles, assignments or policies. Each file is
    <templateId>.json in deterministic JSON (sorted keys, sorted string arrays), so a git diff of
    the snapshot shows exactly which action was added or removed.

    Completeness: the list call is made without $select, so it returns every property the list
    endpoint knows. Any documented unifiedRoleDefinition property that is still missing from ALL
    roles after that call is fetched with one extra call, $select=id,<missing properties>, and merged
    into the roles by id. A documented property that the API does not return even then is not an
    error: it is listed in export-status.json and reported with Write-Warning.

    Regression guard: a core property (templateId, id, displayName, isBuiltIn, isPrivileged,
    rolePermissions) that every previously written file had, and that no role has now, stops the
    export (API shape regression); nothing is written then. Any other property that disappears is
    written as is, listed under lostProperties in export-status.json, and reaches review through the
    comparison.

    export-status.json goes next to the output folder (not inside it, so role-definitions/ holds only
    role files). It has no timestamp, so it changes only when the content changes.

.PARAMETER OutputPath
    Folder to write to. Files of roles that no longer exist are removed.

.PARAMETER Definitions
    Role definitions to write instead of calling Graph. For tests. Without -FetchSelect, the extra
    $select call is skipped.

.PARAMETER FetchSelect
    Scriptblock that takes a $select string and returns the role items for it, instead of calling
    Graph. For tests. Without it, the real endpoint is called (only when a documented property is missing).

.PARAMETER StatusPath
    Where to write export-status.json. Defaults to export-status.json in the parent folder of -OutputPath.

.PARAMETER MinimumRoles
    Refuse to write fewer roles than this. An empty or truncated Graph response must not wipe the snapshot.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $OutputPath,

    [Parameter()]
    [array] $Definitions,

    [Parameter()]
    [scriptblock] $FetchSelect,

    [Parameter()]
    [string] $StatusPath,

    [Parameter()]
    [int] $MinimumRoles = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'src')
. (Join-Path $srcPath 'helpers.ps1')
. (Join-Path $srcPath 'graphEndpoints.ps1')

# Documented properties of unifiedRoleDefinition (beta).
# Without these the snapshot is unusable: losing one from every role stops the export.
$core = @('templateId', 'id', 'displayName', 'isBuiltIn', 'isPrivileged', 'rolePermissions')
$documented = @('allowedPrincipalTypes', 'description', 'displayName', 'id', 'isBuiltIn', 'isEnabled', 'isPrivileged', 'resourceScopes', 'rolePermissions', 'templateId', 'version')

if (-not $PSBoundParameters.ContainsKey('Definitions')) {
    $token = Get-GraphAccessTokenString
    $Definitions = @(Get-AllGraphItems -Uri $script:GraphEndpoints.RoleDefinitions -AccessToken $token)
    if (-not $PSBoundParameters.ContainsKey('FetchSelect')) {
        $FetchSelect = {
            param([string] $Select)
            Get-AllGraphItems -Uri "$($script:GraphEndpoints.RoleDefinitions)?`$select=$Select" -AccessToken $token
        }.GetNewClosure()
    }
}

$builtIn = @($Definitions | Where-Object { $_.PSObject.Properties['isBuiltIn']?.Value -eq $true })
if ($builtIn.Count -lt $MinimumRoles) {
    throw "Only $($builtIn.Count) built-in roles found (minimum $MinimumRoles). Refusing to overwrite the snapshot."
}

function Get-PropertyNames {
    param([array] $Roles)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($role in $Roles) {
        foreach ($p in $role.PSObject.Properties) { if ($p.Name -notlike '@odata.*') { [void]$set.Add($p.Name) } }
    }
    return , $set
}

# 1. Documented properties missing from every role: one extra call with $select, merged by id.
$present = Get-PropertyNames $builtIn
$missing = @($documented | Where-Object { -not $present.Contains($_) })
if ($missing.Count -gt 0 -and $FetchSelect) {
    $select = (@('id') + $missing) -join ','
    $byId = @{}
    foreach ($item in @(& $FetchSelect $select)) {
        $itemId = $item.PSObject.Properties['id']?.Value
        if ($itemId) { $byId[([string]$itemId).ToLowerInvariant()] = $item }
    }
    foreach ($role in $builtIn) {
        $roleId = [string]($role.PSObject.Properties['id']?.Value ?? $role.PSObject.Properties['templateId']?.Value)
        $item = $byId[$roleId.ToLowerInvariant()]
        if (-not $item) { continue }
        foreach ($name in $missing) {
            $prop = $item.PSObject.Properties[$name]
            if ($prop) { $role | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force }
        }
    }
}

$names = Get-PropertyNames $builtIn
$stillMissing = @($documented | Where-Object { -not $names.Contains($_) } | Sort-Object)
foreach ($name in $stillMissing) {
    Write-Warning "Documented role property '$name' is not returned by the API for any built-in role."
}

$guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$files = [ordered]@{}
foreach ($role in $builtIn) {
    $templateId = [string]($role.PSObject.Properties['templateId']?.Value ?? $role.PSObject.Properties['id']?.Value)
    if ($templateId -notmatch $guid) { throw "Role '$($role.displayName)' has no GUID templateId." }
    $name = "$($templateId.ToLowerInvariant()).json"
    $files[$name] = (($role | ConvertTo-DeterministicJson) -replace "`r`n", "`n") + "`n"
}

# 2. Regression guard: nothing that every previous file had may disappear. Checked before any write.
$lost = @()
$outFull = [System.IO.Path]::GetFullPath($OutputPath)
if (Test-Path -Path $outFull -PathType Container) {
    $previous = $null
    foreach ($f in Get-ChildItem -Path $outFull -Filter '*.json' -File) {
        try { $old = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json } catch { Write-Warning "Skipping unreadable $($f.Name) in the regression check."; continue }
        $oldNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($p in $old.PSObject.Properties) { [void]$oldNames.Add($p.Name) }
        if ($null -eq $previous) { $previous = $oldNames } else { $previous.IntersectWith($oldNames) }
    }
    if ($null -ne $previous -and $previous.Count -gt 0) {
        $lost = @($previous | Where-Object { -not $names.Contains($_) } | Sort-Object)
        # Only the properties everything rests on stop the export: without them the snapshot is
        # unusable, which points to an API failure. Any other lost property (resourceScopes is
        # documented as "will be deprecated soon") is written, recorded in export-status.json, and
        # reaches review through the comparison like any other change.
        $fatal = @($lost | Where-Object { $_ -in $core })
        if ($fatal.Count -gt 0) {
            throw "API shape regression: every previous role file had '$($fatal -join "', '")', and no role has it now. Refusing to overwrite the snapshot."
        }
        foreach ($name in $lost) { Write-Warning "Property '$name' was in every previous role file and is in none now." }
    }
}

# 3. Write.
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
foreach ($name in $files.Keys) {
    [System.IO.File]::WriteAllText((Join-Path $OutputPath $name), $files[$name], $utf8)
}
foreach ($file in Get-ChildItem -Path $OutputPath -Filter '*.json' -File) {
    if (-not $files.Contains($file.Name)) { Remove-Item $file.FullName }
}

$status = [ordered]@{
    roles                       = $builtIn.Count
    lostProperties              = @($lost)
    documentedProperties        = @($documented | Sort-Object)
    missingDocumentedProperties = $stillMissing
    properties                  = @($names | Sort-Object)
}
if (-not $StatusPath) {
    $StatusPath = Join-Path (Split-Path -Parent $outFull) 'export-status.json'
}
$statusJson = ($status | ConvertTo-DeterministicJson) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($StatusPath, $statusJson + "`n", $utf8)

Write-Host "Wrote $($files.Count) built-in role definitions to $OutputPath (status: $StatusPath)"
