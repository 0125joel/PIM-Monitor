# 02 — Mappenstructuur

## Inhoudsopgave

1. [Repository-root](#1-repository-root)
2. [src/](#2-src)
3. [inventory/](#3-inventory)
4. [docs/](#4-docs)
5. [docs-site/](#5-docs-site)
6. [Naamgevingsconventies](#6-naamgevingsconventies)
7. [Relaties tussen bestanden](#7-relaties-tussen-bestanden)

---

## 1. Repository-root

```
PIM-Monitor/
├── monitor-pipeline.yml         Pipeline-definitie (schema, taken, variabelen)
├── expected-changes.json        Optioneel: regels voor onderdrukking van wijzigingen
├── inventory/                   PIM-statusmomentopnamen (door pipeline gecommit)
├── src/                         PowerShell-bronscripts
├── docs/                        Ontwikkelaarsdocumentatie (deze map)
├── docs-site/                   Gebruikersdocumentatiesite (Docusaurus)
└── .gitignore
```

| Bestand / Map | Eigenaar | Doel |
|---|---|---|
| `monitor-pipeline.yml` | Ontwikkelaar | Definieert schema, authenticatietaak en git-commitstap |
| `expected-changes.json` | Beheerder | Onderdrukt bekende-goede wijzigingen om meldingsmoeheid te voorkomen |
| `inventory/` | Pipeline | Geschreven en gecommit door de pipeline tijdens elke scan |
| `src/` | Ontwikkelaar | PowerShell-scripts die worden uitgevoerd tijdens een scan-run |
| `docs/` | Ontwikkelaar | Deze documentatie |
| `docs-site/` | Ontwikkelaar | Docusaurus-gebruikersdocumentatie |

> [!NOTE]
> `expected-changes.json` is optioneel en wordt beheerd door de beheerder, niet gegenereerd door de pipeline. De pipeline leest het aan het begin van elke scan en herschrijft het na de filterstap (waarbij verbruikte en verlopen entries worden verwijderd).

---

## 2. src/

```
src/
├── Scan-PimState.ps1       Orchestrator — startpunt voor elke pipeline-run
├── graphEndpoints.ps1      URI-constanten en URI-bouwfuncties per entiteit
├── helpers.ps1             Gedeelde hulpprogramma's (paginering, JSON, inventory-I/O)
├── diff.ps1                Diff-engine en ernstigheidsclassificatie
├── git.ps1                 Git-commit, push en geschiedenisfuncties
├── notifications.ps1       Bezorging van e-mail- en webhooknotificaties
└── README.md               Testhandleiding voor lokale validatie
```

### Scan-PimState.ps1

De overkoepelende orchestrator. Dit is het enige bestand dat de pipeline rechtstreeks uitvoert. Alle andere modules worden via dot-sourcing geimporteerd.

Verantwoordelijkheden: modules importeren in afhankelijkheidsvolgorde, Graph API-token ophalen, alle scansecties orkestreren, verwachte wijzigingen filteren, resultaten samenvatten en git en notificaties aansturen.

### graphEndpoints.ps1

Centraliseert alle Graph API-URI's. Bevat:
- `$script:GraphV1` en `$script:GraphBeta` basisdomeinen.
- `$script:GraphEndpoints`-hashtabel voor verzamelingsendpoints.
- URI-bouwfuncties voor endpoints per entiteit (vereisen een rol-ID of groeps-ID als filter).

> [!TIP]
> Alle API-versiebeslissingen staan hier. Wanneer Microsoft een beta-endpoint naar v1.0 promoveert, hoeft alleen dit bestand te worden bijgewerkt.

### helpers.ps1

Algemene hulpprogramma's gebruikt door alle andere modules:

| Functie | Doel |
|---|---|
| `ConvertTo-DeterministicJson` | Object serialiseren naar gesorteerde, genormaliseerde JSON |
| `Get-AllGraphItems` | Pagineren door een Graph-endpoint, alle items retourneren |
| `Get-InventorySlug` | `displayName` omzetten naar kebab-case mapnaam |
| `New-InventoryFolder` | `inventory/{workload}/{slug}` aanmaken indien niet bestaat |
| `Save-InventoryFile` | Object schrijven naar `{map}/{naam}.json` via deterministische serialisatie |

### diff.ps1

De motor voor wijzigingsdetectie en -classificatie. Zie [06-wijzigingsdetectie.md](06-wijzigingsdetectie.md) voor een uitgebreide beschrijving van alle functies.

### git.ps1

Afhandeling van git-operaties binnen de pipeline:

| Functie | Doel |
|---|---|
| `Publish-InventoryChanges` | Stagen, committen, pushen; eenmalig rebasen bij afwijzing |
| `Get-StagedChanges` | Name-statuslijst van gestagede bestanden retourneren |
| `Get-InventoryFileFromGit` | Bestand lezen op een specifieke git-ref |

### notifications.ps1

Bezorging van notificaties en opbouw van payloads. Zie [07-notificaties.md](07-notificaties.md) voor details over alle functies en payloadformaten.

---

## 3. inventory/

```
inventory/
├── directory-roles/
│   └── {rol-slug}/
│       ├── definition.json
│       ├── policy.json
│       └── assignments.json
├── pim-groups/
│   └── {groep-slug}/
│       ├── definition.json
│       ├── policy.json
│       └── assignments.json
├── authentication-contexts/
│   └── {slug}/
│       └── definition.json
├── administrative-units/
│   └── {slug}/
│       └── definition.json
└── activation-events/
    └── JJJJ-MM.json
```

Deze map wordt **niet handmatig bewerkt**. Ze wordt uitsluitend door de pipeline geschreven via `Save-InventoryFile`. Handmatige bewerkingen kunnen valse positieven veroorzaken bij de volgende scan.

> [!WARNING]
> Voeg `inventory/` niet toe aan `.gitignore`. De pipeline gebruikt de uitgecheckte inventory-bestanden als vorige status. Als de map wordt uitgesloten, rapporteert elke scan elke entiteit als nieuw.

---

## 4. docs/

```
docs/
├── en/                      Engelstalige documentatie (12 bestanden + README)
├── nl/                      Nederlandstalige documentatie (deze map)
└── architecture.md          Oorspronkelijk planningsdocument (vervangen door docs/en/)
```

> [!NOTE]
> `docs/architecture.md` is het oorspronkelijke planningsdocument uit de initiële ontwerpfase. Het wordt bewaard voor historische referentie. De gezaghebbende ontwikkelaarsdocumentatie staat in `docs/en/` en `docs/nl/`.

---

## 5. docs-site/

De Docusaurus-documentatiesite voor **gebruikers** (beheerders, installateurs). Behandelt installatie, configuratie en referentiegidsen voor pipeline-variabelen en notificatie-instellingen. Staat los van deze ontwikkelaarsdocumentatie.

---

## 6. Naamgevingsconventies

| Conventie | Voorbeeld | Regel |
|---|---|---|
| Inventory-mapnamen | `global-administrator` | kebab-case; afgeleid van `displayName` via `Get-InventorySlug` |
| Inventory-bestandsnamen | `definition.json` | Altijd een van: `definition.json`, `policy.json`, `assignments.json` |
| Activatieeventsbestanden | `2026-04.json` | ISO jaar-maandformaat; één bestand per kalendermaand |
| Bronscripts | `Scan-PimState.ps1` | PascalCase; PowerShell werkwoord-zelfstandignaamwoord-conventie |
| Pipeline-bestand | `monitor-pipeline.yml` | kebab-case; voorvoegsel `monitor-` |

---

## 7. Relaties tussen bestanden

```
monitor-pipeline.yml
    │
    └─ voert uit ────────────── src/Scan-PimState.ps1
                                        │
                      dot-sources ──────┼──── src/helpers.ps1
                                        │         ↑
                      dot-sources ──────┼──── src/graphEndpoints.ps1
                                        │
                      dot-sources ──────┼──── src/diff.ps1
                                        │         (roept ConvertTo-DeterministicJson
                                        │          aan uit helpers.ps1)
                      dot-sources ──────┼──── src/git.ps1
                                        │
                      dot-sources ──────┼──── src/notifications.ps1
                                        │         (roept ConvertTo-DeterministicJson
                                        │          aan uit helpers.ps1)
                                        │
                         leest/schrijft ┴──── inventory/
                                              (terug gecommit naar git door pipeline)
```

De orchestrator (`Scan-PimState.ps1`) is het enige bestand dat functies uit meerdere modules aanroept. Individuele modules zijn cohesief en roepen elkaar niet aan, met één uitzondering: `diff.ps1` en `notifications.ps1` roepen beide `ConvertTo-DeterministicJson` aan uit `helpers.ps1`.
