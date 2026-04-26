# 00 — Architectuur

## Inhoudsopgave

1. [Overzicht](#1-overzicht)
2. [Probleemstelling](#2-probleemstelling)
3. [Systeemcontext](#3-systeemcontext)
4. [Componentenoverzicht](#4-componentenoverzicht)
5. [Belangrijke ontwerpbeslissingen](#5-belangrijke-ontwerpbeslissingen)
6. [Kwaliteitsattributen](#6-kwaliteitsattributen)
7. [Beperkingen](#7-beperkingen)
8. [Architectuurlagen](#8-architectuurlagen)
9. [Statusmodel](#9-statusmodel)
10. [Levenscyclus van een scan-run](#10-levenscyclus-van-een-scan-run)
11. [Externe interfaces](#11-externe-interfaces)
12. [Toekomstige fases](#12-toekomstige-fases)

---

## 1. Overzicht

PIM Monitor is een **geplande Azure DevOps-pipeline** die Microsoft Entra ID Privileged Identity Management (PIM) bewaakt op configuratieafwijking en ongeautoriseerde wijzigingen. De pipeline draait onbeheerd op een hosted agent, haalt de volledige huidige PIM-status op via de Microsoft Graph API, vergelijkt deze met de vorige status die als JSON-bestanden in de repository is opgeslagen, en stuurt beheerders een melding bij wijzigingen.

De repository zelf is de statusopslag. Geen externe database, geen pipeline-artefacten, geen deltatokens.

```
PIM Monitor (Azure DevOps, instelbaar schema)
  ├── Repository ophalen (inventory-bestanden = vorige status)
  ├── Authenticeren (Workload Identity Federation, geen secrets)
  ├── Huidige PIM-status ophalen (Graph API, volledige fetch)
  ├── Inventory-bestanden vergelijken met huidige status
  ├── Wijzigingen classificeren op ernst (Hoog / Middel / Laag / Informatief)
  ├── Inventory-bestanden bijwerken (aanmaken / bijwerken / verwijderen)
  ├── Committen en pushen naar repository (alleen bij gewijzigde bestanden)
  └── Notificaties verzenden (indien geconfigureerd en wijzigingen gevonden)
```

---

## 2. Probleemstelling

Microsoft Entra ID PIM biedt geen ingebouwd mechanisme om:

- Proactief te detecteren en te waarschuwen bij wijzigingen in rolassignments, beleidsregels of groepslidmaatschap.
- Configuratieafwijking bij te houden over tijd (verzwakking van beleid, nieuwe eligible assignments, permanente rollenopdrachten).
- Een gestructureerd, opvraagbaar auditspoor te bieden buiten het Entra-auditlog (dat retentielimieten kent en geen pushnotificaties biedt).

PIM Monitor vult deze lacune met geplande scans die elke wijziging als een git-commit vastleggen.

---

## 3. Systeemcontext

```
+----------------------------+      Graph API      +---------------------+
|  Entra-tenant van klant    |<------------------->|  Azure DevOps       |
|                            |                     |  Pipeline Agent     |
|  - Directory-rollen        |      WIF OIDC       |                     |
|  - PIM-groepen             |<------------------->|  App-registratie    |
|  - Beleidsregels           |  (geen client secret)|  Serviceverbinding  |
|  - Assignments             |                     +----------+----------+
+----------------------------+                                |
                                                              | git push
                                                              v
                                                    +--------------------+
                                                    |  ADO Git-repo      |
                                                    |  inventory/        |
                                                    |  (status + historie)|
                                                    +--------------------+
                                                              |
                                                       e-mail / webhook
                                                              v
                                                    +--------------------+
                                                    |  Beheerders        |
                                                    +--------------------+
```

---

## 4. Componentenoverzicht

| Component | Bestand | Verantwoordelijkheid |
|---|---|---|
| Orchestrator | `src/Scan-PimState.ps1` | Scan-stroom op hoog niveau, module-imports, foutafhandeling |
| Graph-endpoints | `src/graphEndpoints.ps1` | URI-constanten en URI-bouwfuncties per entiteit |
| Helpers | `src/helpers.ps1` | Paginering, JSON-serialisatie, inventory-I/O |
| Diff-engine | `src/diff.ps1` | Wijzigingsdetectie, ernstigheidsclassificatie, ruisonderdrukking |
| Git-operaties | `src/git.ps1` | Committen, pushen, rebasen bij conflict |
| Notificaties | `src/notifications.ps1` | E-mail (Graph), webhooks (Teams / Slack / Discord / generiek) |
| Pipeline-definitie | `monitor-pipeline.yml` | Schema, authenticatietaak, git-commitstap |

---

## 5. Belangrijke ontwerpbeslissingen

### 5.1 Runtime: Azure DevOps Pipelines

Gekozen boven Azure Functions vanwege:

| Aspect | Azure Functions | Azure DevOps Pipelines |
|---|---|---|
| Kosten | Consumption plan (~gratis) | 1800 gratis minuten/maand |
| Complexiteit | Function App + Storage Account | Repo + YAML-pipeline |
| Authenticatie | Managed Identity of App Registration | Serviceverbinding + WIF |
| Infrastructuur | Meer bewegende delen | Git push en klaar |
| Precedent | — | Bewezen model (Maester.dev) |
| Enterprise-bekendheid | Wisselend | Hoog: de meeste bedrijven gebruiken ADO |

### 5.2 Statusopslag: Git als database

Inventory-bestanden in de repository zijn de bron van waarheid voor de vorige PIM-status. Elke pipeline-run checkt de repository uit, leest de huidige inventory, vergelijkt deze met de nieuw opgehaalde API-data, en schrijft eventuele wijzigingen terug.

Gevolgen:
- **Geen externe opslag.** Geen Azure Blob, geen Cosmos DB, geen pipeline-artefacten.
- **Auditspoor zonder extra werk.** Elke wijziging is een git-commit met tijdstempel.
- **Beschikbaar via REST.** De Azure DevOps Git REST API maakt het mogelijk dat externe tools (PIM Manager) de wijzigingsgeschiedenis opvragen.

### 5.3 Wijzigingsdetectie: volledige fetch + diff

Elke scan haalt de volledige huidige PIM-status op via de Graph API en vergelijkt deze met de vastgelegde inventory-bestanden. Geen delta queries, geen webhooksubscripties.

Motivatie: de datavolumes zijn klein; volledige fetches duren slechts enkele seconden. Delta queries vereisen het persisteren van deltatokens over runs heen; git is al de persistente opslag, een tweede laag voegt complexiteit toe zonder wezenlijk voordeel.

### 5.4 Taal: PowerShell

- Standaard aanwezig op ubuntu-latest hosted agents.
- Microsoft Graph PowerShell SDK is de door Microsoft ondersteunde eersteklasclient.
- Maester.dev heeft dit model op schaal bewezen.
- `AzurePowerShell@5` biedt eersteklas WIF-tokenacquisitie.

### 5.5 Deterministische JSON

De Graph API garandeert geen eigenschapsvolgorde. PowerShell's `ConvertTo-Json` behoudt de invoegvolgorde. Zonder normalisatie zou elke scan een andere bytereeks produceren voor identieke API-data, wat leidt tot valse positieven bij elke run.

Alle writes naar inventory-bestanden gaan via `ConvertTo-DeterministicJson` (in `helpers.ps1`):
1. Sleutels alfabetisch sorteren, recursief.
2. Arrays sorteren op `id`-veld (of waarde voor stringarrays).
3. `@odata.*`-metadatasleutels verwijderen.
4. 2-spatie-inspringing, UTF-8 zonder BOM.

---

## 6. Kwaliteitsattributen

| Attribuut | Doel | Mechanisme |
|---|---|---|
| Correctheid | Geen valse positieven of gemiste wijzigingen | Deterministische JSON; volledige fetch |
| Auditeerbaarheid | Volledige wijzigingsgeschiedenis | Git-commits; één commit per scan |
| Beveiliging | Geen credentials in code of variabelen | Workload Identity Federation |
| Betrouwbaarheid | Verwerkt Graph-throttling en pushconflicten | Exponentieel backoff; push-met-rebase |
| Onderhoudbaarheid | Declaratieve ernstigheidsregels | Opzoektabellen in `diff.ps1` |
| Uitbreidbaarheid | Nieuwe API-velden verschijnen automatisch | Volledige responsopslag; geen `$select`-filtering |
| Observeerbaarheid | Pipeline-logs + HTML-scanrapport | `Write-StepLog` doorheen; `Export-ScanReport` |

---

## 7. Beperkingen

- **PowerShell 7.x vereist.** `Set-StrictMode -Version Latest` is afgedwongen. De `?.`-operator en `-AsHashtable` op `ConvertFrom-Json` zijn 7.x-functies.
- **`AzurePowerShell@5`-taak.** Authenticatie is gekoppeld aan dit taaktype.
- **Az.Accounts 3.0+ retourneert `SecureString`.** `Get-AzAccessToken` retourneert `.Token` als `SecureString` op nieuwere SDK-versies. De codebase pakt dit uit via `NetworkCredential`.
- **Eén branch: `main`.** De pipeline pusht altijd naar `origin HEAD:main`.
- **Hosted agent is vluchtig.** De enige status die bewaard blijft tussen runs is de git-repository.

---

## 8. Architectuurlagen

```
monitor-pipeline.yml         (pipeline-planning + taakdefinities)
        |
        v
Scan-PimState.ps1            (orchestrator)
        |
        +-- graphEndpoints.ps1    (URI-constanten + URI-bouwfuncties)
        |
        +-- helpers.ps1           (Get-AllGraphItems, ConvertTo-DeterministicJson,
        |                          Save-InventoryFile, New-InventoryFolder)
        |
        +-- diff.ps1              (Compare-InventoryFolder, Compare-PolicyRules,
        |                          Compare-Assignments, Compare-FlatProperties,
        |                          Find-ExpiringAssignments, Group-ChangesBySeverity)
        |
        +-- git.ps1               (Publish-InventoryChanges)
        |
        +-- notifications.ps1     (Send-EmailNotification, Send-WebhookNotification,
                                   Format-ChangeSummaryHtml, Build-TeamsPayload, ...)
```

---

## 9. Statusmodel

### Inventory-structuur

```
inventory/
├── directory-roles/           (één map per rol)
│   └── {rol-slug}/
│       ├── definition.json    (unifiedRoleDefinition van beta API)
│       ├── policy.json        (policyAssignment + uitgebreide regels van v1.0)
│       └── assignments.json   (permanent / eligible / active arrays)
├── pim-groups/                (één map per PIM-onboarded groep)
│   └── {groep-slug}/
│       ├── definition.json    (groepseigenschappen van v1.0)
│       ├── policy.json        (member + owner beleidswrappers van beta)
│       └── assignments.json   (member/owner × permanent/eligible/active)
├── authentication-contexts/   (opzoektabel: claimValue → displayName)
│   └── {slug}/definition.json
├── administrative-units/      (opzoektabel: directoryScopeId → displayName)
│   └── {slug}/definition.json
└── activation-events/         (maandelijkse archieven van PIM-auditlogevents)
    └── JJJJ-MM.json
```

### Levenscyclus van inventory-mappen

- **Aangemaakt** wanneer een entiteit voor het eerst wordt gezien.
- **Bijgewerkt** per bestand wanneer alleen die bestandsdata wijzigt.
- **Verwijderd** (volledige map) wanneer `Get-RemovedEntities` een slug op schijf detecteert die afwezig is in de huidige API-fetch.

---

## 10. Levenscyclus van een scan-run

1. Module-import in afhankelijkheidsvolgorde.
2. Tokenacquisitie via `Get-AzAccessToken`.
3. Opzoektabellen ophalen (authenticatiecontexten, beheereenheden).
4. Activatieevenementen bijwerken (PIM-auditlog).
5. Directory-rollen ophalen (parallel, ThrottleLimit 3), post-processing sequentieel.
6. PIM-groepen ophalen (sequentieel).
7. Aflopende assignments detecteren.
8. Verwachte wijzigingen filteren.
9. Wijzigingen groeperen op ernst.
10. HTML-rapport (optioneel).
11. Git-commit.
12. Notificaties versturen.

---

## 11. Externe interfaces

| Interface | Richting | Protocol | Doel |
|---|---|---|---|
| Microsoft Graph API | Uitgaand | HTTPS REST | PIM-status ophalen |
| Azure DevOps Git | In/uitgaand | HTTPS Git | Uitchecken en pushen van inventory |
| Graph sendMail | Uitgaand | HTTPS REST | E-mailnotificaties |
| Webhook-URL | Uitgaand | HTTPS POST | Teams / Slack / Discord / aangepaste notificaties |
| ADO Git REST API | Inkomend (PIM Manager) | HTTPS REST | Wijzigingstijdlijn voor PIM Manager |

---

## 12. Toekomstige fases

| Fase | Functie | Opmerkingen |
|---|---|---|
| 4 | Auditlog acteurattributie | `GET /auditLogs/directoryAudits` — wie heeft een wijziging aangebracht |
| 4 | Beveiligingswaarschuwingen | `GET /identityGovernance/roleManagementAlerts/alerts` (alleen beta) |
| 4 | Openstaande aanvragen | `GET /roleManagement/directory/roleEligibilityScheduleRequests` |
| Toekomst | Aangepaste meldingsregels | Meld alleen bij specifieke rollen of wijzigingstypen |
| Toekomst | Self-hosted agentdocumentatie | Voor tenants met privénetwerktoegang |
