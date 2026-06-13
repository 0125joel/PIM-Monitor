<#
.SYNOPSIS
    Access model compliance detection — severity classification and desired-state enforcement.

.DESCRIPTION
    Loads user-defined access model definitions from AccessModel/ folder. Each file groups
    roles by EAM plane and severity (High/Medium/Low) and optionally specifies a sparse
    set of expected PIM policy properties. Detects two types of violations:

    1. Compliance: role in model file, but policy doesn't match expectedConfig
    2. Coverage: role in inventory but not in any model file (configurable scope + exclusions)

    Change entries flow through existing Test-ChangeIsExpected and notification pipeline
    without modification.
#>

Set-StrictMode -Version Latest

<#
Declarative mapping: expectedConfig field name -> rule extraction + comparison logic.
Each row defines how to extract expected and actual values from Graph API policy rules.
New properties supported by adding rows; unknown keys in expectedConfig generate
warnings but don't break the scan.
#>
$script:ExpectedConfigToRule = @(
    @{
        fieldName = "maxActivationDuration"
        ruleId    = "Expiration_EndUser_Assignment"
        extractor = {
            param($rule)
            if ((Test-ObjectHasKey $rule 'setting') -and (Test-ObjectHasKey $rule.setting 'maximumDuration')) {
                return $rule.setting.maximumDuration
            }
            return $null
        }
        comparison = 'StringEqual'
    }

    @{
        fieldName = "requireJustification"
        ruleId    = "Enablement_EndUser_Assignment"
        extractor = {
            param($rule)
            if ((Test-ObjectHasKey $rule 'setting') -and (Test-ObjectHasKey $rule.setting 'enabledRules')) {
                return @('Justification') -in $rule.setting.enabledRules
            }
            return $false
        }
        comparison = 'BoolEqual'
    }

    @{
        fieldName = "requireTicketing"
        ruleId    = "Enablement_EndUser_Assignment"
        extractor = {
            param($rule)
            if ((Test-ObjectHasKey $rule 'setting') -and (Test-ObjectHasKey $rule.setting 'enabledRules')) {
                return @('Ticketing') -in $rule.setting.enabledRules
            }
            return $false
        }
        comparison = 'BoolEqual'
    }

    @{
        fieldName  = "requireMFA"
        ruleId     = "AuthenticationContext_EndUser_Assignment"
        fullPolicy = $true
        extractor  = {
            param($policy)
            $rules = $policy.PSObject.Properties['rules']?.Value
            if (-not $rules) { return $false }

            $authRule = @($rules) | Where-Object { $_.id -eq 'AuthenticationContext_EndUser_Assignment' } | Select-Object -First 1
            if ($authRule) {
                if (Test-ObjectHasKey $authRule 'isEnabled') {
                    return $authRule.isEnabled
                }
            }

            $enablementRule = @($rules) | Where-Object { $_.id -eq 'Enablement_EndUser_Assignment' } | Select-Object -First 1
            if ($enablementRule) {
                if ((Test-ObjectHasKey $enablementRule 'setting') -and (Test-ObjectHasKey $enablementRule.setting 'enabledRules')) {
                    return 'MultiFactorAuthentication' -in $enablementRule.setting.enabledRules
                }
            }
            return $false
        }
        comparison = 'BoolEqual'
    }

    @{
        fieldName = "requireApproval"
        ruleId    = "Approval_EndUser_Assignment"
        extractor = {
            param($rule)
            if ((Test-ObjectHasKey $rule 'setting') -and (Test-ObjectHasKey $rule.setting 'isApprovalRequired')) {
                return $rule.setting.isApprovalRequired
            }
            return $false
        }
        comparison = 'BoolEqual'
    }

    @{
        fieldName = "allowPermanentEligible"
        ruleId    = "Expiration_Admin_Eligibility"
        extractor = {
            param($rule)
            if (Test-ObjectHasKey $rule 'isExpirationRequired') {
                return -not $rule.isExpirationRequired
            }
            return $false
        }
        comparison = 'BoolEqual'
    }

    @{
        fieldName = "maxEligibleDuration"
        ruleId    = "Expiration_Admin_Eligibility"
        extractor = {
            param($rule)
            if (Test-ObjectHasKey $rule 'maximumDuration') {
                return $rule.maximumDuration
            }
            return $null
        }
        comparison = 'StringEqual'
    }

    @{
        fieldName = "allowPermanentActive"
        ruleId    = "Expiration_Admin_Assignment"
        extractor = {
            param($rule)
            if (Test-ObjectHasKey $rule 'isExpirationRequired') {
                return -not $rule.isExpirationRequired
            }
            return $false
        }
        comparison = 'BoolEqual'
    }

    @{
        fieldName = "maxActiveDuration"
        ruleId    = "Expiration_Admin_Assignment"
        extractor = {
            param($rule)
            if (Test-ObjectHasKey $rule 'maximumDuration') {
                return $rule.maximumDuration
            }
            return $null
        }
        comparison = 'StringEqual'
    }

    @{
        fieldName = "authContext"
        ruleId    = "AuthenticationContext_EndUser_Assignment"
        extractor = {
            param($rule)
            if (-not $rule) { return $null }
            if ((Test-ObjectHasKey $rule 'isEnabled') -and $rule.isEnabled) {
                $claimValue = $rule.PSObject.Properties['setting']?.Value?.PSObject.Properties['claimValue']?.Value
                if ($claimValue) { return [string]$claimValue }
            }
            return $null
        }
        comparison = 'StringEqual'
    }
)

# Declarative field checks for Get-AuthContextPolicyCompliance.
# Each entry: field name, evaluate scriptblock that receives ($caPolicy, $expectedValue)
# and returns @{ passes = [bool]; actual = <display value or $null> }.
$script:CaPolicyConfigToCheck = @(
    @{
        field    = 'requireState'
        evaluate = {
            param($p, $exp)
            $actual = $p.PSObject.Properties['state']?.Value
            @{ passes = [string]$actual -eq [string]$exp; actual = $actual }
        }
    }
    @{
        field    = 'requireAuthStrengthId'
        evaluate = {
            param($p, $exp)
            $gc     = $p.PSObject.Properties['grantControls']?.Value
            $str    = if ($gc) { $gc.PSObject.Properties['authenticationStrength']?.Value } else { $null }
            $actual = if ($str) { $str.PSObject.Properties['id']?.Value } else { $null }
            @{ passes = [string]$actual -eq [string]$exp; actual = $actual }
        }
    }
    @{
        field    = 'requireSignInFrequencyEveryTime'
        evaluate = {
            param($p, $exp)
            if (-not [bool]$exp) { return @{ passes = $true; actual = $null } }
            $sc       = $p.PSObject.Properties['sessionControls']?.Value
            $sif      = if ($sc)  { $sc.PSObject.Properties['signInFrequency']?.Value }      else { $null }
            $enabled  = if ($sif) { $sif.PSObject.Properties['isEnabled']?.Value }           else { $null }
            $interval = if ($sif) { $sif.PSObject.Properties['frequencyInterval']?.Value }   else { $null }
            @{
                passes = ([bool]$enabled -eq $true) -and ([string]$interval -eq 'everyTime')
                actual = if ($sif) { "isEnabled=$enabled frequencyInterval=$interval" } else { $null }
            }
        }
    }
    @{
        field    = 'requireCompliantDevice'
        evaluate = {
            param($p, $exp)
            if (-not [bool]$exp) { return @{ passes = $true; actual = $null } }
            $gc  = $p.PSObject.Properties['grantControls']?.Value
            $bc  = if ($gc) { $gc.PSObject.Properties['builtInControls']?.Value } else { $null }
            @{
                passes = $bc -and ('compliantDevice' -in $bc)
                actual = if ($bc) { $bc -join ', ' } else { $null }
            }
        }
    }
)

<#
.SYNOPSIS
    Builds a slug-to-claimValue map from inventory/authentication-contexts/.

.PARAMETER InventoryPath
    Path to the inventory root directory (contains authentication-contexts/ subdirectory).

.RETURNS
    Hashtable: slug -> claimValue (e.g. @{ 'phish-resistant-sif' = 'c2' })
    Empty hashtable if path doesn't exist.
#>
function Get-AuthContextMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $InventoryPath
    )

    $map = @{}
    $authContextPath = Join-Path -Path $InventoryPath -ChildPath "authentication-contexts"

    if (-not (Test-Path $authContextPath -PathType Container)) {
        Write-Verbose "No authentication-contexts inventory found at: $authContextPath"
        return $map
    }

    foreach ($dir in Get-ChildItem -Path $authContextPath -Directory) {
        $defFile = Join-Path -Path $dir.FullName -ChildPath "definition.json"
        if (Test-Path $defFile) {
            try {
                $def = Get-Content -Path $defFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json
                if ($def.id) {
                    $map[$dir.Name] = $def.id
                    Write-Verbose "Auth context: $($dir.Name) -> $($def.id)"
                }
            }
            catch {
                Write-Warning "Failed to parse auth context definition '$defFile': $_"
            }
        }
    }

    return $map
}

<#
.SYNOPSIS
    Resolves an authContext slug in an expectedConfig to its claimValue.

.PARAMETER ExpectedConfig
    The expectedConfig object (PSCustomObject or hashtable). May contain an 'authContext'
    field holding a slug from inventory/authentication-contexts/.

.PARAMETER AuthContextMap
    Hashtable from Get-AuthContextMap: slug -> claimValue.

.RETURNS
    A hashtable copy of ExpectedConfig with authContext replaced by its resolved claimValue,
    or with authContext removed (and a warning emitted) if the slug is not in the map.
    Returns the input unchanged if no authContext field is present.
#>
function Resolve-AuthContextConfig {
    [CmdletBinding()]
    param(
        [Parameter()]
        $ExpectedConfig,

        [Parameter()]
        [hashtable] $AuthContextMap = @{}
    )

    if (-not $ExpectedConfig) { return $ExpectedConfig }

    $configHash      = ConvertTo-Hashtable -InputObject $ExpectedConfig
    $authContextSlug = $configHash['authContext']

    if (-not $authContextSlug) { return $ExpectedConfig }

    $resolved = $configHash.Clone()

    if (-not $AuthContextMap -or -not $AuthContextMap.ContainsKey($authContextSlug)) {
        Write-Warning "Auth context slug '$authContextSlug' not found in inventory; skipping authContext compliance check."
        $resolved.Remove('authContext')
    } else {
        $resolved['authContext'] = $AuthContextMap[$authContextSlug]
    }

    return $resolved
}

<#
.SYNOPSIS
    Loads all access-model definitions from the AccessModel/ folder.

.PARAMETER TiersPath
    Path to the AccessModel directory.

.RETURNS
    Array of access-model objects: @{ name, description, severity, roles, expectedConfig }
    Empty array if the path doesn't exist.

#>
function Get-TierDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TiersPath
    )

    $tiers = @()

    if (-not (Test-Path $TiersPath -PathType Container)) {
        Write-Verbose "Access-model path does not exist: $TiersPath"
        return $tiers
    }

    $tierFiles = Get-ChildItem -Path $TiersPath -Filter "*.json" -File -Recurse | Where-Object { $_.Name -ne 'coverage-exclusions.json' }

    $allRoleIds = @{}

    foreach ($file in $tierFiles | Sort-Object Name) {
        try {
            $content = Get-Content -Path $file.FullName -Raw -Encoding utf8NoBOM | ConvertFrom-Json
            Write-Verbose "Loaded access-model file: $($file.Name)"

            $severity = $content.PSObject.Properties['severity']?.Value
            if (-not $severity) {
                $securityLevel = $content.PSObject.Properties['securityLevel']?.Value
                $severityMap   = @{ Privileged = 'High'; Specialized = 'Medium'; Enterprise = 'Low' }
                $severity      = $severityMap[$securityLevel]
            }

            if (-not $severity) {
                Write-Warning "Access-model file '$($file.Name)' missing 'severity' or 'securityLevel' field, skipping."
                continue
            }

            if ($severity -notin @('High', 'Medium', 'Low')) {
                Write-Warning "Access-model file '$($file.Name)' has invalid severity '$severity', skipping."
                continue
            }

            if (-not $content.PSObject.Properties['severity']) {
                $content | Add-Member -NotePropertyName 'severity' -NotePropertyValue $severity
            }

            if (-not $content.roles) {
                $content.roles = @()
            }

            foreach ($role in $content.roles) {
                if ($role.id) {
                    if ($allRoleIds.ContainsKey($role.id)) {
                        Write-Warning "Role ID '$($role.id)' appears in multiple access-model files: '$($allRoleIds[$role.id])' and '$($file.Name)'. First match wins."
                    }
                    else {
                        $allRoleIds[$role.id] = $file.Name
                    }
                }
            }

            $tiers += $content
        }
        catch {
            Write-Warning "Failed to parse access-model file '$($file.Name)': $_"
            continue
        }
    }

    return @($tiers)
}

<#
.SYNOPSIS
    Loads coverage exclusion list from AccessModel/coverage-exclusions.json.

.PARAMETER TiersPath
    Path to the AccessModel directory.

.RETURNS
    HashSet of role IDs to exclude from coverage checks. Empty set if file doesn't exist.
#>
function Get-CoverageExclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TiersPath
    )

    $exclusionFile = Join-Path -Path $TiersPath -ChildPath "coverage-exclusions.json"
    $exclusionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path $exclusionFile)) {
        Write-Verbose "Coverage exclusions file not found: $exclusionFile"
        return $exclusionSet
    }

    try {
        $content = Get-Content -Path $exclusionFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json
        if ($content.excludedRoleIds) {
            foreach ($role in $content.excludedRoleIds) {
                if ($role.id) {
                    $null = $exclusionSet.Add($role.id)
                }
            }
        }
        Write-Verbose "Loaded $($exclusionSet.Count) role exclusions from coverage check"
    }
    catch {
        Write-Warning "Failed to parse coverage exclusions: $_"
    }

    return $exclusionSet
}

<#
.SYNOPSIS
    Compares role's actual policy against expected config for a single field.

.PARAMETER Field
    Expected config field name (e.g., "requireMFA").

.PARAMETER Expected
    Expected value from the access-model file.

.PARAMETER Actual
    Actual value extracted from Graph API policy.

.RETURNS
    Comparison object: @{ field, expected, actual, matches }
#>
function Compare-ConfigField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Field,

        [Parameter()]
        $Expected,

        [Parameter()]
        $Actual,

        [Parameter(Mandatory)]
        [ValidateSet('StringEqual', 'BoolEqual')]
        [string] $Comparison
    )

    $isMatch = $false

    switch ($Comparison) {
        'StringEqual' {
            $isMatch = [string]$Expected -eq [string]$Actual
        }
        'BoolEqual' {
            $isMatch = [bool]$Expected -eq [bool]$Actual
        }
    }

    return @{
        field   = $Field
        expected = $Expected
        actual   = $Actual
        matches  = $isMatch
    }
}

<#
.SYNOPSIS
    Checks if a role's policy complies with expectedConfig (sparse comparison).

.PARAMETER RolePolicy
    Full policy object from inventory/directory-roles/{slug}/policy.json.

.PARAMETER ExpectedConfig
    User-specified config constraints (hashtable or PSObject). Only keys present
    are checked; missing keys mean no constraint.

.RETURNS
    Array of violations: @{ field, expected, actual } for fields that don't match.
    Empty array if expectedConfig is null/empty or all fields match.

#>
function Test-RolePolicyCompliance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RolePolicy,

        [Parameter()]
        $ExpectedConfig
    )

    $violations = @()

    if (-not $ExpectedConfig) { return $violations }

    [string[]]$fieldNames = Get-ObjectKeys -InputObject $ExpectedConfig

    if ($fieldNames.Count -eq 0) { return $violations }

    $configHash = ConvertTo-Hashtable -InputObject $ExpectedConfig
    foreach ($expectedField in $fieldNames) {
        $expectedValue = $configHash[$expectedField]

        $mapping = $script:ExpectedConfigToRule | Where-Object { $_.fieldName -eq $expectedField }

        if (-not $mapping) {
            Write-Warning "Unknown expectedConfig field: '$expectedField' — skipping."
            continue
        }

        try {
            $policyRules = $RolePolicy.PSObject.Properties['policy']?.Value?.PSObject.Properties['rules']?.Value
            $rule = if ($policyRules) { $policyRules | Where-Object { $_.id -eq $mapping.ruleId } | Select-Object -First 1 } else { $null }

            $isFullPolicy = [bool]$mapping['fullPolicy']

            # Absent rule = non-compliant: the control doesn't exist, so the requirement cannot be met.
            if (-not $rule -and -not $isFullPolicy) {
                Write-Warning "Rule '$($mapping.ruleId)' not found in policy for field '$expectedField'"
                $violations += @{
                    field    = $expectedField
                    expected = $expectedValue
                    actual   = $null
                }
                continue
            }

            # fullPolicy extractors receive the inner policy object (with .rules); all others receive the specific rule
            $extractorArg = if ($isFullPolicy) { $RolePolicy.PSObject.Properties['policy']?.Value } else { $rule }
            $actualValue = & $mapping.extractor $extractorArg

            $comparison = Compare-ConfigField -Field $expectedField -Expected $expectedValue -Actual $actualValue -Comparison $mapping.comparison

            if (-not $comparison.matches) {
                $violations += @{
                    field    = $comparison.field
                    expected = $comparison.expected
                    actual   = $comparison.actual
                }
            }
        }
        catch {
            Write-Warning "Error checking field '$expectedField': $_"
            $violations += @{
                field    = $expectedField
                expected = $expectedValue
                actual   = "ERROR: $_"
            }
        }
    }

    return @($violations)
}

<#
.SYNOPSIS
    Detects compliance violations (role in tier but policy doesn't match expectedConfig).

.PARAMETER TierDefinitions
    Array of loaded tier objects from Get-TierDefinitions.

.PARAMETER RoleResults
    Array of role results from Scan-PimState (with cleanAssignments, definition, policy, slug).

.RETURNS
    Array of change-entry objects ready for notification pipeline:
    @{
        severity, workload, entity, fileType, ruleId, changeType, context, description, isAlert, old, new
    }

#>
function Get-ComplianceViolations {
    [CmdletBinding()]
    param(
        [Parameter()]
        [array] $TierDefinitions = @(),

        [Parameter(Mandatory)]
        [array] $RoleResults,

        [Parameter()]
        [hashtable] $AuthContextMap = @{}
    )

    $violations = @()

    if (@($TierDefinitions).Count -eq 0) {
        return $violations
    }

    $roleResultsByIdLower = @{}
    foreach ($result in $RoleResults) {
        if (-not $result.error -and $result.definition.id) {
            $roleResultsByIdLower[$result.definition.id.ToLower()] = $result
        }
    }

    foreach ($tier in $TierDefinitions) {
        # Use PSObject.Properties safe access — expectedConfig is optional (strict mode would throw otherwise)
        $tierExpectedConfig = $tier.PSObject.Properties['expectedConfig']?.Value

        if (-not $tierExpectedConfig) {
            Write-Verbose "Access model '$($tier.name)' has no expectedConfig, skipping compliance checks."
            continue
        }

        $resolvedConfig = Resolve-AuthContextConfig -ExpectedConfig $tierExpectedConfig -AuthContextMap $AuthContextMap

        foreach ($tierRole in $tier.roles) {
            $roleId = $tierRole.id
            if (-not $roleId) { continue }

            $roleResult = $roleResultsByIdLower[$roleId.ToLower()]
            if (-not $roleResult) {
                Write-Verbose "Role ID '$roleId' from access model '$($tier.name)' not found in current inventory."
                continue
            }
            $policyViolations = Test-RolePolicyCompliance -RolePolicy $roleResult.policyAssignment -ExpectedConfig $resolvedConfig

            if (@($policyViolations).Count -gt 0) {
                $oldValues = @{}
                $newValues = @{}
                foreach ($violation in $policyViolations) {
                    $oldValues[$violation.field] = $violation.actual
                    $newValues[$violation.field] = $violation.expected
                }
                $violations += @{
                    severity    = $tier.severity
                    workload    = "directory-roles"
                    entity      = $roleResult.slug
                    fileType    = "access-model-compliance"
                    ruleId      = "compliance"
                    roleId      = $roleResult.definition.id
                    changeType  = "non-compliant"
                    context     = $roleResult.definition.displayName
                    description = "Access model '$($tier.name)' compliance: $(@($policyViolations).Count) violation(s) on '$($roleResult.definition.displayName)'"
                    isAlert     = $true
                    old         = $oldValues
                    new         = $newValues
                }
            }
        }
    }

    return @($violations)
}

<#
.SYNOPSIS
    Detects coverage violations (roles in inventory but not in any tier).

.PARAMETER TierDefinitions
    Array of loaded tier objects from Get-TierDefinitions.

.PARAMETER RoleResults
    Array of role results from Scan-PimState.

.PARAMETER Exclusions
    HashSet of role IDs to exclude from coverage checks (from coverage-exclusions.json).

.PARAMETER Scope
    Coverage check scope: "privileged" (only roles with isPrivileged=true) or "all".
    Default: "privileged".

.RETURNS
    Array of change-entry objects for unclassified roles.

#>
function Get-CoverageViolations {
    [CmdletBinding()]
    param(
        [Parameter()]
        [array] $TierDefinitions = @(),

        [Parameter(Mandatory)]
        [array] $RoleResults,

        [Parameter()]
        [System.Collections.Generic.HashSet[string]] $Exclusions,

        [Parameter()]
        [ValidateSet('privileged', 'all')]
        [string] $Scope = 'privileged'
    )

    $violations = @()

    if (-not $Exclusions) {
        $Exclusions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $classifiedRoleIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tier in $TierDefinitions) {
        foreach ($tierRole in $tier.roles) {
            if ($tierRole.id) {
                $null = $classifiedRoleIds.Add($tierRole.id)
            }
        }
    }

    foreach ($result in $RoleResults) {
        if ($result.error) { continue }

        $roleId = $result.definition.id
        if (-not $roleId) { continue }

        if ($classifiedRoleIds.Contains($roleId)) {
            continue
        }

        if ($Exclusions.Contains($roleId)) {
            continue
        }

        if ($Scope -eq 'privileged' -and -not ((Test-ObjectHasKey $result.definition 'isPrivileged') -and $result.definition.isPrivileged)) {
            continue
        }

        $violations += @{
            severity    = "Medium"
            workload    = "directory-roles"
            entity      = $result.slug
            fileType    = "access-model-coverage"
            changeType  = "unclassified"
            context     = $result.definition.displayName
            description = "Unclassified role: '$($result.definition.displayName)' (ID: $roleId) is not in any access model definition."
            isAlert     = $true
            old         = $null
            new         = "Needs classification in an access model file"
        }
    }

    return @($violations)
}

<#
.SYNOPSIS
    Loads all group access model definitions from AccessModel/pim-groups/ folder.

.PARAMETER Path
    Path to AccessModel/pim-groups directory.

.RETURNS
    Array of group definition objects: @{ name, description, severity, groups, expectedConfig }
    Empty array if Path doesn't exist.

#>
function Get-GroupDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $groupDefs = @()

    if (-not (Test-Path $Path -PathType Container)) {
        Write-Verbose "Group access model path does not exist: $Path"
        return $groupDefs
    }

    $groupFiles = Get-ChildItem -Path $Path -Filter "*.json" -File -Recurse | Where-Object { $_.Name -ne 'coverage-exclusions.json' }

    $allGroupIds = @{}

    foreach ($file in $groupFiles | Sort-Object Name) {
        try {
            $content = Get-Content -Path $file.FullName -Raw -Encoding utf8NoBOM | ConvertFrom-Json
            Write-Verbose "Loaded group definition file: $($file.Name)"

            $severity = $content.PSObject.Properties['severity']?.Value
            if (-not $severity) {
                $securityLevel = $content.PSObject.Properties['securityLevel']?.Value
                $severityMap   = @{ Privileged = 'High'; Specialized = 'Medium'; Enterprise = 'Low' }
                $severity      = $severityMap[$securityLevel]
            }

            if (-not $severity) {
                Write-Warning "Group definition file '$($file.Name)' missing 'severity' or 'securityLevel' field, skipping."
                continue
            }

            if ($severity -notin @('High', 'Medium', 'Low')) {
                Write-Warning "Group definition file '$($file.Name)' has invalid severity '$severity', skipping."
                continue
            }

            if (-not $content.PSObject.Properties['severity']) {
                $content | Add-Member -NotePropertyName 'severity' -NotePropertyValue $severity
            }

            if (-not $content.groups) {
                $content.groups = @()
            }

            foreach ($group in $content.groups) {
                if ($group.id) {
                    if ($allGroupIds.ContainsKey($group.id)) {
                        Write-Warning "Group ID '$($group.id)' appears in multiple definition files: '$($allGroupIds[$group.id])' and '$($file.Name)'. First match wins."
                    }
                    else {
                        $allGroupIds[$group.id] = $file.Name
                    }
                }
            }

            # Validate expectedConfig sub-keys if present
            $expectedConfigObj = $content.PSObject.Properties['expectedConfig']?.Value
            if ($expectedConfigObj) {
                foreach ($accessId in @('member', 'owner')) {
                    $expectedSub = $expectedConfigObj.PSObject.Properties[$accessId]?.Value
                    if ($expectedSub) {
                        [string[]]$fieldNames = Get-ObjectKeys -InputObject $expectedSub

                        foreach ($fieldName in $fieldNames) {
                            if (-not ($script:ExpectedConfigToRule | Where-Object { $_.fieldName -eq $fieldName })) {
                                Write-Warning "Unknown expectedConfig field in ${accessId}: '$fieldName' (file: $($file.Name))"
                            }
                        }
                    }
                }
            }

            $groupDefs += $content
        }
        catch {
            Write-Warning "Failed to parse group definition file '$($file.Name)': $_"
            continue
        }
    }

    return @($groupDefs)
}

<#
.SYNOPSIS
    Loads coverage exclusion list from AccessModel/pim-groups/coverage-exclusions.json.

.PARAMETER Path
    Path to AccessModel/pim-groups directory.

.RETURNS
    HashSet of group IDs to exclude from coverage checks. Empty set if file doesn't exist.
#>
function Get-GroupCoverageExclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $exclusionFile = Join-Path -Path $Path -ChildPath "coverage-exclusions.json"
    $exclusionSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path $exclusionFile)) {
        Write-Verbose "Group coverage exclusions file not found: $exclusionFile"
        return $exclusionSet
    }

    try {
        $content = Get-Content -Path $exclusionFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json
        if ($content.excludedGroupIds) {
            foreach ($group in $content.excludedGroupIds) {
                if ($group.id) {
                    $null = $exclusionSet.Add($group.id)
                }
            }
        }
        Write-Verbose "Loaded $($exclusionSet.Count) group exclusions from coverage check"
    }
    catch {
        Write-Warning "Failed to parse group coverage exclusions: $_"
    }

    return $exclusionSet
}

<#
.SYNOPSIS
    Detects compliance violations for PIM groups (member and owner policies).

.PARAMETER GroupDefinitions
    Array of loaded group definition objects from Get-GroupDefinitions.

.PARAMETER GroupResults
    Array of group results from Scan-PimState (with policyAssignment wrapper, definition, slug).

.RETURNS
    Array of change-entry objects ready for notification pipeline.

#>
function Get-GroupComplianceViolations {
    [CmdletBinding()]
    param(
        [Parameter()]
        [array] $GroupDefinitions = @(),

        [Parameter(Mandatory)]
        [array] $GroupResults,

        [Parameter()]
        [hashtable] $AuthContextMap = @{}
    )

    $violations = @()

    if (@($GroupDefinitions).Count -eq 0) {
        return $violations
    }

    $groupResultsByIdLower = @{}
    foreach ($result in $GroupResults) {
        if (-not $result.error -and $result.definition.id) {
            $groupResultsByIdLower[$result.definition.id.ToLower()] = $result
        }
    }

    foreach ($groupDef in $GroupDefinitions) {
        $groupDefExpectedConfig = $groupDef.PSObject.Properties['expectedConfig']?.Value

        if (-not $groupDefExpectedConfig) {
            Write-Verbose "Group definition '$($groupDef.name)' has no expectedConfig, skipping compliance checks."
            continue
        }

        foreach ($groupEntry in $groupDef.groups) {
            $groupId = $groupEntry.id
            if (-not $groupId) { continue }

            $groupResult = $groupResultsByIdLower[$groupId.ToLower()]
            if (-not $groupResult) {
                Write-Verbose "Group ID '$groupId' from definition '$($groupDef.name)' not found in current inventory."
                continue
            }

            $policyWrapper = $groupResult.policyAssignment

            foreach ($accessId in @('member', 'owner')) {
                $expectedSub = $groupDefExpectedConfig.PSObject.Properties[$accessId]?.Value
                if (-not $expectedSub) {
                    Write-Verbose "Group definition '$($groupDef.name)' has no expectedConfig for $accessId, skipping."
                    continue
                }

                $subPolicy = $policyWrapper.PSObject.Properties[$accessId]?.Value
                if (-not $subPolicy) {
                    Write-Warning "Group '$($groupResult.definition.displayName)' missing $accessId policy."
                    continue
                }

                $resolvedSub = Resolve-AuthContextConfig -ExpectedConfig $expectedSub -AuthContextMap $AuthContextMap
                $policyViolations = Test-RolePolicyCompliance -RolePolicy $subPolicy -ExpectedConfig $resolvedSub

                foreach ($pv in $policyViolations) {
                    $violations += @{
                        severity    = $groupDef.severity
                        workload    = "pim-groups"
                        entity      = $groupResult.slug
                        fileType    = "group-compliance"
                        ruleId      = "$accessId/$($pv.field)"
                        groupId     = $groupResult.definition.id
                        changeType  = "non-compliant"
                        context     = "$($groupResult.definition.displayName) ($accessId)"
                        description = "Access model '$($groupDef.name)' compliance: '$($pv.field)' violation on '$($groupResult.definition.displayName)' ($accessId)"
                        isAlert     = $true
                        old         = $pv.actual
                        new         = $pv.expected
                    }
                }
            }
        }
    }

    return @($violations)
}

<#
.SYNOPSIS
    Detects coverage violations for PIM groups (groups in inventory but not in any definition).

.PARAMETER GroupDefinitions
    Array of loaded group definition objects from Get-GroupDefinitions.

.PARAMETER GroupResults
    Array of group results from Scan-PimState.

.PARAMETER Exclusions
    HashSet of group IDs to exclude from coverage checks (from coverage-exclusions.json).

.RETURNS
    Array of change-entry objects for unclassified groups.

#>
function Get-GroupCoverageViolations {
    [CmdletBinding()]
    param(
        [Parameter()]
        [array] $GroupDefinitions = @(),

        [Parameter(Mandatory)]
        [array] $GroupResults,

        [Parameter()]
        [System.Collections.Generic.HashSet[string]] $Exclusions
    )

    $violations = @()

    if (-not $Exclusions) {
        $Exclusions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    $classifiedGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($groupDef in $GroupDefinitions) {
        foreach ($groupEntry in $groupDef.groups) {
            if ($groupEntry.id) {
                $null = $classifiedGroupIds.Add($groupEntry.id)
            }
        }
    }

    foreach ($result in $GroupResults) {
        if ($result.error) { continue }

        $groupId = $result.definition.id
        if (-not $groupId) { continue }

        if ($classifiedGroupIds.Contains($groupId)) {
            continue
        }

        if ($Exclusions.Contains($groupId)) {
            continue
        }

        $violations += @{
            severity    = "Medium"
            workload    = "pim-groups"
            entity      = $result.slug
            fileType    = "group-coverage"
            changeType  = "unclassified"
            context     = $result.definition.displayName
            description = "Unclassified PIM group: '$($result.definition.displayName)' (ID: $groupId) is not in any group definition."
            isAlert     = $true
            old         = $null
            new         = "Needs classification in a group access model file"
        }
    }

    return @($violations)
}

<#
.SYNOPSIS
    Verifies that each auth context in inventory is backed by a correctly configured CA policy.

.PARAMETER CaPolicies
    Array of CA policy objects fetched from Graph (already filtered to policies that target at
    least one auth context claim). Pass an empty array when Policy.Read.All is not granted;
    the function will emit "no policy found" violations for every auth context with a config.json.

.PARAMETER InventoryPath
    Path to the inventory root. The function reads:
      authentication-contexts/{slug}/definition.json  — Graph API response; contains claimValue (id)
      authentication-contexts/{slug}/config.json      — operator-defined expected controls (never
                                                        written by the scan pipeline)

.RETURNS
    Array of High-severity change-entry objects, one per failing check per auth context.
    Empty array if no auth contexts have a config.json.

#>
function Get-AuthContextPolicyCompliance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array] $CaPolicies,

        [Parameter(Mandatory)]
        [string] $InventoryPath
    )

    $violations = @()

    # Build claimValue -> [policies] lookup from the supplied CA policy array.
    $claimToPolicies = @{}
    foreach ($caPolicy in $CaPolicies) {
        $conds = $caPolicy.PSObject.Properties['conditions']?.Value
        $apps  = if ($conds)  { $conds.PSObject.Properties['applications']?.Value } else { $null }
        $refs  = if ($apps)   { $apps.PSObject.Properties['includeAuthenticationContextClassReferences']?.Value } else { $null }
        if (-not $refs) { continue }
        foreach ($claimValue in $refs) {
            if (-not $claimToPolicies.ContainsKey($claimValue)) {
                $claimToPolicies[$claimValue] = [System.Collections.Generic.List[object]]::new()
            }
            $claimToPolicies[$claimValue].Add($caPolicy)
        }
    }

    $authContextsPath = Join-Path -Path $InventoryPath -ChildPath "authentication-contexts"
    if (-not (Test-Path $authContextsPath -PathType Container)) {
        Write-Verbose "No authentication-contexts inventory found; skipping CA policy compliance."
        return @($violations)
    }

    foreach ($dir in Get-ChildItem -Path $authContextsPath -Directory) {
        $slug       = $dir.Name
        $configFile = Join-Path -Path $dir.FullName -ChildPath "config.json"
        $defFile    = Join-Path -Path $dir.FullName -ChildPath "definition.json"

        if (-not (Test-Path $configFile)) {
            Write-Verbose "Auth context '$slug' has no config.json; skipping CA policy compliance."
            continue
        }

        try {
            if (-not (Test-Path $defFile)) {
                Write-Warning "Auth context '$slug' has config.json but no definition.json; skipping."
                continue
            }

            $def        = Get-Content -Path $defFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json
            $claimValue = $def.PSObject.Properties['id']?.Value
            if (-not $claimValue) {
                Write-Warning "Auth context '$slug' definition.json has no 'id' field; skipping."
                continue
            }

            $config = Get-Content -Path $configFile -Raw -Encoding utf8NoBOM | ConvertFrom-Json

            $matchedPolicies = @()
            if ($claimToPolicies.ContainsKey($claimValue)) {
                $matchedPolicies = @($claimToPolicies[$claimValue])
            }

            if ($matchedPolicies.Count -eq 0) {
                $violations += @{
                    severity    = "High"
                    changeType  = "non-compliant"
                    workload    = "conditional-access"
                    entity      = $slug
                    fileType    = "auth-context-policy-compliance"
                    ruleId      = "policyExists"
                    context     = "$slug (claim: $claimValue)"
                    description = "CA policy compliance: no CA policy found that enforces auth context '$slug' (claim: $claimValue)"
                    isAlert     = $true
                    old         = $null
                    new         = "A CA policy targeting claim '$claimValue' with required controls"
                }
                continue
            }

            # At least one policy must satisfy ALL requirements. Collect per-field failures across
            # all matched policies; only emit a violation if NO policy passes that field.
            [string[]]$configFields = @($config | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)

            foreach ($fieldName in $configFields) {
                $expectedValue = $config.$fieldName
                $checkDef = $script:CaPolicyConfigToCheck | Where-Object { $_.field -eq $fieldName } | Select-Object -First 1

                if (-not $checkDef) {
                    Write-Warning "Unknown config.json field '$fieldName' for auth context '$slug'; skipping."
                    continue
                }

                $anyPolicyPasses = $false
                $lastActualValue = $null

                foreach ($caPolicy in $matchedPolicies) {
                    $result          = & $checkDef.evaluate $caPolicy $expectedValue
                    $lastActualValue = $result.actual
                    if ($result.passes) { $anyPolicyPasses = $true; break }
                }

                if (-not $anyPolicyPasses) {
                    $policyNames = ($matchedPolicies | ForEach-Object { $_.PSObject.Properties['displayName']?.Value }) -join ', '
                    $violations += @{
                        severity    = "High"
                        changeType  = "non-compliant"
                        workload    = "conditional-access"
                        entity      = $slug
                        fileType    = "auth-context-policy-compliance"
                        ruleId      = $fieldName
                        context     = "$slug (claim: $claimValue)"
                        description = "CA policy compliance: auth context '$slug' — '$fieldName' check failed on: $policyNames"
                        isAlert     = $true
                        old         = $lastActualValue
                        new         = $expectedValue
                    }
                }
            }
        }
        catch {
            Write-Warning "Error checking CA policy compliance for auth context '$slug': $_"
        }
    }

    return @($violations)
}
