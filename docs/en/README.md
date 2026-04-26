# PIM Monitor — Developer Documentation

Technical reference for administrators and developers working on or with PIM Monitor.

---

## Contents

| # | Document | What it covers |
|---|---|---|
| [00](00-architecture.md) | Architecture | System design, design decisions, quality attributes |
| [01](01-introduction.md) | Introduction | Problem statement, solution, target audience, prerequisites |
| [02](02-folder-structure.md) | Folder Structure | Repository layout, every file and folder explained |
| [03](03-data-flow.md) | Data Flow | Scan run sequence, each processing step in detail |
| [04](04-graph-api.md) | Graph API | Endpoints, v1.0 vs beta, pagination, throttling |
| [05](05-inventory-format.md) | Inventory Format | JSON schema per file type, deterministic serialization |
| [06](06-change-detection.md) | Change Detection | Diff engine, severity classification, noise suppression |
| [07](07-notifications.md) | Notifications | Email and webhook channels, payload formats |
| [08](08-git-operations.md) | Git Operations | Commit strategy, push/rebase, history as audit trail |
| [09](09-authentication.md) | Authentication | Workload Identity Federation, token acquisition |
| [10](10-pipeline.md) | Pipeline | YAML anatomy, scheduling, variables, artifacts |
| [11](11-pim-manager-integration.md) | PIM Manager Integration | Inventory contract, ADO REST API, auth flow |

---

## Quick Reference

**Entry point:** `src/Scan-PimState.ps1` — orchestrates every scan run.

**Module load order:**
```
helpers.ps1 → graphEndpoints.ps1 → diff.ps1 → git.ps1 → notifications.ps1
```

**Inventory root:** `inventory/` — committed to git; the repo is the state store.

**Key constraint:** All JSON written via `ConvertTo-DeterministicJson` (in `helpers.ps1`).
Without it, every run produces false-positive diffs from property reordering.

**Authentication:** `AzurePowerShell@5` task with a WIF service connection.
No client secrets anywhere in the codebase.

---

## Getting Help

- Architecture decisions: [00-architecture.md](00-architecture.md)
- Something changed unexpectedly: [06-change-detection.md](06-change-detection.md)
- Notifications not sending: [07-notifications.md](07-notifications.md)
- Pipeline not running: [10-pipeline.md](10-pipeline.md)
- Auth errors: [09-authentication.md](09-authentication.md)
