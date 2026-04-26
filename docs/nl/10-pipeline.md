# 10 — Pipeline

## Inhoudsopgave

1. [Overzicht pipelinebestand](#1-overzicht-pipelinebestand)
2. [Trigger en schema](#2-trigger-en-schema)
3. [Pool](#3-pool)
4. [Variabelen](#4-variabelen)
5. [Stappen](#5-stappen)
6. [Pipelinevariabelen-referentie](#6-pipelinevariabelen-referentie)
7. [Artefacten](#7-artefacten)
8. [Schema aanpassen](#8-schema-aanpassen)
9. [Handmatig uitvoeren](#9-handmatig-uitvoeren)

---

## 1. Overzicht pipelinebestand

`monitor-pipeline.yml` is de Azure DevOps-pipelinedefinitie. Er is geen buildtrigger (`trigger: none`): de pipeline draait uitsluitend op schema en bij handmatige activering.

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
  - PowerShell@2 (module installeren)
  - AzurePowerShell@5 (scan uitvoeren)
  - script (git-gebruiker configureren)
  - script (committen en pushen)
  - PublishBuildArtifacts@1 (rapport publiceren, conditioneel)
```

---

## 2. Trigger en schema

```yaml
trigger: none

schedules:
  - cron: "*/30 * * * *"
    displayName: "PIM Change Scan (elke 30 minuten)"
    branches:
      include: [main]
    always: true
```

- `trigger: none` schakelt code-push-triggers uit. De pipeline wordt nooit uitgevoerd bij een commit (om te voorkomen dat een scancommit een nieuwe scan triggert).
- `always: true` voert het schema uit, ook als er geen nieuwe commits zijn. Zonder dit zou ADO geplande runs overslaan als de branch niet is gewijzigd.
- De cron draait elke 30 minuten. Pas dit aan naar elk geldig cron-expressie. Het ADO-schedulerminimum is circa 5 minuten.

---

## 3. Pool

```yaml
pool:
  vmImage: "ubuntu-latest"
```

`ubuntu-latest` is een door Microsoft gehoste agent met:
- PowerShell 7.x voorgeinstalleerd.
- Az PowerShell-modules voorgeinstalleerd.
- Git voorgeinstalleerd.

De `Microsoft.Graph`-module is niet voorgeinstalleerd en wordt in de eerste pipelinestap geinstalleerd.

---

## 4. Variabelen

```yaml
variables:
  NOTIFICATION_MIN_SEVERITY: "Medium"
```

Alleen `NOTIFICATION_MIN_SEVERITY` is in de YAML gedefinieerd met een standaardwaarde. Alle overige notificatievariabelen (`NOTIFICATION_EMAIL`, `NOTIFICATION_MAIL_FROM`, `NOTIFICATION_WEBHOOK_URL`, `REPORT_ARTIFACT`) moeten worden gedefinieerd in het variabelenpaneel van de Azure DevOps-pipeline-gebruikersinterface.

> [!IMPORTANT]
> Definieer `NOTIFICATION_EMAIL`, `NOTIFICATION_MAIL_FROM`, `NOTIFICATION_WEBHOOK_URL` en `REPORT_ARTIFACT` **niet** in de YAML. YAML-variabelen overschaduwen UI-variabelen met dezelfde naam. Een YAML-standaardwaarde zou een UI-waarde altijd overschrijven.

---

## 5. Stappen

### Stap 1: Uitchecken

```yaml
- checkout: self
  persistCredentials: true
  displayName: "Repository uitchecken"
```

`persistCredentials: true` is vereist voor de git-push. Zonder dit is de credential-helper niet geconfigureerd en mislukt `git push`.

### Stap 2: Microsoft.Graph-module installeren

```yaml
- task: PowerShell@2
  inputs:
    targetType: inline
    pwsh: true
    script: |
      Install-Module -Name Microsoft.Graph -Force -SkipPublisherCheck -AllowClobber
  displayName: "Microsoft.Graph-module installeren"
```

> [!TIP]
> Om de pipeline te versnellen kunt u alleen de benodigde submodule installeren: `Install-Module Microsoft.Graph.Authentication`. Dit is voldoende voor tokenacquisitie.

### Stap 3: Scan uitvoeren (AzurePowerShell@5)

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: "pim-monitor-service-connection"
    ScriptType: "FilePath"
    ScriptPath: "$(Build.SourcesDirectory)/src/Scan-PimState.ps1"
    azurePowerShellVersion: "LatestVersion"
    pwsh: true
  displayName: "PIM-wijzigingsscan uitvoeren"
  env:
    NOTIFICATION_EMAIL: $(NOTIFICATION_EMAIL)
    NOTIFICATION_MAIL_FROM: $(NOTIFICATION_MAIL_FROM)
    NOTIFICATION_WEBHOOK_URL: $(NOTIFICATION_WEBHOOK_URL)
    NOTIFICATION_MIN_SEVERITY: $(NOTIFICATION_MIN_SEVERITY)
    REPORT_ARTIFACT: $(REPORT_ARTIFACT)
```

Dit is de hoofdtaak. De `azureSubscription`-waarde moet exact overeenkomen met de naam van de serviceverbinding (hoofdlettergevoelig).

### Stap 4: Git-gebruiker configureren

```yaml
- script: |
    git config user.name "PIM Monitor"
    git config user.email "pim-monitor@pipeline"
  displayName: "Git-gebruiker configureren"
  condition: always()
```

`condition: always()` zorgt dat git is geconfigureerd ook als de scanstap mislukte.

### Stap 5: Committen en pushen

```yaml
- script: |
    cd $(Build.SourcesDirectory)
    git add inventory/
    if git diff --cached --quiet; then
      echo "##[section] Geen wijzigingen gedetecteerd in inventory/"
    else
      TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      git commit -m "scan: $TIMESTAMP"
      git push origin HEAD:main
    fi
  displayName: "Inventorywijzigingen committen en pushen"
  condition: always()
```

`condition: always()` zorgt dat deze stap ook bij een fout in de PowerShell-taak wordt uitgevoerd, om gedeeltelijk geschreven inventory-bestanden alsnog te committen.

### Stap 6: HTML-scanrapport publiceren (conditioneel)

```yaml
- task: PublishBuildArtifacts@1
  inputs:
    PathtoPublish: "$(Build.ArtifactStagingDirectory)"
    ArtifactName: "scan-report"
    publishLocation: Container
  displayName: "HTML-scanrapport publiceren"
  condition: eq(variables['REPORT_ARTIFACT'], 'true')
```

Wordt alleen uitgevoerd wanneer `REPORT_ARTIFACT=true`.

---

## 6. Pipelinevariabelen-referentie

Configureer in **Azure DevOps** → **Pipelines** → **{Pipeline}** → **Bewerken** → **Variabelen**:

| Variabele | Vereist | Standaard | Beschrijving |
|---|---|---|---|
| `NOTIFICATION_EMAIL` | Nee | (niet ingesteld) | Ontvangersadres voor scanrapporten |
| `NOTIFICATION_MAIL_FROM` | Nee | (niet ingesteld) | Verzenderspostbus voor Graph `sendMail` |
| `NOTIFICATION_WEBHOOK_URL` | Nee | (niet ingesteld) | Webhook-URL voor Teams / Slack / Discord / generiek |
| `NOTIFICATION_MIN_SEVERITY` | Nee | `Medium` | Minimale ernst voor notificaties |
| `REPORT_ARTIFACT` | Nee | (niet ingesteld) | Stel in op `true` voor HTML-rapport als pipeline-artefact |
| `EXPIRING_WINDOW_DAYS` | Nee | `14` | Aantal dagen vooruit om aflopende assignments te melden |

---

## 7. Artefacten

Bij `REPORT_ARTIFACT=true` publiceert de pipeline een `scan-report`-artefact met `scan-report.html`. Beschikbaar in de Azure DevOps-pipeline-run-gebruikersinterface onder **Artefacten** → **scan-report**. Retentie volgt het retentiebeleid van het project.

---

## 8. Schema aanpassen

Pas de `cron`-expressie in `monitor-pipeline.yml` aan:

| Interval | Cron-expressie |
|---|---|
| Elke 15 minuten | `*/15 * * * *` |
| Elke 30 minuten | `*/30 * * * *` |
| Elk uur | `0 * * * *` |
| Elke 4 uur | `0 */4 * * *` |
| Dagelijks om middernacht UTC | `0 0 * * *` |

> [!NOTE]
> De Azure DevOps-scheduler heeft een minimumresolutie van circa 5 minuten.

---

## 9. Handmatig uitvoeren

Om een handmatige run te starten zonder het schema te wijzigen:

1. Navigeer naar **Pipelines** → **{Pipeline}**.
2. Klik op **Pipeline uitvoeren**.
3. Selecteer de branch (`main`) en klik op **Uitvoeren**.

Handmatige runs doorlopen dezelfde stappen als geplande runs. Er is geen manier om extra parameters mee te geven via de gebruikersinterface (zonder pipelineparameters toe te voegen aan de YAML).
