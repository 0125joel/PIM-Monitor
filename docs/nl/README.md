# PIM Monitor — Ontwikkelaarsdocumentatie

Technische referentie voor beheerders en ontwikkelaars die met of aan PIM Monitor werken.

---

## Inhoudsopgave

| # | Document | Inhoud |
|---|---|---|
| [00](00-architectuur.md) | Architectuur | Systeemontwerp, ontwerpbeslissingen, kwaliteitsattributen |
| [01](01-introductie.md) | Introductie | Probleemstelling, oplossing, doelgroep, vereisten |
| [02](02-mappenstructuur.md) | Mappenstructuur | Repository-indeling, elke map en elk bestand uitgelegd |
| [03](03-dataflow.md) | Dataflow | Scan-run volgorde, elke verwerkingsstap in detail |
| [04](04-graph-api.md) | Graph API | Endpoints, v1.0 vs beta, paginering, throttling |
| [05](05-inventory-formaat.md) | Inventory-formaat | JSON-schema per bestandstype, deterministische serialisatie |
| [06](06-wijzigingsdetectie.md) | Wijzigingsdetectie | Diff-engine, ernstigheidsclassificatie, ruis onderdrukken |
| [07](07-notificaties.md) | Notificaties | E-mail- en webhookkanalen, payload-formaten |
| [08](08-git-operaties.md) | Git-operaties | Commitstrategie, push/rebase, geschiedenis als auditspoor |
| [09](09-authenticatie.md) | Authenticatie | Workload Identity Federation, token ophalen |
| [10](10-pipeline.md) | Pipeline | YAML-anatomie, planning, variabelen, artefacten |
| [11](11-pim-manager-integratie.md) | PIM Manager-integratie | Inventorycontract, ADO REST API, authenticatiestroom |

---

## Snelreferentie

**Startpunt:** `src/Scan-PimState.ps1` — orkestreert elke scan-run.

**Volgorde van module-import:**
```
helpers.ps1 → graphEndpoints.ps1 → diff.ps1 → git.ps1 → notifications.ps1
```

**Inventory-root:** `inventory/` — vastgelegd in git; de repository is de statusopslag.

**Cruciale beperking:** Alle JSON wordt geschreven via `ConvertTo-DeterministicJson` (in `helpers.ps1`).
Zonder deze functie levert elke run valse positieven op door gewijzigde eigenschapsvolgorde.

**Authenticatie:** `AzurePowerShell@5`-taak met een WIF-serviceverbinding.
Geen client secrets in de codebase.

---

## Hulp nodig?

- Architectuurkeuzes: [00-architectuur.md](00-architectuur.md)
- Iets veranderde onverwacht: [06-wijzigingsdetectie.md](06-wijzigingsdetectie.md)
- Notificaties worden niet verstuurd: [07-notificaties.md](07-notificaties.md)
- Pipeline wordt niet uitgevoerd: [10-pipeline.md](10-pipeline.md)
- Authenticatiefouten: [09-authenticatie.md](09-authenticatie.md)
