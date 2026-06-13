# 10 — Pipeline

## Table of Contents

1. [Pipeline File Overview](#1-pipeline-file-overview)
2. [Trigger and Schedule](#2-trigger-and-schedule)
3. [Pool](#3-pool)
4. [Variables](#4-variables)
5. [Steps](#5-steps)
6. [Pipeline Variables Reference](#6-pipeline-variables-reference)
7. [Artifacts](#7-artifacts)
8. [Adjusting the Schedule](#8-adjusting-the-schedule)
9. [Running Manually](#9-running-manually)

---

## 1. Pipeline File Overview

`monitor-pipeline.yml` is the Azure DevOps pipeline definition. It has no build trigger (`trigger: none`) — it runs exclusively on a schedule and on manual dispatch.

```yaml
trigger: none

schedules:
  - cron: "*/30 * * * *"
    ...

pool:
  vmImage: "ubuntu-latest"

variables:
  NOTIFICATION_MIN_SEVERITY: "Medium"

steps:
  - checkout
  - PowerShell@2 (install module)
  - AzurePowerShell@5 (run scan)
  - script (configure git user)
  - script (commit and push)
  - PublishBuildArtifacts@1 (publish report, conditional)
```

---

## 2. Trigger and Schedule

```yaml
trigger: none

schedules:
  - cron: "*/30 * * * *"
    displayName: "PIM Change Scan (every 30 minutes)"
    branches:
      include: [main]
    always: true
```

- `trigger: none` disables code push triggers. The pipeline never runs on a commit (to prevent a scan commit from triggering another scan).
- `always: true` runs the schedule even when there are no new commits since the last run. Without this, ADO would skip scheduled runs if the branch has not changed.
- The cron runs every 30 minutes. Adjust to any valid cron expression. The ADO minimum schedule interval is approximately 5 minutes.

---

## 3. Pool

```yaml
pool:
  vmImage: "ubuntu-latest"
```

`ubuntu-latest` is a Microsoft-hosted agent with:
- PowerShell 7.x pre-installed.
- Az PowerShell modules installed (Az.Accounts, Az.Resources, etc.).
- Git pre-installed.

No custom agent configuration is required. `Microsoft.Graph` module is not pre-installed and is installed in the first pipeline step.

---

## 4. Variables

```yaml
variables:
  NOTIFICATION_MIN_SEVERITY: "Medium"
```

Only `NOTIFICATION_MIN_SEVERITY` is defined in the YAML with a default. All other notification variables (`NOTIFICATION_EMAIL`, `NOTIFICATION_MAIL_FROM`, `NOTIFICATION_WEBHOOK_URL`, `REPORT_ARTIFACT`) must be defined in the Azure DevOps pipeline UI variables panel.

> [!IMPORTANT]
> Do not define `NOTIFICATION_EMAIL`, `NOTIFICATION_MAIL_FROM`, `NOTIFICATION_WEBHOOK_URL`, or `REPORT_ARTIFACT` in the YAML. YAML variable definitions shadow UI variables of the same name. A YAML default would always override a value set in the UI, making it impossible to configure notifications without editing the YAML.

Pipeline variables are passed to the `AzurePowerShell@5` task via the `env:` block:

```yaml
env:
  NOTIFICATION_EMAIL: $(NOTIFICATION_EMAIL)
  NOTIFICATION_MAIL_FROM: $(NOTIFICATION_MAIL_FROM)
  NOTIFICATION_WEBHOOK_URL: $(NOTIFICATION_WEBHOOK_URL)
  NOTIFICATION_MIN_SEVERITY: $(NOTIFICATION_MIN_SEVERITY)
  REPORT_ARTIFACT: $(REPORT_ARTIFACT)
```

If a UI variable is not defined, ADO passes the literal string `$(VARIABLE_NAME)` to the task. PIM Monitor detects this pattern and treats it as "not configured" (see [07-notifications.md](07-notifications.md) Section 1).

---

## 5. Steps

### Step 1: Checkout

```yaml
- checkout: self
  persistCredentials: true
  displayName: "Checkout repository"
```

`persistCredentials: true` is required for the git push step. Without it, the credential helper is not configured and the push fails.

### Step 2: Install Microsoft.Graph module

```yaml
- task: PowerShell@2
  inputs:
    targetType: inline
    pwsh: true
    script: |
      Install-Module -Name Microsoft.Graph -Force -SkipPublisherCheck -AllowClobber
  displayName: "Install Microsoft.Graph module"
```

This step installs the full Microsoft.Graph meta-module. It is currently installed but not directly used at the module import level — `Scan-PimState.ps1` calls `Get-AzAccessToken` (from Az.Accounts, pre-installed) and `Invoke-RestMethod` (built-in) rather than `Invoke-MgGraphRequest`. The module is retained here because future phases may use Graph SDK cmdlets.

> [!TIP]
> To speed up the pipeline, you can install only the specific submodule needed: `Install-Module Microsoft.Graph.Authentication`. This installs faster and is sufficient for token acquisition via Graph SDK.

### Step 3: Run scan (AzurePowerShell@5)

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: "pim-monitor-service-connection"
    ScriptType: "FilePath"
    ScriptPath: "$(Build.SourcesDirectory)/src/Scan-PimState.ps1"
    azurePowerShellVersion: "LatestVersion"
    pwsh: true
  displayName: "Run PIM change scan"
  env:
    ...
```

This is the main task. It performs the WIF OIDC exchange and executes the scan script. The `azureSubscription` value must match the service connection name exactly (case-sensitive).

### Step 4: Configure git user

```yaml
- script: |
    git config user.name "PIM Monitor"
    git config user.email "pim-monitor@pipeline"
  displayName: "Configure git user"
  condition: always()
```

`condition: always()` ensures git is configured even if the scan step failed, so the bash commit step can still run cleanup if needed.

### Step 5: Commit and push

```yaml
- script: |
    cd $(Build.SourcesDirectory)
    git add inventory/

    if git diff --cached --quiet; then
      echo "##[section] No changes detected in inventory/"
    else
      TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      git commit -m "scan: $TIMESTAMP"
      git push origin HEAD:main
      echo "##[section] Inventory changes published"
    fi
  displayName: "Commit and push inventory changes"
  condition: always()
```

`condition: always()` ensures this step runs even if the PowerShell scan step threw an error, to commit any inventory files that were written before the error occurred.

This step and the `Publish-InventoryChanges` function in `git.ps1` both attempt to commit. In normal operation, the PowerShell task commits and pushes first. This bash step finds nothing staged and exits cleanly. If the PowerShell task wrote files but did not commit (e.g., exception thrown between file writes and the git call), this step commits the partial update.

### Step 6: Publish report artifact (conditional)

```yaml
- task: PublishBuildArtifacts@1
  inputs:
    PathtoPublish: "$(Build.ArtifactStagingDirectory)"
    ArtifactName: "scan-report"
    publishLocation: Container
  displayName: "Publish HTML scan report"
  condition: eq(variables['REPORT_ARTIFACT'], 'true')
```

Only runs when `REPORT_ARTIFACT=true`. The artifact is named `scan-report` and contains `scan-report.html`.

### Step 7: Check for upstream version updates

```bash
LATEST_TAG=$(curl -sf "https://api.github.com/repos/0125joel/PIM-Monitor/releases/latest" \
  | jq -r '.tag_name // empty')
CURRENT_VERSION=$(grep -oP '\d+\.\d+\.\d+' "$(Build.SourcesDirectory)/VERSION")
# Compare: if LATEST > CURRENT, set UPSTREAM_UPDATE_AVAILABLE=true
```

This step checks whether a newer version of PIM Monitor is available on GitHub by:
1. Reading your `VERSION` file (what you're running)
2. Calling the GitHub API to fetch the latest release
3. Comparing semantic versions
4. Setting `UPSTREAM_UPDATE_AVAILABLE` if an update is available

To disable: set pipeline variable `NOTIFY_UPSTREAM_UPDATE=false`.

---

## 6. Pipeline Variables Reference

Configure these in **Azure DevOps** → **Pipelines** → **{Pipeline}** → **Edit** → **Variables**:

| Variable | Required | Default | Description |
|---|---|---|---|
| `NOTIFICATION_EMAIL` | No | (not set) | Recipient email address for scan reports |
| `NOTIFICATION_MAIL_FROM` | No | (not set) | Sender mailbox for Graph `sendMail` |
| `NOTIFICATION_WEBHOOK_URL` | No | (not set) | Webhook URL for Teams / Slack / Discord / generic |
| `NOTIFICATION_MIN_SEVERITY` | No | `Medium` | Minimum severity for notifications (`High`, `Medium`, `Low`, `Informational`) |
| `REPORT_ARTIFACT` | No | (not set) | Set to `true` to publish HTML report as pipeline artifact |
| `EXPIRING_WINDOW_DAYS` | No | `14` | Days ahead to flag expiring assignments |

---

## 7. Artifacts

When `REPORT_ARTIFACT=true`, the pipeline publishes a `scan-report` artifact containing `scan-report.html`. This is the same HTML as the email notification, rendered with `MinSeverity=Low` (all severities included).

The artifact is available in the Azure DevOps pipeline run UI under **Artifacts** → **scan-report**. Artifact retention follows the project's retention policy.

---

## 8. Adjusting the Schedule

To change how often the pipeline runs, edit the `cron` expression in `monitor-pipeline.yml`:

| Interval | Cron expression |
|---|---|
| Every 15 minutes | `*/15 * * * *` |
| Every 30 minutes | `*/30 * * * *` |
| Every hour | `0 * * * *` |
| Every 4 hours | `0 */4 * * *` |
| Daily at midnight UTC | `0 0 * * *` |

> [!NOTE]
> The Azure DevOps scheduler has a minimum resolution of approximately 5 minutes. Expressions more frequent than `*/5 * * * *` may not run at the expected frequency.

---

## 9. Running Manually

To trigger a manual run without changing the schedule:

1. Navigate to **Pipelines** → **{Pipeline}**.
2. Click **Run pipeline**.
3. Select the branch (`main`) and click **Run**.

Manual runs go through the same steps as scheduled runs. There is no way to pass additional parameters to a manual run via the UI (without adding pipeline parameters to the YAML).
