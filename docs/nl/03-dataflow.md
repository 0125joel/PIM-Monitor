# 03 — Dataflow

## Inhoudsopgave

1. [Stroom op hoog niveau](#1-stroom-op-hoog-niveau)
2. [Stap 1: Authenticatie](#2-stap-1-authenticatie)
3. [Stap 2: Opzoektabellen ophalen](#3-stap-2-opzoektabellen-ophalen)
4. [Stap 3: Activatieevenementen](#4-stap-3-activatieevenementen)
5. [Stap 4: Directory-rollen](#5-stap-4-directory-rollen)
6. [Stap 5: PIM-groepen](#6-stap-5-pim-groepen)
7. [Stap 6: Aflopende assignments](#7-stap-6-aflopende-assignments)
8. [Stap 7: Verwachte wijzigingen filteren](#8-stap-7-verwachte-wijzigingen-filteren)
9. [Stap 8: Ernstigheidsgroepering](#9-stap-8-ernstigheidsgroepering)
10. [Stap 9: Git-commit](#10-stap-9-git-commit)
11. [Stap 10: Notificaties](#11-stap-10-notificaties)
12. [Foutafhandeling](#12-foutafhandeling)
13. [Parallellisme](#13-parallellisme)

---

## 1. Stroom op hoog niveau

```
Pipeline-agent start
        │
        ▼
[Repository uitchecken]  ←── inventory/ = vorige status
        │
        ▼
[Microsoft.Graph-module installeren]
        │
        ▼
[AzurePowerShell@5]  ←── WIF OIDC-tokenuitwisseling
        │
        ▼
  Scan-PimState.ps1
        │
        ├── [Auth] Get-AzAccessToken → $token
        │
        ├── [Opzoek] Authenticatiecontexten + Beheereenheden
        │
        ├── [Events] PIM-auditlog → activation-events/JJJJ-MM.json
        │
        ├── [Directory-rollen] Definities + Beleid + Assignments (parallel)
        │       └── diff + inventory schrijven + $allChanges bijvullen
        │
        ├── [PIM-groepen] Discovery + Beleid + Assignments (sequentieel)
        │       └── diff + inventory schrijven + $allChanges bijvullen
        │
        ├── [Aflopen] Alle assignments scannen op naderende vervaldatum
        │       └── toevoegen aan $allChanges
        │
        ├── [Filter] Verwachte wijzigingen verwijderen (expected-changes.json)
        │
        ├── [Groepeer] Group-ChangesBySeverity → $changesBySeverity
        │
        ├── [Rapport] Export-ScanReport (indien REPORT_ARTIFACT=true)
        │
        ├── [Git] Publish-InventoryChanges (bij wijzigingen)
        │
        └── [Meld] Send-EmailNotification / Send-WebhookNotification
```

---

## 2. Stap 1: Authenticatie

De pipeline draait binnen een `AzurePowerShell@5`-taak die een OIDC-tokenuitwisseling uitvoert via een WIF-serviceverbinding. Dit maakt `Get-AzAccessToken` beschikbaar zonder enig client secret.

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
$token = if ($rawToken -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $rawToken).Password
} else {
    $rawToken
}
```

De `SecureString`-uitpakking is vereist op Az.Accounts 3.0+ (Az-module 12+). Het resulterende `$token` is een plaintext-string die als `Bearer`-header wordt meegegeven aan alle Graph API-aanroepen.

---

## 3. Stap 2: Opzoektabellen ophalen

Authenticatiecontexten en beheereenheden worden als eerste opgehaald omdat ze worden **gerefereerd door** beleids- en assignmentdata. Ze inventariseren vereist dezelfde stroom als andere entiteiten: ophalen, sluggen, map aanmaken, diff uitvoeren, inventory schrijven, verwijderde entiteiten detecteren.

---

## 4. Stap 3: Activatieevenementen

PIM-activatieevenementen komen van `GET /auditLogs/directoryAudits` gefilterd op `loggedByService eq 'PIM'`.

De fetch gebruikt een incrementeel venster:
1. Als het huidige maandbestand bestaat en niet leeg is, wordt het meest recente `activityDateTime` gelezen.
2. De fetch haalt events op vanaf dat tijdstempel + 1 seconde.
3. Nieuwe events worden samengevoegd in de bestaande array (gededupliceerd op `id`), gesorteerd op `activityDateTime`, en teruggeschreven.

> [!NOTE]
> Als `AuditLog.Read.All` niet is verleend op de app-registratie, registreert deze stap een waarschuwing en gaat verder. De rest van de scan wordt niet beïnvloed.

---

## 5. Stap 4: Directory-rollen

Dit is de meest complexe sectie omdat het een parallelle ophaalfase combineert met een sequentiële nabewerkingsfase.

### Ophaalfase (parallel)

```
Get-AllGraphItems(RoleDefinitions)  →  $roleDefinitions[]
        │
        └── ForEach-Object -Parallel -ThrottleLimit 3
                │
                ├── displayName slugificeren
                ├── Beleid ophalen (policyAssignment + uitgebreide regels)
                ├── Permanente assignments ophalen
                ├── Eligible assignments ophalen
                └── Actieve assignments ophalen
                        └── Retourneer: @{ definition; slug; policyAssignment; assignments }
```

`ThrottleLimit 3`: elke rol activeert 4 Graph API-aanroepen, dus maximaal 12 gelijktijdige aanvragen. Binnen het parallelle blok zijn module-functies niet beschikbaar via `$using:`; de retry- en pagineringlogica is daar lokaal ingebouwd.

### Nabewerkingsfase (sequentieel)

Na het verzamelen van alle rolresultaten:
1. `Remove-AssignmentNoise` verwijdert `scheduleInfo.startDateTime` (heartbeat-tijdstempel van Microsoft, wordt elke ~30 minuten bijgewerkt zonder gebruikersactie).
2. `Compare-InventoryFolder` vergelijkt oud vs nieuw per bestandstype.
3. `Save-InventoryFile` schrijft alle drie inventory-bestanden.
4. `Get-RemovedEntities` detecteert mappen op schijf waarvan de slug afwezig is in de huidige rollfetch.

---

## 6. Stap 5: PIM-groepen

PIM-onboarded groepen worden ontdekt via `GET /beta/identityGovernance/privilegedAccess/group/resources`.

> [!WARNING]
> Dit endpoint is door Microsoft gedeprecieerd en stopt data retourneren op **28 oktober 2026**. De vervangende aanpak is het verzamelen van unieke `groupId`-waarden uit `eligibilityScheduleInstances` en `assignmentScheduleInstances`.

Per ontdekte groep: definitie ophalen, eligible en actieve assignments ophalen (gefilterd op `groupId`), beleid ophalen (member + owner), ruisverwijdering, diff, inventory schrijven.

PIM-groepverwerking is sequentieel (geen parallel) omdat het groepsaantal doorgaans veel lager is dan het rollenantal.

---

## 7. Stap 6: Aflopende assignments

`Find-ExpiringAssignments` scant alle assignmentsets op entries waarbij `scheduleInfo.expiration.endDateTime` is ingesteld en binnen het geconfigureerde venster valt.

```powershell
$daysRemaining = ($expiryTime - $nowUtc).TotalDays
if ($daysRemaining -gt 0 -and $daysRemaining -le $WindowDays) {
    # Middel-ernstige wijziging met changeType = "expiring"
}
```

Het venster wordt bepaald door `EXPIRING_WINDOW_DAYS` (standaard 14 dagen). Deze entries worden opgenomen in notificaties maar wijzigen geen inventory-bestand.

---

## 8. Stap 7: Verwachte wijzigingen filteren

Als `expected-changes.json` bestaat, wordt `Test-ChangeIsExpected` aangeroepen voor elke entry in `$allChanges`. Na het filteren herschrijft de pipeline het bestand en verwijdert verlopen entries. Als er niets overblijft, wordt het bestand verwijderd.

---

## 9. Stap 8: Ernstigheidsgroepering

`Group-ChangesBySeverity` verdeelt `$allChanges` in vier buckets: `High`, `Medium`, `Low`, `Informational`, plus een `.Total`-teller. Dit resultaat wordt doorgegeven aan zowel de notificatiefuncties als de HTML-rapportexporteur.

---

## 10. Stap 9: Git-commit

`Publish-InventoryChanges` wordt alleen aangeroepen wanneer `$changesBySeverity.Total > 0`.

```
git add inventory/
git diff --cached --quiet  →  exit 0 = geen wijzigingen → vroeg terugkeren
git commit -m "scan: {ISO tijdstempel}"
git push origin HEAD:main
    └── bij afwijzing: git fetch + git rebase + opnieuw pushen
```

De rebasestrategie wordt verkozen boven merge-commits om de geschiedenis lineair te houden. De commit-SHA wordt na de push vastgelegd en doorgegeven aan notificatiefuncties.

---

## 11. Stap 10: Notificaties

Notificaties worden alleen verstuurd wanneer `$changesBySeverity.Total > 0`. Elk kanaal wordt onafhankelijk overgeslagen als het niet geconfigureerd is.

ADO-pipelinevariabelen die niet zijn ingesteld in de gebruikersinterface worden doorgegeven als letterlijke `$(NAAM_VARIABELE)`-tekenreeksen. `Scan-PimState.ps1` detecteert dit patroon en behandelt onopgeloste macros als niet geconfigureerd.

---

## 12. Foutafhandeling

Elke hoofdsectie in `Scan-PimState.ps1` is omgeven door `try/catch`. Een fout in één sectie voorkomt niet dat andere secties worden voltooid. De uitzondering wordt opnieuw gegenereerd na logging, waardoor de pipelinestap mislukt. Dit is opzettelijk: een gedeeltelijke scan die stilzwijgend slaagt is slechter dan een zichtbare pipelinefout.

`$ErrorActionPreference = "Stop"` is ingesteld bovenaan de orchestrator. Alle niet-terminerende fouten worden terminerend. Dit voorkomt stille fouten.

---

## 13. Parallellisme

| Sectie | Strategie | ThrottleLimit | Reden |
|---|---|---|---|
| Directory-rollen (ophalen) | `ForEach-Object -Parallel` | 3 | Elke rol = 4 API-aanroepen; 3 × 4 = 12 gelijktijdige aanvragen |
| Directory-rollen (nabewerking) | Sequentieel | — | Bestandswrites en wijzigingsverzameling mogen niet concurreren |
| PIM-groepen | Sequentieel | — | Laag groepsaantal; overhead niet de moeite waard |
| Opzoektabellen ophalen | Sequentieel | — | Slechts twee opzoektabellen |

> [!NOTE]
> Het `-Parallel`-blok in de Directory-rollen-sectie heeft geen toegang tot module-functies via `$using:`. De retry- en pagineringlogica zijn lokaal ingebouwd als scriptblokken.
