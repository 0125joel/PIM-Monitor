# 11 — PIM Manager Integration

## Table of Contents

1. [Overview](#1-overview)
2. [The Inventory Contract](#2-the-inventory-contract)
3. [ADO Git REST API Endpoints](#3-ado-git-rest-api-endpoints)
4. [Commit Message Parsing](#4-commit-message-parsing)
5. [Authentication in PIM Manager](#5-authentication-in-pim-manager)
6. [Connection Setup Flow](#6-connection-setup-flow)
7. [PIM Manager Integration Points](#7-pim-manager-integration-points)
8. [Severity Rendering](#8-severity-rendering)
9. [What PIM Monitor Must Not Do](#9-what-pim-monitor-must-not-do)

---

## 1. Overview

PIM Monitor and PIM Manager are **independent projects** with no code dependency. PIM Monitor runs as a pipeline; PIM Manager is a web application. The only coupling is the **inventory file format** stored in the git repository.

PIM Manager's planned `/monitor` page reads the change timeline from the PIM Monitor repository via the Azure DevOps Git REST API. It does not need access to the pipeline, the pipeline variables, or the PIM Monitor source code. It needs only read access to the repository.

```
PIM Monitor repo (git)
        │
        │  Azure DevOps Git REST API
        │  (user's MSAL session, incremental consent)
        ▼
PIM Manager /monitor page
        │
        ├── List scan commits → timeline
        ├── Diff between commits → what changed
        └── Read file at commit → snapshot view
```

---

## 2. The Inventory Contract

The following guarantees are maintained by PIM Monitor as a versioned contract for consumers:

| Guarantee | Details |
|---|---|
| Folder structure | `inventory/directory-roles/{slug}/`, `inventory/pim-groups/{slug}/`, `inventory/authentication-contexts/{slug}/`, `inventory/administrative-units/{slug}/`, `inventory/activation-events/` |
| File names | Always `definition.json`, `policy.json`, `assignments.json` (or `definition.json` only for lookups) |
| JSON format | Sorted keys, sorted arrays, no `@odata.*` metadata, 2-space indent, UTF-8 no BOM |
| Full API response | No `$select` filtering; all Graph API fields present |
| One commit per scan | Each pipeline run produces at most one commit to `inventory/` |
| Commit message format | `scan: YYYY-MM-DDTHH:mm:ssZ` |

**Breaking changes** to any of the above require coordination with PIM Manager before deployment. Treat this as a versioned API.

> [!WARNING]
> Never change the commit message format, folder structure, or file name scheme without first updating PIM Manager's parser. PIM Manager derives the scan timestamp and identifies file types from these patterns.

---

## 3. ADO Git REST API Endpoints

PIM Manager uses these REST API calls to build the change timeline:

### List scan commits

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/commits
    ?searchCriteria.itemPath=/inventory/
    &api-version=7.1
```

Returns commits that touched at least one file under `inventory/`. PIM Manager filters these by commit message prefix `scan: ` to distinguish scan commits from manual commits or the initial setup commit.

### Diff between two commits

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/diffs/commits
    ?baseVersion={commitA}
    &targetVersion={commitB}
    &api-version=7.1
```

Returns the list of changed files with their change type (add / edit / delete). The file paths reveal the entity and file type (`inventory/directory-roles/global-administrator/policy.json` = policy change on Global Administrator).

### Read current inventory state

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
    ?path=/inventory/
    &recursionLevel=full
    &api-version=7.1
```

Returns a flat list of all files under `inventory/`, including their paths and content URLs. Used to build the current-state view.

### Read a file at a specific commit

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
    ?path=/inventory/directory-roles/global-administrator/policy.json
    &version={commitId}
    &api-version=7.1
```

Returns the raw JSON content of the file at the specified commit. Used to show the "before" and "after" state for a specific change.

---

## 4. Commit Message Parsing

PIM Manager parses the scan timestamp from the commit message:

```
"scan: 2026-04-25T10:30:00Z"
       └──────────────────── ISO 8601 UTC timestamp
```

The format is fixed. PIM Manager splits on `"scan: "` and parses the remainder as a datetime.

Manual commits pushed to `inventory/` by an operator (e.g., for corrections) will not match this prefix and will be displayed differently in the timeline (or excluded, depending on PIM Manager's filtering).

---

## 5. Authentication in PIM Manager

PIM Manager uses MSAL with **incremental consent**. The Azure DevOps API scope is requested only when the user enables the Monitor workload:

```
ADO API scope: 499b84ac-1321-427f-aa17-267ca6975798/.default
```

This is the Azure DevOps resource ID. Requesting this scope with `.default` grants access to all ADO REST API endpoints that the user has access to.

The user must have at least **Reader** access to the PIM Monitor repository in Azure DevOps. No additional permissions are needed beyond repo read access.

---

## 6. Connection Setup Flow

Before the `/monitor` page can fetch data, the user configures which repository to read from. Three values are required:

| Setting | Example | Source |
|---|---|---|
| Organization | `contoso` | ADO organization name |
| Project | `security-monitoring` | ADO project name |
| Repository | `pim-monitor` | ADO repository name |

PIM Manager constructs the API base URL as:
```
https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}
```

An optional shortcut: if the user pastes a DevOps repository URL
(`https://dev.azure.com/contoso/security-monitoring/_git/pim-monitor`),
PIM Manager can extract org, project, and repo from the URL pattern.

Configuration is stored in `localStorage` (client-side, no backend). PIM Monitor does not need to know about this configuration.

---

## 7. PIM Manager Integration Points

The following locations in PIM Manager are affected by the Monitor integration. This section documents what PIM Manager must implement; it is here for cross-reference, not as PIM Monitor instructions.

| Integration Point | PIM Manager Location | Description |
|---|---|---|
| Workload type | `types/workload.types.ts` | Add `"monitor"` to `WorkloadType` union |
| Auth scope | `hooks/useIncrementalConsent.ts` | Register ADO API scope |
| Service | `services/devopsService.ts` (new) | ADO Git REST API calls |
| Types | `types/monitor.types.ts` (new) | `MonitorChangeEntry`, `MonitorTimeline`, `DevOpsConfig` |
| Page | `app/monitor/page.tsx` (new) | Change timeline UI |
| Navigation | `components/Sidebar.tsx` | Add Monitor nav item |
| Workload chip | `components/WorkloadChips.tsx` | Toggle Monitor on/off |

The existing `withRetry()` helper in PIM Manager's service layer applies to ADO REST API calls as well. ADO does throttle under load.

---

## 8. Severity Rendering

PIM Monitor classifies changes by severity. PIM Manager's `/monitor` page should render these consistently:

| Severity | Suggested color | Examples |
|---|---|---|
| High | Red | MFA disabled, permanent assignment created, role removed from PIM |
| Medium | Orange/amber | Activation duration changed, new eligible assignment, assignment expiring |
| Low | Green | Notification settings changed, assignment expired/removed |
| Informational | Gray | New API property appeared, display name changed |

The severity for a specific change can be derived in two ways:
1. From the PIM Monitor notification payload (if PIM Manager receives webhooks from PIM Monitor).
2. By parsing the changed file path and JSON diff to classify the change independently (more complex but decoupled from notifications).

The simpler approach for the initial integration is to rely on file path classification:
- Path ends in `policy.json` with a changed `Enablement_EndUser_Assignment` rule → High
- Path ends in `assignments.json` with an added entry → Medium
- Path ends in `definition.json` with a changed `displayName` → Informational

---

## 9. What PIM Monitor Must Not Do

To keep the contract clean and the two projects independent:

- **No PIM Manager-specific formatting.** Inventory files store raw API data. PIM Manager formats it for display.
- **No awareness of PIM Manager types.** PIM Monitor does not import or reference any PIM Manager type definitions.
- **No commit structure changes for PIM Manager.** The commit message format and inventory folder structure are chosen for the audit trail. PIM Manager adapts to them.
- **No webhook to PIM Manager.** PIM Manager reads git history; it does not receive push notifications from PIM Monitor.
