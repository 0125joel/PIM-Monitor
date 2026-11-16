#requires -Version 7.0
<#
.SYNOPSIS
    Writes Microsoft's description and isPrivileged flag for every resource action the built-in roles use.

.DESCRIPTION
    A role definition lists its actions (rolePermissions[].allowedResourceActions) but says nothing
    about them. Graph describes each action per namespace:
    GET /beta/roleManagement/directory/resourceNamespaces/{namespace}/resourceActions
    with name, description and isPrivileged (Microsoft's flag for a sensitive action; it applies only to
    the microsoft.directory namespace, so it is null for every other namespace). Like the
    role definitions, this is the same in every tenant and holds no tenant data.

    The namespaces are taken from the actions in the role snapshot, so only what the roles use is
    fetched. Output, in deterministic JSON:
      <OutputPath>/<namespace>.json   actions of one namespace, sorted by name
      <OutputPath>/index.json         per namespace: status (ok, failed), action count, and for a
                                      failed namespace the error; plus how many role actions have a
                                      description (coverage)

    A namespace that fails keeps its previous file, so one bad response never wipes good data. The
    status in index.json says it is stale. Needs RoleManagement.Read.Directory, the same permission as
    the role export.

.PARAMETER RoleDefinitionsDir
    The role snapshot folder (role-definitions/) to read the action names from.

.PARAMETER OutputPath
    Folder to write to (resource-actions/). Files of namespaces no role uses any more are removed.

.PARAMETER Fetch
    Scriptblock that takes a namespace and returns its resource actions, instead of calling Graph.
    For tests.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RoleDefinitionsDir,
    [Parameter(Mandatory)] [string] $OutputPath,
    [Parameter()] [scriptblock] $Fetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'src')
. (Join-Path $srcPath 'helpers.ps1')
. (Join-Path $srcPath 'graphEndpoints.ps1')

function Write-JsonFile { param($Object, [string] $Path)
    $json = ($Object | ConvertTo-DeterministicJson) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

$roleActions = @(Get-ChildItem -Path $RoleDefinitionsDir -Filter '*.json' -File | ForEach-Object {
        $role = Get-Content -Raw -Path $_.FullName | ConvertFrom-Json
        @($role.rolePermissions | ForEach-Object { $_.allowedResourceActions }) | Where-Object { $_ }
    } | Sort-Object -Unique)
if ($roleActions.Count -eq 0) { throw "No role actions found in $RoleDefinitionsDir." }
$namespaces = @($roleActions | ForEach-Object { ($_ -split '/', 2)[0] } | Sort-Object -Unique)

if (-not $Fetch) {
    $token = Get-GraphAccessTokenString
    $Fetch = {
        param([string] $Namespace)
        $uri = "$script:GraphBeta/roleManagement/directory/resourceNamespaces/$([uri]::EscapeDataString($Namespace))/resourceActions?`$select=name,description,isPrivileged"
        Get-AllGraphItems -Uri $uri -AccessToken $token
    }
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$status = [ordered]@{}
$known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ns in $namespaces) {
    $file = Join-Path $OutputPath "$ns.json"
    try {
        $items = @(& $Fetch $ns)
        if ($items.Count -eq 0) { throw 'empty response' }
        $actions = @($items | ForEach-Object {
                [ordered]@{
                    name         = [string]$_.name
                    description  = [string]($_.PSObject.Properties['description']?.Value ?? '')
                    # Microsoft: isPrivileged "applies only for actions in the microsoft.directory
                    # resource namespace". Elsewhere it is not a verdict, so it is null, not false.
                    isPrivileged = if ($ns -eq 'microsoft.directory') { [bool]($_.PSObject.Properties['isPrivileged']?.Value) } else { $null }
                }
            } | Sort-Object { $_.name })
        Write-JsonFile @{ namespace = $ns; actions = $actions } $file
        $status[$ns] = [ordered]@{ status = 'ok'; actions = $actions.Count }
    }
    catch {
        # Keep the previous file: stale but correct beats empty.
        $status[$ns] = [ordered]@{ status = if (Test-Path $file) { 'failed-kept-previous' } else { 'failed' }; error = "$($_.Exception.Message)" }
    }
    if (Test-Path $file) {
        (Get-Content -Raw -Path $file | ConvertFrom-Json).actions | ForEach-Object { [void]$known.Add([string]$_.name) }
    }
}

foreach ($f in Get-ChildItem -Path $OutputPath -Filter '*.json' -File) {
    if ($f.Name -ne 'index.json' -and $f.BaseName -notin $namespaces) { Remove-Item $f.FullName }
}

$described = @($roleActions | Where-Object { $known.Contains($_) }).Count
Write-JsonFile ([ordered]@{
        namespaces  = $status
        roleActions = $roleActions.Count
        described   = $described
        undescribed = @($roleActions | Where-Object { -not $known.Contains($_) })
    }) (Join-Path $OutputPath 'index.json')

$failed = @($status.Keys | Where-Object { $status[$_].status -ne 'ok' })
Write-Host "Resource actions: $($namespaces.Count) namespaces, $($failed.Count) failed; $described of $($roleActions.Count) role actions described."
