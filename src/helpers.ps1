<#
.SYNOPSIS
    Helper functions for PIM Monitor pipeline.

.DESCRIPTION
    Provides utilities for Graph API calls, deterministic JSON serialization,
    and inventory management.
#>


<#
.SYNOPSIS
    Converts an object to JSON with deterministic key ordering and sorted arrays.

.DESCRIPTION
    Produces byte-identical JSON output for semantically identical Graph API responses,
    regardless of property order returned by the API. Strips @odata.* metadata.
    Requires PowerShell 7.x (uses -Depth on ConvertTo-Json).

.PARAMETER InputObject
    The object to serialize (typically from Invoke-MgGraphRequest).

.PARAMETER Depth
    Maximum nesting depth for JSON serialization. Default: 20.

.EXAMPLE
    $role = Invoke-MgGraphRequest -Uri "/beta/roleManagement/directory/roleDefinitions/$id"
    ConvertTo-DeterministicJson -InputObject $role | Set-Content -Path "definition.json"
#>
function ConvertTo-DeterministicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        $InputObject,

        [ValidateRange(1, 100)]
        [int] $Depth = 20
    )

    process {
        function Normalize ([object] $obj) {
            # Null passthrough
            if ($null -eq $obj) { return $null }

            # Arrays: normalize each element, then sort by 'id' (objects) or value (primitives)
            if ($obj -is [System.Collections.IList]) {
                [array] $items = @($obj | ForEach-Object { Normalize $_ })
                if ($items.Count -gt 1) {
                    if ($items[0] -is [System.Collections.IDictionary] -and $items[0].Contains('id')) {
                        $items = @($items | Sort-Object { [string] $_['id'] })
                    }
                    elseif ($items[0] -is [string]) {
                        $items = @($items | Sort-Object)
                    }
                }
                return , $items
            }

            # Objects (PSObject or hashtable): sort keys alphabetically, strip @odata.*
            if ($obj -is [System.Collections.IDictionary]) {
                $sorted = [ordered]@{}
                $obj.GetEnumerator() |
                    Where-Object { $_.Key -notlike '@odata.*' } |
                    Sort-Object Key |
                    ForEach-Object { $sorted[$_.Key] = Normalize $_.Value }
                return $sorted
            }

            # PSCustomObject from ConvertFrom-Json / Invoke-RestMethod.
            # Exclude string and ValueType (bool, int, etc.) — they are technically [psobject]
            # in PowerShell but must be treated as primitives. Using .Count on PSObject.Properties
            # can fail under Set-StrictMode -Version Latest for certain object types.
            if (($obj -is [psobject]) -and -not ($obj -is [string]) -and -not ($obj -is [System.ValueType])) {
                $sorted = [ordered]@{}
                $obj.PSObject.Properties |
                    Where-Object { $_.Name -notlike '@odata.*' } |
                    Sort-Object Name |
                    ForEach-Object { $sorted[$_.Name] = Normalize $_.Value }
                return $sorted
            }

            # Primitives (string, int, bool, datetime, enum): pass through
            return $obj
        }

        $normalized = Normalize $InputObject
        ConvertTo-Json -InputObject $normalized -Depth $Depth
    }
}

<#
.SYNOPSIS
    Fetches all items from a paginated Graph API endpoint.

.DESCRIPTION
    Handles automatic pagination by following @odata.nextLink.
    Returns all items as an array.

.PARAMETER Uri
    The Graph API endpoint URI.

.PARAMETER AccessToken
    Access token for authentication.

.EXAMPLE
    $roles = Get-AllGraphItems -Uri "/beta/roleManagement/directory/roleDefinitions" -AccessToken $token
#>
function Get-AllGraphItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [string] $AccessToken
    )

    $allItems = @()
    $headers = @{ Authorization = "Bearer $AccessToken" }

    $currentUri = $Uri
    while ($currentUri) {
        $attempt = 0
        $response = $null
        while ($true) {
            try {
                $response = Invoke-RestMethod -Uri $currentUri -Headers $headers -Method Get
                break
            }
            catch {
                $attempt++
                if ($attempt -ge 6) { throw }
                $isRetryable = ($_ -match '429') -or ($_ -match 'Too Many Requests') -or ($_ -match '5\d\d')
                if (-not $isRetryable) { throw }
                $retryAfter = $null
                try { $retryAfter = $_.Exception.Response.Headers.RetryAfter?.Delta?.TotalSeconds } catch {}
                $waitSecs = if ($retryAfter -and $retryAfter -gt 0) { [int]$retryAfter } else { [math]::Pow(2, $attempt + 1) }
                Write-Warning "Graph throttled on $currentUri (attempt $attempt/5) — waiting ${waitSecs}s"
                Start-Sleep -Seconds $waitSecs
            }
        }

        $pageItems = $response.PSObject.Properties['value']?.Value
        if ($pageItems) {
            $allItems += $pageItems
        }

        $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
    }

    return $allItems
}

<#
.SYNOPSIS
    Gets the slug (URL-friendly name) for a role or group.

.DESCRIPTION
    Converts displayName to kebab-case for use in inventory folder names.

.PARAMETER Name
    The display name to slugify.

.EXAMPLE
    Get-InventorySlug -Name "Global Administrator"  # Returns "global-administrator"
#>
function Get-InventorySlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    return $Name.ToLower() `
        -replace '[^\w\s-]', '' `
        -replace '\s+', '-' `
        -replace '-+', '-' `
        -replace '^-|-$', ''
}

<#
.SYNOPSIS
    Ensures inventory folder structure exists.

.DESCRIPTION
    Creates folder at inventory/{workload}/{slug} if it doesn't exist.

.PARAMETER Workload
    The workload type: "directory-roles", "pim-groups", "authentication-contexts",
    or "administrative-units".

.PARAMETER Slug
    The entity slug (kebab-case identifier).

.EXAMPLE
    New-InventoryFolder -Workload "directory-roles" -Slug "global-administrator"
#>
function New-InventoryFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("directory-roles", "pim-groups", "authentication-contexts", "administrative-units", "activation-events")]
        [string] $Workload,

        [Parameter(Mandatory)]
        [string] $Slug
    )

    $folderPath = Join-Path -Path (Get-Location) -ChildPath "inventory" -AdditionalChildPath $Workload, $Slug

    if (-not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    }

    return $folderPath
}

<#
.SYNOPSIS
    Writes a JSON file to inventory with deterministic formatting.

.PARAMETER InputObject
    The object to serialize.

.PARAMETER FolderPath
    The inventory folder path.

.PARAMETER FileName
    The file name (e.g., "definition.json", "policy.json").

.EXAMPLE
    Save-InventoryFile -InputObject $roleDefinition -FolderPath $folder -FileName "definition.json"
#>
function Save-InventoryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $FolderPath,

        [Parameter(Mandatory)]
        [ValidatePattern("^(definition|policy|assignments|\d{4}-\d{2})\.json$")]
        [string] $FileName
    )

    $filePath = Join-Path -Path $FolderPath -ChildPath $FileName
    $json = ConvertTo-DeterministicJson -InputObject $InputObject
    Set-Content -Path $filePath -Value $json -Encoding utf8NoBOM -Force
}

<#
.SYNOPSIS
    Moves a removed entity folder to the inventory archive.

.DESCRIPTION
    Called when Get-RemovedEntities detects an entity no longer present in PIM.
    Instead of leaving the folder in place (causing repeated removal notifications)
    or deleting it (losing history), moves it to inventory/archive/{workload}/{slug}_{date}.

    Git sees the move as a delete + add, preserving full history via git log --follow.

.PARAMETER FolderPath
    Full path to the entity folder being archived (e.g. inventory/directory-roles/global-administrator).

.PARAMETER InventoryRoot
    Root inventory path (e.g. /repo/inventory).
#>
function Move-ToArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FolderPath,

        [Parameter(Mandatory)]
        [string] $InventoryRoot
    )

    $dateSuffix    = Get-Date -AsUTC -Format 'yyyy-MM-dd'
    $workload      = Split-Path -Leaf (Split-Path -Parent $FolderPath)
    $slug          = Split-Path -Leaf $FolderPath
    $archiveDir    = Join-Path $InventoryRoot (Join-Path 'archive' $workload)
    $archiveDest   = Join-Path $archiveDir "${slug}_${dateSuffix}"

    if (-not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    }

    Move-Item -Path $FolderPath -Destination $archiveDest -Force
    Write-Host "  Archived: $workload/$slug -> archive/$workload/${slug}_${dateSuffix}"
}
