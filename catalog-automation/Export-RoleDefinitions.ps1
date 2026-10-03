#requires -Version 7.0
<#
.SYNOPSIS
    Writes the built-in Entra directory role definitions as one JSON file per role.

.DESCRIPTION
    Built-in role definitions are identical in every tenant, so the snapshot holds no tenant data:
    only roles with isBuiltIn = true, never custom roles, assignments or policies. Each file is
    <templateId>.json in deterministic JSON (sorted keys, sorted string arrays), so a git diff of
    the snapshot shows exactly which action was added or removed.

    Run it against a dedicated dev tenant with an app that only has RoleManagement.Read.Directory.

.PARAMETER OutputPath
    Folder to write to. Files of roles that no longer exist are removed.

.PARAMETER Definitions
    Role definitions to write instead of calling Graph. For tests.

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
    [int] $MinimumRoles = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'src')
. (Join-Path $srcPath 'helpers.ps1')
. (Join-Path $srcPath 'graphEndpoints.ps1')

if (-not $PSBoundParameters.ContainsKey('Definitions')) {
    $token = Get-GraphAccessTokenString
    $Definitions = @(Get-AllGraphItems -Uri $script:GraphEndpoints.RoleDefinitions -AccessToken $token)
}

$builtIn = @($Definitions | Where-Object { $_.PSObject.Properties['isBuiltIn']?.Value -eq $true })
if ($builtIn.Count -lt $MinimumRoles) {
    throw "Only $($builtIn.Count) built-in roles found (minimum $MinimumRoles). Refusing to overwrite the snapshot."
}

$guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$written = [System.Collections.Generic.HashSet[string]]::new()
foreach ($role in $builtIn) {
    $templateId = [string]($role.PSObject.Properties['templateId']?.Value ?? $role.id)
    if ($templateId -notmatch $guid) { throw "Role '$($role.displayName)' has no GUID templateId." }
    $name = "$($templateId.ToLowerInvariant()).json"
    $json = ($role | ConvertTo-DeterministicJson) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText((Join-Path $OutputPath $name), $json + "`n", [System.Text.UTF8Encoding]::new($false))
    [void]$written.Add($name)
}

foreach ($file in Get-ChildItem -Path $OutputPath -Filter '*.json' -File) {
    if (-not $written.Contains($file.Name)) { Remove-Item $file.FullName }
}

Write-Host "Wrote $($written.Count) built-in role definitions to $OutputPath"
