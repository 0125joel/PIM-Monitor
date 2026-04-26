# 07 — Notificaties

## Inhoudsopgave

1. [Overzicht](#1-overzicht)
2. [Ernstigheidsfiltering](#2-ernstigheidsfiltering)
3. [E-mail via Graph sendMail](#3-e-mail-via-graph-sendmail)
4. [Webhooks](#4-webhooks)
5. [Teams-payload (Adaptive Card)](#5-teams-payload-adaptive-card)
6. [Slack-payload (Block Kit)](#6-slack-payload-block-kit)
7. [Discord-payload (Embed)](#7-discord-payload-embed)
8. [Generieke webhookpayload](#8-generieke-webhookpayload)
9. [HTML-scanrapport](#9-html-scanrapport)
10. [Commit-diff-URL](#10-commit-diff-url)
11. [Een nieuw notificatiekanaal toevoegen](#11-een-nieuw-notificatiekanaal-toevoegen)

---

## 1. Overzicht

PIM Monitor ondersteunt twee notificatiekanalen: e-mail (via Microsoft Graph `sendMail`) en webhooks. Beide zijn optioneel en onafhankelijk configureerbaar via pipelinevariabelen. Geen van beide kanalen vereist secrets in de pipeline.

Notificaties worden verstuurd in `Scan-PimState.ps1` na de git-commit, zodat de commit-SHA beschikbaar is voor "Diff bekijken"-links.

```
$changesBySeverity.Total > 0
        │
        ├── NOTIFICATION_EMAIL + NOTIFICATION_MAIL_FROM ingesteld?
        │       └── Send-EmailNotification
        │
        └── NOTIFICATION_WEBHOOK_URL ingesteld?
                └── Send-WebhookNotification
                        │
                        ├── URL bevat webhook.office.com → Teams
                        ├── URL bevat hooks.slack.com → Slack
                        ├── URL bevat discord.com/api/webhooks → Discord
                        └── anders → Generiek
```

> [!NOTE]
> ADO-pipelinevariabelen die niet zijn ingesteld worden doorgegeven als letterlijke `$(NAAM_VARIABELE)`-tekenreeksen. `Scan-PimState.ps1` detecteert dit patroon en behandelt onopgeloste macros als niet geconfigureerd.

---

## 2. Ernstigheidsfiltering

Beide kanalen respecteren `NOTIFICATION_MIN_SEVERITY` (standaard `Medium`). Wijzigingen onder de drempel worden weggelaten uit de notificatiepayload.

De ernstigheidsrang:

```powershell
$script:SeverityRank = @{ High = 3; Medium = 2; Low = 1; Informational = 0 }
```

`NOTIFICATION_MIN_SEVERITY=Low` omvat alle wijzigingen. `High` onderdrukt alles behalve hoog-ernstige wijzigingen.

---

## 3. E-mail via Graph sendMail

### Configuratie

| Variabele | Vereist | Beschrijving |
|---|---|---|
| `NOTIFICATION_EMAIL` | Ja | Ontvangersadres |
| `NOTIFICATION_MAIL_FROM` | Ja | Verzenderspostbus (moet bestaan in de tenant) |

### Vereiste rechten

`Mail.Send` applicatierecht op de app-registratie. Zie sectie [09-authenticatie.md](09-authenticatie.md) voor het beperken tot een specifieke postbus via een applicatietoegangsbeleid.

### API-aanroep

```
POST https://graph.microsoft.com/v1.0/users/{mailFrom}/sendMail
```

### Onderwerpformaat

- Één ernst: `[PIM Monitor] 1 High change`
- Meerdere: `[PIM Monitor] 3 changes: 1 High, 2 Medium`

### HTML-e-mailstructuur

`Format-ChangeSummaryHtml` genereert een responsieve HTML-e-mail. Ontwerptokens per ernst:

| Element | Hoog | Middel | Laag | Informatief |
|---|---|---|---|---|
| Randkleur | `#ef4444` (rood) | `#d97706` (amber) | `#22c55e` (groen) | `#737373` (grijs) |
| Achtergrond | `#fef2f2` | `#fffbeb` | `#f0fdf4` | `#f9fafb` |
| Labelkleur | `#b91c1c` | `#92400e` | `#166534` | `#374151` |

Elke wijziging wordt weergegeven als een inklapbare `<details>/<summary>`-kaart met entiteitsnaam, korte beschrijving en velddiff (rood voor oude waarden, groen voor nieuwe).

---

## 4. Webhooks

### Configuratie

| Variabele | Vereist | Beschrijving |
|---|---|---|
| `NOTIFICATION_WEBHOOK_URL` | Ja | Volledige webhook-URL |

Webhooktype wordt automatisch gedetecteerd op basis van de URL:

| URL-patroon | Type |
|---|---|
| `webhook.office.com` | Teams |
| `hooks.slack.com` | Slack |
| `discord.com/api/webhooks` | Discord |
| anders | Generiek |

---

## 5. Teams-payload (Adaptive Card)

Teams-webhooks vereisen een **Power Automate-workflow** als doel ("When a Teams webhook request is received"-trigger). De oude O365 Incoming Webhook-connector is gedeprecieerd.

De payload gebruikt het Adaptive Card-formaat (`type: "AdaptiveCard"`, schema `1.5`):
- Containeropmaak per ernst: `attention` (Hoog), `warning` (Middel), `good` (Laag), `default` (Informatief).
- Maximaal 15 wijzigingsentries per ernstigheidssectie; daarna "... and N more".
- Directe Entra-portaallinks bij wijzigingen voor bekende rol- of groeps-ID's.

---

## 6. Slack-payload (Block Kit)

Block Kit-payload met koptekst, samenvattingssectie met aantallen per ernst, en per ernstigheidssectie een tekstblok met maximaal 20 wijzigingentries. "Diff bekijken"-link indien commit-SHA beschikbaar.

---

## 7. Discord-payload (Embed)

Embed-payload met kleur op basis van hoogste aanwezige ernst: rood (`15548997`) voor Hoog, oranje (`15844367`) voor Middel, groen (`5763719`) voor Laag of geen. Veldwaarden beperkt tot 1024 tekens; maximaal 10 wijzigingen per veld.

---

## 8. Generieke webhookpayload

Voor niet-herkende URL's:

```json
{
  "text": "PIM Monitor — 3 change(s) detected",
  "summary": "PIM Monitor — change report\n...",
  "changesBySeverity": {
    "high": 1, "medium": 2, "low": 0, "informational": 0, "total": 3
  }
}
```

---

## 9. HTML-scanrapport

Bij `REPORT_ARTIFACT=true` schrijft `Export-ScanReport` het HTML-rapport naar `$BUILD_ARTIFACTSTAGINGDIRECTORY/scan-report.html`. De `PublishBuildArtifacts@1`-pipelinetaak maakt het beschikbaar als artefact `scan-report`. Standaard `MinSeverity` voor het rapport is `Low` (alles opnemen).

---

## 10. Commit-diff-URL

`Get-CommitDiffUrl` bouwt een link naar het platform-specifieke diff-scherm:

| Platform | Detectie | URL-formaat |
|---|---|---|
| Azure DevOps | `$env:BUILD_REPOSITORY_URI` is ingesteld | `{repoUri}/commit/{sha}?refName=refs%2Fheads%2Fmain` |
| GitHub | `$env:GITHUB_SERVER_URL` en `$env:GITHUB_REPOSITORY` zijn ingesteld | `{serverUrl}/{repo}/commit/{sha}` |
| Geen van beide | Geen van de bovenstaande env-variabelen | `$null` (link weggelaten) |

---

## 11. Een nieuw notificatiekanaal toevoegen

1. URL-detectie toevoegen in `Get-WebhookType`:
   ```powershell
   if ($Url -match 'chat\.googleapis\.com') { return 'GoogleChat' }
   ```

2. Payloadbouwfunctie `Build-GoogleChatPayload` toevoegen in `notifications.ps1`.

3. Case toevoegen in het `switch ($type)`-blok in `Send-WebhookNotification`.

4. Documenteer het nieuwe kanaal in de Docusaurus-gebruikersdocumentatie (`docs-site/docs/configuration/notifications.md`).

Geen wijzigingen aan de orchestrator nodig.
