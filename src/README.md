# PIM Monitor: PowerShell Scripts

## Overview

PIM Monitor runs as an Azure DevOps Pipeline. Each scan:
1. Fetches current PIM state from Graph API
2. Compares it against inventory files
3. Detects and classifies changes by severity
4. Writes updated inventory files (deterministic JSON)
5. Commits and pushes changes to the repo
6. Sends notifications (Phase 2)

## Script Organization

| Script | Responsibility |
|---|---|
| `Scan-PimState.ps1` | Main pipeline script (entry point). Orchestrates fetch → diff → write → notify. |
| `helpers.ps1` | Utility functions: deterministic JSON, pagination, slug generation, inventory I/O |
| `graphEndpoints.ps1` | Centralized Graph API URIs and per-item URI builders |
| `diff.ps1` | Rule-based change detection and severity classification |
| `git.ps1` | Git operations (commit, push, history reads) |
| `notifications.ps1` | Email (Graph sendMail) + webhook (Teams/Slack/Discord/generic) delivery |

### Why this split?

- **`graphEndpoints.ps1`**: all Graph API URIs in one place. Makes v1.0/beta management easy (move from beta → v1.0 = one line change). New endpoints added in Phase 2 go here too.
- **`diff.ps1`**: declarative rule-based severity. Add a new severity rule = add a line to `$PolicyRuleSeverity` hashtable. No code changes needed.
- **`helpers.ps1`**: pure utilities, no domain logic. Reused everywhere.

## Inventory Structure

```
inventory/
├── directory-roles/{slug}/            # definition.json, policy.json, assignments.json
├── pim-groups/{slug}/                 # same three files (Phase 2)
├── authentication-contexts/{slug}/    # definition.json only (lookup)
└── administrative-units/{slug}/       # definition.json only (lookup)
```

**Lookups** (`authentication-contexts`, `administrative-units`) exist so consumers can resolve IDs (e.g., `claimValue: "c1"` → `"Require MFA"`) without additional Graph API calls. Same per-entity folder pattern as roles/groups. Git diffs show exactly which entity changed.

## Severity Classification (diff.ps1)

Severity is **rule-based**, not property-based. The `$PolicyRuleSeverity` hashtable maps rule ID prefixes to severity:

| Rule ID prefix | Severity | What it controls |
|---|---|---|
| `Enablement_EndUser_Assignment` | High | MFA, justification, ticketing on activation |
| `Approval_EndUser_Assignment` | High | Approval requirement + approvers |
| `AuthenticationContext_EndUser_Assignment` | High | Conditional Access auth context |
| `Expiration_EndUser_Assignment` | Medium | Max activation duration |
| `Expiration_Admin_Eligibility` | Medium | Eligible assignment max duration |
| `Expiration_Admin_Assignment` | Medium | Active assignment max duration |
| `Enablement_Admin_Assignment` | Medium | MFA, justification on direct assignment |
| `Enablement_Admin_Eligibility` | Medium | Requirements for creating eligible assignments |
| `Notification_` | Low | All 9 notification rules |

**To add a new rule:** add a line to the hashtable. No diff engine changes needed.

**Assignment changes** classify by category and expiration:
- New permanent (no-expiration) assignment → **High**
- New eligible/active assignment with expiration → **Medium**
- Assignment removed/expired → **Low**

**Definition changes**:
- `rolePermissions` changed → **High** (what the role can do changed)
- Other properties (displayName, description) → **Low**

## Data Flow

```
┌────────────────────┐
│  Graph API         │ ← graphEndpoints.ps1 (URI config)
└─────────┬──────────┘
          │
          ↓  helpers.ps1: Get-AllGraphItems (pagination)
┌────────────────────┐
│  Fetched objects   │ (in memory)
└─────────┬──────────┘
          │
          ↓  diff.ps1: Compare-InventoryFolder
┌────────────────────┐
│  Old files on disk │ ← Read-PreviousInventoryFile
└─────────┬──────────┘
          │
          ↓  diff.ps1: Compare-PolicyRules / Compare-Assignments
┌────────────────────┐
│  Change list with  │
│  severity labels   │
└─────────┬──────────┘
          │
          ↓  helpers.ps1: Save-InventoryFile (deterministic JSON)
┌────────────────────┐
│  Inventory files   │ (overwritten)
└─────────┬──────────┘
          │
          ↓  Pipeline YAML: git add + commit + push
┌────────────────────┐
│  Git history       │ (= audit trail)
└────────────────────┘
```

## Phase 1 Status

| Task | Status |
|---|---|
| Repo structure + CLAUDE.md | ✅ |
| `helpers.ps1` utilities | ✅ |
| `graphEndpoints.ps1` centralized URIs | ✅ |
| `diff.ps1` rule-based severity | ✅ |
| Lookup inventories (auth contexts, AUs) | ✅ |
| Directory Roles fetch (definition, policy, assignments with `$expand=principal`) | ✅ |
| Pipeline YAML (`monitor-pipeline.yml`) | ✅ |
| End-to-end test against a real tenant | 🔲 |

## Phase 2 Tasks

- [x] PIM Groups scanning (discover via schedule instances, fetch per-group definition/policy/assignments)
- [x] Email notifications via Graph `sendMail`
- [x] Webhook notifications (Teams, Slack, Discord, custom)
- [ ] Documentation site (Docusaurus + GitHub Pages + Cloudflare)

### Notification env vars

| Variable | Purpose |
|---|---|
| `NOTIFICATION_EMAIL` | Recipient address (required to enable email) |
| `NOTIFICATION_MAIL_FROM` | Sender UPN/address (service principal needs `Mail.Send`) |
| `NOTIFICATION_WEBHOOK_URL` | Webhook endpoint. Shape auto-detected from URL |
| `NOTIFICATION_MIN_SEVERITY` | `High`, `Medium`, or `Low` (default `Medium`) |

### PIM Groups inventory shape

```
pim-groups/{slug}/
├── definition.json       # group object
├── policy.json           # { member: <policyAssignment>, owner: <policyAssignment> }
└── assignments.json      # { eligible: [...], active: [...] }  (accessId on each entry)
```

The member/owner wrapper in `policy.json` is handled transparently by `Compare-PolicyRules`. It detects the wrapper and recurses per access type.

## Naming Conventions

- **Scripts:** PascalCase for entry points (`Scan-PimState.ps1`), lowercase for modules (`helpers.ps1`, `diff.ps1`)
- **Functions:** Verb-Noun (`Get-InventoryChanges`, `Save-InventoryFile`, `Compare-PolicyRules`)
- **Parameters:** PascalCase (`-InputObject`, `-FolderPath`, `-RoleId`)
- **Variables:** camelCase (`$inventoryRoot`, `$roleDefinitions`, `$allChanges`)
- **Script-scoped config:** `$script:` prefix (e.g., `$script:GraphEndpoints`, `$script:PolicyRuleSeverity`)
