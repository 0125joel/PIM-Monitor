# 04 — Graph API

## Inhoudsopgave

1. [API-versiebeleid](#1-api-versiebeleid)
2. [Endpointoverzicht](#2-endpointoverzicht)
3. [Verzamelingsendpoints](#3-verzamelingsendpoints)
4. [URI-bouwfuncties per entiteit](#4-uri-bouwfuncties-per-entiteit)
5. [Paginering](#5-paginering)
6. [Throttling en retry](#6-throttling-en-retry)
7. [Gedeprecieerde endpoints](#7-gedeprecieerde-endpoints)
8. [Een nieuw endpoint toevoegen](#8-een-nieuw-endpoint-toevoegen)

---

## 1. API-versiebeleid

PIM Monitor gebruikt standaard **v1.0-endpoints**. Beta wordt alleen gebruikt wanneer specifieke eigenschappen niet beschikbaar zijn in v1.0. Dit minimaliseert blootstelling aan breaking changes in de beta-API.

De regel: gebruik de minst geprivilegieerde, meest stabiele versie die de vereiste data biedt.

> [!WARNING]
> Beta-endpoints kunnen zonder aankondiging worden gewijzigd of verwijderd. Elk gebruik van een beta-endpoint moet worden gedocumenteerd met de reden en een notitie over wanneer dit opnieuw beoordeeld moet worden.

---

## 2. Endpointoverzicht

| Endpoint | Versie | Waarom |
|---|---|---|
| `GET /roleManagement/directory/roleDefinitions` | **beta** | `isPrivileged`, `allowedPrincipalTypes` en `version` zijn alleen beschikbaar in beta |
| `GET /roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '{id}'` | v1.0 | Permanente (niet-PIM) assignments |
| `GET /roleManagement/directory/roleEligibilitySchedules?$filter=roleDefinitionId eq '{id}'` | v1.0 | PIM eligible assignment-schema's |
| `GET /roleManagement/directory/roleAssignmentSchedules?$filter=roleDefinitionId eq '{id}'` | v1.0 | PIM actieve/geactiveerde assignment-schema's |
| `GET /policies/roleManagementPolicyAssignments?$filter=...scopeType eq 'Directory'...` | v1.0 | Directory-rolbeleid |
| `GET /policies/roleManagementPolicyAssignments?$filter=...scopeType eq 'Group'...` | **beta** | `scopeType eq 'Group'`-filter werkt niet in v1.0 |
| `GET /groups/{id}` | v1.0 | Groepseigenschappen |
| `GET /identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$filter=groupId eq '{id}'` | v1.0 | PIM-groep eligible assignments |
| `GET /identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$filter=groupId eq '{id}'` | v1.0 | PIM-groep actieve/permanente assignments |
| `GET /identityGovernance/privilegedAccess/group/resources` | **beta** | PIM-groepsdiscovery — beta, niet gedocumenteerd voor discovery, geen einddatum (afgevangen) |
| `GET /identity/conditionalAccess/authenticationContextClassReferences` | v1.0 | Opzoektabel authenticatiecontexten |
| `GET /directory/administrativeUnits` | v1.0 | Opzoektabel beheereenheden |
| `GET /auditLogs/directoryAudits?$filter=loggedByService eq 'PIM'...` | v1.0 | PIM-activatieevenementen |
| `GET /identityGovernance/roleManagementAlerts/alerts` | **beta** | Beveiligingswaarschuwingen (geen v1.0-equivalent, fase 4) |

---

## 3. Verzamelingsendpoints

Verzamelingsendpoints zijn gedefinieerd als constanten in `$script:GraphEndpoints` in `graphEndpoints.ps1`:

```powershell
$script:GraphEndpoints = @{
    RoleDefinitions         = "$script:GraphBeta/roleManagement/directory/roleDefinitions"
    AuthenticationContexts  = "$script:GraphV1/identity/conditionalAccess/authenticationContextClassReferences"
    AdministrativeUnits     = "$script:GraphV1/directory/administrativeUnits"
    GroupResources          = "$script:GraphBeta/identityGovernance/privilegedAccess/group/resources"
}
```

Deze worden rechtstreeks doorgegeven aan `Get-AllGraphItems`, dat paginering afhandelt.

---

## 4. URI-bouwfuncties per entiteit

Endpoints per entiteit vereisen een rol-ID of groeps-ID in het filter. Ze zijn geimplementeerd als functies in `graphEndpoints.ps1`:

| Functie | Endpointpatroon |
|---|---|
| `Get-RolePolicyUri -RoleId` | `/policies/roleManagementPolicyAssignments?$filter=...roleDefinitionId eq '{id}'&$expand=policy($expand=rules)` |
| `Get-RolePermanentAssignmentsUri -RoleId` | `/roleManagement/directory/roleAssignments?$filter=roleDefinitionId eq '{id}'&$expand=principal` |
| `Get-RoleEligibleAssignmentsUri -RoleId` | `/roleManagement/directory/roleEligibilitySchedules?$filter=roleDefinitionId eq '{id}'&$expand=principal` |
| `Get-RoleActiveAssignmentsUri -RoleId` | `/roleManagement/directory/roleAssignmentSchedules?$filter=roleDefinitionId eq '{id}'&$expand=principal` |
| `Get-GroupPolicyUri -GroupId` | `/beta/policies/roleManagementPolicyAssignments?$filter=scopeId eq '{id}' and scopeType eq 'Group'&$expand=policy($expand=rules)` |
| `Get-GroupEligibleAssignmentsUri -GroupId` | `/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$filter=groupId eq '{id}'&$expand=principal` |
| `Get-GroupActiveAssignmentsUri -GroupId` | `/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$filter=groupId eq '{id}'&$expand=principal` |
| `Get-AuditLogsPimUri -Since` | `/auditLogs/directoryAudits?$filter=loggedByService eq 'PIM' and activityDateTime ge {since}&$orderby=activityDateTime desc` |

---

## 5. Paginering

`Get-AllGraphItems` handelt paginering automatisch af:

```powershell
function Get-AllGraphItems {
    param([string] $Uri, [string] $AccessToken)
    $allItems = @()
    $headers  = @{ Authorization = "Bearer $AccessToken" }
    $currentUri = $Uri
    while ($currentUri) {
        $response   = Invoke-RestMethod -Uri $currentUri -Headers $headers -Method Get
        $pageItems  = $response.PSObject.Properties['value']?.Value
        if ($pageItems) { $allItems += $pageItems }
        $currentUri = $response.PSObject.Properties['@odata.nextLink']?.Value
    }
    return $allItems
}
```

`PSObject.Properties['value']?.Value` wordt gebruikt in plaats van `$response.value` omdat `Set-StrictMode -Version Latest` een uitzondering gooit bij ontbrekende eigenschappen. De null-conditionele `?.Value` retourneert `$null` op de laatste pagina, wat de lus beëindigt.

---

## 6. Throttling en retry

Microsoft Graph throttlet aanvragen bij te hoge belasting. De retrylogica binnen het Directory-rollen `-Parallel`-blok:

1. Endpoint aanroepen.
2. Bij succes: `Start-Sleep -Milliseconds 500` (beleefde pacing).
3. Bij fout:
   - 429 of 5xx: wacht op `Retry-After`-header (of exponentieel backoff: 2^poging seconden) en probeer opnieuw.
   - Niet-opnieuw-probeerbare 4xx: direct opnieuw gooien.
   - Maximaal 5 pogingen voor opnieuw gooien.

`Get-AllGraphItems` (buiten parallelle blokken) bevat geen eigen retrylogica. Voeg dit toe als throttling ook buiten parallelle aanroepen een probleem wordt.

---

## 7. Gedeprecieerde endpoints

### `GET /beta/identityGovernance/privilegedAccess/group/resources`

**Status:** Beta, niet gedocumenteerd als discovery-surface. **Geen gepubliceerde einddatum.** De vaak genoemde deadline "28 oktober 2026" geldt voor PIM iteratie 2 (`/beta/privilegedAccess/aadRoles` + `/azureResources`), die dit project niet gebruikt.

Huidig gebruik: ontdekken welke groepen PIM-onboarded zijn. Er is **geen** tenant-brede vervanging: `eligibilityScheduleInstances`, `assignmentScheduleInstances` en `roleManagementPolicyAssignments` vereisen allemaal een `groupId`/`scopeId`-filter en kunnen groepen niet enumereren. Een lege/gewijzigde respons wordt afgevangen door `Test-SafeToArchive` om massale false-archivering te voorkomen.

### `resourceScopes` op roldefinities

**Status:** Gedeprecieerd door Microsoft. Documentatie: "DO NOT USE. Will be deprecated soon."

PIM Monitor slaat de volledige roldefinitierespons op inclusief `resourceScopes` (conform het vollederespons-principe). Gebruik dit veld niet in logica; gebruik in plaats daarvan `directoryScopeId` op assignments.

---

## 8. Een nieuw endpoint toevoegen

1. **URI toevoegen** aan `graphEndpoints.ps1`:
   - Verzamelingsendpoint: sleutel toevoegen aan `$script:GraphEndpoints`.
   - Endpoint per entiteit: nieuwe URI-bouwfunctie toevoegen.

2. **Data ophalen** in `Scan-PimState.ps1` via `Get-AllGraphItems` of `Invoke-RestMethod`.

3. **Data opslaan** via `Save-InventoryFile`.

4. **Difflogica toevoegen** in `diff.ps1` (of hergebruik `Compare-InventoryFolder` als de standaard driebestandsstructuur van toepassing is).

5. **Ernstigheidsregels bijwerken** in `diff.ps1` indien het nieuwe gegevenstype nieuwe eigenschapsnamen of regel-ID's introduceert.

6. **Endpoint documenteren** in het overzicht in sectie 2 van dit document.

7. **Vereist recht toevoegen** aan de app-registratiedocumentatie in [09-authenticatie.md](09-authenticatie.md).
