# 01 — Introductie

## Inhoudsopgave

1. [Wat is PIM Monitor](#1-wat-is-pim-monitor)
2. [Welk probleem lost het op](#2-welk-probleem-lost-het-op)
3. [Hoe het werkt](#3-hoe-het-werkt)
4. [Doelgroep](#4-doelgroep)
5. [Wat PIM Monitor niet is](#5-wat-pim-monitor-niet-is)
6. [Vereisten](#6-vereisten)
7. [Relatie met PIM Manager](#7-relatie-met-pim-manager)

---

## 1. Wat is PIM Monitor

PIM Monitor is een **geplande Azure DevOps-pipeline** die Microsoft Entra ID Privileged Identity Management (PIM) continu bewaakt op wijzigingen in:

- Directory-roldefinities (rechten, in-/uitgeschakelde status)
- PIM-beleidsregels (MFA-vereisten, goedkeuringsworkflows, activatieduur)
- Rolassignments (permanent, eligible, actief)
- PIM-groepslidmaatschap (member- en owner-assignments)
- Opzoekentiteiten: authenticatiecontextklasreferenties en beheereenheden

Bij een gedetecteerde wijziging:
1. Werkt PIM Monitor de inventory-bestanden in de repository bij.
2. Maakt het een commit met tijdstempel (`scan: 2026-04-25T10:00:00Z`).
3. Stuurt het optioneel een notificatie via e-mail en/of webhook.

De repositorygeschiedenis wordt een **volledig, opvraagbaar auditspoor** van elke PIM-configuratiewijziging.

---

## 2. Welk probleem lost het op

| Lacune in Entra ID PIM | Hoe PIM Monitor dit aanpakt |
|---|---|
| Geen proactieve waarschuwing bij wijzigingen in rolassignments | Detectie en melding binnen het geconfigureerde scaninterval |
| Geen waarschuwing bij verzwakking van beleid (bijv. MFA uitgeschakeld) | Vergelijkt beleidsregels per rol; classificeert ernst |
| Auditlog heeft retentielimieten en vereist handmatige raadpleging | Git-geschiedenis is permanent en opvraagbaar via REST API |
| Geen gestructureerde diffweergave: "wat is er precies gewijzigd?" | Git-diff toont oud vs nieuw voor elke JSON-eigenschap |
| Configuratieafwijking gaat onopgemerkt | Elke scan legt de volledige status vast |

---

## 3. Hoe het werkt

```
Azure DevOps Pipeline (elke 30 min, instelbaar)
  │
  ├─ 1. Repository ophalen ── inventory/ bevat de vorige status
  │
  ├─ 2. Authenticeren ──────── WIF: OIDC-tokenuitwisseling, geen client secret
  │
  ├─ 3. Status ophalen ────── Microsoft Graph API (volledige fetch)
  │
  ├─ 4. Vergelijken ──────── nieuwe status vs inventory-bestanden
  │
  ├─ 5. Classificeren ────── elke wijziging krijgt Hoog / Middel / Laag / Informatief
  │
  ├─ 6. Inventory schrijven ── JSON-bestanden bijwerken (aanmaken / bijwerken / verwijderen)
  │
  ├─ 7. Committen & pushen ── alleen bij gewijzigde bestanden; bericht: "scan: {tijdstempel}"
  │
  └─ 8. Melden ──────────── e-mail en/of webhook (indien geconfigureerd)
```

---

## 4. Doelgroep

Deze documentatie is bestemd voor:

- **Beheerders** die PIM Monitor opzetten of onderhouden in een Azure DevOps-project.
- **Ontwikkelaars** die PIM Monitor uitbreiden (nieuwe notificatiekanalen, extra inventorycategorieën, aangepaste ernstigheidsregels).
- **Integrators** die bouwen op de git-geschiedenis van PIM Monitor (bijv. de `/monitor`-pagina van PIM Manager).

Basisbekendheid wordt verondersteld met: Azure DevOps Pipelines, Microsoft Entra ID, PowerShell 7 en Microsoft Graph API.

---

## 5. Wat PIM Monitor niet is

- **Geen real-timesysteem.** Het pollt op schema. De minimale praktische interval is de ADO-schedulerminimum (circa 5 minuten).
- **Geen SIEM.** Het detecteert en registreert wijzigingen; het correleert niet, onderzoekt niet en reageert niet op bedreigingen.
- **Geen hersteltool.** PIM Monitor wijzigt geen PIM-configuratie. Het is alleen-lezen ten opzichte van Entra ID.
- **Geen CLI of webapplicatie.** Het draait onbeheerd in een pipeline.
- **Geen vervanging voor Entra-auditlogs.** Het legt configuratiestatus wijzigingen vast; acteurattributie (wie heeft de wijziging aangebracht) is gepland voor fase 4.

---

## 6. Vereisten

| Vereiste | Details |
|---|---|
| Azure DevOps-project | Gratis laag voldoende (1800 pipelineminuten/maand) |
| App-registratie | Vereiste applicatierechten + beheerdersconsent (zie [09-authenticatie.md](09-authenticatie.md)) |
| WIF-serviceverbinding | Federatieve credentials op de app-registratie (zie [09-authenticatie.md](09-authenticatie.md)) |
| PowerShell 7.x | Aanwezig op ubuntu-latest hosted agent, geen extra setup |
| Microsoft.Graph-module | Geinstalleerd door de pipeline in een `PowerShell@2`-stap (zie [10-pipeline.md](10-pipeline.md)) |

Optioneel voor notificaties:

| Optionele vereiste | Wanneer nodig |
|---|---|
| `Mail.Send`-recht op app-registratie | E-mailnotificaties zijn geconfigureerd |
| Verzenderspostbus in de tenant | E-mailnotificaties via Graph `sendMail` |
| Webhook-URL | Teams / Slack / Discord / aangepaste webhooknotificaties |

---

## 7. Relatie met PIM Manager

PIM Monitor is een **zelfstandig project** zonder codeafhankelijkheid van PIM Manager.

Het koppelpunt is het **inventory-bestandsformaat** dat in git is opgeslagen. De geplande `/monitor`-pagina van PIM Manager verbruikt de wijzigingstijdlijn door de commitgeschiedenis te lezen via de Azure DevOps Git REST API.

Zie [11-pim-manager-integratie.md](11-pim-manager-integratie.md) voor het volledige integratiecontract.
