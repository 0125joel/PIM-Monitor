# 11 — PIM Manager-integratie

## Inhoudsopgave

1. [Overzicht](#1-overzicht)
2. [Het inventorycontract](#2-het-inventorycontract)
3. [ADO Git REST API-endpoints](#3-ado-git-rest-api-endpoints)
4. [Commitberichtparsing](#4-commitberichtparsing)
5. [Authenticatie in PIM Manager](#5-authenticatie-in-pim-manager)
6. [Verbindingsinstelstroom](#6-verbindingsinstelstroom)
7. [Integratiepunten in PIM Manager](#7-integratiepunten-in-pim-manager)
8. [Weergave van ernst](#8-weergave-van-ernst)
9. [Wat PIM Monitor niet mag doen](#9-wat-pim-monitor-niet-mag-doen)

---

## 1. Overzicht

PIM Monitor en PIM Manager zijn **zelfstandige projecten** zonder codeafhankelijkheid. PIM Monitor draait als pipeline; PIM Manager is een webapplicatie. Het enige koppelpunt is het **inventory-bestandsformaat** opgeslagen in git.

De geplande `/monitor`-pagina van PIM Manager leest de wijzigingstijdlijn uit de PIM Monitor-repository via de Azure DevOps Git REST API. PIM Manager heeft geen toegang nodig tot de pipeline, de pipelinevariabelen of de PIM Monitor-broncode, alleen leestoegang tot de repository.

```
PIM Monitor-repo (git)
        │
        │  Azure DevOps Git REST API
        │  (MSAL-sessie van gebruiker, incrementele toestemming)
        ▼
PIM Manager /monitor-pagina
        │
        ├── Scancommits weergeven → tijdlijn
        ├── Diff tussen commits → wat is gewijzigd
        └── Bestand lezen op commit → momentopnameweergave
```

---

## 2. Het inventorycontract

De volgende garanties worden door PIM Monitor gehandhaafd als een versiecontract voor consumenten:

| Garantie | Details |
|---|---|
| Mapstructuur | `inventory/directory-roles/{slug}/`, `inventory/pim-groups/{slug}/`, `inventory/authentication-contexts/{slug}/`, `inventory/administrative-units/{slug}/`, `inventory/activation-events/` |
| Bestandsnamen | Altijd `definition.json`, `policy.json`, `assignments.json` (of alleen `definition.json` voor opzoekentiteiten) |
| JSON-formaat | Gesorteerde sleutels, gesorteerde arrays, geen `@odata.*`-metadata, 2-spatie-inspringing, UTF-8 zonder BOM |
| Volledige API-respons | Geen `$select`-filtering; alle Graph API-velden aanwezig |
| Één commit per scan | Elke pipeline-run produceert maximaal één commit naar `inventory/` |
| Commitberichtformaat | `scan: JJJJ-MM-DDTHH:mm:ssZ` |

**Breaking changes** aan een van de bovenstaande vereisen afstemming met PIM Manager voor inzet. Behandel dit als een versioned API.

> [!WARNING]
> Wijzig nooit het commitberichtformaat, de mapstructuur of het bestandsnaamschema zonder eerst de parser van PIM Manager bij te werken.

---

## 3. ADO Git REST API-endpoints

PIM Manager gebruikt deze REST API-aanroepen om de wijzigingstijdlijn op te bouwen:

### Scancommits weergeven

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/commits
    ?searchCriteria.itemPath=/inventory/
    &api-version=7.1
```

Retourneert commits die minimaal één bestand onder `inventory/` hebben geraakt. PIM Manager filtert op het commitberichtvoorvoegsel `scan: ` om scancommits te onderscheiden van handmatige commits.

### Diff tussen twee commits

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/diffs/commits
    ?baseVersion={commitA}
    &targetVersion={commitB}
    &api-version=7.1
```

Retourneert de lijst van gewijzigde bestanden met hun wijzigingstype. De bestandspaden onthullen de entiteit en het bestandstype.

### Huidige inventorystatus lezen

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
    ?path=/inventory/
    &recursionLevel=full
    &api-version=7.1
```

Retourneert een platte lijst van alle bestanden onder `inventory/`, inclusief hun paden en inhouds-URL's.

### Bestand lezen op een specifieke commit

```
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
    ?path=/inventory/directory-roles/global-administrator/policy.json
    &version={commitId}
    &api-version=7.1
```

Retourneert de ruwe JSON-inhoud van het bestand op de opgegeven commit.

---

## 4. Commitberichtparsing

PIM Manager parseert het scantijdstempel uit het commitbericht:

```
"scan: 2026-04-25T10:30:00Z"
       └──────────────────── ISO 8601 UTC tijdstempel
```

Het formaat is vastgelegd. PIM Manager splitst op `"scan: "` en parseert de rest als datetime. Handmatige commits naar `inventory/` die dit voorvoegsel niet hebben, worden anders weergegeven in de tijdlijn.

---

## 5. Authenticatie in PIM Manager

PIM Manager gebruikt MSAL met **incrementele toestemming**. Het Azure DevOps API-bereik wordt alleen aangevraagd wanneer de gebruiker de Monitor-workload inschakelt:

```
ADO API-bereik: 499b84ac-1321-427f-aa17-267ca6975798/.default
```

Dit is de Azure DevOps-resource-ID. De gebruiker moet minimaal **Lezer**-toegang hebben tot de PIM Monitor-repository in Azure DevOps.

---

## 6. Verbindingsinstelstroom

Voordat de `/monitor`-pagina data kan ophalen, configureert de gebruiker welke repository gelezen moet worden. Drie waarden zijn vereist:

| Instelling | Voorbeeld | Bron |
|---|---|---|
| Organisatie | `contoso` | ADO-organisatienaam |
| Project | `security-monitoring` | ADO-projectnaam |
| Repository | `pim-monitor` | ADO-repositorynaam |

PIM Manager bouwt de API-basis-URL als:
```
https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}
```

Optionele snelkoppeling: de gebruiker plakt een DevOps-repository-URL en PIM Manager extraheert org, project en repo uit het URL-patroon.

Configuratie wordt opgeslagen in `localStorage` (client-kant, geen backend). PIM Monitor hoeft niets te weten van deze configuratie.

---

## 7. Integratiepunten in PIM Manager

| Integratiepunt | PIM Manager-locatie | Beschrijving |
|---|---|---|
| Workloadtype | `types/workload.types.ts` | `"monitor"` toevoegen aan `WorkloadType`-union |
| Auth-bereik | `hooks/useIncrementalConsent.ts` | ADO API-bereik registreren |
| Service | `services/devopsService.ts` (nieuw) | ADO Git REST API-aanroepen |
| Types | `types/monitor.types.ts` (nieuw) | `MonitorChangeEntry`, `MonitorTimeline`, `DevOpsConfig` |
| Pagina | `app/monitor/page.tsx` (nieuw) | Wijzigingstijdlijn-gebruikersinterface |
| Navigatie | `components/Sidebar.tsx` | Monitor-navigatie-item toevoegen |
| Workload-chip | `components/WorkloadChips.tsx` | Monitor in- en uitschakelen |

De bestaande `withRetry()`-helper in de servicelaag van PIM Manager is ook van toepassing op ADO REST API-aanroepen.

---

## 8. Weergave van ernst

PIM Monitor classificeert wijzigingen op ernst. De `/monitor`-pagina van PIM Manager geeft deze consistent weer:

| Ernst | Aanbevolen kleur | Voorbeelden |
|---|---|---|
| Hoog | Rood | MFA uitgeschakeld, permanente assignment aangemaakt, rol verwijderd uit PIM |
| Middel | Oranje/amber | Activatieduur gewijzigd, nieuwe eligible assignment, aflopende assignment |
| Laag | Groen | Notificatie-instellingen gewijzigd, assignment verlopen/verwijderd |
| Informatief | Grijs | Nieuwe API-eigenschap verschenen, weergavenaam gewijzigd |

---

## 9. Wat PIM Monitor niet mag doen

Om het contract schoon en de twee projecten onafhankelijk te houden:

- **Geen PIM Manager-specifieke opmaak.** Inventory-bestanden slaan ruwe API-data op. PIM Manager formateert deze voor weergave.
- **Geen bewustzijn van PIM Manager-types.** PIM Monitor importeert of verwijst niet naar PIM Manager-typedefinities.
- **Geen commitstructuurwijzigingen voor PIM Manager.** Het commitberichtformaat en de inventorymapstructuur dienen het auditspoor; PIM Manager past zich daaraan aan.
- **Geen webhook naar PIM Manager.** PIM Manager leest git-geschiedenis; het ontvangt geen pushnotificaties van PIM Monitor.
