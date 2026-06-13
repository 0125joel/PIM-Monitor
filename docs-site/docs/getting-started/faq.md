---
sidebar_position: 4
description: Answers to common questions about PIM Monitor setup, authentication, Graph permissions, and pipeline behavior.
---

# FAQ

## Workload Identity Federation (WIF) Setup

### Do I need to manually enter the issuer and subject identifier, or does ADO generate them?

ADO generates both the **Issuer** and **Subject identifier** automatically when you create the service connection with "Workload Identity Federation (automatic)". You copy these exact values from ADO's form and paste them into Entra ID. Do not manually construct them.

---

### What if the issuer URL looks different than what's in the documentation?

The issuer shown in Azure DevOps is tenant-specific and includes your tenant ID and `/v2.0`. This is expected. Use exactly what ADO shows, not the generic documentation example.

---

### Why do I need to grant Reader role on the subscription if PIM Monitor only uses Graph API?

Azure DevOps needs to verify that the app registration has valid permissions on the subscription as part of the service connection verification process. Even though PIM Monitor only reads from Microsoft Graph (not Azure resources), ADO requires this subscription-level access to complete the WIF handshake.

---

### Can I use a different role instead of Reader?

Yes. You can use any role that allows `Microsoft.Resources/subscriptions/read`, such as:
- Reader (minimum required)
- Contributor (if you plan to expand PIM Monitor later)
- Any custom role with `Microsoft.Resources/subscriptions/read`

---

### How long does service connection verification take?

Usually 5-10 seconds. If it takes longer than 30 seconds, it may have timed out. Try clicking "Verify and save" again.

---

### What should I do with the client secret in the app registration?

Do not create one. WIF uses OIDC token exchange instead of client secrets. This is more secure because there is no credential to rotate or leak.

## Deployment and Operation

### How often does PIM Monitor run?

4 times a day by default (`0 */6 * * *`). You can configure the schedule in `monitor-pipeline.yml` using any cron expression.

---

### Where does PIM Monitor store its data?

All data is stored as JSON files in the inventory folder of the git repository. Every scan creates a commit with the updated state. This serves as both the current state and an audit trail.

---

### What happens if there are no changes in a scan?

No commit is created. The pipeline succeeds, but no files are written and no notifications are sent.

---

### Can I run PIM Monitor manually instead of on a schedule?

Yes. In Azure DevOps, you can set the pipeline to manual trigger only, or both manual and scheduled. See the pipeline YAML configuration.

## Notifications

### How do I send email notifications?

Set pipeline variable `NOTIFICATION_EMAIL` to the recipient address and `NOTIFICATION_MAIL_FROM` to the sender mailbox. The app registration must have `Mail.Send` permission and admin consent.

---

### Can I send notifications to both email and webhook?

Yes. Both are optional and independent. Set both environment variables to enable both channels.

---

### What webhook providers are supported?

PIM Monitor auto-detects the provider from the URL:
- Microsoft Teams (via Power Automate webhook trigger)
- Slack (via Incoming Webhook)
- Discord (via channel webhook)
- Custom HTTP endpoints

---

### How do I get a webhook URL for Teams?

Teams has deprecated Incoming Webhooks. Use Power Automate instead:
1. Create a new cloud flow > Automated cloud flow
2. Trigger: "When a Teams webhook request is received"
3. Get the webhook URL from the trigger
4. Paste into `NOTIFICATION_WEBHOOK_URL`

## Troubleshooting

### The pipeline runs but doesn't commit anything. Is it working?

Yes, this is normal. If there are no PIM changes detected, no commit is created. Check the pipeline run logs to confirm "No changes detected" message. This is expected behavior for most runs.

---

### I see "Graph API 429 throttling" errors. What do I do?

PIM Monitor is fetching too much data too quickly. This is rare with default settings. If it happens:
1. Increase the scheduled interval (run less frequently)
2. Contact the PIM Monitor maintainers if you have a very large tenant

---

### The pipeline logs show "Permission denied" on a Graph API call.

Ensure all required scopes are granted to the app registration and that admin consent was given. Check the prerequisites page for the full list of required permissions.

---

### The pipeline fails with `InvalidAuthenticationToken` / `IDX14102`.

This error means the Graph API received a malformed token. It happens when `Get-AzAccessToken` returns a `SecureString` (Az.Accounts 3.0+, shipped with Az 12+) but the value is interpolated directly into a string, producing `"Bearer System.Security.SecureString"` instead of the actual JWT.

PIM Monitor handles this automatically using `NetworkCredential` to unwrap the `SecureString`. If you see this error, ensure you are running the current version of the scan script (not an older copy that calls `Get-AzAccessToken` without the unwrap step).

---

### The pipeline fails with `The property '@odata.nextLink' cannot be found on this object`.

This is a `Set-StrictMode -Version Latest` violation. It occurs when the last page of a paginated Graph API response has no `@odata.nextLink` property and the script accesses it directly with dot notation.

PIM Monitor uses `PSObject.Properties['@odata.nextLink']?.Value` to safely read the property without requiring it to exist. Ensure you are running the current version of the scan script.

---

### The pipeline fails with `The property 'Count' cannot be found on this object`.

Also a `Set-StrictMode` violation. It can occur in:
- `ConvertTo-DeterministicJson` when the normalizer incorrectly treats a string or boolean as a PSCustomObject (fixed by excluding `[string]` and `[System.ValueType]` from the PSObject branch)
- Property chains like `.scheduleInfo.expiration.endDateTime` on a PSCustomObject that may not have those keys (fixed by using `PSObject.Properties['key']?.Value`)

Ensure you are running the current version of `src/helpers.ps1` and `src/diff.ps1`.

---

### How do I test locally before deploying to the pipeline?

See [Local Testing](./local-testing.md). You will need PowerShell 7+, the Az PowerShell module, and a tenant admin or PIM admin account.

## GitHub Actions

### How do I deploy to GitHub Actions instead of Azure DevOps?

See [Installation: GitHub Actions](./installation-github.md) for a complete walkthrough. The process is similar to ADO but uses GitHub's OIDC for WIF instead.

---

### Can I run on both Azure DevOps AND GitHub?

Yes. Both the ADO pipeline and GitHub Actions workflow can run independently on the same repository. They use the same PowerShell scripts and produce the same output.

---

### Which platform should I choose?

Choose based on where your team already is:
- **Azure DevOps:** If you use Azure DevOps for other pipelines
- **GitHub Actions:** If you use GitHub and prefer Actions over paying for ADO

Both are equally capable for PIM Monitor.

## General

### Is PIM Monitor free?

Yes. It's open source under the MIT license.

---

### What Azure/Entra ID roles do I need to set up PIM Monitor?

- **Entra ID:** Global Administrator or Privileged Role Administrator (to grant app permissions and admin consent)
- **Azure DevOps:** Stakeholder or higher (to create pipelines and service connections)
- **Azure Portal:** Owner or User Access Administrator on the subscription (to grant Reader role to the app)

---

### How is this different from the built-in PIM audit logs?

PIM Monitor:
- Captures the complete state of all roles/policies/assignments as JSON (audit trail via git history)
- Classifies changes by severity (High/Medium/Low)
- Sends notifications immediately on detection
- Stores data in your own repo (not subject to Graph API retention limits)
- Can be customized and extended

Built-in PIM audit logs in Entra ID:
- Available in the Azure portal
- Retention limited to ~30 days
- Simpler to view but less queryable

Both can be used together. PIM Monitor provides deeper analysis and longer history.

---

### Does PIM Monitor modify anything?

No. PIM Monitor only reads from Microsoft Graph. It does not create, modify, or delete any assignments, policies, or settings. It is read-only.

---

### Can I use PIM Monitor to enforce policies?

Not directly. PIM Monitor detects changes and notifies. You would need a separate automation layer to enforce. See the customize section for examples of how to build on PIM Monitor.
