# 06 — Wijzigingsdetectie

## Inhoudsopgave

1. [Overzicht](#1-overzicht)
2. [Startpunt: Compare-InventoryFolder](#2-startpunt-compare-inventoryfolder)
3. [Definitiediff: Compare-FlatProperties](#3-definitiediff-compare-flatproperties)
4. [Beleidsdiff: Compare-PolicyRules](#4-beleidsdiff-compare-policyrules)
5. [Assignmentdiff: Compare-Assignments](#5-assignmentdiff-compare-assignments)
6. [Ernstigheidsclassificatie](#6-ernstigheidsclassificatie)
7. [Ruisonderdrukking: Remove-AssignmentNoise](#7-ruisonderdrukking-remove-assignmentnoise)
8. [Aflopende assignments: Find-ExpiringAssignments](#8-aflopende-assignments-find-expiringassignments)
9. [Onderdrukking van verwachte wijzigingen](#9-onderdrukking-van-verwachte-wijzigingen)
10. [Schema van een wijzigingsentry](#10-schema-van-een-wijzigingsentry)
11. [De diff-engine uitbreiden](#11-de-diff-engine-uitbreiden)

---

## 1. Overzicht

De diff-engine in `diff.ps1` volgt een **declaratief, regelgebaseerd ontwerp**. Ernst wordt bepaald door opzoektabellen, niet door if/else-vertakkingen. Een ernstigheidsregel toevoegen of aanpassen betekent een tabelentry bewerken, niet functies wijzigen.

De engine werkt op drie granulariteitsniveaus:
- **Mapniveau** (`Compare-InventoryFolder`): detecteert nieuwe of verwijderde entiteiten.
- **Bestandsniveau** (gedispatched door `Compare-InventoryFolder`): detecteert welk bestand is gewijzigd.
- **Subobjectniveau**: drie gespecialiseerde vergelijkers per bestandstype.

---

## 2. Startpunt: Compare-InventoryFolder

```powershell
Compare-InventoryFolder -FolderPath $mappad -NewData $nieuweData -EntityName $entiteitnaam
```

Parameters:
- `$mappad`: pad naar de inventorymap van de entiteit.
- `$nieuweData`: hashtabel op bestandstype (`definition`, `policy`, `assignments`).
- `$entiteitnaam`: weergavenaam voor logberichten en wijzigingsbeschrijvingen.

Logica:

```
Voor elk bestandstype in $nieuweData:
  │
  ├── $oudeData = Read-PreviousInventoryFile(bestandspad)
  │
  ├── $oudeData == null EN $nieuweData != null
  │       → Nieuwe entiteit: Hoog voor "definition", Middel voor overige
  │
  ├── $oudeData != null EN $nieuweData == null
  │       → Entiteit verwijderd: Hoog
  │
  └── Test-ObjectEqual($oudeData, $nieuweData)
          → Gelijk: overslaan
          → Verschil: doorsturen naar vergelijker per bestandstype
                  "definition"  → Compare-FlatProperties
                  "policy"      → Compare-PolicyRules
                  "assignments" → Compare-Assignments
```

---

## 3. Definitiediff: Compare-FlatProperties

Vergelijkt de twee `definition.json`-objecten op **het niveau van afzonderlijke eigenschappen**. Produceert één wijzigingsentry per gewijzigde, toegevoegde of verwijderde eigenschap.

Eigenschappen in `$script:DiffIgnoreProperties` worden volledig overgeslagen (systeemtijdstempels, OData-metadata, ID-velden).

Voor elke niet-genegeerde eigenschap:
- **Aanwezig in nieuw maar niet in oud** (`new_property`): altijd `Informatief`.
- **Aanwezig in oud maar niet in nieuw** (`removed_property`): ernst via `Get-PropertySeverity`.
- **Aanwezig in beide maar verschillend** (`updated`): ernst via `Get-PropertySeverity`.

### Eigendomsernstigheidstabel

```powershell
$script:PropertySeverity = [ordered]@{
    "rolePermissions"        = "High"
    "allowedResourceActions" = "High"
    "isPrivileged"           = "High"
    "isEnabled"              = "High"
    "allowedPrincipalTypes"  = "Medium"
    "displayName"            = "Informational"
    "description"            = "Informational"
    "version"                = "Informational"
}
$script:DefaultPropertySeverity = "Informational"
```

Overeenkomst is prefix-gebaseerd. Onbekende eigenschappen vallen terug op `Informational`.

---

## 4. Beleidsdiff: Compare-PolicyRules

Vergelijkt `policy.json`-objecten op **het niveau van afzonderlijke regels**. Matcht regels op hun `id`-veld.

### Detectie van PIM-groepswrapper

Als het beleidsobject `member`- of `owner`-sleutels heeft (PIM-groepsbeleid), detecteert de functie dit en roept zichzelf recursief aan voor elk subbeleid.

### Ernstigheidsregel-ID-tabel

```powershell
$script:PolicyRuleSeverity = [ordered]@{
    "Enablement_EndUser_Assignment"           = "High"
    "Approval_EndUser_Assignment"             = "High"
    "AuthenticationContext_EndUser_Assignment" = "High"
    "Expiration_EndUser_Assignment"           = "Medium"
    "Expiration_Admin_Eligibility"            = "Medium"
    "Expiration_Admin_Assignment"             = "Medium"
    "Enablement_Admin_Assignment"             = "Medium"
    "Enablement_Admin_Eligibility"            = "Medium"
    "Notification_"                           = "Low"
}
$script:DefaultPolicyRuleSeverity = "Medium"
```

Volgorde is belangrijk: eerste overeenkomst wint. `"Notification_"` is een prefixovereenkomst die alle negen notificatieregels vangt.

---

## 5. Assignmentdiff: Compare-Assignments

Vergelijkt `assignments.json`-objecten op **het niveau van afzonderlijke assignmententries**. Matcht entries op een samengestelde sleutel.

### Assignmentsleutel

`Get-AssignmentKey` bouwt een stabiele samengestelde sleutel:

```
Directory-rollen:  principalId + "|" + directoryScopeId
PIM-groepen:       principalId + "|" + groupId + "|" + accessId
Terugval:          assignment.id
```

### Wijzigingstypen en ernst

| Situatie | changeType | Ernst |
|---|---|---|
| Sleutel in oud maar niet in nieuw | `removed` | Laag |
| Sleutel in nieuw, categorie `permanent` | `added` | Hoog |
| Sleutel in nieuw, categorie `eligible` | `added` | Middel |
| Sleutel in nieuw, categorie `active` | `added` | Middel |
| Sleutel in nieuw, `scheduleInfo.expiration.endDateTime == null` (elke categorie) | `added` | Hoog |
| Sleutel in beide, maar waarden verschillen | `updated` | Middel |

---

## 6. Ernstigheidsclassificatie

PIM Monitor gebruikt vier ernstniveaus:

| Ernst | Betekenis | Voorbeelden |
|---|---|---|
| Hoog | Directe beveiligingsimpact | MFA uitgeschakeld, goedkeuring verwijderd, permanente assignment, rol verwijderd uit PIM |
| Middel | Significante configuratiewijziging | Activatieduur gewijzigd, nieuwe eligible/actieve assignment, verloopbeleid gewijzigd |
| Laag | Beheers- of cosmetische wijziging | Notificatie-instellingen gewijzigd, weergavenaam gewijzigd, assignment verlopen/verwijderd |
| Informatief | Nieuwe API-velden, activatieevenementen | Nieuwe eigenschap in Graph-respons verschenen |

Alle ernstigheidsregels zijn gedefinieerd als opzoektabellen in `diff.ps1`. Om een ernst te wijzigen, bewerk de tabelentry — geen functies aanpassen.

---

## 7. Ruisonderdrukking: Remove-AssignmentNoise

`Remove-AssignmentNoise` verwijdert velden uit assignmentobjecten die op een vaste schema veranderen zonder een werkelijke gebruikers- of beheerdersactie te vertegenwoordigen.

```powershell
$script:AssignmentNoisePaths = @('scheduleInfo.startDateTime')
```

`scheduleInfo.startDateTime` wordt door Microsoft Graph elke ~30 minuten bijgewerkt als onderdeel van een intern inrichtingsheartbeat. Zonder verwijdering zou elke scan een wijziging committen voor elke actieve assignment.

De functie maakt een diepe kopie via JSON-round-trip voor het wijzigen, zodat de originele objecten nooit worden gemuteerd.

---

## 8. Aflopende assignments: Find-ExpiringAssignments

Scant alle assignmentcategorieën op entries waarbij `scheduleInfo.expiration.endDateTime` is ingesteld en binnen het geconfigureerde venster valt. Geeft `Medium`-ernstige wijzigingen terug met `changeType = "expiring"`. Wijzigt geen inventory-bestand.

Venster instelbaar via `EXPIRING_WINDOW_DAYS` (standaard 14 dagen).

---

## 9. Onderdrukking van verwachte wijzigingen

`Test-ChangeIsExpected` controleert elke wijziging op overeenkomst met entries in `expected-changes.json`.

Schema van `expected-changes.json`:

```json
{
  "expected": [
    {
      "workload":    "directory-roles",
      "entity":      "global-administrator",
      "fileType":    "policy",
      "ruleId":      "Expiration_Admin_Eligibility",
      "expiresUtc":  "2026-05-01T00:00:00Z",
      "reason":      "Geplande beleidsupdating tijdens onderhoudsvenster"
    }
  ]
}
```

Overeenkomst is AND-gebaseerd: alle opgegeven velden moeten overeenkomen. Een veld weglaten maakt het een wildcard voor die dimensie. Na het filteren herschrijft de pipeline het bestand en verwijdert verlopen entries.

---

## 10. Schema van een wijzigingsentry

Elke wijzigingsentry is een PowerShell-hashtabel met deze standaardvelden:

| Veld | Type | Altijd aanwezig | Beschrijving |
|---|---|---|---|
| `severity` | string | Ja | `High`, `Medium`, `Low` of `Informational` |
| `changeType` | string | Ja | `created`, `deleted`, `updated`, `added`, `removed`, `new_property`, `removed_property`, `expiring` |
| `description` | string | Ja | Leesbare samenvatting |
| `context` | string | Ja | Weergavenaam van de entiteit |
| `old` | any | Nee | Vorige waarde (null voor nieuwe entiteiten) |
| `new` | any | Nee | Nieuwe waarde (null voor verwijderde entiteiten) |
| `fileType` | string | Meestal | `definition`, `policy` of `assignments` |
| `ruleId` | string | Beleidswijzigingen | Beleidsregel-ID |
| `propertyKey` | string | Definitiewijzigingen | Eigenschapsnaam |
| `category` | string | Assignmentwijzigingen | `permanent`, `eligible` of `active` |
| `isAlert` | boolean | Alleen aflopen | Markeert aflopende-assignment-entries |
| `daysRemaining` | int | Alleen aflopen | Dagen tot vervaldatum |

---

## 11. De diff-engine uitbreiden

**Nieuwe ernstigheidsregel voor een beleidsregel-ID:** bewerk `$script:PolicyRuleSeverity` in `diff.ps1`.

**Nieuwe ernstigheidsregel voor een definitie-eigenschap:** bewerk `$script:PropertySeverity` in `diff.ps1`.

**Ruis van een assignmentveld onderdrukken:** voeg het dot-notatie-pad toe aan `$script:AssignmentNoisePaths`.

**Een eigenschap aan de diff-negeerlijst toevoegen:** voeg toe aan `$script:DiffIgnoreProperties` (voor systeembeheerde velden die veranderen zonder gebruikersactie).

**Nieuw workloadtype toevoegen:** `Compare-InventoryFolder` is workload-agnostisch en verwerkt elke `@{ definition; policy; assignments }`-structuur. Voeg de fetchlogica toe in `Scan-PimState.ps1`, roep `Compare-InventoryFolder` aan, roep `Save-InventoryFile` aan en roep `Get-RemovedEntities` aan. Geen wijzigingen aan `diff.ps1` nodig tenzij het nieuwe type nieuwe regel-ID's of eigenschapsnamen introduceert.
