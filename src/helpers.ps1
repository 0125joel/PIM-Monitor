function ConvertTo-DeterministicJson {
    <#
    .SYNOPSIS
        Converts an object to JSON with alphabetically sorted keys and sorted arrays.

    .DESCRIPTION
        Normalizes the input before serialization: hashtable and PSObject keys are sorted
        alphabetically, @odata.* metadata properties are stripped, and arrays of objects
        with an 'id' field are sorted by id. This ensures inventory files produce identical
        output across runs regardless of Graph API property ordering.

        Deliberate boundary: arrays of objects WITHOUT an 'id' field and non-string scalar
        arrays keep their original order. Sorting those would corrupt semantically ordered
        data (e.g., approval stages in policy rules, where array position is the escalation
        order). If Graph ever reorders such an array between scans, that shows up as a diff;
        accept that over silently rewriting meaningful order.

    .PARAMETER InputObject
        The object to serialize. Accepts pipeline input. Null is allowed.

    .PARAMETER Depth
        JSON serialization depth. Defaults to 20.

    .EXAMPLE
        $roleDefinition | ConvertTo-DeterministicJson | Set-Content definition.json
    #>
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
            if ($null -eq $obj) { return $null }

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
                # unary comma prevents PowerShell from unwrapping single-element arrays
                return , $items
            }

            if ($obj -is [System.Collections.IDictionary]) {
                $sorted = [ordered]@{}
                $obj.GetEnumerator() |
                    Where-Object { $_.Key -notlike '@odata.*' } |
                    Sort-Object Key |
                    ForEach-Object { $sorted[$_.Key] = Normalize $_.Value }
                return $sorted
            }

            # [string] and [System.ValueType] are technically [psobject] in PowerShell but must
            # be treated as primitives — the PSObject branch would incorrectly enumerate their members.
            if (($obj -is [psobject]) -and -not ($obj -is [string]) -and -not ($obj -is [System.ValueType])) {
                $sorted = [ordered]@{}
                $obj.PSObject.Properties |
                    Where-Object { $_.Name -notlike '@odata.*' } |
                    Sort-Object Name |
                    ForEach-Object { $sorted[$_.Name] = Normalize $_.Value }
                return $sorted
            }

            return $obj
        }

        $normalized = Normalize $InputObject
        ConvertTo-Json -InputObject $normalized -Depth $Depth
    }
}

function Get-AllGraphItems {
    <#
    .SYNOPSIS
        Fetches all pages from a paginated Microsoft Graph endpoint.

    .DESCRIPTION
        Follows @odata.nextLink pagination until all items are collected.
        Returns a flat array of all items from the 'value' property of each page.

    .PARAMETER Uri
        The initial Graph API URI to fetch.

    .PARAMETER AccessToken
        Bearer token for the Authorization header.

    .EXAMPLE
        $groups = Get-AllGraphItems -Uri $script:GraphEndpoints.GroupResources -AccessToken $token
    #>
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
        $response = Invoke-GraphRequest -Uri $currentUri -Headers $headers

        $pageItems = $response.PSObject.Properties['value']?.Value
        if ($pageItems) {
            $allItems += $pageItems
        }

        $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
    }

    return $allItems
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Retries a scriptblock on transient HTTP errors (429 and 5xx) with exponential backoff.

    .DESCRIPTION
        Calls the scriptblock and, if it throws a 429 (Too Many Requests) or 5xx error,
        waits and retries with jittered exponential backoff. Respects the Retry-After header
        when present. Non-retryable errors are re-thrown immediately.

    .PARAMETER ScriptBlock
        The operation to execute. Should be a closure capturing any required variables.

    .PARAMETER OperationName
        Human-readable label used in warning messages.

    .PARAMETER MaxAttempts
        Maximum number of attempts before giving up. Defaults to 10.

    .EXAMPLE
        Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $headers }.GetNewClosure() -OperationName "sendMail"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $ScriptBlock,

        [string] $OperationName = 'operation',

        [int] $MaxAttempts = 10
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $attempt++
            if ($attempt -ge $MaxAttempts) { throw }

            # Classify on the actual HTTP status code when available. Matching the message
            # string alone misfires: error messages embed URIs and GUIDs, and any digit run
            # like "429" or "5xx" inside those would make a permanent 403/404 "retryable".
            $statusCode = $null
            try {
                $response = $_.Exception.PSObject.Properties['Response']?.Value
                if ($response) { $statusCode = [int]$response.StatusCode }
            } catch { Write-Debug "Failed to read response status code" }

            $isRetryable = if ($statusCode) {
                ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -le 599)
            } else {
                # Fallback for exceptions without a Response (word boundaries reduce GUID false matches)
                ($_ -match '\b429\b') -or ($_ -match 'Too Many Requests') -or ($_ -match '\b5\d\d\b')
            }
            if (-not $isRetryable) { throw }

            $retryAfter = $null
            try {
                $ra = $_.Exception.Response.Headers.GetValues('Retry-After') | Select-Object -First 1
                if ($ra -and $ra -match '^\d+$') { $retryAfter = [int]$ra }
            } catch { Write-Debug "Failed to parse Retry-After header" }
            if (-not $retryAfter -or $retryAfter -le 0) {
                try { $retryAfter = [int]$_.Exception.Response.Headers.RetryAfter?.Delta?.TotalSeconds } catch { Write-Debug "Failed to extract RetryAfter delta" }
            }

            $base     = if ($retryAfter -and $retryAfter -gt 0) { $retryAfter } else { [math]::Pow(2, $attempt + 1) }
            $jitter   = $base * (0.8 + (Get-Random -Minimum 0 -Maximum 40) / 100)
            $waitSecs = [math]::Max(5, [math]::Min([math]::Round($jitter), 60))
            Write-Warning "Throttled on $OperationName (attempt $attempt/$($MaxAttempts-1)) — waiting ${waitSecs}s"
            Start-Sleep -Seconds $waitSecs
        }
    }
}

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Makes a GET request to the Microsoft Graph API with retry support.

    .DESCRIPTION
        Wraps Invoke-RestMethod with Invoke-WithRetry for automatic handling of
        429 throttling and 5xx server errors. GET-only; use Invoke-WithRetry
        directly for POST/PATCH/DELETE calls.

    .PARAMETER Uri
        The Graph API endpoint URI.

    .PARAMETER Headers
        Request headers. Must include Authorization with a Bearer token.

    .PARAMETER MaxAttempts
        Maximum retry attempts. Defaults to 10.

    .EXAMPLE
        $org = Invoke-GraphRequest -Uri $script:GraphEndpoints.Organization -Headers @{ Authorization = "Bearer $token" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [int] $MaxAttempts = 10
    )

    $action = { Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get }.GetNewClosure()
    Invoke-WithRetry -ScriptBlock $action -OperationName $Uri -MaxAttempts $MaxAttempts
}

function Get-InventorySlug {
    <#
    .SYNOPSIS
        Converts a display name to a lowercase URL-safe slug.

    .DESCRIPTION
        Lowercases the name, removes non-alphanumeric characters (except hyphens),
        collapses whitespace to hyphens, and strips leading/trailing hyphens.

    .PARAMETER Name
        The display name to slugify (e.g., "Global Administrator").

    .EXAMPLE
        Get-InventorySlug -Name "Global Administrator"
        # Returns: global-administrator
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    # NFD decomposition folds diacritics before the ASCII-only filter, so "Café" → "cafe" not "caf".
    $normalized = $Name.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', ''
    return $normalized.ToLowerInvariant() `
        -replace '[^a-z0-9\s-]', '' `
        -replace '\s+', '-' `
        -replace '-+', '-' `
        -replace '^-|-$', ''
}

function New-InventoryFolder {
    <#
    .SYNOPSIS
        Creates an inventory folder for a given workload and slug if it does not exist.

    .PARAMETER Workload
        The inventory workload category (e.g., "directory-roles", "pim-groups").

    .PARAMETER Slug
        The slug identifying the role or group within the workload.

    .EXAMPLE
        $path = New-InventoryFolder -Workload "directory-roles" -Slug "global-administrator"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("directory-roles", "pim-groups", "authentication-contexts", "administrative-units", "activation-events", "conditional-access")]
        [string] $Workload,

        [Parameter(Mandatory)]
        [string] $Slug
    )

    $folderPath = Join-Path -Path (Get-Location) -ChildPath "inventory" -AdditionalChildPath $Workload, $Slug

    if (-not (Test-Path $folderPath)) {
        if ($PSCmdlet.ShouldProcess($folderPath, 'Create inventory folder')) {
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
        }
    }

    return $folderPath
}

function Save-InventoryFile {
    <#
    .SYNOPSIS
        Serializes an object to deterministic JSON and writes it to an inventory file.

    .DESCRIPTION
        All inventory files must pass through ConvertTo-DeterministicJson to guarantee
        identical output across pipeline runs. The FileName parameter is validated against
        the allowed inventory file names to prevent accidental writes to arbitrary paths.

    .PARAMETER InputObject
        The object to serialize and write.

    .PARAMETER FolderPath
        Full path to the inventory folder (returned by New-InventoryFolder).

    .PARAMETER FileName
        The target filename. Must match one of the allowed inventory file names.

    .EXAMPLE
        Save-InventoryFile -InputObject $definition -FolderPath $path -FileName "definition.json"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $FolderPath,

        [Parameter(Mandatory)]
        [ValidatePattern("^(definition|policy|assignments|config|pending-approvals|security-alerts|\d{4}-\d{2})\.json$")]
        [string] $FileName
    )

    $filePath = Join-Path -Path $FolderPath -ChildPath $FileName
    $json = ConvertTo-DeterministicJson -InputObject $InputObject
    if ($PSCmdlet.ShouldProcess($filePath, 'Write inventory file')) {
        Set-Content -Path $filePath -Value $json -Encoding utf8NoBOM -Force
    }
}

function Move-ToArchive {
    <#
    .SYNOPSIS
        Moves a role or group inventory folder to the archive directory.

    .DESCRIPTION
        Called when a role or group disappears from PIM. The folder is moved rather than
        deleted so the historical inventory data is preserved. The destination path is
        inventory/archive/{workload}/{slug}_{date}.

    .PARAMETER FolderPath
        Full path to the inventory folder to archive.

    .PARAMETER InventoryRoot
        Root of the inventory directory (contains the workload subdirectories).

    .EXAMPLE
        Move-ToArchive -FolderPath $folderPath -InventoryRoot $inventoryRoot
    #>
    [CmdletBinding(SupportsShouldProcess)]
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

    if ($PSCmdlet.ShouldProcess($FolderPath, "Archive to archive/$workload/${slug}_${dateSuffix}")) {
        if (-not (Test-Path $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        }
        Move-Item -Path $FolderPath -Destination $archiveDest -Force
        Write-Host "  Archived: $workload/$slug -> archive/$workload/${slug}_${dateSuffix}"
    }
}

<#
.SYNOPSIS
    Retrieves a pipeline environment variable, handling ADO unresolved macro references.

.DESCRIPTION
    Azure DevOps sets unresolved variables as literal $(VAR_NAME) strings when the variable
    is absent from both YAML and UI. This helper returns null for those cases, otherwise
    returns the environment variable value.

.PARAMETER Name
    Name of the environment variable to retrieve.

.EXAMPLE
    $email = Get-PipelineEnvVar -Name 'NOTIFICATION_EMAIL'
#>
function Get-PipelineEnvVar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ($value -and $value -notmatch '^\$\(') {
        return $value
    }
    return $null
}

<#
.SYNOPSIS
    Unwraps a SecureString access token from Get-AzAccessToken.

.DESCRIPTION
    Az.Accounts 5.x returns .Token as SecureString; newer versions may return plain string.
    This helper safely converts SecureString to plain text using NetworkCredential,
    with fallback for future versions that return plain string.

.EXAMPLE
    $token = Get-GraphAccessTokenString
#>
function Get-GraphAccessTokenString {
    [CmdletBinding()]
    param()

    $rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
    if ($rawToken -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $rawToken).Password
    }
    return $rawToken
}

<#
.SYNOPSIS
    Logs a timestamped step message to the host.

.DESCRIPTION
    Writes a message prefixed with the current UTC timestamp in ISO 8601 format.
    Used by pipeline orchestrators to mark major scan phases.

.PARAMETER Message
    The step message to log.

.EXAMPLE
    Write-StepLog "Fetching role definitions from Graph API"
#>
function Write-StepLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    $ts = Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ"
    Write-Host "[$ts] $Message"
}

<#
.SYNOPSIS
    Converts a PSObject or IDictionary to a hashtable.

.DESCRIPTION
    Safely converts any object with properties/keys to a hashtable. If the object is already
    a hashtable, returns it as-is. For PSObjects, extracts NoteProperty values. For IDictionaries,
    copies all key-value pairs.

.PARAMETER InputObject
    The object to convert.

.EXAMPLE
    $hash = ConvertTo-Hashtable -InputObject $psObject
#>
function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($InputObject -is [System.Collections.Hashtable]) {
        return $InputObject
    }

    $result = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $result[$key] = $InputObject[$key]
        }
    } else {
        foreach ($prop in ($InputObject | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
            $result[$prop] = $InputObject.$prop
        }
    }
    return $result
}

# Properties ignored when diffing any inventory object — present in every Graph response
# but carry no semantic meaning for change detection (sourcing-order: must be before diff.ps1).
$script:DiffIgnoreProperties = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '@odata.context', '@odata.type', '@odata.id',
        'id', 'templateId', 'target',
        'createdDateTime', 'modifiedDateTime', 'createdUsing',
        'lastModifiedDateTime', 'lastModifiedBy'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

function Get-ObjectKeys {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) { return @($InputObject.Keys) }
    return @($InputObject | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
}

function Get-AssignmentEndDateTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Assignment)
    $si  = $Assignment.PSObject.Properties['scheduleInfo']?.Value
    if ($null -eq $si)  { return $null }
    $exp = $si.PSObject.Properties['expiration']?.Value
    if ($null -eq $exp) { return $null }
    return $exp.PSObject.Properties['endDateTime']?.Value
}

function Get-AccessIdPrefix {
    # Returns "<accessId> " (e.g. "member ") for PIM Group assignments, or "" for role assignments.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Assignment)
    $accessId = $Assignment.PSObject.Properties['accessId']?.Value
    if ($accessId) { return "$accessId " }
    return ''
}

function Find-InventorySlugById {
    <#
    .SYNOPSIS
        Resolves the inventory folder slug for an entity by its object id.

    .DESCRIPTION
        Scans the definition.json files under a workload folder and returns the folder
        name (slug) whose definition carries the given id. Used when an entity's display
        name (and therefore its slug) could not be fetched, so the existing folder can
        still be protected from false archival.

    .PARAMETER WorkloadPath
        Inventory folder for the workload (e.g. inventory/pim-groups).

    .PARAMETER EntityId
        The Graph object id to look for.

    .EXAMPLE
        $slug = Find-InventorySlugById -WorkloadPath (Join-Path $inventoryRoot "pim-groups") -EntityId $groupId
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkloadPath,

        [Parameter(Mandatory)]
        [string] $EntityId
    )

    if (-not (Test-Path $WorkloadPath)) { return $null }

    foreach ($folder in (Get-ChildItem -Path $WorkloadPath -Directory)) {
        $definitionPath = Join-Path -Path $folder.FullName -ChildPath "definition.json"
        if (-not (Test-Path $definitionPath)) { continue }
        try {
            $definition = Get-Content -Path $definitionPath -Raw -Encoding utf8 | ConvertFrom-Json
            $id = $definition.PSObject.Properties['id']?.Value
            if ($id -eq $EntityId) { return $folder.Name }
        }
        catch {
            continue
        }
    }

    return $null
}

function Test-DictKeyExists {
    # Checks if a key exists in a dictionary. Works for Hashtable and OrderedDictionary (ConvertFrom-Json -AsHashtable).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Dictionary,
        [Parameter(Mandatory)] $Key
    )
    return $Key -in $Dictionary.Keys
}

function Test-IsPimGroupWrapper {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Object)
    if ($Object -is [System.Collections.IDictionary]) {
        return ($Object['member'] -is [System.Collections.IDictionary]) -or
               ($Object['owner']  -is [System.Collections.IDictionary])
    }
    # PSCustomObject from JSON deserialization
    return (Test-ObjectHasKey -Object $Object -Key 'member') -or
           (Test-ObjectHasKey -Object $Object -Key 'owner')
}
