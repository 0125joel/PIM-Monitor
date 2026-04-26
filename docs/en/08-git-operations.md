# 08 — Git Operations

## Table of Contents

1. [Overview](#1-overview)
2. [Commit Strategy](#2-commit-strategy)
3. [Push and Conflict Resolution](#3-push-and-conflict-resolution)
4. [Commit Message Format](#4-commit-message-format)
5. [Git History as Audit Trail](#5-git-history-as-audit-trail)
6. [Reading History: Get-InventoryFileFromGit](#6-reading-history-get-inventoryfilefromgit)
7. [Staging: Get-StagedChanges](#7-staging-get-stagedchanges)
8. [Pipeline Git Configuration](#8-pipeline-git-configuration)

---

## 1. Overview

Git operations in PIM Monitor serve two purposes:

1. **State persistence**: the checkout of the repo at the start of each pipeline run provides the previous PIM state for diffing. Writing updated inventory files and committing them persists the new state for the next run.

2. **Audit trail**: every commit represents a point-in-time snapshot of PIM configuration. External tools (PIM Manager, scripts, analysts) can query this history via the Azure DevOps Git REST API.

All git operations are encapsulated in `src/git.ps1` and called from `Scan-PimState.ps1`.

---

## 2. Commit Strategy

`Publish-InventoryChanges` is called only when `$changesBySeverity.Total > 0`. If the scan detects no changes, no commit is made and the pipeline run produces no git output.

Within `Publish-InventoryChanges`:

1. **Stage only the inventory folder**: `git add inventory/`. Files outside `inventory/` are never staged by the pipeline.
2. **Check for changes**: `git diff --cached --quiet`. Exit code 0 means no staged changes; the function returns early with `committed = $false`.
3. **Commit**: `git commit -m "scan: {timestamp}"`.
4. **Push**: `git push origin HEAD:main`.
5. **Retry on rejection**: if the push fails (another run committed in between), fetch and rebase, then push again.

The function returns `@{ committed; message; commitSha }`. The commit SHA is passed to notification functions to construct diff links.

---

## 3. Push and Conflict Resolution

Because the pipeline runs on a schedule, two runs can overlap. The checkout of Run B happens after Run A's checkout but before Run A's push. When Run B tries to push, origin has moved forward.

```
Run A: checkout → scan → commit → push (succeeds)
Run B: checkout → scan → commit → push (REJECTED: non-fast-forward)
                                          │
                                          └── git fetch origin main
                                              git rebase origin/main
                                              git push origin HEAD:main
```

The rebase strategy is preferred over a merge commit because it keeps the history linear. Each scan commit is a standalone point-in-time snapshot; merge commits add noise to the timeline.

> [!CAUTION]
> If the rebase fails (a genuine conflict between the two scan commits), `Publish-InventoryChanges` throws and the pipeline step fails. This should not happen in normal operation because no two scans modify the same file in incompatible ways — both scans write deterministic JSON and the second scan's version of a file is always a full overwrite, not a partial edit. If it does occur, investigate whether a manual commit was made to `inventory/` while the pipeline was running.

---

## 4. Commit Message Format

```
scan: 2026-04-25T10:30:00Z
```

The format is `scan: {ISO 8601 UTC timestamp}`. This is intentionally machine-parseable: PIM Manager's change timeline reads the timestamp from the commit message to display when each scan occurred.

> [!IMPORTANT]
> Do not change the commit message format. PIM Manager parses `scan: ` as a prefix to extract the timestamp. See [11-pim-manager-integration.md](11-pim-manager-integration.md).

The git user is configured as:
- `user.name`: `PIM Monitor`
- `user.email`: `pim-monitor@pipeline`

This is set immediately before staging in `Publish-InventoryChanges`. It is also set as a separate pipeline step (`Configure git user`) before the bash commit step, because both the PowerShell task and the bash script step may commit.

---

## 5. Git History as Audit Trail

The history of `inventory/` in the repository is the primary audit record. Each scan commit captures a complete snapshot of what changed.

### What the history shows

- **Which file changed**: the path `inventory/directory-roles/global-administrator/policy.json` tells you it was a policy change on the Global Administrator role.
- **What changed**: `git diff {commitA} {commitB} -- inventory/directory-roles/global-administrator/policy.json` shows the exact JSON diff (old vs new property values).
- **When it changed**: the commit timestamp.
- **How many changes**: the number of files in the commit.

### What the history does not show (yet)

- **Who made the change** in Entra ID: actor attribution requires querying `GET /auditLogs/directoryAudits` (Phase 4 feature).
- **Why** it was changed: context comes from external processes (change management tickets, etc.).

### Querying the history via Azure DevOps REST API

```
# List scan commits
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/commits
    ?searchCriteria.itemPath=/inventory/
    &api-version=7.1

# Diff between two commits
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/diffs/commits
    ?baseVersion={commitA}
    &targetVersion={commitB}
    &api-version=7.1

# Read a specific file at a specific commit
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
    ?path=/inventory/directory-roles/global-administrator/policy.json
    &version={commitId}
    &api-version=7.1
```

See [11-pim-manager-integration.md](11-pim-manager-integration.md) for the full REST API integration spec.

---

## 6. Reading History: Get-InventoryFileFromGit

`Get-InventoryFileFromGit` reads the content of an inventory file at a specific git ref, using `git show`:

```powershell
Get-InventoryFileFromGit -Path "inventory/directory-roles/global-administrator/definition.json" -Ref "HEAD~1"
```

This is used for historical diffing within the pipeline itself. It returns a parsed `PSCustomObject` (via `ConvertFrom-Json`), or `$null` if the file did not exist at that ref.

> [!NOTE]
> This function is not currently called in the main scan flow. The scan reads inventory files directly from disk (the checked-out working tree), which represents the state at the last commit. `Get-InventoryFileFromGit` is available for use in diagnostic scripts or future features that need to compare across more than one scan interval.

---

## 7. Staging: Get-StagedChanges

`Get-StagedChanges` returns the list of staged files with their change status (`A` = added, `M` = modified, `D` = deleted), using `git diff --cached --name-status`.

```powershell
$changes = Get-StagedChanges
# Returns: @( @{ Status = "M"; Path = "inventory/directory-roles/..." }, ... )
```

Currently not called in the main scan flow. Available for use in notification functions that want to include a file-change list in addition to the semantic change descriptions.

---

## 8. Pipeline Git Configuration

The `monitor-pipeline.yml` checkout step requires `persistCredentials: true` for the push to work:

```yaml
- checkout: self
  persistCredentials: true
```

Without this, the git credential helper is not configured and `git push` fails with an authentication error.

The bash commit step in the pipeline handles the case where the PowerShell scan completed but the push was not done via `Publish-InventoryChanges` (e.g., because the pipeline was interrupted after writing inventory files but before the git step in the PowerShell task). Both the PowerShell task and the bash commit step run with `condition: always()` to ensure cleanup happens even on failure.

> [!NOTE]
> The bash commit step and the PowerShell `Publish-InventoryChanges` function can both commit. In normal operation, only one of them commits: if `Publish-InventoryChanges` already committed and pushed, `git add inventory/ && git diff --cached --quiet` in the bash step finds nothing staged and exits cleanly.
