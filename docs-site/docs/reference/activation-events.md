---
sidebar_position: 4
description: PIM activation and assignment events captured by PIM Monitor from the Entra audit log, including field reference and limitations.
---

# Activation Events

PIM Monitor archives activation and assignment change events from the Microsoft Graph audit log.

## Overview

During each scan, PIM Monitor fetches audit log entries logged by the PIM service since the last fetch. Events are organized into monthly files in the `inventory/activation-events/` directory.

Example file structure:
```
inventory/
└── activation-events/
    ├── 2026-04.json     # April events
    ├── 2026-03.json     # March events
    └── 2026-02.json     # February events
```

## Format

Each monthly file contains a JSON array of audit log entries:

```json
[
  {
    "id": "5fcdba1e-1234-1234-1234-123456789abc",
    "activityDateTime": "2026-04-20T14:30:00Z",
    "loggedByService": "PIM",
    "operationType": "Assign",
    "initiatedBy": {
      "user": {
        "id": "user-123",
        "displayName": "Alice Admin",
        "userPrincipalName": "alice@contoso.com"
      }
    },
    "targetResources": [
      {
        "id": "role-123",
        "displayName": "Global Administrator",
        "type": "Role"
      },
      {
        "id": "principal-456",
        "displayName": "Bob User",
        "type": "User"
      }
    ],
    "result": "Success",
    "resultReason": "Success"
  }
]
```

## High-Impact Events

The following event types indicate PIM assignments or policy changes:

- **Assign**: User assigned eligible or active role/group
- **Remove**: User removed from role/group
- **Activate**: User activated an eligible assignment
- **Deactivate**: User deactivated an active assignment
- **ApproveRequest**: Approver approved a role activation request
- **RejectRequest**: Approver rejected a role activation request
- **UpdatePolicy**: PIM policy rule updated

## How it Works

### First Run

On the first scan, PIM Monitor fetches events from the past 30 days (Graph API retention limit). These are saved to the current month's file (e.g., `2026-04.json`).

### Subsequent Runs (Same Month)

Subsequent scans fetch events since the last saved event (timestamp + 1 second). New events are merged with existing events using `id` as the deduplication key. Events are sorted by `activityDateTime` before saving.

### Month Boundary

When the calendar month changes (e.g., from April to May), a new monthly file is automatically created. Events from previous months are never modified.

### Retention

Monthly files are permanent archives. PIM Monitor does not delete them. You can manage retention via git cleanup policies or manual deletion if space is constrained.

## Accessing Events

### Via Git

Since events are stored as JSON in the repository, you can browse them directly:

```bash
git log -p inventory/activation-events/
grep -r "Activate" inventory/activation-events/
```

### Programmatically

Load and process events in PowerShell:

```powershell
$events = Get-Content "inventory/activation-events/2026-04.json" -Raw | ConvertFrom-Json
$events | Where-Object { $_.operationType -eq 'Activate' } | ForEach-Object {
    Write-Host "$($_.activityDateTime): $($_.initiatedBy.user.displayName)"
}
```

## Filtering and Analysis

### High-risk activations

```powershell
$events | Where-Object {
    $_.operationType -eq 'Activate' -and
    $_.targetResources[0].displayName -like '*Admin*'
} | ForEach-Object { Write-Host "$($_.activityDateTime): $($_.initiatedBy.user.displayName)" }
```

### Failed requests

```powershell
$events | Where-Object { $_.result -ne 'Success' }
```

### Approvals

```powershell
$events | Where-Object { $_.operationType -in @('ApproveRequest', 'RejectRequest') }
```

## Integration with Notifications

Activation events are included in PIM Monitor notifications as informational entries (independent of policy/assignment diffs). This allows admins to see a full audit trail in chat notifications without triggering alerts.

## Limitations

- Fetches only events logged by the PIM service (`loggedByService eq 'PIM'`).
- Graph API retains audit logs for up to 30 days. First scan recovers only the past 30 days.
- Event detail depends on the Graph API response. Some fields may be empty or null.
- No real-time stream. Events are fetched during each scheduled scan.

## Troubleshooting

**No events appearing:** Verify that PIM activation/assignment changes are happening in your tenant. The audit log may take a few minutes to appear.

**Duplicate events in a month file:** This should not happen due to deduplication by ID. If observed, manually clean the file or regenerate from git history.

**Missing events across month boundary:** Events are split by calendar month. Check both the old and new month's files if looking for events near midnight UTC.
