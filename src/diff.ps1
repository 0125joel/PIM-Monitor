<#
.SYNOPSIS
    Diff engine for PIM Monitor — compares inventory files and classifies changes.

.DESCRIPTION
    Uses a rule-based severity classification system. Severity is determined by:
    1. Which file changed (definition, policy, assignments)
    2. The type of change (created, updated, deleted)
    3. For policy updates: which specific rule IDs changed

    The classification rules are declarative — extend by adding entries to the
    lookup tables, not by writing new if/else branches.
#>

# ============================================================================
# Severity Classification Rules
# ============================================================================

# Policy rule ID → severity when that rule changes.
# Matched by prefix — "Enablement_EndUser" matches "Enablement_EndUser_Assignment".
# Order matters: first match wins. More specific patterns go first.
$script:PolicyRuleSeverity = [ordered]@{
    # Activation requirements — security-critical
    "Enablement_EndUser_Assignment"              = "High"     # MFA, justification, ticketing on activation
    "Approval_EndUser_Assignment"                = "High"     # Approval requirement + approvers
    "AuthenticationContext_EndUser_Assignment"    = "High"     # Conditional Access auth context

    # Assignment duration/expiration — medium impact
    "Expiration_EndUser_Assignment"              = "Medium"   # Max activation duration
    "Expiration_Admin_Eligibility"               = "Medium"   # Eligible assignment max duration
    "Expiration_Admin_Assignment"                = "Medium"   # Active assignment max duration
    "Enablement_Admin_Assignment"                = "Medium"   # MFA, justification on direct assignment
    "Enablement_Admin_Eligibility"               = "Medium"   # Requirements for creating eligible assignments

    # Notifications — low impact
    "Notification_"                              = "Low"      # All 9 notification rules (prefix match)
}

# Default severity for rule IDs not matching any pattern above.
$script:DefaultPolicyRuleSeverity = "Medium"

# ============================================================================
# Property-Level Diff — Configuration
# ============================================================================

# Fields to skip in flat-property diffs (system timestamps, OData metadata).
# Extend this list to silence fields that change without carrying config signal.
$script:DiffIgnoreProperties = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        '@odata.context', '@odata.type', '@odata.id',
        'id', 'templateId',
        'createdDateTime', 'modifiedDateTime', 'createdUsing',
        'lastModifiedDateTime', 'lastModifiedBy'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

# Property name → severity when that property changes in a definition file.
# Prefix-matched, same pattern as $script:PolicyRuleSeverity — extend freely.
# Unknown/new properties fall back to $script:DefaultPropertySeverity (Informational),
# so any field Microsoft adds to the API is automatically captured.
$script:PropertySeverity = [ordered]@{
    "rolePermissions"        = "High"
    "allowedResourceActions" = "High"
    "isPrivileged"           = "High"
    "isEnabled"              = "High"
    "allowedPrincipalTypes"  = "Medium"
    "displayName"            = "Informational"
    "description"            = "Informational"
    "version"                = "Informational"
}

$script:DefaultPropertySeverity  = "Informational"   # new/unknown API fields
$script:DefaultCategorySeverity  = "Medium"           # unknown assignment category types

# Nested field paths to strip from assignment objects before diff and storage.
# scheduleInfo.startDateTime: Microsoft re-provisions this heartbeat timestamp
# every ~30 min without any user action — storing it creates spurious commits.
# Paths use dot-notation; @(@(...)) flattens in PowerShell so we use strings instead.
$script:AssignmentNoisePaths = @('scheduleInfo.startDateTime')

# ============================================================================
# Core Comparison Functions
# ============================================================================

<#
.SYNOPSIS
    Compares two JSON-serializable objects for equality.

.DESCRIPTION
    Normalizes both objects to deterministic JSON and compares the strings.
    Returns $true if identical, $false if different.
#>
function Test-ObjectEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Left,
        [Parameter(Mandatory)] $Right
    )

    $leftJson  = ConvertTo-DeterministicJson -InputObject $Left
    $rightJson = ConvertTo-DeterministicJson -InputObject $Right

    return $leftJson -eq $rightJson
}

<#
.SYNOPSIS
    Checks whether an object exposes a given key/property.

.DESCRIPTION
    Works for both hashtables (fresh fetch data) and PSCustomObject
    (data loaded from disk via ConvertFrom-Json). Returns $false for $null.
#>
function Test-ObjectHasKey {
    [CmdletBinding()]
    param(
        [Parameter()] $Object,
        [Parameter(Mandatory)] [string] $Key
    )

    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) }
    if ($Object -is [psobject]) { return $null -ne $Object.PSObject.Properties[$Key] }
    return $false
}

<#
.SYNOPSIS
    Reads a previous inventory file from disk (current committed state).

.DESCRIPTION
    Reads the file at the given path if it exists. Returns $null if not found.
    Used to compare against newly fetched data before overwriting.

.PARAMETER FilePath
    Absolute path to the inventory file.
#>
function Read-PreviousInventoryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    try {
        $content = Get-Content -Path $FilePath -Raw -Encoding utf8
        return $content | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to read previous inventory file $FilePath : $_"
        return $null
    }
}

# ============================================================================
# Policy Diff — Rule-Level Analysis
# ============================================================================

<#
.SYNOPSIS
    Compares two policy objects at the individual rule level.

.DESCRIPTION
    Matches rules by their 'id' field, detects added/removed/changed rules,
    and returns per-rule change entries with severity from the lookup table.

    Works for both Directory Role policies (flat) and PIM Group policies
    (member/owner wrapper — call once per sub-policy).

.PARAMETER OldPolicy
    Previous policy object (with .policy.rules array).

.PARAMETER NewPolicy
    Current policy object (with .policy.rules array).

.PARAMETER Context
    Human-readable context string (e.g., "Global Administrator").

.RETURNS
    Array of change entries: @{ severity, ruleId, description, old, new }
#>
function Compare-PolicyRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $OldPolicy,
        [Parameter(Mandatory)] $NewPolicy,
        [Parameter(Mandatory)] [string] $Context
    )

    $changes = @()

    # PIM Groups wrap two policy assignments (member + owner) in one file.
    # Detect the wrapper and recurse into each sub-policy.
    $isWrapped = (Test-ObjectHasKey -Object $NewPolicy -Key 'member') -or
                 (Test-ObjectHasKey -Object $NewPolicy -Key 'owner')   -or
                 (Test-ObjectHasKey -Object $OldPolicy -Key 'member') -or
                 (Test-ObjectHasKey -Object $OldPolicy -Key 'owner')
    if ($isWrapped) {
        foreach ($accessId in @('member', 'owner')) {
            $oldSub = if (Test-ObjectHasKey -Object $OldPolicy -Key $accessId) { $OldPolicy.$accessId } else { $null }
            $newSub = if (Test-ObjectHasKey -Object $NewPolicy -Key $accessId) { $NewPolicy.$accessId } else { $null }
            if ($null -eq $newSub -and $null -eq $oldSub) { continue }

            # Sub-policy added or removed wholesale
            if ($null -eq $oldSub) {
                $changes += @{
                    severity    = "Medium"
                    ruleId      = "(all)"
                    changeType  = "added"
                    context     = $Context
                    description = "Policy added for $accessId access ($Context)"
                    old         = $null
                    new         = $newSub
                }
                continue
            }
            if ($null -eq $newSub) {
                $changes += @{
                    severity    = "Medium"
                    ruleId      = "(all)"
                    changeType  = "removed"
                    context     = $Context
                    description = "Policy removed for $accessId access ($Context)"
                    old         = $oldSub
                    new         = $null
                }
                continue
            }

            $subChanges = Compare-PolicyRules -OldPolicy $oldSub -NewPolicy $newSub -Context "$Context — $accessId"
            $changes += $subChanges
        }
        return $changes
    }

    # Extract rules arrays — handle both expanded and flat structures
    $oldRules = @()
    $newRules = @()

    if ((Test-ObjectHasKey $OldPolicy 'policy') -and (Test-ObjectHasKey $OldPolicy.policy 'rules')) {
        $oldRules = $OldPolicy.policy.rules
    }
    elseif (Test-ObjectHasKey $OldPolicy 'rules') {
        $oldRules = $OldPolicy.rules
    }

    if ((Test-ObjectHasKey $NewPolicy 'policy') -and (Test-ObjectHasKey $NewPolicy.policy 'rules')) {
        $newRules = $NewPolicy.policy.rules
    }
    elseif (Test-ObjectHasKey $NewPolicy 'rules') {
        $newRules = $NewPolicy.rules
    }

    # Build lookup by rule ID
    $oldByRuleId = @{}
    foreach ($rule in $oldRules) {
        if ($rule.id) { $oldByRuleId[$rule.id] = $rule }
    }

    $newByRuleId = @{}
    foreach ($rule in $newRules) {
        if ($rule.id) { $newByRuleId[$rule.id] = $rule }
    }

    # Detect changed and removed rules
    foreach ($ruleId in $oldByRuleId.Keys) {
        if (-not $newByRuleId.ContainsKey($ruleId)) {
            # Rule removed
            $changes += @{
                severity    = Get-PolicyRuleSeverity -RuleId $ruleId
                ruleId      = $ruleId
                changeType  = "removed"
                context     = $Context
                description = "Policy rule removed: $ruleId ($Context)"
                old         = $oldByRuleId[$ruleId]
                new         = $null
            }
        }
        else {
            # Rule exists in both — check for changes
            if (-not (Test-ObjectEqual -Left $oldByRuleId[$ruleId] -Right $newByRuleId[$ruleId])) {
                $changes += @{
                    severity    = Get-PolicyRuleSeverity -RuleId $ruleId
                    ruleId      = $ruleId
                    changeType  = "updated"
                    context     = $Context
                    description = "Policy rule changed: $ruleId ($Context)"
                    old         = $oldByRuleId[$ruleId]
                    new         = $newByRuleId[$ruleId]
                }
            }
        }
    }

    # Detect added rules
    foreach ($ruleId in $newByRuleId.Keys) {
        if (-not $oldByRuleId.ContainsKey($ruleId)) {
            $changes += @{
                severity    = Get-PolicyRuleSeverity -RuleId $ruleId
                ruleId      = $ruleId
                changeType  = "added"
                context     = $Context
                description = "Policy rule added: $ruleId ($Context)"
                old         = $null
                new         = $newByRuleId[$ruleId]
            }
        }
    }

    return $changes
}

<#
.SYNOPSIS
    Looks up the severity for a policy rule ID using prefix matching.

.PARAMETER RuleId
    The rule ID (e.g., "Enablement_EndUser_Assignment").

.RETURNS
    "High", "Medium", or "Low".
#>
function Get-PolicyRuleSeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RuleId
    )

    foreach ($pattern in $script:PolicyRuleSeverity.Keys) {
        if ($RuleId.StartsWith($pattern)) {
            return $script:PolicyRuleSeverity[$pattern]
        }
    }

    return $script:DefaultPolicyRuleSeverity
}

<#
.SYNOPSIS
    Looks up the severity for a definition property name using prefix matching.

.PARAMETER PropertyKey
    The property name (e.g., "rolePermissions", "displayName").

.RETURNS
    Severity string, defaulting to $script:DefaultPropertySeverity for unknown keys.
#>
function Get-PropertySeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PropertyKey
    )

    foreach ($pattern in $script:PropertySeverity.Keys) {
        if ($PropertyKey.StartsWith($pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $script:PropertySeverity[$pattern]
        }
    }

    return $script:DefaultPropertySeverity
}

# ============================================================================
# Assignment Diff — Entry-Level Analysis
# ============================================================================

<#
.SYNOPSIS
    Strips volatile system fields from all assignments in an assignments object.

.DESCRIPTION
    Normalizes assignment data before both diffing and writing to disk, so that
    Microsoft Graph heartbeat fields (e.g. scheduleInfo.startDateTime) do not
    cause spurious diffs or unnecessary commits.

    The set of paths to strip is configured in $script:AssignmentNoisePaths.

.PARAMETER Assignments
    Hashtable of assignment categories: @{ permanent=@(...); eligible=@(...); active=@(...) }

.RETURNS
    New hashtable with the same structure, volatile fields removed from each entry.
#>
function Remove-AssignmentNoise {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Assignments
    )

    $normalized = @{}

    foreach ($category in $Assignments.Keys) {
        $items = $Assignments[$category]
        if (-not $items) {
            $normalized[$category] = @()
            continue
        }

        $normalized[$category] = @($items | ForEach-Object {
            # Deep copy via JSON round-trip so the original object is never mutated
            $copy = $_ | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json -AsHashtable

            foreach ($dotPath in $script:AssignmentNoisePaths) {
                $pathParts = $dotPath -split '\.'
                $node = $copy
                for ($i = 0; $i -lt ($pathParts.Count - 1); $i++) {
                    if ($node -is [System.Collections.IDictionary] -and $node.ContainsKey($pathParts[$i])) {
                        $node = $node[$pathParts[$i]]
                    }
                    else {
                        $node = $null
                        break
                    }
                }
                if ($null -ne $node -and $node -is [System.Collections.IDictionary]) {
                    $node.Remove($pathParts[-1]) | Out-Null
                }
            }

            # Convert back to PSCustomObject: hashtable keys do not appear in
            # PSObject.Properties, which breaks Get-AssignmentKey and the
            # severity check in Compare-Assignments.
            $copy | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
        })
    }

    return $normalized
}

# ============================================================================
# Assignment Diff — Entry-Level Analysis
# ============================================================================

<#
.SYNOPSIS
    Compares old and new assignment sets and detects individual changes.

.DESCRIPTION
    Matches assignments by principalId + directoryScopeId (or groupId + accessId).
    Detects added, removed, and changed assignments. Classifies severity based
    on the assignment category and change type.

.PARAMETER OldAssignments
    Previous assignments object (with permanent/eligible/active arrays).

.PARAMETER NewAssignments
    Current assignments object (with permanent/eligible/active arrays).

.PARAMETER Context
    Human-readable context string (e.g., "Global Administrator").

.RETURNS
    Array of change entries: @{ severity, category, changeType, description, old, new }
#>
function Compare-Assignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $OldAssignments,
        [Parameter(Mandatory)] $NewAssignments,
        [Parameter(Mandatory)] [string] $Context
    )

    $changes = @()

    # Derive categories dynamically from both objects so any new Graph API
    # category type (beyond permanent/eligible/active) is caught automatically.
    $categories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($obj in @($OldAssignments, $NewAssignments)) {
        if ($null -eq $obj) { continue }
        if ($obj -is [System.Collections.IDictionary]) {
            foreach ($key in $obj.Keys) { $categories.Add($key) | Out-Null }
        } else {
            foreach ($p in $obj.PSObject.Properties) { $categories.Add($p.Name) | Out-Null }
        }
    }

    foreach ($category in $categories) {
        $oldEntries = @()
        $newEntries = @()

        if (Test-ObjectHasKey $OldAssignments $category) {
            $rawOld = $OldAssignments.$category
            if ($null -ne $rawOld) { $oldEntries = @($rawOld) }
        }
        if (Test-ObjectHasKey $NewAssignments $category) {
            $rawNew = $NewAssignments.$category
            if ($null -ne $rawNew) { $newEntries = @($rawNew) }
        }

        # Build lookup by principalId (primary key for matching)
        $oldById = @{}
        foreach ($entry in $oldEntries) {
            $key = Get-AssignmentKey -Assignment $entry
            if ($key) { $oldById[$key] = $entry }
        }

        $newById = @{}
        foreach ($entry in $newEntries) {
            $key = Get-AssignmentKey -Assignment $entry
            if ($key) { $newById[$key] = $entry }
        }

        # Detect removed assignments
        foreach ($key in $oldById.Keys) {
            if (-not $newById.ContainsKey($key)) {
                $changes += @{
                    severity    = "Low"
                    category    = $category
                    changeType  = "removed"
                    context     = $Context
                    description = "$category assignment removed ($Context)"
                    old         = $oldById[$key]
                    new         = $null
                }
            }
        }

        # Detect added and changed assignments
        foreach ($key in $newById.Keys) {
            if (-not $oldById.ContainsKey($key)) {
                # New assignment — unknown category types fall back to DefaultCategorySeverity
                $severity = switch ($category) {
                    "permanent" { "High" }
                    "eligible"  { "Medium" }
                    "active"    { "Medium" }
                    default     { $script:DefaultCategorySeverity }
                }

                # Check for permanent (no expiration) — always high
                $scheduleInfo = $newById[$key].PSObject.Properties['scheduleInfo']?.Value
                $expiration   = if ($null -ne $scheduleInfo) { $scheduleInfo.PSObject.Properties['expiration']?.Value } else { $null }
                $endDateTime  = if ($null -ne $expiration)   { $expiration.PSObject.Properties['endDateTime']?.Value  } else { $null }
                if ($null -eq $endDateTime -and $category -ne "permanent") {
                    $severity = "High"
                }

                $changes += @{
                    severity    = $severity
                    category    = $category
                    changeType  = "added"
                    context     = $Context
                    description = "New $category assignment ($Context)"
                    old         = $null
                    new         = $newById[$key]
                }
            }
            else {
                # Both exist — check for changes
                if (-not (Test-ObjectEqual -Left $oldById[$key] -Right $newById[$key])) {
                    $changes += @{
                        severity    = "Medium"
                        category    = $category
                        changeType  = "updated"
                        context     = $Context
                        description = "$category assignment changed ($Context)"
                        old         = $oldById[$key]
                        new         = $newById[$key]
                    }
                }
            }
        }
    }

    # Deduplicate: a direct permanent-active assignment creates both a permanent
    # schedule entry (roleAssignmentSchedule) and an active instance
    # (roleAssignmentScheduleInstance) in the same scan cycle. Both appear as
    # "added" or "removed" changes but originate from one user action. Merge them
    # into a single alert when: the active entry has assignmentType "Assigned"
    # (direct assignment, not an eligible activation) and a permanent entry exists
    # for the same principal + scope in the same diff.
    $toRemove = [System.Collections.Generic.HashSet[object]]::new()
    $toAdd    = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($changeType in @('added', 'removed')) {
        $dataKey  = if ($changeType -eq 'added') { 'new' } else { 'old' }
        $byKey    = @{}

        foreach ($change in $changes) {
            if ($change.changeType -ne $changeType -or -not $change[$dataKey]) { continue }
            $key = Get-AssignmentKey -Assignment $change[$dataKey]
            if (-not $key) { continue }
            if (-not $byKey.ContainsKey($key)) { $byKey[$key] = @{} }
            $byKey[$key][$change.category] = $change
        }

        foreach ($key in $byKey.Keys) {
            $byCategory = $byKey[$key]
            if (-not ($byCategory.ContainsKey('active') -and $byCategory.ContainsKey('permanent'))) { continue }

            $activeChange    = $byCategory['active']
            $permanentChange = $byCategory['permanent']
            $assignmentType  = $activeChange[$dataKey].PSObject.Properties['assignmentType']?.Value
            if ($assignmentType -ne 'Assigned') { continue }

            $toRemove.Add($activeChange)    | Out-Null
            $toRemove.Add($permanentChange) | Out-Null

            if ($changeType -eq 'added') {
                $toAdd.Add(@{
                    severity    = 'High'
                    category    = 'active'
                    changeType  = 'added'
                    context     = $Context
                    description = "New permanent active assignment ($Context)"
                    old         = $null
                    new         = $activeChange.new
                }) | Out-Null
            } else {
                $toAdd.Add(@{
                    severity    = 'High'
                    category    = 'active'
                    changeType  = 'removed'
                    context     = $Context
                    description = "Permanent active assignment removed ($Context)"
                    old         = $activeChange.old
                    new         = $null
                }) | Out-Null
            }
        }
    }

    if ($toRemove.Count -gt 0) {
        $changes = @($changes | Where-Object { -not $toRemove.Contains($_) }) + @($toAdd)
    }

    return $changes
}

<#
.SYNOPSIS
    Generates a stable key for an assignment entry (for matching old vs new).

.DESCRIPTION
    Combines principalId + scope to uniquely identify an assignment.
    Handles both Directory Role format (directoryScopeId) and PIM Group format (groupId + accessId).
#>
function Get-AssignmentKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Assignment
    )

    $principalId = $Assignment.PSObject.Properties['principalId']?.Value
    if (-not $principalId) {
        $principal   = $Assignment.PSObject.Properties['principal']?.Value
        $principalId = $principal.PSObject.Properties['id']?.Value
    }

    if (-not $principalId) {
        return $Assignment.PSObject.Properties['id']?.Value
    }

    $directoryScopeId = $Assignment.PSObject.Properties['directoryScopeId']?.Value
    if ($directoryScopeId) {
        return "$principalId|$directoryScopeId"
    }

    $groupId = $Assignment.PSObject.Properties['groupId']?.Value
    if ($groupId) {
        $accessId = $Assignment.PSObject.Properties['accessId']?.Value
        return "$principalId|$groupId|$accessId"
    }

    return "$principalId|/"
}

# ============================================================================
# Property-Level Diff — Definition Files
# ============================================================================

<#
.SYNOPSIS
    Compares two objects at the top-level property level and emits one change
    entry per changed, added, or removed property.

.DESCRIPTION
    Properties in $script:DiffIgnoreProperties are skipped entirely.
    New properties (present in new but absent in old) always get
    $script:DefaultPropertySeverity (Informational), ensuring any field
    Microsoft adds to a Graph API response is automatically captured.
    Changed/removed properties are classified via Get-PropertySeverity.

.PARAMETER OldObject
    Previous object (PSCustomObject or hashtable).

.PARAMETER NewObject
    Current object (PSCustomObject or hashtable).

.PARAMETER Context
    Human-readable context string for descriptions (e.g., "Global Administrator").

.PARAMETER FileType
    The file type being diffed (used in the change entry).

.RETURNS
    Array of change entries: @{ severity, fileType, changeType, propertyKey, description, old, new }
#>
function Compare-FlatProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $OldObject,
        [Parameter(Mandatory)] $NewObject,
        [Parameter(Mandatory)] [string] $Context,
        [string] $FileType = "definition"
    )

    $changes = @()

    # Collect all property names from both objects, excluding the ignore list
    $allKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $getKeys = {
        param($obj)
        if ($null -eq $obj) { return @() }
        if ($obj -is [System.Collections.IDictionary]) { return @($obj.Keys) }
        if ($obj -is [psobject]) { return @($obj.PSObject.Properties.Name) }
        return @()
    }

    foreach ($key in (& $getKeys $OldObject)) {
        if (-not $script:DiffIgnoreProperties.Contains($key)) { $allKeys.Add($key) | Out-Null }
    }
    foreach ($key in (& $getKeys $NewObject)) {
        if (-not $script:DiffIgnoreProperties.Contains($key)) { $allKeys.Add($key) | Out-Null }
    }

    # Returns @{Value=...; Exists=$true/$false}. Using a hashtable avoids
    # PowerShell's pipeline flattening when the property value is itself an array.
    $getValue = {
        param($obj, $key)
        if ($null -eq $obj) { return @{ Value = $null; Exists = $false } }
        if ($obj -is [System.Collections.IDictionary]) {
            if ($obj.Contains($key)) { return @{ Value = $obj[$key]; Exists = $true } }
            return @{ Value = $null; Exists = $false }
        }
        if ($obj -is [psobject]) {
            $prop = $obj.PSObject.Properties[$key]
            if ($null -ne $prop) { return @{ Value = $prop.Value; Exists = $true } }
            return @{ Value = $null; Exists = $false }
        }
        return @{ Value = $null; Exists = $false }
    }

    foreach ($key in $allKeys) {
        $oldResult   = & $getValue $OldObject $key
        $newResult   = & $getValue $NewObject $key
        $oldVal      = $oldResult['Value']
        $existsInOld = $oldResult['Exists']
        $newVal      = $newResult['Value']
        $existsInNew = $newResult['Exists']

        if ($existsInNew -and -not $existsInOld) {
            $changes += @{
                severity    = $script:DefaultPropertySeverity
                fileType    = $FileType
                changeType  = "new_property"
                propertyKey = $key
                context     = $Context
                description = "New property in definition for ${Context}: $key"
                old         = $null
                new         = $newVal
            }
        }
        elseif ($existsInOld -and -not $existsInNew) {
            $changes += @{
                severity    = (Get-PropertySeverity -PropertyKey $key)
                fileType    = $FileType
                changeType  = "removed_property"
                propertyKey = $key
                context     = $Context
                description = "Property removed from definition for ${Context}: $key"
                old         = $oldVal
                new         = $null
            }
        }
        elseif ($existsInOld -and $existsInNew) {
            if (-not (Test-ObjectEqual -Left $oldVal -Right $newVal)) {
                $changes += @{
                    severity    = (Get-PropertySeverity -PropertyKey $key)
                    fileType    = $FileType
                    changeType  = "updated"
                    propertyKey = $key
                    context     = $Context
                    description = "Definition changed for ${Context}: $key"
                    old         = $oldVal
                    new         = $newVal
                }
            }
        }
    }

    return $changes
}

# ============================================================================
# Main Diff Orchestrator
# ============================================================================

<#
.SYNOPSIS
    Compares an inventory folder against newly fetched data.

.DESCRIPTION
    Reads previous files from disk, compares with new data, classifies all
    changes by severity. Works for any workload (directory-roles, pim-groups,
    authentication-contexts, administrative-units).

.PARAMETER FolderPath
    Path to the inventory folder for this entity.

.PARAMETER NewData
    Hashtable of new data keyed by file type: @{ definition = $obj; policy = $obj; assignments = $obj }
    For lookup entities, only "definition" is expected.

.PARAMETER EntityName
    Human-readable name for log messages (e.g., "Global Administrator").

.RETURNS
    Array of change entries, each with severity, description, old, new.
#>
function Compare-InventoryFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FolderPath,

        [Parameter(Mandatory)]
        [hashtable] $NewData,

        [Parameter(Mandatory)]
        [string] $EntityName
    )

    $changes = @()
    $isNewEntity = -not (Test-Path $FolderPath)

    foreach ($fileType in $NewData.Keys) {
        $fileName = "$fileType.json"
        $filePath = Join-Path -Path $FolderPath -ChildPath $fileName

        $oldData = Read-PreviousInventoryFile -FilePath $filePath
        $newDataForFile = $NewData[$fileType]

        # New entity (folder doesn't exist yet)
        if ($null -eq $oldData -and $null -ne $newDataForFile) {
            $severity = if ($fileType -eq "definition") { "High" } else { "Medium" }
            $changes += @{
                severity    = $severity
                fileType    = $fileType
                changeType  = "created"
                context     = $EntityName
                description = "New $fileType for $EntityName"
                old         = $null
                new         = $newDataForFile
            }
            continue
        }

        # Entity removed (shouldn't happen in normal flow, but handle it)
        if ($null -ne $oldData -and $null -eq $newDataForFile) {
            $changes += @{
                severity    = "High"
                fileType    = $fileType
                changeType  = "deleted"
                context     = $EntityName
                description = "$fileType removed for $EntityName"
                old         = $oldData
                new         = $null
            }
            continue
        }

        # Both exist — skip if no data
        if ($null -eq $oldData -and $null -eq $newDataForFile) { continue }

        # Quick check: any change at all?
        if (Test-ObjectEqual -Left $oldData -Right $newDataForFile) { continue }

        # File changed — detailed analysis per type
        switch ($fileType) {
            "definition" {
                # Property-level analysis: one change entry per changed/added/removed property.
                # Unknown new properties are caught as Informational automatically.
                $propChanges = Compare-FlatProperties `
                    -OldObject $oldData `
                    -NewObject $newDataForFile `
                    -Context   $EntityName `
                    -FileType  $fileType
                $changes += $propChanges
            }

            "policy" {
                # Rule-level analysis
                $ruleChanges = Compare-PolicyRules -OldPolicy $oldData -NewPolicy $newDataForFile -Context $EntityName
                $changes += $ruleChanges
            }

            "assignments" {
                # Entry-level analysis
                $assignmentChanges = Compare-Assignments -OldAssignments $oldData -NewAssignments $newDataForFile -Context $EntityName
                $changes += $assignmentChanges
            }
        }
    }

    return $changes
}

<#
.SYNOPSIS
    Detects entities that were removed (folder exists but no new data fetched).

.PARAMETER WorkloadPath
    Path to the workload folder (e.g., "inventory/directory-roles").

.PARAMETER CurrentSlugs
    Array of slugs that were fetched in the current scan.

.RETURNS
    Array of change entries for removed entities.
#>
function Get-RemovedEntities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkloadPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $CurrentSlugs
    )

    $changes = @()

    if (-not (Test-Path $WorkloadPath)) { return $changes }

    $existingFolders = Get-ChildItem -Path $WorkloadPath -Directory
    $currentSlugSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$CurrentSlugs,
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($folder in $existingFolders) {
        if (-not $currentSlugSet.Contains($folder.Name)) {
            $changes += @{
                severity    = "High"
                fileType    = "definition"
                changeType  = "deleted"
                description = "Entity removed from PIM: $($folder.Name)"
                old         = $folder.FullName
                new         = $null
                folderPath  = $folder.FullName
            }
        }
    }

    return $changes
}

<#
.SYNOPSIS
    Detects assignments expiring within a configurable window.

.DESCRIPTION
    Scans all assignments (permanent, eligible, active) across all roles/groups.
    For each assignment with an endDateTime, calculates days remaining.
    Returns Medium-severity changes for assignments expiring within the window.

    Permanent assignments (no endDateTime) are skipped — they never expire.

.PARAMETER Assignments
    Hashtable of assignments by entity slug: @{ 'slug' = @{ permanent=...; eligible=...; active=... }; ... }

.PARAMETER WindowDays
    Number of days ahead to scan (default: 14, from env var EXPIRING_WINDOW_DAYS).

.RETURNS
    Array of change entries with severity='Medium', changeType='expiring'
#>
function Find-ExpiringAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Assignments,

        [ValidateRange(1, 365)]
        [int] $WindowDays = 14
    )

    $changes = @()
    $nowUtc = Get-Date -AsUTC

    foreach ($entityId in $Assignments.Keys) {
        $entityAssignments = $Assignments[$entityId]

        foreach ($category in @('permanent', 'eligible', 'active')) {
            $categoryAssignments = $entityAssignments[$category]
            if (-not $categoryAssignments) { continue }

            foreach ($assignment in $categoryAssignments) {
                $scheduleInfo = $assignment.PSObject.Properties['scheduleInfo']?.Value
                $expiration   = if ($null -ne $scheduleInfo) { $scheduleInfo.PSObject.Properties['expiration']?.Value } else { $null }
                $endDateTime  = if ($null -ne $expiration)   { $expiration.PSObject.Properties['endDateTime']?.Value  } else { $null }
                if (-not $endDateTime) {
                    continue
                }

                try {
                    $expiryTime = [datetime]::Parse($endDateTime, [System.Globalization.CultureInfo]::InvariantCulture)
                    $daysRemaining = ($expiryTime - $nowUtc).TotalDays

                    if ($daysRemaining -gt 0 -and $daysRemaining -le $WindowDays) {
                        $principal = $assignment.PSObject.Properties['principal']?.Value
                        $principalName = if ($principal -and $principal.PSObject.Properties['displayName']?.Value) {
                            $principal.displayName
                        }
                        else {
                            $principal.PSObject.Properties['mail']?.Value ?? $assignment.PSObject.Properties['principalId']?.Value
                        }

                        $changes += @{
                            severity       = "Medium"
                            changeType     = "expiring"
                            daysRemaining  = [math]::Round($daysRemaining)
                            description    = "Assignment expiring in $([math]::Round($daysRemaining)) days ($category): $principalName"
                            category       = $category
                            assignment     = $assignment
                            expiryTime     = $expiryTime
                            isAlert        = $true
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to parse endDateTime for assignment: $_"
                }
            }
        }
    }

    return $changes
}

<#
.SYNOPSIS
    Tests if a detected change matches an expected suppression entry.

.DESCRIPTION
    Checks whether a change matches on workload, entity slug, fileType, and optionally ruleId.
    Expired expectations (expiresUtc in the past) are ignored.

.PARAMETER Change
    A change entry from the diff engine.

.PARAMETER Expectations
    Array of expected-change entries from expected-changes.json.

.RETURNS
    $true if change matches and is not expired; $false otherwise.
#>
function Test-ChangeIsExpected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Change,

        [Parameter()]
        [array] $Expectations = @()
    )

    if (-not $Expectations -or $Expectations.Count -eq 0) {
        return $false
    }

    $changeWorkload = if ($Change.workload) { $Change.workload.ToLower() } else { "" }
    $changeEntity = if ($Change.entity) { $Change.entity.ToLower() } else { "" }
    $changeFileType = if ($Change.fileType) { $Change.fileType.ToLower() } else { "" }
    $changeRuleId = if ($Change.ruleId) { $Change.ruleId } else { $null }

    foreach ($expectation in $Expectations) {
        if ($expectation.expiresUtc) {
            try {
                $expiryTime = [datetime]::Parse($expectation.expiresUtc, [System.Globalization.CultureInfo]::InvariantCulture)
                if ((Get-Date -AsUTC) -gt $expiryTime) {
                    continue
                }
            }
            catch {
                Write-Warning "Failed to parse expiresUtc: $_"
                continue
            }
        }

        if ($expectation.workload -and $expectation.workload.ToLower() -ne $changeWorkload) {
            continue
        }

        if ($expectation.entity -and $expectation.entity.ToLower() -ne $changeEntity) {
            continue
        }

        if ($expectation.fileType -and $expectation.fileType.ToLower() -ne $changeFileType) {
            continue
        }

        if ($expectation.ruleId) {
            if ($changeRuleId -and $changeRuleId.ToLower() -eq $expectation.ruleId.ToLower()) {
                return $true
            }
            continue
        }

        return $true
    }

    return $false
}

<#
.SYNOPSIS
    Aggregates changes into severity buckets, separating alerts from informational entries.

.PARAMETER Changes
    Flat array of change entries (each must have a 'severity' key and optional 'isAlert' flag).

.RETURNS
    Hashtable: @{ High = @(...), Medium = @(...), Low = @(...), Informational = @(...), Total = [int] }

    Informational entries are those without 'isAlert' flag (e.g., activation events).
#>
function Group-ChangesBySeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array] $Changes
    )

    $grouped = @{
        High          = @($Changes | Where-Object { $_.severity -eq "High" })
        Medium        = @($Changes | Where-Object { $_.severity -eq "Medium" })
        Low           = @($Changes | Where-Object { $_.severity -eq "Low" })
        Informational = @($Changes | Where-Object { $_.severity -notin @("High", "Medium", "Low") })
        Total         = $Changes.Count
    }

    return $grouped
}
