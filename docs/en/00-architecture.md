# 00 — Architecture

## Table of Contents

1. [Overview](#1-overview)
2. [Problem Statement](#2-problem-statement)
3. [System Context](#3-system-context)
4. [Component Overview](#4-component-overview)
5. [Key Design Decisions](#5-key-design-decisions)
6. [Design Principles & Quality Guidelines](#6-design-principles--quality-guidelines)
7. [Quality Attributes (NFRs)](#7-quality-attributes-nfrs)
8. [Architectural Decision Records (ADRs)](#8-architectural-decision-records-adrs)
9. [Security Architecture](#9-security-architecture)
10. [Constraints](#10-constraints)
11. [Architecture Layers](#11-architecture-layers)
12. [State Model](#12-state-model)
13. [Scan Run Lifecycle](#13-scan-run-lifecycle)
14. [External Interfaces](#14-external-interfaces)
15. [Future Phases](#15-future-phases)

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

| Component | File(s) | Responsibility |
|---|---|---|
| Orchestrator | `src/Scan-PimState.ps1` | Top-level scan flow, module imports, error handling |
| Graph endpoints | `src/graphEndpoints.ps1` | URI constants and per-item URI builders |
| Helpers | `src/helpers.ps1` | Pagination, JSON serialization, inventory I/O, shared helpers |
| Diff engine | `src/diff.ps1` | Change detection, severity classification, noise suppression |
| Compliance | `src/compliance.ps1` | Access model compliance: tier rules, coverage, CA policy checks |
| Git operations | `src/git.ps1` | Commit, push, rebase on conflict |
| Notifications (shared) | `src/notifications-shared.ps1` | Diff-rendering helpers, exec summary, CI URL builders — used by all channels |
| Notifications (email) | `src/notifications-email.ps1` | HTML body renderer + Graph sendMail |
| Notifications (webhook) | `src/notifications-webhook.ps1` | Dispatcher: URL detection + platform delegation + generic JSON payload |
| Notifications (Teams) | `src/notifications-webhook-teams.ps1` | Adaptive Card 1.6 payload builder |
| Notifications (Slack) | `src/notifications-webhook-slack.ps1` | Block Kit payload builder |
| Notifications (Discord) | `src/notifications-webhook-discord.ps1` | Embeds payload builder |
| Notifications (HTML) | `src/notifications-html.ps1` | Standalone HTML scan report artifact |
| Notifications (errors) | `src/notifications-error.ps1` | Separate channel for component-level scan failures |
| Upstream check | `src/Send-UpstreamUpdate.ps1` | Notifies when a newer PIM Monitor release is available |
| Pipeline definition | `monitor-pipeline.yml` | Schedule, authentication task, artifact publish |

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
- `AzurePowerShell@5` provides first-class WIF token acquisition via `Get-AzAccessToken -ResourceTypeName MSGraph`.
- Graph API is called via `Invoke-RestMethod` directly — no SDK installation or version pinning required.
- Maester.dev has proven this model at scale for Azure DevOps-based security monitoring.

### 5.5 Deterministic JSON

The Graph API does not guarantee property order. PowerShell's `ConvertTo-Json` preserves insertion order. Without normalization, every scan run would produce a different byte sequence for identical API data, causing false-positive git diffs on every run.

All inventory file writes go through `ConvertTo-DeterministicJson` (in `helpers.ps1`), which:
1. Sorts object keys alphabetically, recursively.
2. Sorts arrays by `id` field (or value for string arrays).
3. Strips `@odata.*` metadata properties.
4. Uses 2-space indentation, UTF-8 without BOM.

---

## 6. Design Principles & Quality Guidelines

### 6.1 Modularity

The codebase is built from **loosely coupled modules** that each have exactly one responsibility:

```
monitor-pipeline.yml
        |
        v
Scan-PimState.ps1          (orchestrator — no business logic)
        |
        +-- graphEndpoints.ps1         (URI construction only)
        |
        +-- helpers.ps1                (I/O, JSON, pagination)
        |
        +-- diff.ps1                   (change detection, severity)
        |
        +-- compliance.ps1             (access model evaluation)
        |
        +-- git.ps1                    (commit + push)
        |
        +-- notifications-shared.ps1   (shared rendering helpers)
        |
        +-- notifications-email.ps1
        +-- notifications-webhook.ps1  (dispatcher)
        +-- notifications-webhook-teams.ps1
        +-- notifications-webhook-slack.ps1
        +-- notifications-webhook-discord.ps1
        +-- notifications-html.ps1
        +-- notifications-error.ps1
```

**Guidelines:**
- Modules communicate only via function parameters and return values — never via shared mutable global state.
- The orchestrator (`Scan-PimState.ps1`) composes modules; individual modules do not call each other. The one exception is `diff.ps1` calling `ConvertTo-DeterministicJson` from `helpers.ps1`, which is why `helpers.ps1` is always sourced first.
- New data sources (e.g. security alerts, pending requests — see [Future Phases](#15-future-phases)) can be added as their own fetch/diff path without modifying existing modules.

**Notification scaling rule — one channel = one file:**

When adding a new webhook target (Mattermost, PagerDuty, n8n, etc.):
1. Create `src/notifications-webhook-<platform>.ps1` with `Build-<Platform>Payload`.
2. Add a URL-pattern match to `Get-WebhookType` in `notifications-webhook.ps1`.
3. Add a `switch` case in `Send-WebhookNotification` and `notifications-error.ps1`.
4. Dot-source the new file in `Scan-PimState.ps1` before `notifications-webhook.ps1`.

Never add a second payload builder to an existing channel file. The cost of one extra file is dwarfed by the cost of editing a 700-line file where unrelated builders share a namespace.

### 6.2 Clean Code

| Principle | Application in PIM Monitor |
|---|---|
| **Meaningful Names** | `Compare-PolicyRules` not `Check-Policy`; `Get-InventorySlug` not `Slugify`; `Group-ChangesBySeverity` not `Sort-Changes` |
| **Approved Verbs** | PowerShell approved verbs throughout: `Get-`, `Compare-`, `Save-`, `Publish-`, `Send-`, `Export-`, `Build-`, `Move-`, `Test-`, `Convert-` |
| **Small Functions** | Functions do one thing; complex operations are split into named helper functions |
| **DRY** | Shared diff-rendering helpers (`Format-DiffValue`, `Get-ChangeDiffRows`) live in `notifications-shared.ps1` and are called by all channels — never duplicated as inline closures |
| **StrictMode** | `Set-StrictMode -Version Latest` enforced throughout; null-conditional `?.` is used with explicit null-check fallbacks for multi-level property chains |
| **Error Handling** | Never `catch { }` (empty catch). Every caught error is logged and appended to `$scanErrors` |

**Naming conventions:**

```powershell
# Files
diff.ps1                          # {concern}.ps1
notifications-webhook-teams.ps1   # notifications-{channel}-{platform}.ps1

# Functions (Verb-Noun, PowerShell approved verb)
Compare-PolicyRules
Get-InventorySlug
ConvertTo-DeterministicJson
Test-IsPimGroupWrapper

# Variables
$scanErrors                       # camelCase for local/script scope
$script:DiffIgnoreProperties      # $script: prefix for module-level state
$script:SeverityRank              # $script: prefix for module-level lookup tables
```

### 6.3 No Silent Failure

Every component failure is captured — never swallowed.

- Each module appends failures to the shared `$scanErrors` collection in the orchestrator.
- A single role's policy fetch failing does not abort the scan. The error is collected and `Send-ScanErrorNotification` fires at the end of the run, independently of the change notification.
- Empty catch blocks (`catch { }`) are forbidden. A swallowed error is invisible in pipeline logs and defeats the monitoring purpose of the tool.
- Partial success is valid: if 143 of 144 roles succeed, the scan commits the 143 and reports the failure for the 144th.

---

## 7. Quality Attributes (NFRs)

| Attribute | Goal | How Achieved |
|---|---|---|
| **Correctness** | No false positives, no missed changes | Deterministic JSON; full fetch (no delta); `-in .Keys` instead of `.ContainsKey()` for `OrderedDictionary` compatibility (PS 7.3+) |
| **Idempotency** | Two successive runs with no tenant changes produce no git commit and no notification | Byte-for-byte identical JSON output via `ConvertTo-DeterministicJson`; git commit only when staged changes exist |
| **Auditability** | Complete change history, queryable externally | One git commit per scan with ISO timestamp; `git log` and `git diff` expose the full timeline; ADO Git REST API queryable by PIM Manager |
| **Security** | No credentials in code or pipeline variables | Workload Identity Federation; OIDC token never stored; no `CLIENT_SECRET` |
| **Reliability** | Handles Graph throttling and push conflicts | Exponential backoff with jitter (`Invoke-WithRetry`); push-with-rebase on conflict |
| **Maintainability** | Declarative severity rules; modular notification channels | Lookup tables in `diff.ps1`; one file per channel; shared helpers in `notifications-shared.ps1` |
| **Extensibility** | New API fields appear automatically; new channels added without touching existing files | Full response storage (no `$select`); one-channel-one-file rule |
| **Observability** | Pipeline logs show scan progress at each step | Timestamped `Write-Host` throughout; `Export-ScanReport` HTML artifact; `Send-ScanErrorNotification` for component failures |

---

## 8. Architectural Decision Records (ADRs)

Key decisions documented for future maintainers:

| # | Decision | Status | Rationale |
|---|---|---|---|
| ADR-001 | **Azure DevOps Pipelines** over Azure Functions | ✅ Accepted | No extra infrastructure; enterprise familiarity; WIF native in `AzurePowerShell@5` |
| ADR-002 | **Git as state store** (no external DB) | ✅ Accepted | Audit trail for free; no Blob/Cosmos setup; queryable via ADO Git REST API |
| ADR-003 | **Full fetch + diff** over delta queries | ✅ Accepted | Self-healing on missed runs; no delta token persistence; data volume is small |
| ADR-004 | **PowerShell** over Bash/Python | ✅ Accepted | Native on ubuntu-latest; `AzurePowerShell@5` WIF integration; proven by Maester.dev |
| ADR-005 | **`ConvertTo-DeterministicJson`** for all inventory writes | ✅ Accepted | Prevents false-positive git diffs from Graph API property order changes |
| ADR-006 | **One notification channel = one file** | ✅ Accepted | Each channel evolves independently; avoids 700-line multi-builder files |
| ADR-007 | **`ConvertFrom-Json -AsHashtable`** returns `OrderedDictionary` in PS 7.3+ | ⚠️ Risk Accepted | Use `-in $dict.Keys` instead of `$dict.ContainsKey($k)` everywhere dicts originate from JSON parsing |
| ADR-008 | **No Microsoft.Graph SDK**; plain `Invoke-RestMethod` | ✅ Accepted | Eliminates install/cache pipeline step; `Az.Accounts` token via `Get-AzAccessToken` works directly |
| ADR-009 | **`Set-StrictMode -Version Latest`** throughout | ✅ Accepted | Catches undefined variables and null-access at runtime rather than silently returning `$null` |
| ADR-010 | **`ThrottleLimit 5` + per-thread `Invoke-WithRetry`**, no shared backpressure | ✅ Accepted | Data volume is small; ThrottleLimit was empirically tuned down from 8 to 5 to reduce sustained Graph 429s. Sharing backpressure state across isolated `-Parallel` runspaces requires synchronization primitives that add complexity and risk to the critical fetch path. If structural 429-throttling persists despite ThrottleLimit 5 (visible as repeated retry-wait lines in pipeline logs or scan durations exceeding 5 minutes), revisit with a coordinated semaphore or lower ThrottleLimit. |

---

## 9. Security Architecture

### Data Classification

| Data | Sensitivity | Storage | Lifetime |
|---|---|---|---|
| Graph API access token | High | Memory only (pipeline agent) | Single scan run |
| Inventory files (PIM state) | Medium | Git repository | Permanent (audit history) |
| Webhook URL | Medium | Pipeline secret variable | Permanent |
| Notification email address | Low | Pipeline variable | Permanent |

Inventory files contain PIM role assignments and policy configurations — not access tokens, passwords, or personal data beyond display names and UPNs already present in your Entra tenant.

### Security Principles

1. **No client secrets.** Authentication is via Workload Identity Federation. The OIDC token is short-lived (10 minutes), issued by Azure DevOps, and never stored anywhere.
2. **Least privilege.** The App Registration holds read-only permissions for all PIM data. `Mail.Send` is the only write permission and can be scoped to a single sender mailbox via an [application access policy](https://learn.microsoft.com/en-us/graph/auth-limit-mailbox-access).
3. **No data exfiltration.** The only outbound writes are: git push to the same repository, email via Graph `sendMail`, and HTTP POST to the configured webhook URL. No third-party services are contacted.
4. **No agent-local secrets.** Pipeline variables marked as secret are masked in logs. The scan script never logs token values or webhook URLs.

### Data in Transit

- **HTTPS only.** All Graph API calls and webhook POSTs are HTTPS. Git push uses HTTPS with the ADO service connection credential.
- **No data stored on agents.** Hosted agents are ephemeral; all state lives in the git repository.

---

## 10. Constraints

- **PowerShell 7.x required.** `Set-StrictMode -Version Latest` is enforced. The `?.` null-conditional operator and `-AsHashtable` on `ConvertFrom-Json` are 7.x features.
- **`AzurePowerShell@5` task.** Authentication is tied to this task type; changing to a different task type requires reworking token acquisition.
- **Az.Accounts 3.0+ returns `SecureString`.** `Get-AzAccessToken` returns `.Token` as a `SecureString` on newer SDK versions. The codebase unwraps it via `NetworkCredential`.
- **One branch: `main`.** The pipeline always pushes to `origin HEAD:main`. Multi-branch deployments are not currently supported.
- **Hosted agent is ephemeral.** The only state that survives between runs is the git repository. Do not rely on agent-local files.

---

## 11. Architecture Layers

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
        |                          Get-InventorySlug, Get-ObjectKeys,
        |                          Get-AssignmentEndDateTime, Test-IsPimGroupWrapper)
        |
        +-- diff.ps1              (Compare-InventoryFolder, Compare-PolicyRules,
        |                          Compare-Assignments, Compare-FlatProperties,
        |                          Find-ExpiringAssignments, Test-ChangeIsExpected,
        |                          Group-ChangesBySeverity)
        |
        +-- compliance.ps1        (Get-ComplianceViolations, Get-GroupComplianceViolations,
        |                          Get-AuthContextPolicyCompliance,
        |                          Get-CoverageViolations, Get-GroupCoverageViolations)
        |
        +-- git.ps1               (Publish-InventoryChanges, Get-StagedChanges,
        |                          Get-InventoryFileFromGit)
        |
        +-- notifications-shared.ps1   (Format-DiffValue, Test-DiffScalar,
        |                               Get-DiffPropertyRows, Get-ChangeDiffRows,
        |                               Get-ExecutiveSummaryLine, Format-ChangeSummaryText,
        |                               Get-CommitDiffUrl, Get-ArtifactReportUrl)
        |
        +-- notifications-email.ps1         (Build-EmailChangeHtml, Send-EmailNotification)
        +-- notifications-webhook.ps1       (Get-WebhookType, Send-WebhookNotification,
        |                                    Build-GenericPayload)
        +-- notifications-webhook-teams.ps1  (Build-TeamsPayload)
        +-- notifications-webhook-slack.ps1  (Build-SlackPayload)
        +-- notifications-webhook-discord.ps1 (Build-DiscordPayload)
        +-- notifications-html.ps1           (Build-HtmlReport, Export-ScanReport)
        +-- notifications-error.ps1          (Send-ScanErrorNotification)
```

Each module has a single responsibility. The orchestrator composes them; individual modules do not call each other.

> [!NOTE]
> `diff.ps1` references `ConvertTo-DeterministicJson` from `helpers.ps1`. Module load order in the orchestrator is therefore: `helpers.ps1` first, then the rest in any order.

---

## 12. State Model

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
├── conditional-access/        (CA policies targeting authentication contexts)
│   └── {policy-slug}/
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
- NFD-normalized, then non-ASCII characters removed (diacritics stripped: "Café" → "cafe").
- Lowercased.
- Non-word characters (except spaces and hyphens) removed.
- Spaces and consecutive hyphens collapsed to a single hyphen.
- Leading and trailing hyphens stripped.

Example: `"Global Administrator"` → `"global-administrator"`.

---

## 13. Scan Run Lifecycle

1. **Module import.** `Scan-PimState.ps1` dot-sources all modules in dependency order.
2. **Token acquisition.** `Get-AzAccessToken -ResourceTypeName MSGraph` via the `AzurePowerShell@5` task context. Token is unwrapped from `SecureString` via `NetworkCredential`.
3. **Lookup fetches.** Authentication contexts, Conditional Access policies, and administrative units fetched and inventoried.
4. **Activation events.** PIM audit log events since the last recorded event appended to the current month file.
5. **Directory Roles.** All role definitions fetched; policies and assignments fetched in parallel per role (ThrottleLimit 5). Results post-processed sequentially for diff and write.
6. **PIM Groups.** All PIM-onboarded groups discovered; policies and assignments fetched per group sequentially.
7. **Expiring assignments.** All assignment sets scanned for entries expiring within `EXPIRING_WINDOW_DAYS` (default 14).
8. **Expected-change filtering.** Changes matching entries in `expected-changes.json` are suppressed; expired and consumed entries cleaned up.
9. **Access model compliance.** When `AccessModel/` folder is present: role and group compliance violations evaluated against tier definitions; CA policy compliance evaluated against auth context requirements. Violations added to the change set.
10. **Severity grouping.** `Group-ChangesBySeverity` aggregates all changes into High / Medium / Low / Informational buckets.
11. **Git commit.** `Publish-InventoryChanges` stages `inventory/`, commits with `scan: {timestamp}`, pushes to `origin HEAD:main`.
12. **HTML report** (optional). Written to `$BUILD_ARTIFACTSTAGINGDIRECTORY` when `REPORT_ARTIFACT=true`.
13. **Notifications.** Email and/or webhook sent if changes meet the minimum severity threshold.
14. **Scan error notification.** If `$scanErrors` is non-empty, `Send-ScanErrorNotification` fires independently of step 13.

---

## 14. External Interfaces

| Interface | Direction | Protocol | Purpose |
|---|---|---|---|
| Microsoft Graph API | Outbound | HTTPS REST | Fetch PIM state |
| Azure DevOps Git | Inbound/outbound | HTTPS Git | Checkout and push inventory |
| Graph sendMail | Outbound | HTTPS REST | Email notifications |
| Webhook URL | Outbound | HTTPS POST | Teams / Slack / Discord / custom notifications |
| ADO Git REST API | Inbound (from PIM Manager) | HTTPS REST | Change timeline consumed by PIM Manager |

---

## 15. Future Phases

| Phase | Feature | Notes |
|---|---|---|
| 4 | Audit log actor attribution | `GET /auditLogs/directoryAudits` — who made a change |
| 4 | Security alerts | `GET /identityGovernance/roleManagementAlerts/alerts` (beta-only) |
| 4 | Pending requests | `GET /roleManagement/directory/roleEligibilityScheduleRequests` |
| Future | Custom alerting rules | Notify only for specific roles/change types |
| Future | Self-hosted agent docs | For tenants that require private network access |
| Future | Delta queries | Only relevant if full fetch becomes a performance concern |
