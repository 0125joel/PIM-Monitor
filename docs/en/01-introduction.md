# 01 — Introduction

## Table of Contents

1. [What Is PIM Monitor](#1-what-is-pim-monitor)
2. [Problem It Solves](#2-problem-it-solves)
3. [How It Works](#3-how-it-works)
4. [Target Audience](#4-target-audience)
5. [What PIM Monitor Is Not](#5-what-pim-monitor-is-not)
6. [Prerequisites](#6-prerequisites)
7. [Relationship to PIM Manager](#7-relationship-to-pim-manager)

---

## 1. What Is PIM Monitor

PIM Monitor is a **scheduled Azure DevOps pipeline** that continuously monitors Microsoft Entra ID Privileged Identity Management (PIM) for changes to:

- Directory role definitions (permissions, enabled/disabled state)
- PIM policies (MFA requirements, approval workflows, activation duration)
- Role assignments (permanent, eligible, active)
- PIM Group membership (member and owner assignments)
- Lookup entities: authentication context class references and administrative units

When a change is detected, PIM Monitor:
1. Updates the inventory files in the repository (one JSON file per data category per entity).
2. Commits the changes with a timestamp (`scan: 2026-04-25T10:00:00Z`).
3. Optionally sends a notification via email and/or webhook.

The repository history becomes a **complete, queryable audit trail** of every PIM configuration change over time.

---

## 2. Problem It Solves

| Gap in Entra ID PIM | How PIM Monitor addresses it |
|---|---|
| No proactive alerting on role assignment changes | Detects and notifies within the configured scan interval |
| No alerting on policy weakening (e.g., MFA disabled) | Diffs policy rules per role; classifies severity |
| Audit log has retention limits and requires manual querying | Git history is permanent and queryable via REST API |
| No structured diff view: "what exactly changed?" | Git diff shows old vs new JSON values for every property |
| Configuration drift goes unnoticed | Every scan captures the full state; drift accumulates as commits |

---

## 3. How It Works

```
Azure DevOps Pipeline (every 30 min, configurable)
  │
  ├─ 1. Checkout repo ──── inventory/ contains the previous state
  │
  ├─ 2. Authenticate ────── WIF: OIDC token exchange, no client secret
  │
  ├─ 3. Fetch state ─────── Microsoft Graph API (full fetch, all roles/groups)
  │
  ├─ 4. Diff ────────────── new state vs inventory files
  │
  ├─ 5. Classify ────────── each change gets High / Medium / Low / Informational
  │
  ├─ 6. Write inventory ─── update JSON files (create / update / delete folders)
  │
  ├─ 7. Commit & push ───── only if files changed; message: "scan: {timestamp}"
  │
  └─ 8. Notify ──────────── email and/or webhook (if configured)
```

---

## 4. Target Audience

This documentation is for:

- **Administrators** setting up or maintaining PIM Monitor in an Azure DevOps project.
- **Developers** extending PIM Monitor (new notification channels, additional inventory categories, custom severity rules).
- **Integrators** building on PIM Monitor's git history (e.g., PIM Manager's `/monitor` page).

Basic familiarity is assumed with: Azure DevOps Pipelines, Microsoft Entra ID, PowerShell 7, and Microsoft Graph API fundamentals.

---

## 5. What PIM Monitor Is Not

- **Not a real-time system.** It polls on a schedule. The minimum practical interval is the Azure DevOps scheduler minimum (approximately 5 minutes). Changes between scans are batched into one commit.
- **Not a SIEM.** It detects and records changes; it does not correlate, investigate, or respond to threats.
- **Not a remediation tool.** PIM Monitor does not modify PIM configuration. It is read-only with respect to Entra ID.
- **Not a CLI or web application.** It runs unattended in a pipeline. There is no interactive interface.
- **Not a replacement for Entra audit logs.** It captures configuration state changes; it does not capture every individual action or actor attribution (actor attribution is a planned Phase 4 feature via `GET /auditLogs/directoryAudits`).

---

## 6. Prerequisites

| Requirement | Details |
|---|---|
| Azure DevOps project | Free tier sufficient (1800 pipeline minutes/month) |
| App Registration | Required application permissions + admin consent (see [09-authentication.md](09-authentication.md)) |
| WIF Service Connection | Federated credentials on the App Registration (see [09-authentication.md](09-authentication.md)) |
| PowerShell 7.x | Provided by the `ubuntu-latest` hosted agent — no setup required |
| Microsoft.Graph module | Installed in the pipeline by a `PowerShell@2` step (see [10-pipeline.md](10-pipeline.md)) |

Optional for notifications:

| Optional Requirement | Required When |
|---|---|
| `Mail.Send` permission on App Registration | Email notifications are configured |
| Notification mailbox in the tenant | Email notifications via Graph `sendMail` |
| Webhook URL | Teams / Slack / Discord / custom webhook notifications |

---

## 7. Relationship to PIM Manager

PIM Monitor is a **standalone project**. It has no code dependency on PIM Manager and can be deployed and operated independently.

The connection point is the **inventory file format** stored in git. PIM Manager's planned `/monitor` page consumes the change timeline by reading commit history via the Azure DevOps Git REST API. PIM Monitor guarantees the inventory structure as a versioned contract; PIM Manager adapts its parser to it.

See [11-pim-manager-integration.md](11-pim-manager-integration.md) for the full integration contract.
