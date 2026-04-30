# 03 — Data Flow

## Table of Contents

1. [High-Level Flow](#1-high-level-flow)
2. [Step 1: Authentication](#2-step-1-authentication)
3. [Step 2: Lookup Fetches](#3-step-2-lookup-fetches)
4. [Step 3: Activation Events](#4-step-3-activation-events)
5. [Step 4: Directory Roles](#5-step-4-directory-roles)
6. [Step 5: PIM Groups](#6-step-5-pim-groups)
7. [Step 6: Expiring Assignments](#7-step-6-expiring-assignments)
8. [Step 7: Expected-Change Filtering](#8-step-7-expected-change-filtering)
9. [Step 8: Severity Grouping](#9-step-8-severity-grouping)
10. [Step 9: Git Commit](#10-step-9-git-commit)
11. [Step 10: Notifications](#11-step-10-notifications)
12. [Error Handling](#12-error-handling)
13. [Parallelism](#13-parallelism)

---

## 1. High-Level Flow

```
Pipeline agent starts
        │
        ▼
[Checkout repo]  ←── inventory/ = previous state
        │
        ▼
[Install Microsoft.Graph module]
        │
        ▼
[AzurePowerShell@5]  ←── WIF OIDC token exchange
        │
        ▼
  Scan-PimState.ps1
        │
        ├── [Auth] Get-AzAccessToken → $token
        │
        ├── [Lookups] Authentication Contexts + Administrative Units
        │
        ├── [Events] PIM audit log → activation-events/YYYY-MM.json
        │
        ├── [Directory Roles] Definitions + Policies + Assignments (parallel)
        │       │
        │       └── diff + write inventory + collect $allChanges
        │
        ├── [PIM Groups] Discovery + Policies + Assignments (sequential)
        │       │
        │       └── diff + write inventory + collect $allChanges
        │
        ├── [Expiring] Scan all assignments for upcoming expirations
        │       │
        │       └── append to $allChanges
        │
        ├── [Filter] Remove expected changes (expected-changes.json)
        │
        ├── [Group] Group-ChangesBySeverity → $changesBySeverity
        │
        ├── [Report] Export-ScanReport (if REPORT_ARTIFACT=true)
        │
        ├── [Git] Publish-InventoryChanges (if any changes)
        │
        └── [Notify] Send-EmailNotification / Send-WebhookNotification
```

---

## 2. Step 1: Authentication

The pipeline runs inside an `AzurePowerShell@5` task that uses a WIF service connection to perform an OIDC token exchange. This makes `Get-AzAccessToken` available without any client secret.

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
$token = if ($rawToken -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $rawToken).Password
} else {
    $rawToken
}
```

The `SecureString` unwrap is required on Az.Accounts 3.0+ (Az module 12+), which changed the return type of `.Token`. The fallback branch handles older versions transparently.

The resulting `$token` is a plain string passed as a `Bearer` header to all Graph API calls throughout the scan.

---

## 3. Step 2: Lookup Fetches

Authentication contexts and administrative units are fetched before roles and groups because they are **referenced by** policy and assignment data. Inventorying them first ensures their slugs are available for later resolution.

For each lookup type:
1. `Get-AllGraphItems` fetches all entries from the collection endpoint.
2. Each entry is slugified and a folder created under `inventory/{workload}/{slug}/`.
3. `Compare-InventoryFolder` diffs the current `definition.json` against the new data.
4. `Save-InventoryFile` writes the updated `definition.json`.
5. `Get-RemovedEntities` detects any folder on disk whose slug is absent from the current fetch.

---

## 4. Step 3: Activation Events

PIM activation events come from `GET /auditLogs/directoryAudits` filtered by `loggedByService eq 'PIM'`.

The fetch uses an incremental window:
1. If the current month file (`activation-events/YYYY-MM.json`) exists and is non-empty, the most recent `activityDateTime` is read.
2. The fetch fetches events since that timestamp + 1 second.
3. New events are merged into the existing array (deduplicated by `id`), sorted by `activityDateTime`, and written back.

This avoids fetching the entire audit history on every scan while guaranteeing no event is skipped if the pipeline is interrupted.

> [!NOTE]
> If `AuditLog.Read.All` is not granted on the App Registration, this step logs a warning and continues. The rest of the scan is unaffected. Activation events are informational and do not contribute to the `$allChanges` severity buckets.

---

## 5. Step 4: Directory Roles

This is the most complex section because it combines a parallel fetch phase with a sequential post-processing phase.

### Fetch phase (parallel)

```
Get-AllGraphItems(RoleDefinitions)  →  $roleDefinitions[]
        │
        └── ForEach-Object -Parallel -ThrottleLimit 3
                │
                ├── Slugify displayName
                ├── Fetch policy (policyAssignment + expanded rules)
                ├── Fetch permanent assignments
                ├── Fetch eligible assignments
                └── Fetch active assignments
                        │
                        └── Return: @{ definition; slug; policyAssignment; assignments }
```

The `ThrottleLimit` is 3 (not 8) for the role section because each role spawns 4 Graph API calls. Effective concurrency is up to 12 simultaneous requests, which is near the per-app throttling threshold.

Within the parallel block, Graph API calls use a local retry loop (up to 5 attempts, exponential backoff) because `Get-AllGraphItems` is not available in the `$using:` scope in a `-Parallel` block.

### Post-processing phase (sequential)

After all role results are collected:
1. `Remove-AssignmentNoise` strips `scheduleInfo.startDateTime` from all assignments. This field is a heartbeat timestamp that Microsoft updates every ~30 minutes without any user action.
2. `Compare-InventoryFolder` diffs old vs new for each file type.
3. `Save-InventoryFile` writes all three inventory files.
4. Detected changes are appended to `$allChanges`.

Finally, `Get-RemovedEntities` detects folders present in `inventory/directory-roles/` whose slugs were not in the current role fetch (i.e., roles removed from PIM).

---

## 6. Step 5: PIM Groups

PIM-onboarded groups are discovered via `GET /beta/identityGovernance/privilegedAccess/group/resources`.

> [!WARNING]
> This endpoint is deprecated by Microsoft and will stop returning data on **October 28, 2026**. When that happens, the discovery mechanism must be replaced. The likely replacement is collecting distinct `groupId` values from `eligibilityScheduleInstances` and `assignmentScheduleInstances` (which require `$filter=groupId eq '...'` and cannot be enumerated unfiltered).

For each discovered group:
1. Group definition fetched from `GET /groups/{id}` (v1.0).
2. Eligible assignments fetched from `eligibilityScheduleInstances?$filter=groupId eq '{id}'` (v1.0).
3. Active/permanent assignments fetched from `assignmentScheduleInstances?$filter=groupId eq '{id}'` (v1.0).
4. Policies fetched from beta `policies/roleManagementPolicyAssignments?$filter=scopeId eq '{groupId}' and scopeType eq 'Group'` (returns member + owner policy objects).
5. Noise removal, diff, inventory write, and change collection follow the same pattern as Directory Roles.

PIM Group processing is sequential (not parallel) because the group count is typically much lower than the role count.

---

## 7. Step 6: Expiring Assignments

`Find-ExpiringAssignments` scans all assignment sets collected during the role scan. For each assignment with a non-null `scheduleInfo.expiration.endDateTime`:
- Parse the `endDateTime` as UTC.
- Calculate `$daysRemaining = ($expiryTime - $nowUtc).TotalDays`.
- If `$daysRemaining` is between 0 and `$EXPIRING_WINDOW_DAYS` (default 14), emit a `Medium`-severity change entry with `changeType = "expiring"`.

These entries are appended to `$allChanges` and surface in notifications as advance warning. They do not modify any inventory file.

> [!NOTE]
> The expiring-assignments check currently covers only Directory Role assignments collected during the current scan run. PIM Group assignments are not yet included in this check.

---

## 8. Step 7: Expected-Change Filtering

If `expected-changes.json` exists, `Test-ChangeIsExpected` is called for each entry in `$allChanges`. A change is suppressed when it matches on:
- `workload` (e.g., `"directory-roles"`)
- `entity` (slug, e.g., `"global-administrator"`)
- `fileType` (e.g., `"policy"`)
- `ruleId` (optional — for policy-specific suppression)

After filtering, the file is rewritten:
- Consumed entries (matched at least once and no longer needed) remain unless they also expired.
- Expired entries (current UTC > `expiresUtc`) are removed.
- If no entries remain, the file is deleted.

---

## 9. Step 8: Severity Grouping

`Group-ChangesBySeverity` partitions `$allChanges` into four buckets:

| Bucket | Severity values |
|---|---|
| `High` | `"High"` |
| `Medium` | `"Medium"` |
| `Low` | `"Low"` |
| `Informational` | anything else (e.g., `"Informational"`) |

The result `$changesBySeverity` contains `.High`, `.Medium`, `.Low`, `.Informational` arrays and a `.Total` count. This structure is passed to both the notification functions and the HTML report exporter.

---

## 10. Step 9: Git Commit

`Publish-InventoryChanges` is called only when `$changesBySeverity.Total -gt 0`.

```
git config user.name "PIM Monitor"
git config user.email "pim-monitor@pipeline"
git add inventory/
git diff --cached --quiet  →  exit 0 = no changes → return early
git commit -m "scan: {ISO timestamp}"
git push origin HEAD:main
    │
    └── if push rejected (exit != 0):
            git fetch origin main
            git rebase origin/main
            git push origin HEAD:main
```

The push-with-rebase handles the case where two parallel pipeline runs (or a manual commit) advance the remote branch between the checkout and the push. A rebase is preferred over a merge commit to keep the history linear.

> [!WARNING]
> If the rebase itself fails (genuine conflict), the function throws and the pipeline step fails. This requires manual intervention (`git rebase --abort` on the local clone, then investigate the conflict).

The commit SHA is captured after the push (post-rebase) and passed to the notification functions for constructing "View Diff" links.

---

## 11. Step 10: Notifications

Notifications are sent only when `$changesBySeverity.Total -gt 0`. Each channel is independently skipped if not configured.

**Email:** Checks for unresolved ADO macro references (`$(VARIABLE_NAME)` literal strings) before treating a value as set. If both `NOTIFICATION_EMAIL` and `NOTIFICATION_MAIL_FROM` are present and non-macro, `Send-EmailNotification` is called.

**Webhook:** If `NOTIFICATION_WEBHOOK_URL` is present and non-macro, `Send-WebhookNotification` is called. It auto-detects the webhook type from the URL and dispatches to the appropriate payload builder.

The `NOTIFICATION_MIN_SEVERITY` variable controls which severity levels are included. Default is `Medium`, meaning Low and Informational changes are not notified but are still committed and stored.

---

## 12. Error Handling

Each major component section in `Scan-PimState.ps1` is wrapped in `try/catch`. If a component fails, the exception is logged as a warning and recorded in a `$scanErrors` accumulator (`List[hashtable]` with `Component` and `Error` fields). The remaining components continue to run, and the pipeline exits with code 0.

The one exception is the initial token acquisition block (~line 89). If `Get-AzAccessToken` fails, the script throws immediately — there is no meaningful scan to continue without a valid token.

After all components have run (and after regular change notifications are dispatched), `Send-ScanErrorNotification` is called if `$scanErrors.Count -gt 0`. This sends a separate email and/or webhook message listing each failed component and a truncated error message (~200 characters). It uses the same `NOTIFICATION_EMAIL`, `NOTIFICATION_MAIL_FROM`, and `NOTIFICATION_WEBHOOK_URL` env vars as the regular change notification, but the payload is completely independent and does not involve `$ChangesBySeverity`.

`$ErrorActionPreference = "Stop"` is set at the top of the orchestrator. All non-terminating errors become terminating within each section. This prevents Graph API calls from silently returning error objects. The per-component `try/catch` blocks ensure those terminating errors are captured rather than propagating to the top-level pipeline.

---

## 13. Parallelism

| Section | Strategy | ThrottleLimit | Reason |
|---|---|---|---|
| Directory Roles (fetch) | `ForEach-Object -Parallel` | 3 | Each role = 4 API calls; 3 × 4 = 12 concurrent requests |
| Directory Roles (post-process) | Sequential | — | File writes and change collection must not race |
| PIM Groups | Sequential | — | Low group count; parallel overhead not worth it |
| Lookup fetches | Sequential | — | Two lookups only; no benefit from parallelism |

> [!NOTE]
> The `-Parallel` block in the Directory Roles section cannot access module-level functions directly. The retry logic and pagination are inlined locally within the block via script blocks (`$invokeWithRetry`, `$fetchAssignments`). This is a PowerShell limitation for parallel runspaces.
