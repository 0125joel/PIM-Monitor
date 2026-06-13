<#
.SYNOPSIS
    Main PIM Monitor scan script for Azure DevOps Pipeline.

.DESCRIPTION
    Fetches current PIM state from Graph API, diffs against inventory files,
    updates inventory, and prepares notifications.

    Runs via AzurePowerShell@5 task with WIF authentication.
    Expects: NOTIFICATION_EMAIL, NOTIFICATION_MAIL_FROM, NOTIFICATION_WEBHOOK_URL (all optional)

    Flow:
    1. Authenticate via WIF (Get-AzAccessToken)
    2. Fetch lookups (authentication contexts, administrative units)
    3. Fetch Directory Roles (definition, policy, assignments per role)
    4. (Phase 2) Fetch PIM Groups
    5. Diff against previous inventory → classify changes by severity
    6. Write inventory files (deterministic JSON)
    7. (Phase 2) Send notifications

.EXAMPLE
    ./Scan-PimState.ps1
#>

#Requires -Version 7.0

param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "helpers.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "graphEndpoints.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "diff.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "git.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-shared.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-email.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-webhook-teams.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-webhook-slack.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-webhook-discord.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-webhook.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-html.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-error.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "compliance.ps1")

Write-StepLog "PIM Monitor scan starting"

$inventoryRoot = Join-Path -Path (Get-Location) -ChildPath "inventory"
if (-not (Test-Path $inventoryRoot)) {
    New-Item -ItemType Directory -Path $inventoryRoot -Force | Out-Null
}

$allChanges = @()
$scanErrors = [System.Collections.Generic.List[hashtable]]::new()

$expectedChangesPath = Join-Path -Path (Get-Location) -ChildPath "expected-changes.json"
$expectations = @()
if (Test-Path $expectedChangesPath) {
    try {
        $expectedContent = Get-Content -Path $expectedChangesPath -Raw -Encoding utf8 | ConvertFrom-Json
        $expectations = @($expectedContent.expected)
        Write-Host "Loaded $($expectations.Count) expected changes"
    }
    catch {
        Write-Warning "Failed to load expected-changes.json: $_"
    }
}

Write-StepLog "Acquiring Graph API access token"

$token = Get-GraphAccessTokenString
if (-not $token) {
    throw "Failed to acquire Graph API access token"
}

$tenantDisplayName = try {
    $orgResponse = Invoke-GraphRequest -Uri $script:GraphEndpoints.Organization -Headers @{ Authorization = "Bearer $token" }
    $orgResponse.PSObject.Properties['value']?.Value[0].PSObject.Properties['displayName']?.Value
}
catch { $null }

Write-StepLog "Fetching authentication contexts"

$authContextLookup = @{}
try {
    $authContexts = @(Get-AllGraphItems -Uri $script:GraphEndpoints.AuthenticationContexts -AccessToken $token)
    Write-Host "  Found $($authContexts.Count) authentication contexts"

    $authContextSlugs = @()

    foreach ($authContext in $authContexts) {
        $slug = Get-InventorySlug -Name $authContext.displayName
        $authContextSlugs += $slug

        $folderPath = New-InventoryFolder -Workload "authentication-contexts" -Slug $slug

        $changes = Compare-InventoryFolder `
            -FolderPath $folderPath `
            -NewData @{ definition = $authContext } `
            -EntityName $authContext.displayName

        $allChanges += $changes

        Save-InventoryFile -InputObject $authContext -FolderPath $folderPath -FileName "definition.json"
    }

    foreach ($ac in $authContexts) {
        $acId   = $ac.PSObject.Properties['id']?.Value
        $acName = $ac.PSObject.Properties['displayName']?.Value
        if ($acId -and $acName) { $authContextLookup[$acId] = $acName }
    }

    $authContextWorkloadPath = Join-Path $inventoryRoot "authentication-contexts"
    if (Test-SafeToArchive -DiscoveredCount $authContexts.Count -WorkloadPath $authContextWorkloadPath) {
        $removedAuthContexts = Get-RemovedEntities `
            -WorkloadPath $authContextWorkloadPath `
            -CurrentSlugs $authContextSlugs
        $allChanges += $removedAuthContexts
        foreach ($r in $removedAuthContexts) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
    }
    else {
        $scanErrors.Add(@{ Component = 'Authentication Contexts discovery'; Error = "Discovery returned 0 entities while inventory still contains folders; skipped archival to prevent mass false-removal." })
    }
}
catch {
    Write-Warning "Authentication contexts scan failed: $_"
    $scanErrors.Add(@{ Component = 'Authentication Contexts'; Error = $_.ToString() })
}

Write-StepLog "Fetching Conditional Access policies for authentication contexts"

$caPolicies = @()
try {
    $allCaPolicies = @(Get-AllGraphItems -Uri $script:GraphEndpoints.ConditionalAccessPolicies -AccessToken $token)

    # Only store policies that reference at least one auth context claim — all others are out of scope.
    $caPolicies = @($allCaPolicies | Where-Object {
        $conds = $_.PSObject.Properties['conditions']?.Value
        $apps  = if ($conds) { $conds.PSObject.Properties['applications']?.Value } else { $null }
        $refs  = if ($apps)  { $apps.PSObject.Properties['includeAuthenticationContextClassReferences']?.Value } else { $null }
        $refs -and @($refs).Count -gt 0
    })

    Write-Host "  Found $($caPolicies.Count) CA policies targeting authentication contexts (of $($allCaPolicies.Count) total)"

    $caPolicySlugs = @()
    foreach ($caPolicy in $caPolicies) {
        $slug = Get-InventorySlug -Name $caPolicy.displayName
        $caPolicySlugs += $slug

        $folderPath = New-InventoryFolder -Workload "conditional-access" -Slug $slug

        $changes = Compare-InventoryFolder `
            -FolderPath $folderPath `
            -NewData @{ definition = $caPolicy } `
            -EntityName $caPolicy.displayName

        $allChanges += $changes

        Save-InventoryFile -InputObject $caPolicy -FolderPath $folderPath -FileName "definition.json"
    }

    # Guard uses the raw fetch count ($allCaPolicies), not the auth-context-filtered subset: a tenant
    # legitimately having no auth-context-targeting policies must still archive stale folders.
    $caWorkloadPath = Join-Path $inventoryRoot "conditional-access"
    if (Test-SafeToArchive -DiscoveredCount $allCaPolicies.Count -WorkloadPath $caWorkloadPath) {
        $removedCaPolicies = Get-RemovedEntities `
            -WorkloadPath $caWorkloadPath `
            -CurrentSlugs $caPolicySlugs
        $allChanges += $removedCaPolicies
        foreach ($r in $removedCaPolicies) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
    }
    else {
        $scanErrors.Add(@{ Component = 'Conditional Access discovery'; Error = "Discovery returned 0 entities while inventory still contains folders; skipped archival to prevent mass false-removal." })
    }
}
catch {
    if ($_ -match 'Policy\.Read' -or $_ -match 'Authorization_RequestDenied' -or $_ -match 'AccessDenied' -or $_ -match 'required scopes') {
        Write-Warning "Conditional Access policies skipped: Policy.Read.All permission not granted on App Registration."
    }
    else {
        Write-Warning "Conditional Access policies scan failed: $_"
        $scanErrors.Add(@{ Component = 'Conditional Access Policies'; Error = $_.ToString() })
    }
}

Write-StepLog "Fetching administrative units"

try {
    $adminUnits = @(Get-AllGraphItems -Uri $script:GraphEndpoints.AdministrativeUnits -AccessToken $token)
    Write-Host "  Found $($adminUnits.Count) administrative units"

    $adminUnitSlugs = @()

    foreach ($adminUnit in $adminUnits) {
        $slug = Get-InventorySlug -Name $adminUnit.displayName
        $adminUnitSlugs += $slug

        $folderPath = New-InventoryFolder -Workload "administrative-units" -Slug $slug

        $changes = Compare-InventoryFolder `
            -FolderPath $folderPath `
            -NewData @{ definition = $adminUnit } `
            -EntityName $adminUnit.displayName

        $allChanges += $changes

        Save-InventoryFile -InputObject $adminUnit -FolderPath $folderPath -FileName "definition.json"
    }

    $adminUnitWorkloadPath = Join-Path $inventoryRoot "administrative-units"
    if (Test-SafeToArchive -DiscoveredCount $adminUnits.Count -WorkloadPath $adminUnitWorkloadPath) {
        $removedAdminUnits = Get-RemovedEntities `
            -WorkloadPath $adminUnitWorkloadPath `
            -CurrentSlugs $adminUnitSlugs
        $allChanges += $removedAdminUnits
        foreach ($r in $removedAdminUnits) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
    }
    else {
        $scanErrors.Add(@{ Component = 'Administrative Units discovery'; Error = "Discovery returned 0 entities while inventory still contains folders; skipped archival to prevent mass false-removal." })
    }
}
catch {
    Write-Warning "Administrative units scan failed: $_"
    $scanErrors.Add(@{ Component = 'Administrative Units'; Error = $_.ToString() })
}

Write-StepLog "Fetching PIM activation events"

try {
    $eventsRoot = Join-Path -Path $inventoryRoot -ChildPath "activation-events"
    if (-not (Test-Path $eventsRoot)) {
        New-Item -ItemType Directory -Path $eventsRoot -Force | Out-Null
    }

    $currentYearMonth = (Get-Date -AsUTC).ToString("yyyy-MM")
    $currentMonthFile = Join-Path -Path $eventsRoot -ChildPath "$currentYearMonth.json"

    $fetchSince = (Get-Date -AsUTC).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Derive fetchSince from the current AND previous month files. On the first scan of a
    # new month the current file does not exist yet; falling back to now-30d would re-fetch
    # the previous month's events and duplicate them into the new file.
    $previousYearMonth = (Get-Date -AsUTC).AddMonths(-1).ToString("yyyy-MM")
    $previousMonthFile = Join-Path -Path $eventsRoot -ChildPath "$previousYearMonth.json"

    $lastKnownEventTime = $null
    foreach ($monthFile in @($currentMonthFile, $previousMonthFile)) {
        if (-not (Test-Path $monthFile)) { continue }
        try {
            $existingEvents = Get-Content -Path $monthFile -Raw -Encoding utf8 | ConvertFrom-Json
            if ($existingEvents -and @($existingEvents).Count -gt 0) {
                $lastEvent = $existingEvents | Sort-Object { [datetime]$_.activityDateTime } | Select-Object -Last 1
                $lastEventTimeRaw = if ($lastEvent) { $lastEvent.PSObject.Properties['activityDateTime']?.Value } else { $null }
                if ($lastEventTimeRaw) {
                    $lastTime = [datetime]::Parse(
                        $lastEventTimeRaw,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                    if ($null -eq $lastKnownEventTime -or $lastTime -gt $lastKnownEventTime) {
                        $lastKnownEventTime = $lastTime
                    }
                }
            }
        }
        catch {
            Write-Warning "Could not parse existing events ($monthFile): $_"
            $scanErrors.Add(@{ Component = 'Activation Events (monthly file parse)'; Error = $_.ToString() })
        }
    }
    if ($lastKnownEventTime) {
        $fetchSince = $lastKnownEventTime.AddSeconds(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    $auditUri = Get-AuditLogsPimUri -Since $fetchSince
    $auditEvents = @(Get-AllGraphItems -Uri $auditUri -AccessToken $token)

    Write-Host "  Found $($auditEvents.Count) events since $fetchSince"

    if ($auditEvents.Count -gt 0) {
        $monthlyEvents = @()
        if (Test-Path $currentMonthFile) {
            try {
                $monthlyEvents = @(Get-Content -Path $currentMonthFile -Raw -Encoding utf8 | ConvertFrom-Json)
            }
            catch {
                $monthlyEvents = @()
            }
        }

        $eventIds = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($monthlyEvents | ForEach-Object { $_.id }),
            [System.StringComparer]::Ordinal
        )

        $newEventCount = 0
        foreach ($auditEntry in $auditEvents) {
            if (-not $eventIds.Contains($auditEntry.id)) {
                $monthlyEvents += $auditEntry
                $newEventCount++
            }
        }

        $monthlyEvents = @($monthlyEvents | Sort-Object { [datetime]$_.activityDateTime })

        Save-InventoryFile -InputObject $monthlyEvents -FolderPath $eventsRoot -FileName "$currentYearMonth.json"

        if ($newEventCount -gt 0) {
            Write-Host "  Saved $newEventCount new events ($($monthlyEvents.Count) total) to $currentYearMonth.json"
        }
        else {
            Write-Host "  No new events to save; $($monthlyEvents.Count) total in $currentYearMonth.json"
        }
    }
}
catch {
    if ($_ -match 'AuditLog.Read.All' -or $_ -match 'Authentication_MSGraphPermissionMissing') {
        Write-Warning "Activation events skipped: AuditLog.Read.All permission not granted on App Registration."
    }
    else {
        Write-Warning "Activation events fetch failed: $_"
        $scanErrors.Add(@{ Component = 'Activation Events'; Error = $_.ToString() })
    }
}

Write-StepLog "Fetching Directory Roles"

$roleResults = @()

try {
    $roleDefinitions = @(Get-AllGraphItems -Uri $script:GraphEndpoints.RoleDefinitions -AccessToken $token)
    Write-Host "  Found $($roleDefinitions.Count) role definitions"

    $roleSlugs = @()

    # Functions are not available inside -Parallel; serialize to string so they can cross the
    # runspace boundary via $using:.
    $slugFnStr           = ${function:Get-InventorySlug}.ToString()
    $invokeWithRetryFnStr = ${function:Invoke-WithRetry}.ToString()
    $invokeGraphFnStr    = ${function:Invoke-GraphRequest}.ToString()

    # URI builder functions are also unavailable inside -Parallel, so build the map here.
    $roleUriMap = @{}
    foreach ($role in $roleDefinitions) {
        $roleUriMap[$role.id] = @{
            policy    = Get-RolePolicyUri                -RoleId $role.id
            permanent = Get-RolePermanentAssignmentsUri  -RoleId $role.id
            eligible  = Get-RoleEligibleAssignmentsUri   -RoleId $role.id
            active    = Get-RoleActiveAssignmentsUri     -RoleId $role.id
        }
    }

    $roleResults = @($roleDefinitions | ForEach-Object -Parallel {
            $role = $_
            $roleId = $role.id
            $roleDisplayName = $role.displayName

            $slugName = & ([scriptblock]::Create($using:slugFnStr)) -Name $roleDisplayName

            Write-Host "  Processing: $roleDisplayName ($slugName)"

            try {
                $uris = ($using:roleUriMap)[$roleId]
                $headers = @{ Authorization = "Bearer $($using:token)" }

                ${function:Invoke-WithRetry} = [scriptblock]::Create($using:invokeWithRetryFnStr)
                $invokeGraphRequest = [scriptblock]::Create($using:invokeGraphFnStr)

                # known-debt: pagination inline for runspace isolation — Get-AllGraphItems cannot be
                # serialized here without pulling in its full dependency chain across the runspace boundary.
                $policyItems = @()
                $currentUri = $uris.policy
                while ($currentUri) {
                    $response = & $invokeGraphRequest -Uri $currentUri -Headers $headers
                    $v = $response.PSObject.Properties['value']?.Value
                    if ($v) { $policyItems += $v }
                    $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
                }
                $policyAssignment = $policyItems | Select-Object -First 1

                if (-not $policyAssignment) {
                    Write-Warning "    No policy assignment found for role: $roleDisplayName"
                }

                $permUri = $uris.permanent
                $eligUri = $uris.eligible
                $actUri = $uris.active

                $fetchAssignments = {
                    param($uri)
                    $items = @()
                    $currentUri = $uri
                    while ($currentUri) {
                        $response = & $invokeGraphRequest -Uri $currentUri -Headers $headers
                        $v = $response.PSObject.Properties['value']?.Value
                        if ($v) { $items += $v }
                        $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
                    }
                    return $items
                }

                $permanent = (& $fetchAssignments $permUri) ?? @()
                $eligible = (& $fetchAssignments $eligUri) ?? @()
                $active = (& $fetchAssignments $actUri) ?? @()

                $assignments = @{
                    permanent = $permanent
                    eligible  = $eligible
                    active    = $active
                }

                Write-Host "    Permanent: $($permanent.Count) | Eligible: $($eligible.Count) | Active: $($active.Count)"

                @{
                    definition       = $role
                    slug             = $slugName
                    policyAssignment = $policyAssignment
                    assignments      = $assignments
                    error            = $null
                }
            }
            catch {
                Write-Warning "    Failed to fetch data for role $roleDisplayName — $_"
                @{
                    definition = $role
                    slug       = $slugName
                    error      = $_.ToString()
                }
            }
        } -ThrottleLimit 5)  # tuned from 8 to 5 to reduce sustained Graph 429s; see ADR-010

    foreach ($result in $roleResults) {
        $roleSlugs += $result.slug

        if ($result.error) {
            $scanErrors.Add(@{ Component = "Directory Role: $($result.definition.displayName)"; Error = $result.error })
            continue
        }

        $folderPath = New-InventoryFolder -Workload "directory-roles" -Slug $result.slug

        # Normalize before diff and write: strips heartbeat fields (scheduleInfo.startDateTime)
        # that Microsoft updates every ~30 min without any user action.
        $cleanAssignments = Remove-AssignmentNoise -Assignments $result.assignments
        $result.cleanAssignments = $cleanAssignments

        $newData = @{
            definition  = $result.definition
            assignments = $cleanAssignments
        }
        if ($result.policyAssignment) {
            $newData.policy = $result.policyAssignment
        }

        $changes = Compare-InventoryFolder `
            -FolderPath $folderPath `
            -NewData $newData `
            -EntityName $result.definition.displayName

        $allChanges += $changes

        # Write inventory files
        Save-InventoryFile -InputObject $result.definition -FolderPath $folderPath -FileName "definition.json"
        if ($result.policyAssignment) {
            Save-InventoryFile -InputObject $result.policyAssignment -FolderPath $folderPath -FileName "policy.json"
        }
        Save-InventoryFile -InputObject $cleanAssignments -FolderPath $folderPath -FileName "assignments.json"
    }

    # Detect roles removed from PIM (folder exists but not in current fetch)
    $roleWorkloadPath = Join-Path $inventoryRoot "directory-roles"
    if (Test-SafeToArchive -DiscoveredCount $roleDefinitions.Count -WorkloadPath $roleWorkloadPath) {
        $removedRoles = Get-RemovedEntities `
            -WorkloadPath $roleWorkloadPath `
            -CurrentSlugs $roleSlugs
        $allChanges += $removedRoles
        foreach ($r in $removedRoles) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
    }
    else {
        $scanErrors.Add(@{ Component = 'Directory Roles discovery'; Error = "Discovery returned 0 entities while inventory still contains folders; skipped archival to prevent mass false-removal." })
    }

    Write-StepLog "Directory Roles scan complete"
}
catch {
    Write-Warning "Directory Roles scan failed: $_"
    $scanErrors.Add(@{ Component = 'Directory Roles'; Error = $_.ToString() })
}

# PIM Groups

Write-StepLog "Fetching PIM Groups"

$groupResults = @()   # initialised here so Access-Model Compliance can safely iterate if PIM Groups fails
$groupAssignmentsByEntity = @{}   # initialised here so Expiring Assignments can safely iterate if PIM Groups fails

try {
    # Discover PIM-onboarded groups via the group/resources endpoint. This is the only available
    # discovery surface: the schedule-instance and roleManagementPolicyAssignment endpoints all
    # require a groupId/scopeId filter, and there is no tenant-wide "list all PIM groups" API.
    # The endpoint is beta and undocumented for discovery, so an empty/changed response is possible;
    # Test-SafeToArchive (below) prevents that from mass-archiving the workload.
    $pimGroupResources = @(Get-AllGraphItems -Uri $script:GraphEndpoints.GroupResources -AccessToken $token)
    $groupIds = @($pimGroupResources | ForEach-Object { $_.id } | Where-Object { $_ })

    Write-Host "  Found $($groupIds.Count) PIM-onboarded groups"

    $groupSlugs = @()
    $groupAssignmentsByEntity = @{}
    $groupHeaders = @{ Authorization = "Bearer $token" }

    foreach ($groupId in $groupIds) {
        $groupDisplayName = $null
        $groupDef = $null
        $slug = $null
        try {
            # Fetch group definition first so slug is available for archiving protection
            $groupDef = Invoke-GraphRequest -Uri (Get-GroupDefinitionUri -GroupId $groupId) `
                -Headers $groupHeaders

            $groupDisplayName = $groupDef.displayName
            $slug = Get-InventorySlug -Name $groupDisplayName

            # Track slug immediately — prevents false-positive archiving if later fetches fail
            $groupSlugs += $slug

            Write-Host "  Processing: $groupDisplayName ($slug)"

            $folderPath = New-InventoryFolder -Workload "pim-groups" -Slug $slug

            # Fetch per-group eligible and active instances (filtered by groupId)
            $groupEligible = @(Get-AllGraphItems -Uri (Get-GroupEligibleAssignmentsUri -GroupId $groupId) -AccessToken $token)
            $groupActive = @(Get-AllGraphItems -Uri (Get-GroupActiveAssignmentsUri   -GroupId $groupId) -AccessToken $token)

            # Fetch policies for this group — returns both member and owner policy assignments
            $policyItems = @(Get-AllGraphItems -Uri (Get-GroupPolicyUri -GroupId $groupId) -AccessToken $token)

            # Split into member/owner wrapper (roleDefinitionId = "member" or "owner")
            $policyWrapper = @{}
            foreach ($pa in $policyItems) {
                $accessId = $pa.roleDefinitionId
                if ($accessId -in @('member', 'owner')) {
                    $policyWrapper[$accessId] = $pa
                }
            }

            $assignments = @{
                eligible = $groupEligible
                active   = $groupActive
            }

            Write-Host "    Eligible: $($groupEligible.Count) | Active: $($groupActive.Count) | Policies: $($policyWrapper.Count)"

            $cleanAssignments = Remove-AssignmentNoise -Assignments $assignments
            $groupAssignmentsByEntity[$slug] = $cleanAssignments

            $newData = @{
                definition  = $groupDef
                assignments = $cleanAssignments
            }
            if ($policyWrapper.Count -gt 0) {
                $newData.policy = $policyWrapper
            }

            $changes = Compare-InventoryFolder `
                -FolderPath $folderPath `
                -NewData $newData `
                -EntityName $groupDisplayName

            $allChanges += $changes

            Save-InventoryFile -InputObject $groupDef -FolderPath $folderPath -FileName "definition.json"
            if ($policyWrapper.Count -gt 0) {
                Save-InventoryFile -InputObject $policyWrapper -FolderPath $folderPath -FileName "policy.json"
            }
            Save-InventoryFile -InputObject $cleanAssignments -FolderPath $folderPath -FileName "assignments.json"

            $groupResults += @{
                definition       = $groupDef
                slug             = $slug
                policyAssignment = $policyWrapper
                error            = $null
            }
        }
        catch {
            $errorText = $_.ToString()
            $componentName = if ($groupDisplayName) { "PIM Group: $groupDisplayName" } else { "PIM Group: $groupId" }
            Write-Warning "  Failed to process $componentName — $errorText"
            $scanErrors.Add(@{ Component = $componentName; Error = $errorText })
            if (-not $slug) {
                # The definition fetch failed before the slug was known. Recover it from the
                # existing inventory by object id, otherwise Get-RemovedEntities would treat a
                # transient per-group failure as "removed from PIM" and archive the folder.
                $slug = Find-InventorySlugById -WorkloadPath (Join-Path $inventoryRoot "pim-groups") -EntityId $groupId
                if ($slug) { $groupSlugs += $slug }
            }
            if ($slug) {
                $groupResults += @{
                    definition = $groupDef
                    slug       = $slug
                    error      = $errorText
                }
            }
        }
    }

    # Detect groups removed from PIM (folder exists but not in current resources list)
    # Critical guard: group discovery uses a beta endpoint (group/resources) that is not documented
    # as a discovery surface and can return empty without throwing. Without this, an empty result
    # would archive every PIM group as "removed" and fire a High-severity false-removal cascade.
    $groupWorkloadPath = Join-Path $inventoryRoot "pim-groups"
    if (Test-SafeToArchive -DiscoveredCount $groupIds.Count -WorkloadPath $groupWorkloadPath) {
        $removedGroups = Get-RemovedEntities `
            -WorkloadPath $groupWorkloadPath `
            -CurrentSlugs $groupSlugs
        $allChanges += $removedGroups
        foreach ($r in $removedGroups) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
    }
    else {
        $scanErrors.Add(@{ Component = 'PIM Groups discovery'; Error = "Discovery returned 0 entities while inventory still contains group folders; skipped archival to prevent mass false-removal." })
    }

    Write-StepLog "PIM Groups scan complete"
}
catch {
    Write-Warning "PIM Groups scan failed: $_"
    $scanErrors.Add(@{ Component = 'PIM Groups'; Error = $_.ToString() })
}

# Expiring Assignments Detection

Write-StepLog "Checking for expiring assignments"

try {
    # One call per workload so the change entries carry the correct workload key
    # (also avoids slug collisions between a role and a group in a merged lookup).
    $roleAssignmentsByEntity = @{}
    foreach ($result in $roleResults) {
        if ($result.error) { continue }
        $roleAssignmentsByEntity[$result.slug] = $result.cleanAssignments
    }

    $parsed = 0
    $windowDays = if ([int]::TryParse($env:EXPIRING_WINDOW_DAYS, [ref]$parsed)) { $parsed } else { 14 }
    $expiringChanges  = @(Find-ExpiringAssignments -Assignments $roleAssignmentsByEntity  -WindowDays $windowDays -Workload 'directory-roles')
    $expiringChanges += @(Find-ExpiringAssignments -Assignments $groupAssignmentsByEntity -WindowDays $windowDays -Workload 'pim-groups')

    if ($expiringChanges.Count -gt 0) {
        Write-Host "  Found $($expiringChanges.Count) expiring assignments within $windowDays days"
        $allChanges += $expiringChanges
    }
    else {
        Write-Host "  No expiring assignments detected"
    }
}
catch {
    Write-Warning "Expiring assignments check failed: $_"
    $scanErrors.Add(@{ Component = 'Expiring Assignments'; Error = $_.ToString() })
}

# Access Model Compliance Detection

$classificationPath = Join-Path -Path (Get-Location) -ChildPath "AccessModel"
$authContextMap = Get-AuthContextMap -InventoryPath (Join-Path -Path (Get-Location) -ChildPath "inventory")

if (Test-Path $classificationPath) {
    Write-StepLog "Checking access-model compliance"
    try {
        $tierDefs = @(Get-TierDefinitions -TiersPath $classificationPath)
        $exclusions = Get-CoverageExclusions -TiersPath $classificationPath
        $coverageScope = if ($env:EAM_COVERAGE_SCOPE) { $env:EAM_COVERAGE_SCOPE } else { "privileged" }

        $complianceChanges = @(Get-ComplianceViolations -TierDefinitions $tierDefs -RoleResults $roleResults -AuthContextMap $authContextMap)
        $coverageChanges = @(Get-CoverageViolations  -TierDefinitions $tierDefs -RoleResults $roleResults -Exclusions $exclusions -Scope $coverageScope)

        Write-Host "  Compliance violations: $($complianceChanges.Count)"
        Write-Host "  Unclassified roles:    $($coverageChanges.Count)"
        $allChanges += $complianceChanges + $coverageChanges
    }
    catch {
        Write-Warning "Access-model compliance check failed: $_"
        $scanErrors.Add(@{ Component = 'Access-Model Compliance'; Error = $_.ToString() })
    }

    # Auth Context CA Policy Compliance — only runs when the AccessModel folder is present,
    # because it is part of the access model feature set.
    Write-StepLog "Checking auth context CA policy compliance"
    try {
        $authCtxComplianceChanges = @(Get-AuthContextPolicyCompliance -CaPolicies $caPolicies -InventoryPath $inventoryRoot)
        Write-Host "  Auth context CA policy violations: $($authCtxComplianceChanges.Count)"
        $allChanges += $authCtxComplianceChanges
    }
    catch {
        Write-Warning "Auth context CA policy compliance check failed: $_"
        $scanErrors.Add(@{ Component = 'Auth Context CA Policy Compliance'; Error = $_.ToString() })
    }
}

# Access Model Compliance Detection - PIM Groups

$groupClassificationPath = Join-Path -Path (Get-Location) -ChildPath "AccessModel/pim-groups"

if (Test-Path $groupClassificationPath) {
    Write-StepLog "Checking PIM group access-model compliance"
    try {
        $groupDefs = @(Get-GroupDefinitions -Path $groupClassificationPath)
        $groupExclusions = Get-GroupCoverageExclusions -Path $groupClassificationPath

        $groupComplianceChanges = @(Get-GroupComplianceViolations -GroupDefinitions $groupDefs -GroupResults $groupResults -AuthContextMap $authContextMap)
        $groupCoverageChanges = @(Get-GroupCoverageViolations   -GroupDefinitions $groupDefs -GroupResults $groupResults -Exclusions $groupExclusions)

        Write-Host "  Group compliance violations: $($groupComplianceChanges.Count)"
        Write-Host "  Unclassified groups:         $($groupCoverageChanges.Count)"
        $allChanges += $groupComplianceChanges + $groupCoverageChanges
    }
    catch {
        Write-Warning "PIM group access-model compliance check failed: $_"
        $scanErrors.Add(@{ Component = 'PIM Groups Access-Model Compliance'; Error = $_.ToString() })
    }
}

# Filter Expected Changes

if ($expectations.Count -gt 0) {
    Write-StepLog "Filtering expected changes"

    $suppressedChanges = @()
    $filteredChanges = @()

    foreach ($change in $allChanges) {
        if (Test-ChangeIsExpected -Change $change -Expectations $expectations) {
            Write-Host "  Suppressed: $($change.description)"
            $suppressedChanges += $change
        }
        else {
            $filteredChanges += $change
        }
    }

    $allChanges = $filteredChanges
    Write-Host "  Suppressed $($suppressedChanges.Count) expected change(s)"

    # Clean up expected-changes.json: remove expired entries. Matched (suppressing) entries
    # are intentionally kept until their expiresUtc so they keep suppressing on every scan.
    $remainingExpectations = @()
    $nowUtc = Get-Date -AsUTC

    foreach ($expectation in $expectations) {
        # Check if expired
        if ($expectation.expiresUtc) {
            try {
                $expiryTime = [datetime]::Parse($expectation.expiresUtc, [System.Globalization.CultureInfo]::InvariantCulture)
                if ($nowUtc -gt $expiryTime) {
                    continue
                }
            }
            catch {
                # Keep on parse error
            }
        }

        $remainingExpectations += $expectation
    }

    if ($remainingExpectations.Count -eq 0) {
        # Delete the file if nothing remains
        Remove-Item -Path $expectedChangesPath -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleaned up expected-changes.json"
    }
    else {
        # Rewrite with remaining expectations
        $updatedFile = ConvertTo-DeterministicJson -InputObject @{ expected = $remainingExpectations }
        Set-Content -Path $expectedChangesPath -Value $updatedFile -Encoding utf8NoBOM -Force
        Write-Host "  Updated expected-changes.json with $($remainingExpectations.Count) remaining"
    }
}

# Summarize Changes

$changesBySeverity = Group-ChangesBySeverity -Changes $allChanges

Write-StepLog "Scan summary:"
Write-Host "  Total changes: $($changesBySeverity.Total)"
Write-Host "  High:   $($changesBySeverity.High.Count)"
Write-Host "  Medium: $($changesBySeverity.Medium.Count)"
Write-Host "  Low:    $($changesBySeverity.Low.Count)"

if ($changesBySeverity.High.Count -gt 0) {
    Write-Host ""
    Write-Host "High-severity changes:"
    foreach ($change in $changesBySeverity.High) {
        Write-Host "  - $($change.description)"
    }
}

# Publish Inventory Changes

# Always attempt to publish, regardless of the notification change count: activation events,
# fully suppressed changes, and the expected-changes.json cleanup all modify the working tree
# without contributing to $changesBySeverity.Total. Skipping the commit on those scans would
# drop them from the audit trail (activation events age out of the Graph audit log after 30
# days). Publish-InventoryChanges itself commits only when the staged diff is non-empty.
$publishResult = $null
Write-StepLog "Publishing inventory changes"
# A failed commit/push must not abort the script: the notification steps below are the
# only signal the operator gets, and they matter most on exactly the runs that detected
# changes. Notifications proceed without a commit SHA (no diff links).
try {
    $publishResult = Publish-InventoryChanges
}
catch {
    Write-Warning "Publishing inventory changes failed: $_"
    $scanErrors.Add(@{ Component = 'Publish Inventory Changes'; Error = $_.ToString() })
}

# HTML Report Artifact (optional — enabled by REPORT_ARTIFACT=true)

if ($env:REPORT_ARTIFACT -eq 'true') {
    $stagingDir = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
    if (-not $stagingDir) {
        Write-Warning "REPORT_ARTIFACT is set but BUILD_ARTIFACTSTAGINGDIRECTORY is not — skipping report export"
    }
    elseif ($changesBySeverity.Total -eq 0) {
        Write-StepLog "No changes detected — skipping report artifact"
    }
    else {
        Write-StepLog "Writing HTML scan report"
        $reportPath = Join-Path $stagingDir "scan-report.html"
        $reportTenantId = try { (Get-AzContext).Tenant.Id } catch { $null }
        $reportCommitSha = if ($publishResult -and $publishResult.committed) { $publishResult.commitSha } else { $null }
        Export-ScanReport `
            -ChangesBySeverity $changesBySeverity `
            -OutputPath $reportPath `
            -TenantId $reportTenantId `
            -TenantName $tenantDisplayName `
            -CommitSha $reportCommitSha `
            -AuthContextLookup $authContextLookup
    }
}

# Notifications (after commit so we have SHA for diff links)

if ($changesBySeverity.Total -gt 0) {
    $minSeverity = Get-PipelineEnvVar -Name 'NOTIFICATION_MIN_SEVERITY'
    if (-not $minSeverity) { $minSeverity = 'Medium' }
    $commitSha = if ($publishResult -and $publishResult.committed) { $publishResult.commitSha } else { $null }

    $notifEmail = Get-PipelineEnvVar -Name 'NOTIFICATION_EMAIL'
    $notifFrom = Get-PipelineEnvVar -Name 'NOTIFICATION_MAIL_FROM'
    $notifWebhook = Get-PipelineEnvVar -Name 'NOTIFICATION_WEBHOOK_URL'
    $teamsMentionRaw = Get-PipelineEnvVar -Name 'NOTIFICATION_TEAMS_MENTION'
    $teamsMentionUpns = @()
    if ($teamsMentionRaw) {
        $teamsMentionUpns = @($teamsMentionRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if ($notifEmail -and $notifFrom) {
        Write-StepLog "Sending email notification"
        Send-EmailNotification `
            -ChangesBySeverity $changesBySeverity `
            -ToAddress   $notifEmail `
            -FromAddress $notifFrom `
            -AccessToken $token `
            -MinSeverity $minSeverity `
            -CommitSha   $commitSha `
            -AuthContextLookup $authContextLookup `
            -TenantName  $tenantDisplayName
    }

    if ($notifWebhook) {
        Write-StepLog "Sending webhook notification"
        Send-WebhookNotification `
            -ChangesBySeverity $changesBySeverity `
            -WebhookUrl  $notifWebhook `
            -MinSeverity $minSeverity `
            -CommitSha   $commitSha `
            -TenantName  $tenantDisplayName `
            -MentionUpns $teamsMentionUpns
    }
}
else {
    Write-StepLog "No changes detected — skipping notifications"
}

# Scan Error Notification (independent from change notifications)

if ($scanErrors.Count -gt 0) {
    Write-StepLog "Sending scan-error notification ($($scanErrors.Count) component(s) failed)"

    $notifEmail   = Get-PipelineEnvVar -Name 'NOTIFICATION_EMAIL'
    $notifFrom    = Get-PipelineEnvVar -Name 'NOTIFICATION_MAIL_FROM'
    $notifWebhook = Get-PipelineEnvVar -Name 'NOTIFICATION_WEBHOOK_URL'

    Send-ScanErrorNotification `
        -ScanErrors  $scanErrors.ToArray() `
        -AccessToken $token `
        -ToAddress   $notifEmail `
        -FromAddress $notifFrom `
        -WebhookUrl  $notifWebhook
}
else {
    Write-StepLog "No component errors — skipping scan-error notification"
}

# Completion

Write-StepLog "PIM Monitor scan complete"

# Optional hard-fail on component errors. Default off: the scan stays resilient (commit what
# succeeded, notify, exit 0) unless the operator opts in via FAIL_ON_COMPONENT_ERROR=true, which
# makes the pipeline go red so a degraded scan is visible without relying on notifications.
if ($scanErrors.Count -gt 0 -and (Get-PipelineEnvVar -Name 'FAIL_ON_COMPONENT_ERROR') -eq 'true') {
    $failedComponents = ($scanErrors.ToArray() | ForEach-Object { $_.Component }) -join ', '
    throw "Scan completed with $($scanErrors.Count) component error(s) and FAIL_ON_COMPONENT_ERROR=true: $failedComponents"
}
