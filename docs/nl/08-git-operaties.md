# 08 — Git-operaties

## Inhoudsopgave

1. [Overzicht](#1-overzicht)
2. [Commitstrategie](#2-commitstrategie)
3. [Push en conflictoplossing](#3-push-en-conflictoplossing)
4. [Commitberichtformaat](#4-commitberichtformaat)
5. [Git-geschiedenis als auditspoor](#5-git-geschiedenis-als-auditspoor)
6. [Geschiedenis lezen: Get-InventoryFileFromGit](#6-geschiedenis-lezen-get-inventoryfilefromgit)
7. [Staginglijst: Get-StagedChanges](#7-staginglijst-get-stagedchanges)
8. [Git-configuratie in de pipeline](#8-git-configuratie-in-de-pipeline)

---

## 1. Overzicht

Git-operaties in PIM Monitor dienen twee doelen:

1. **Statuspersistentie**: het uitchecken van de repository aan het begin van elke pipeline-run levert de vorige PIM-status op voor diffing. Het terugschrijven van bijgewerkte inventory-bestanden en committen persisteert de nieuwe status voor de volgende run.

2. **Auditspoor**: elke commit vertegenwoordigt een momentopname van de PIM-configuratie. Externe tools (PIM Manager, scripts) kunnen deze geschiedenis opvragen via de Azure DevOps Git REST API.

Alle git-operaties zijn ingekapseld in `src/git.ps1` en worden aangeroepen vanuit `Scan-PimState.ps1`.

---

## 2. Commitstrategie

`Publish-InventoryChanges` wordt alleen aangeroepen wanneer `$changesBySeverity.Total > 0`. Bij geen wijzigingen wordt er geen commit gemaakt.

Binnen `Publish-InventoryChanges`:

1. **Alleen de inventory-map stagen**: `git add inventory/`. Bestanden buiten `inventory/` worden nooit gestaged door de pipeline.
2. **Controleer op wijzigingen**: `git diff --cached --quiet`. Exit code 0 = geen gestagede wijzigingen; de functie keert vroeg terug.
3. **Commit**: `git commit -m "scan: {tijdstempel}"`.
4. **Push**: `git push origin HEAD:main`.
5. **Opnieuw proberen bij afwijzing**: bij een mislukte push ophalen en rebasen, dan opnieuw pushen.

De functie retourneert `@{ committed; message; commitSha }`. De commit-SHA wordt doorgegeven aan notificatiefuncties.

---

## 3. Push en conflictoplossing

Doordat de pipeline op schema draait, kunnen twee runs overlappen. Run B checkt uit nadat Run A heeft uitgecheckt, maar voor Run A's push. Wanneer Run B probeert te pushen, is de remote al verder.

```
Run A: uitchecken → scannen → committen → pushen (slaagt)
Run B: uitchecken → scannen → committen → pushen (AFGEWEZEN: non-fast-forward)
                                                    │
                                                    └── git fetch origin main
                                                        git rebase origin/main
                                                        git push origin HEAD:main
```

De rebasestrategie heeft de voorkeur boven een mergecommit om de geschiedenis lineair te houden.

> [!CAUTION]
> Als de rebase mislukt (een echte conflict tussen twee scancommits), gooit `Publish-InventoryChanges` een uitzondering en mislukt de pipelinestap. Dit zou in normaal gebruik niet mogen voorkomen, omdat twee scans nooit hetzelfde bestand op incompatibele manieren wijzigen: beide schrijven deterministische JSON als volledige overschrijving. Bij een conflict: onderzoek of er een handmatige commit naar `inventory/` was terwijl de pipeline draaide.

---

## 4. Commitberichtformaat

```
scan: 2026-04-25T10:30:00Z
```

Formaat: `scan: {ISO 8601 UTC tijdstempel}`. Dit is opzettelijk machine-leesbaar: de wijzigingstijdlijn van PIM Manager leest het tijdstempel uit het commitbericht.

> [!IMPORTANT]
> Wijzig het commitberichtformaat niet. PIM Manager parseert het `scan: `-voorvoegsel. Zie [11-pim-manager-integratie.md](11-pim-manager-integratie.md).

De git-gebruiker is geconfigureerd als:
- `user.name`: `PIM Monitor`
- `user.email`: `pim-monitor@pipeline`

---

## 5. Git-geschiedenis als auditspoor

De geschiedenis van `inventory/` in de repository is het primaire auditspoor.

### Wat de geschiedenis toont

- **Welk bestand is gewijzigd**: het pad `inventory/directory-roles/global-administrator/policy.json` geeft aan dat het een beleidswijziging was op de rol Global Administrator.
- **Wat is gewijzigd**: `git diff {commitA} {commitB} -- inventory/.../policy.json` toont de exacte JSON-diff.
- **Wanneer het is gewijzigd**: de committijdstempel.

### Wat de geschiedenis (nog) niet toont

- **Wie de wijziging heeft aangebracht** in Entra ID: acteurattributie vereist het opvragen van `GET /auditLogs/directoryAudits` (fase 4).

### Geschiedenis opvragen via Azure DevOps REST API

```
# Scancommits weergeven
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/commits
    ?searchCriteria.itemPath=/inventory/
    &api-version=7.1

# Diff tussen twee commits
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/diffs/commits
    ?baseVersion={commitA}
    &targetVersion={commitB}
    &api-version=7.1

# Bestand lezen op een specifieke commit
GET https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/items
    ?path=/inventory/directory-roles/global-administrator/policy.json
    &version={commitId}
    &api-version=7.1
```

---

## 6. Geschiedenis lezen: Get-InventoryFileFromGit

`Get-InventoryFileFromGit` leest de inhoud van een inventory-bestand op een specifieke git-ref via `git show`:

```powershell
Get-InventoryFileFromGit -Path "inventory/directory-roles/global-administrator/definition.json" -Ref "HEAD~1"
```

Retourneert een geparseerd `PSCustomObject` of `$null` als het bestand niet bestond op die ref. Momenteel niet aangeroepen in de hoofdscanstroom; beschikbaar voor diagnostische scripts.

---

## 7. Staginglijst: Get-StagedChanges

`Get-StagedChanges` retourneert de lijst van gestagede bestanden met hun wijzigingsstatus (`A` = toegevoegd, `M` = gewijzigd, `D` = verwijderd), via `git diff --cached --name-status`. Momenteel niet aangeroepen in de hoofdscanstroom; beschikbaar voor uitbreidingen.

---

## 8. Git-configuratie in de pipeline

De `checkout`-stap in `monitor-pipeline.yml` vereist `persistCredentials: true` voor de push:

```yaml
- checkout: self
  persistCredentials: true
```

Zonder dit is de git-credential-helper niet geconfigureerd en mislukt `git push`.

Zowel de PowerShell-taak (`Publish-InventoryChanges`) als de bash-commitstap in de pipeline kunnen committen. In normaal gebruik commit de PowerShell-taak als eerste; de bash-stap vindt dan niets gestaged en sluit schoon af. Als de PowerShell-taak bestanden heeft geschreven maar niet heeft gecommit (bijv. door een uitzondering), commit de bash-stap de gedeeltelijke update.

Beide stappen draaien met `condition: always()` zodat opruiming plaatsvindt zelfs bij een fout.
