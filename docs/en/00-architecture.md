# 00 — Architecture

## Table of Contents

1. [Overview](#1-overview)
2. [Problem Statement](#2-problem-statement)
3. [System Context](#3-system-context)
4. [Component Overview](#4-component-overview)
5. [Key Design Decisions](#5-key-design-decisions)
6. [Quality Attributes](#6-quality-attributes)
7. [Constraints](#7-constraints)
8. [Architecture Layers](#8-architecture-layers)
9. [State Model](#9-state-model)
10. [Scan Run Lifecycle](#10-scan-run-lifecycle)
11. [External Interfaces](#11-external-interfaces)
12. [Future Phases](#12-future-phases)

---

## 1. Overview

PIM Monitor is an **Azure DevOps scheduled pipeline** that monitors Microsoft Entra ID PIM (Privileged Identity Management) for configuration drift and unauthorized changes. It runs unattended on a hosted agent, fetches the full current PIM state via Microsoft Graph API, compares it against the previous state stored as JSON files in the repository, and notifies administrators of any changes.

The repository itself is the state store. No external database, no pipeline artifacts, no delta tokens.

```
PIM Monitor (Azure DevOps, user-configured schedule)
  ├── Pull latest repo (inventory files = previous state)
  ├── Authenticate (Workload Identity Federation — no secrets)
  ├── Fetch current PIM state (Graph API, full fetch)
  ├── Diff inventory files vs current state
  ├── Classify changes by severity (High / Medium / Low / Informational)
  ├── Update inventory files (create / update / delete)
  ├── Commit and push to repo (only if files changed)
  └── Send notifications (if configured and changes detected)
```

---

## 2. Problem Statement

Microsoft Entra ID PIM provides no built-in mechanism to:

- Proactively detect and alert on changes to role assignments, policies, or group membership.
- Track configuration drift over time (policy weakening, new eligible assignments, permanent role grants).
- Provide a structured, queryable audit trail beyond the Entra audit log (which has retention limits and no push notification).

PIM Monitor fills this gap with a scheduled, low-overhead scan that stores every change as a git commit.

---

## 3. System Context

```
+-------------------------+      Graph API      +---------------------+
|  Customer's Entra Tenant|<------------------->|  Azure DevOps       |
|                         |                     |  Pipeline Agent     |
|  - Directory Roles      |      WIF OIDC       |                     |
|  - PIM Groups           |<------------------->|  App Registration   |
|  - Policies             |  (no client secret) |  Service Connection |
|  - Assignments          |                     +----------+----------+
+-------------------------+                                |
                                                           | git push
                                                           v
                                                 +--------------------+
                                                 |  ADO Git Repo      |
                                                 |  inventory/        |
                                                 |  (state + history) |
                                                 +--------------------+
                                                           |
                                                    email / webhook
                                                           v
                                                 +--------------------+
                                                 |  Administrators    |
                                                 +--------------------+
```

---

## 4. Component Overview

| Component | File | Responsibility |
|---|---|---|
| Orchestrator | `src/Scan-PimState.ps1` | Top-level scan flow, module imports, error handling |
| Graph endpoints | `src/graphEndpoints.ps1` | URI constants and per-item URI builders |
| Helpers | `src/helpers.ps1` | Pagination, JSON serialization, inventory I/O |
| Diff engine | `src/diff.ps1` | Change detection, severity classification, noise suppression |
| Git operations | `src/git.ps1` | Commit, push, rebase on conflict |
| Notifications | `src/notifications.ps1` | Email (Graph), webhooks (Teams / Slack / Discord / generic) |
| Pipeline definition | `monitor-pipeline.yml` | Schedule, authentication task, git commit step |

---

## 5. Key Design Decisions

### 5.1 Runtime: Azure DevOps Pipelines

Azure DevOps Pipelines was chosen over Azure Functions for the following reasons:

| Aspect | Azure Functions | Azure DevOps Pipelines |
|---|---|---|
| Cost | Consumption plan (~free) | 1800 free minutes/month |
| Setup complexity | Function App + Storage Account | Repo + YAML pipeline |
| Authentication | Managed Identity or App Reg | Service Connection + WIF |
| Infrastructure | More moving parts | Git push and done |
| Precedent | — | Proven model (Maester.dev) |
| Enterprise familiarity | Varies | High — most enterprises use ADO |

For a monitoring task that runs a few seconds per scan, usage stays well within the free tier at any reasonable schedule.

### 5.2 State Storage: Git as the Database

Inventory files in the repository are the source of truth for previous PIM state. Each pipeline run checks out the repo, reads the current inventory, compares it against the freshly fetched API data, and writes back any changes.

Consequences:
- **No external storage.** No Azure Blob, no Cosmos DB, no pipeline artifacts.
- **Audit trail for free.** Every change is a git commit with a timestamp. `git log` and `git diff` expose the full history.
- **Persistent across pipeline agents.** Hosted agents are ephemeral; the repo is not.
- **Queryable via REST.** The Azure DevOps Git REST API allows external tools (PIM Manager) to read the change timeline without special pipeline integration.

### 5.3 Change Detection: Full Fetch + Diff

Each scan fetches the complete current PIM state from Microsoft Graph API and compares it against the committed inventory files. No delta queries, no webhook subscriptions, no persistent state outside of git.

Rationale:
- The data volume (role definitions, assignments, policies) is small. A full fetch takes a few seconds.
- Delta queries require persisting delta tokens across runs. Git already is the persistent store; adding a second persistence layer adds complexity for minimal gain.
- Full fetch guarantees correctness: if a delta sync is missed or corrupted, the next run self-heals automatically.

### 5.4 Language: PowerShell

PowerShell is the implementation language because:
- It is natively available on ubuntu-latest hosted agents (no setup step).
- The Microsoft Graph PowerShell SDK is the Microsoft-supported first-class client.
- Maester.dev has proven this model at scale for Azure DevOps-based security monitoring.
- `AzurePowerShell@5` provides first-class WIF token acquisition.

### 5.5 Deterministic JSON

The Graph API does not guarantee property order. PowerShell's `ConvertTo-Json` preserves insertion order. Without normalization, every scan run would produce a different byte sequence for identical API data, causing false-positive git diffs on every run.

All inventory file writes go through `ConvertTo-DeterministicJson` (in `helpers.ps1`), which:
1. Sorts object keys alphabetically, recursively.
2. Sorts arrays by `id` field (or value for string arrays).
3. Strips `@odata.*` metadata properties.
4. Uses 2-space indentation, UTF-8 without BOM.

---

## 6. Quality Attributes

| Attribute | Goal | Mechanism |
|---|---|---|
| Correctness | No false positives or missed changes | Deterministic JSON; full fetch (no delta) |
| Auditability | Complete change history | Git commits; one commit per scan with ISO timestamp |
| Security | No credentials in code or pipeline variables | Workload Identity Federation; no `CLIENT_SECRET` |
| Reliability | Handles Graph throttling and push conflicts | Exponential backoff; push-with-rebase |
| Maintainability | Declarative severity rules | Lookup tables in `diff.ps1`; no if/else cascades |
| Extensibility | New API fields appear automatically | Full response storage; no `$select` filtering |
| Observability | Pipeline logs + HTML scan report artifact | `Write-StepLog` throughout; `Export-ScanReport` |

---

## 7. Constraints

- **PowerShell 7.x required.** `Set-StrictMode -Version Latest` is enforced. The `?.` null-conditional operator and `-AsHashtable` on `ConvertFrom-Json` are 7.x features.
- **`AzurePowerShell@5` task.** Authentication is tied to this task type; changing to a different task type requires reworking token acquisition.
- **Az.Accounts 3.0+ returns `SecureString`.** `Get-AzAccessToken` returns `.Token` as a `SecureString` on newer SDK versions. The codebase unwraps it via `NetworkCredential`.
- **One branch: `main`.** The pipeline always pushes to `origin HEAD:main`. Multi-branch deployments are not currently supported.
- **Hosted agent is ephemeral.** The only state that survives between runs is the git repository. Do not rely on agent-local files.

---

## 8. Architecture Layers

```
monitor-pipeline.yml         (pipeline schedule + task definitions)
        |
        v
Scan-PimState.ps1            (orchestrator — scan loop, error handling)
        |
        +-- graphEndpoints.ps1    (URI constants + URI builder functions)
        |
        +-- helpers.ps1           (Get-AllGraphItems, ConvertTo-DeterministicJson,
        |                          Save-InventoryFile, New-InventoryFolder,
        |                          Get-InventorySlug)
        |
        +-- diff.ps1              (Compare-InventoryFolder, Compare-PolicyRules,
        |                          Compare-Assignments, Compare-FlatProperties,
        |                          Find-ExpiringAssignments, Test-ChangeIsExpected,
        |                          Group-ChangesBySeverity)
        |
        +-- git.ps1               (Publish-InventoryChanges, Get-StagedChanges,
        |                          Get-InventoryFileFromGit)
        |
        +-- notifications.ps1     (Send-EmailNotification, Send-WebhookNotification,
                                   Format-ChangeSummaryHtml, Format-ChangeSummaryText,
                                   Build-TeamsPayload, Build-SlackPayload,
                                   Build-DiscordPayload, Export-ScanReport)
```

Each module has a single responsibility. The orchestrator composes them; individual modules do not call each other.

> [!NOTE]
> `diff.ps1` references `ConvertTo-DeterministicJson` from `helpers.ps1`. Module load order in the orchestrator is therefore: `helpers.ps1` first, then the rest in any order.

---

## 9. State Model

### Inventory structure

```
inventory/
├── directory-roles/           (one folder per role)
│   └── {role-slug}/
│       ├── definition.json    (unifiedRoleDefinition from beta API)
│       ├── policy.json        (policyAssignment + expanded rules from v1.0)
│       └── assignments.json   (permanent / eligible / active arrays)
├── pim-groups/                (one folder per PIM-onboarded group)
│   └── {group-slug}/
│       ├── definition.json    (group properties from v1.0)
│       ├── policy.json        (member + owner policy wrappers from beta)
│       └── assignments.json   (member/owner × permanent/eligible/active)
├── authentication-contexts/   (lookup: resolve claimValue → displayName)
│   └── {slug}/
│       └── definition.json
├── administrative-units/      (lookup: resolve directoryScopeId → displayName)
│   └── {slug}/
│       └── definition.json
├── activation-events/         (monthly archives of PIM audit log events)
│   └── YYYY-MM.json
└── archive/                   (removed entities, preserved for audit history)
    ├── directory-roles/
    │   └── {slug}_{YYYY-MM-DD}/
    ├── pim-groups/
    │   └── {slug}_{YYYY-MM-DD}/
    ├── authentication-contexts/
    │   └── {slug}_{YYYY-MM-DD}/
    └── administrative-units/
        └── {slug}_{YYYY-MM-DD}/
```

### Lifecycle of inventory folders

- **Created** when an entity is first seen (folder + all applicable files).
- **Updated** per file when only that file's data changes. A policy change touches only `policy.json`.
- **Archived** when `Get-RemovedEntities` detects a slug present on disk but absent from the current API fetch. The folder is moved to `inventory/archive/{workload}/{slug}_{date}` via `Move-ToArchive`. The files are preserved for audit history — nothing is deleted.

### Slug derivation

Folder names are derived from `displayName` via `Get-InventorySlug`:
- Lowercased.
- Non-word characters (except spaces and hyphens) removed.
- Spaces and consecutive hyphens collapsed to a single hyphen.
- Leading and trailing hyphens stripped.

Example: `"Global Administrator"` → `"global-administrator"`.

---

## 10. Scan Run Lifecycle

1. **Module import.** `Scan-PimState.ps1` dot-sources all modules in dependency order.
2. **Token acquisition.** `Get-AzAccessToken -ResourceTypeName MSGraph` via the `AzurePowerShell@5` task context.
3. **Lookup fetches.** Authentication contexts and administrative units fetched and inventoried.
4. **Activation events.** PIM audit log events since the last recorded event appended to the current month file.
5. **Directory Roles.** All role definitions fetched; policies and assignments fetched in parallel per role (ThrottleLimit 3). Results post-processed sequentially for diff and write.
6. **PIM Groups.** All PIM-onboarded groups discovered; policies and assignments fetched per group sequentially.
7. **Expiring assignments.** All assignment sets scanned for entries expiring within `EXPIRING_WINDOW_DAYS` (default 14).
8. **Expected-change filtering.** Changes matching entries in `expected-changes.json` are suppressed; expired entries cleaned up.
9. **Severity grouping.** `Group-ChangesBySeverity` aggregates all changes into High / Medium / Low / Informational buckets.
10. **HTML report** (optional). Written to `$BUILD_ARTIFACTSTAGINGDIRECTORY` when `REPORT_ARTIFACT=true`.
11. **Git commit.** `Publish-InventoryChanges` stages `inventory/`, commits with `scan: {timestamp}`, pushes to `origin HEAD:main`.
12. **Notifications.** Email and/or webhook sent if changes meet the minimum severity threshold.

---

## 11. External Interfaces

| Interface | Direction | Protocol | Purpose |
|---|---|---|---|
| Microsoft Graph API | Outbound | HTTPS REST | Fetch PIM state |
| Azure DevOps Git | Inbound/outbound | HTTPS Git | Checkout and push inventory |
| Graph sendMail | Outbound | HTTPS REST | Email notifications |
| Webhook URL | Outbound | HTTPS POST | Teams / Slack / Discord / custom notifications |
| ADO Git REST API | Inbound (from PIM Manager) | HTTPS REST | Change timeline consumed by PIM Manager |

---

## 12. Future Phases

| Phase | Feature | Notes |
|---|---|---|
| 4 | Audit log actor attribution | `GET /auditLogs/directoryAudits` — who made a change |
| 4 | Security alerts | `GET /identityGovernance/roleManagementAlerts/alerts` (beta-only) |
| 4 | Pending requests | `GET /roleManagement/directory/roleEligibilityScheduleRequests` |
| Future | Custom alerting rules | Notify only for specific roles/change types |
| Future | Self-hosted agent docs | For tenants that require private network access |
| Future | Delta queries | Only relevant if full fetch becomes a performance concern |
