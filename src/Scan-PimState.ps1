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

# Initialization

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Import script modules (order matters: helpers first, then others that depend on it)
. (Join-Path -Path $PSScriptRoot -ChildPath "helpers.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "graphEndpoints.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "diff.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "git.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-shared.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-email.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-webhook.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-html.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "notifications-error.ps1")

function Write-StepLog {
    param([string] $Message)
    $ts = Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ"
    Write-Host "[$ts] $Message"
}

Write-StepLog "PIM Monitor scan starting"

# Ensure inventory folder exists
$inventoryRoot = Join-Path -Path (Get-Location) -ChildPath "inventory"
if (-not (Test-Path $inventoryRoot)) {
    New-Item -ItemType Directory -Path $inventoryRoot -Force | Out-Null
}

# Accumulator for all detected changes across all workloads
$allChanges = @()

# Accumulator for non-fatal component failures
$scanErrors = [System.Collections.Generic.List[hashtable]]::new()

# Load expected changes (if file exists)
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

# Authentication

Write-StepLog "Acquiring Graph API access token"

# WIF authentication via AzurePowerShell@5 task — token obtained via OIDC exchange
# Az.Accounts 5.x returns .Token as SecureString; -AsPlainText doesn't exist in this version.
# NetworkCredential unwraps SecureString safely; falls back to plain string for future versions.
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
$token = if ($rawToken -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $rawToken).Password
} else {
    $rawToken
}
if (-not $token) {
    throw "Failed to acquire Graph API access token"
}

$tenantDisplayName = try {
    $orgResponse = Invoke-GraphRequest -Uri $script:GraphEndpoints.Organization -Headers @{ Authorization = "Bearer $token" }
    $orgResponse.PSObject.Properties['value']?.Value[0].PSObject.Properties['displayName']?.Value
} catch { $null }

# Lookups — Authentication Contexts

Write-StepLog "Fetching authentication contexts"

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

    # Detect removed authentication contexts
    $removedAuthContexts = Get-RemovedEntities `
        -WorkloadPath (Join-Path $inventoryRoot "authentication-contexts") `
        -CurrentSlugs $authContextSlugs
    $allChanges += $removedAuthContexts
    foreach ($r in $removedAuthContexts) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
}
catch {
    Write-Warning "Authentication contexts scan failed: $_"
    $scanErrors.Add(@{ Component = 'Authentication Contexts'; Error = $_.ToString() })
}

# Lookups — Administrative Units

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

    # Detect removed administrative units
    $removedAdminUnits = Get-RemovedEntities `
        -WorkloadPath (Join-Path $inventoryRoot "administrative-units") `
        -CurrentSlugs $adminUnitSlugs
    $allChanges += $removedAdminUnits
    foreach ($r in $removedAdminUnits) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }
}
catch {
    Write-Warning "Administrative units scan failed: $_"
    $scanErrors.Add(@{ Component = 'Administrative Units'; Error = $_.ToString() })
}

# Activation Events (Monthly Archive)

Write-StepLog "Fetching PIM activation events"

try {
    $eventsRoot = Join-Path -Path $inventoryRoot -ChildPath "activation-events"
    if (-not (Test-Path $eventsRoot)) {
        New-Item -ItemType Directory -Path $eventsRoot -Force | Out-Null
    }

    $currentYearMonth = (Get-Date -AsUTC).ToString("yyyy-MM")
    $currentMonthFile = Join-Path -Path $eventsRoot -ChildPath "$currentYearMonth.json"

    $fetchSince = (Get-Date -AsUTC).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

    if (Test-Path $currentMonthFile) {
        try {
            $existingEvents = Get-Content -Path $currentMonthFile -Raw -Encoding utf8 | ConvertFrom-Json
            if ($existingEvents -and $existingEvents.Count -gt 0) {
                $lastEvent = $existingEvents | Sort-Object { [datetime]$_.activityDateTime } | Select-Object -Last 1
                if ($lastEvent -and $lastEvent.activityDateTime) {
                    $lastTime = [datetime]::Parse($lastEvent.activityDateTime)
                    $fetchSince = $lastTime.AddSeconds(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
                }
            }
        }
        catch {
            Write-Warning "Could not parse existing events: $_"
        }
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
        foreach ($event in $auditEvents) {
            if (-not $eventIds.Contains($event.id)) {
                $monthlyEvents += $event
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

# Directory Roles

Write-StepLog "Fetching Directory Roles"

$roleResults = @()   # initialised here so Expiring Assignments can safely iterate if Directory Roles fails

try {
    $roleDefinitions = @(Get-AllGraphItems -Uri $script:GraphEndpoints.RoleDefinitions -AccessToken $token)
    Write-Host "  Found $($roleDefinitions.Count) role definitions"

    $roleSlugs = @()

    # Functions are not available inside -Parallel; serialize to string so it can cross the
    # runspace boundary via $using: (script block variables are not allowed with $using:).
    $slugFnStr = ${function:Get-InventorySlug}.ToString()
    $invokeGraphFnStr = ${function:Invoke-GraphRequest}.ToString()

    # Pre-build all per-role URIs using the URI builder functions before entering -Parallel.
    # URI builder functions are also unavailable inside -Parallel, so this keeps all URI
    # construction in one place (graphEndpoints.ps1) and eliminates inline duplication.
    $roleUriMap = @{}
    foreach ($role in $roleDefinitions) {
        $roleUriMap[$role.id] = @{
            policy    = Get-RolePolicyUri                -RoleId $role.id
            permanent = Get-RolePermanentAssignmentsUri  -RoleId $role.id
            eligible  = Get-RoleEligibleAssignmentsUri   -RoleId $role.id
            active    = Get-RoleActiveAssignmentsUri     -RoleId $role.id
        }
    }

    # Parallel fetch per role (policies + assignments).
    # Pipe functions and endpoints via $using:, collect results for sequential write.
    $roleResults = @($roleDefinitions | ForEach-Object -Parallel {
        $role = $_
        $roleId = $role.id
        $roleDisplayName = $role.displayName

        $slugName = & ([scriptblock]::Create($using:slugFnStr)) -Name $roleDisplayName

        # Output may appear out of order in parallel blocks due to runspace interleaving
        Write-Host "  Processing: $roleDisplayName ($slugName)"

        try {
            $uris    = ($using:roleUriMap)[$roleId]
            $headers = @{ Authorization = "Bearer $($using:token)" }

            # Use serialized Invoke-GraphRequest function for consistent retry logic with jitter
            $invokeGraphRequest = [scriptblock]::Create($using:invokeGraphFnStr)

            $policyItems = @()
            $currentUri = $uris.policy
            while ($currentUri) {
                $response = & $invokeGraphRequest -Uri $currentUri -Headers $headers
                if ($response.value) { $policyItems += $response.value }
                $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
            }
            $policyAssignment = $policyItems | Select-Object -First 1

            if (-not $policyAssignment) {
                Write-Warning "    No policy assignment found for role: $roleDisplayName"
            }

            # Fetch assignments (permanent, eligible, active)
            $permUri = $uris.permanent
            $eligUri = $uris.eligible
            $actUri  = $uris.active

            $fetchAssignments = {
                param($uri)
                $items = @()
                $currentUri = $uri
                while ($currentUri) {
                    $response = & $invokeGraphRequest -Uri $currentUri -Headers $headers
                    if ($response.value) { $items += $response.value }
                    $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
                }
                return $items
            }

            $permanent = (& $fetchAssignments $permUri) ?? @()
            $eligible  = (& $fetchAssignments $eligUri) ?? @()
            $active    = (& $fetchAssignments $actUri)  ?? @()

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
    } -ThrottleLimit 8)

    # Post-process sequentially: organize files, compute diffs, collect changes
    foreach ($result in $roleResults) {
        # Always track slug to prevent false-positive archiving when a role fails transiently
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
    $removedRoles = Get-RemovedEntities `
        -WorkloadPath (Join-Path $inventoryRoot "directory-roles") `
        -CurrentSlugs $roleSlugs
    $allChanges += $removedRoles
    foreach ($r in $removedRoles) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }

    Write-StepLog "Directory Roles scan complete"
}
catch {
    Write-Warning "Directory Roles scan failed: $_"
    $scanErrors.Add(@{ Component = 'Directory Roles'; Error = $_.ToString() })
}

# PIM Groups

Write-StepLog "Fetching PIM Groups"

$groupAssignmentsByEntity = @{}   # initialised here so Expiring Assignments can safely iterate if PIM Groups fails

try {
    # Discover PIM-onboarded groups via the resources endpoint.
    # The unfiltered eligibilityScheduleInstances/assignmentScheduleInstances endpoints
    # require $filter=groupId — they cannot be used for discovery.
    $pimGroupResources = @(Get-AllGraphItems -Uri $script:GraphEndpoints.GroupResources -AccessToken $token)
    $groupIds = @($pimGroupResources | ForEach-Object { $_.id }) | Where-Object { $_ }

    Write-Host "  Found $($groupIds.Count) PIM-onboarded groups"

    $groupSlugs = @()
    $groupAssignmentsByEntity = @{}
    $groupHeaders = @{ Authorization = "Bearer $token" }

    foreach ($groupId in $groupIds) {
        $groupDisplayName = $null
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
            $groupActive   = @(Get-AllGraphItems -Uri (Get-GroupActiveAssignmentsUri   -GroupId $groupId) -AccessToken $token)

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
        }
        catch {
            $componentName = if ($groupDisplayName) { "PIM Group: $groupDisplayName" } else { "PIM Group: $groupId" }
            Write-Warning "  Failed to process $componentName — $_"
            $scanErrors.Add(@{ Component = $componentName; Error = $_.ToString() })
        }
    }

    # Detect groups removed from PIM (folder exists but not in current resources list)
    $removedGroups = Get-RemovedEntities `
        -WorkloadPath (Join-Path $inventoryRoot "pim-groups") `
        -CurrentSlugs $groupSlugs
    $allChanges += $removedGroups
    foreach ($r in $removedGroups) { Move-ToArchive -FolderPath $r.folderPath -InventoryRoot $inventoryRoot }

    Write-StepLog "PIM Groups scan complete"
}
catch {
    Write-Warning "PIM Groups scan failed: $_"
    $scanErrors.Add(@{ Component = 'PIM Groups'; Error = $_.ToString() })
}

# Expiring Assignments Detection

Write-StepLog "Checking for expiring assignments"

try {
    # Aggregate assignments from both workloads into a single lookup for expiry detection
    $allAssignmentsByEntity = @{}

    foreach ($result in $roleResults) {
        $allAssignmentsByEntity[$result.slug] = $result.cleanAssignments
    }

    foreach ($slug in $groupAssignmentsByEntity.Keys) {
        $allAssignmentsByEntity[$slug] = $groupAssignmentsByEntity[$slug]
    }

    $parsed = 0
    $windowDays = if ([int]::TryParse($env:EXPIRING_WINDOW_DAYS, [ref]$parsed)) { $parsed } else { 14 }
    $expiringChanges = @(Find-ExpiringAssignments -Assignments $allAssignmentsByEntity -WindowDays $windowDays)

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

# Filter Expected Changes

if ($expectations.Count -gt 0) {
    Write-StepLog "Filtering expected changes"

    $consumedExpectations = @()
    $filteredChanges = @()

    foreach ($change in $allChanges) {
        if (Test-ChangeIsExpected -Change $change -Expectations $expectations) {
            Write-Host "  Suppressed: $($change.description)"
            $consumedExpectations += $change
        }
        else {
            $filteredChanges += $change
        }
    }

    $allChanges = $filteredChanges
    Write-Host "  Suppressed $($consumedExpectations.Count) expected change(s)"

    # Clean up expected-changes.json: remove consumed and expired entries
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
        $updatedFile = @{ expected = $remainingExpectations } | ConvertTo-Json -Depth 10
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

$publishResult = $null
if ($changesBySeverity.Total -gt 0) {
    Write-StepLog "Publishing inventory changes"
    $publishResult = Publish-InventoryChanges
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
        $reportPath    = Join-Path $stagingDir "scan-report.html"
        $reportTenantId = try { (Get-AzContext).Tenant.Id } catch { $null }
        $reportCommitSha = if ($publishResult -and $publishResult.committed) { $publishResult.commitSha } else { $null }
        Export-ScanReport `
            -ChangesBySeverity $changesBySeverity `
            -OutputPath $reportPath `
            -TenantId $reportTenantId `
            -TenantName $tenantDisplayName `
            -CommitSha $reportCommitSha
    }
}

# Notifications (after commit so we have SHA for diff links)

if ($changesBySeverity.Total -gt 0) {
    $minSeverity = if ($env:NOTIFICATION_MIN_SEVERITY -and $env:NOTIFICATION_MIN_SEVERITY -notmatch '^\$\(') { $env:NOTIFICATION_MIN_SEVERITY } else { 'Medium' }
    $commitSha = if ($publishResult -and $publishResult.committed) { $publishResult.commitSha } else { $null }

    # ADO passes unresolved macro references as literal $(VAR_NAME) strings when a
    # variable is absent from both YAML and UI. Treat those as not set.
    $notifEmail    = if ($env:NOTIFICATION_EMAIL       -notmatch '^\$\(') { $env:NOTIFICATION_EMAIL       } else { $null }
    $notifFrom     = if ($env:NOTIFICATION_MAIL_FROM   -notmatch '^\$\(') { $env:NOTIFICATION_MAIL_FROM   } else { $null }
    $notifWebhook  = if ($env:NOTIFICATION_WEBHOOK_URL -notmatch '^\$\(') { $env:NOTIFICATION_WEBHOOK_URL } else { $null }

    if ($notifEmail -and $notifFrom) {
        Write-StepLog "Sending email notification"
        Send-EmailNotification `
            -ChangesBySeverity $changesBySeverity `
            -ToAddress   $notifEmail `
            -FromAddress $notifFrom `
            -AccessToken $token `
            -MinSeverity $minSeverity `
            -CommitSha   $commitSha
    }

    if ($notifWebhook) {
        Write-StepLog "Sending webhook notification"
        Send-WebhookNotification `
            -ChangesBySeverity $changesBySeverity `
            -WebhookUrl  $notifWebhook `
            -MinSeverity $minSeverity `
            -CommitSha $commitSha
    }
}
else {
    Write-StepLog "No changes detected — skipping notifications"
}

# Scan Error Notification (independent from change notifications)

if ($scanErrors.Count -gt 0) {
    Write-StepLog "Sending scan-error notification ($($scanErrors.Count) component(s) failed)"

    $notifEmail   = if ($env:NOTIFICATION_EMAIL       -and $env:NOTIFICATION_EMAIL       -notmatch '^\$\(') { $env:NOTIFICATION_EMAIL       } else { $null }
    $notifFrom    = if ($env:NOTIFICATION_MAIL_FROM   -and $env:NOTIFICATION_MAIL_FROM   -notmatch '^\$\(') { $env:NOTIFICATION_MAIL_FROM   } else { $null }
    $notifWebhook = if ($env:NOTIFICATION_WEBHOOK_URL -and $env:NOTIFICATION_WEBHOOK_URL -notmatch '^\$\(') { $env:NOTIFICATION_WEBHOOK_URL } else { $null }

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
