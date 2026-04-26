---
sidebar_position: 2
---

# Installation . Azure DevOps

Deploy PIM Monitor as a scheduled Azure DevOps pipeline.

## Step 1: Get the repository

Fork or clone the repo so you have a copy to work from:

```powershell
git clone https://github.com/joel-prins/PIM-Monitor.git
Set-Location PIM-Monitor
```

Fork on GitHub first if you want to push customizations back to your own org repo.

## Step 2: Set your service connection name

This is the only change required in `monitor-pipeline.yml`. Open the file and replace the placeholder with the name of the WIF service connection you created during [Prerequisites](./prerequisites.md):

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: "your-service-connection-name"   # replace this
```

Commit and push the updated `monitor-pipeline.yml` to your repo before continuing.

## Step 2b: Set notification variables (optional)

Notification variables are configured in the Azure DevOps **Variables** panel, not in the YAML file. Setting them in the YAML would shadow the UI values and break overrides.

After creating the pipeline in step 3, go to **Pipelines** > **PIM Monitor** > **Edit** > **Variables** and add whichever of these you need:

| Variable | Default | Example value | Purpose |
|---|---|---|---|
| `NOTIFICATION_EMAIL` | _(unset)_ | `security-team@contoso.com` | Email recipient |
| `NOTIFICATION_MAIL_FROM` | _(unset)_ | `pim-monitor@contoso.com` | Sender mailbox (requires `Mail.Send`) |
| `NOTIFICATION_WEBHOOK_URL` | _(unset)_ | `https://hooks.slack.com/services/...` | Teams, Slack, Discord, or custom webhook |
| `NOTIFICATION_MIN_SEVERITY` | `Medium` | `High` `Medium` `Low` `Informational` | Minimum severity to notify on |
| `EXPIRING_WINDOW_DAYS` | `14` | `7` | Days ahead to flag expiring assignments |
| `REPORT_ARTIFACT` | _(unset)_ | `true` | Upload HTML report as pipeline artifact |

Leave all of these unset to run without notifications. The pipeline will still scan and commit inventory changes. See [Notifications](../configuration/notifications.md) for webhook URL formats and setup.

## Step 3: Create the pipeline in Azure DevOps

1. In your Azure DevOps project, go to **Pipelines** in the left navigation
2. Click **New pipeline** (top right)
3. On "Where is your code?" select **Azure Repos Git** (or GitHub if you forked there)
4. Select the repository that contains PIM Monitor
5. On "Configure your pipeline" select **Existing Azure Pipelines YAML file**
6. In the branch dropdown select **main**, then select `/monitor-pipeline.yml` from the path list
7. Click **Continue**
8. Review the YAML, then click **Save** (dropdown arrow next to "Run") to save without running yet

:::tip Save vs. Save and run
Use **Save** on the first setup to verify the pipeline is wired up before triggering a run. You can always click **Run pipeline** manually afterwards.
:::

### Authorize the service connection

The first time the pipeline runs it will ask permission to use the service connection. Azure DevOps shows a yellow banner: "This pipeline needs permission to access a resource before this run can continue."

Click **View** > **Permit** to grant access. This is a one-time step per service connection.

## Step 4: Allow the pipeline to push to git

The pipeline commits inventory changes back to the repo using `$(System.AccessToken)`, a short-lived token Azure DevOps provides automatically to every pipeline run. No PAT or SSH key is needed.

Two things must be configured:

**4a. Confirm `persistCredentials: true` in the checkout step**

This is already set in the default `monitor-pipeline.yml`. Verify it is present:

```yaml
- checkout: self
  persistCredentials: true
```

**4b. Grant Contribute permission to the build service identity**

1. Go to **Project settings** (bottom-left gear icon) > **Repositories**
2. Select your repository from the list
3. Click the **Security** tab
4. In the user/group list, find one of the following (both may be listed):
   - `<YourProjectName> Build Service (<orgname>)` - project-scoped identity
   - `Project Collection Build Service (<orgname>)` - org-wide identity
5. Click the entry, then set **Contribute** to **Allow**

Use the project-scoped identity (`<YourProjectName> Build Service`) if available, as it follows least-privilege.

## Step 5: First run

1. Go to **Pipelines** and open the PIM Monitor pipeline
2. Click **Run pipeline** > **Run**
3. Watch the **Logs** tab for these stages completing successfully:
   - `Acquiring Graph API access token`
   - `Fetching Directory Roles` (and PIM Groups)
   - `Scan summary: X changes detected`
   - `Commit and push` (only appears if changes were found)

The first run always detects changes because there is no previous inventory to compare against. Subsequent runs only commit when the PIM state has actually changed.

## Verify the run

After a successful first run, pull the latest changes and inspect the inventory:

```powershell
git pull
git log --oneline inventory/
Get-ChildItem inventory/directory-roles/
```

You should see a commit like:

```
1a2b3c4 scan: 2026-04-20T15:30:00Z
```

And folders for each monitored role under `inventory/directory-roles/`.

If the pipeline ran but nothing was committed, no changes were detected from a previous inventory. That is expected if an inventory already existed.

## Troubleshooting

---

### Pipeline fails to authenticate (AADSTS error)

The WIF handshake between Azure DevOps and Entra ID failed.

- Verify the service connection is valid: **Project settings** > **Service connections** > click the connection > **Verify**
- Confirm the federated credential in Entra ID uses the exact Issuer and Subject identifier that ADO generated (see [Prerequisites troubleshooting](./prerequisites.md#troubleshooting))

---

### "This pipeline needs permission" banner does not resolve

The service connection authorization step was skipped or timed out.

- Go to the failed pipeline run > click the yellow **View** banner > **Permit**
- If the banner is gone, re-run the pipeline manually to trigger it again

---

### No inventory files created after first run

The scan ran but wrote nothing.

- Open the pipeline run logs and look for errors in the `Scan-PimState.ps1` step
- Verify the service principal has all required Graph API permissions (see [Prerequisites](./prerequisites.md#service-principal-setup))
- Check that admin consent was granted for all permissions in the app registration

---

### Git push fails (403 or "remote: TF401027")

The build service identity does not have permission to write to the repo.

- Confirm `persistCredentials: true` is on the checkout step
- Go to **Project settings** > **Repositories** > your repo > **Security** and verify **Contribute** is set to **Allow** for the Build Service identity
- If both `<Project> Build Service` and `Project Collection Build Service` are listed, grant **Contribute** to the project-scoped one first

---

## Next

[Pipeline YAML Configuration](../configuration/pipeline-yaml.md) - schedule, variables, and commit format.
