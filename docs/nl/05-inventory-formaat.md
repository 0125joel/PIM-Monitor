# 05 — Inventory-formaat

## Inhoudsopgave

1. [Ontwerpprincipe: volledige API-respons](#1-ontwerpprincipe-volledige-api-respons)
2. [Deterministische JSON](#2-deterministische-json)
3. [Directory-rollen](#3-directory-rollen)
4. [PIM-groepen](#4-pim-groepen)
5. [Opzoekentiteiten](#5-opzoekentiteiten)
6. [Activatieevenementen](#6-activatieevenementen)
7. [Mapnamen en slugs](#7-mapnamen-en-slugs)
8. [Inventory-bestanden lezen](#8-inventory-bestanden-lezen)

---

## 1. Ontwerpprincipe: volledige API-respons

Elk inventory-bestand slaat de **volledige Graph API-respons** op voor die resource, ontdaan van OData-navigatiemetadata (`@odata.type`, `@odata.context`, `@odata.id`, `@odata.count`).

Geen `$select`-filtering. Geen hardgecodeerde eigenschappenlijsten. Geen transformatie.

Gevolgen:
- **Nieuwe API-eigenschappen verschijnen automatisch.** Wanneer Microsoft velden toevoegt aan een endpoint, verschijnen ze bij de volgende scan zonder codewijziging.
- **Git-diff toont alles.** Inclusief eigenschappen die niet waren overwogen bij de bouw van het project.
- **Geen schemaonderhoud.** Het inventoryformaat evolueert mee met de API.
- **Consumentverantwoordelijkheid.** Data op een gebruikersvriendelijke manier presenteren (bijv. regel-ID's omzetten naar beschrijvingen) is de verantwoordelijkheid van consumenten, niet van de pipeline.

> [!WARNING]
> Voeg geen `$select` toe aan Graph API-aanroepen en verwerk de respons niet voor doorgave aan `Save-InventoryFile`. Hierdoor wordt de vollederespons-garantie verbroken.

---

## 2. Deterministische JSON

### Waarom het belangrijk is

De Graph API garandeert geen eigenschapsvolgorde. PowerShell's `ConvertTo-Json` behoudt de invoegvolgorde. Zonder normalisatie zouden twee aanroepen naar hetzelfde endpoint met identieke data verschillende JSON-bytes produceren, en git zou bij elke scan een wijziging melden.

### Het normalisatie-algoritme

`ConvertTo-DeterministicJson` in `helpers.ps1` past de `Normalize`-functie recursief toe:

1. **Null:** pass-through als `$null`.
2. **Arrays:** elk element normaliseren; sorteren op `id` als elementen objecten zijn met een `id`-veld, sorteren op waarde voor stringarrays, volgorde bewaren anders.
3. **Woordenboeken (hashtables):** `@odata.*`-sleutels verwijderen; resterende sleutels alfabetisch sorteren; recursief in waarden.
4. **PSCustomObject:** zelfde als woordenboeken, maar via `$obj.PSObject.Properties`.
5. **Primitieven (string, bool, int, datetime):** ongewijzigd doorgeven.

> [!IMPORTANT]
> `string` en `System.ValueType` (bool, int, etc.) worden uitgesloten van de PSObject-tak, ook al omhult PowerShell technisch alle objecten in `[psobject]`. De typecontrole gebruikt expliciete uitsluiting: `($obj -is [psobject]) -and -not ($obj -is [string]) -and -not ($obj -is [System.ValueType])`. Gebruik `.PSObject.Properties.Count` niet om objecten van primitieven te onderscheiden, dit mislukt onder `Set-StrictMode -Version Latest`.

### Uitvoerformaat

2-spatie-inspringing, UTF-8 zonder BOM (`-Encoding utf8NoBOM`), afsluitende newline door `Set-Content`.

---

## 3. Directory-rollen

### Mappad

```
inventory/directory-roles/{rol-slug}/
```

---

### definition.json

**Bron:** `GET /beta/roleManagement/directory/roleDefinitions` (beta vereist voor `isPrivileged`, `allowedPrincipalTypes`, `version`)

**Inhoud:** Volledig `unifiedRoleDefinition`-object.

Belangrijke velden:

| Veld | Type | Opmerkingen |
|---|---|---|
| `id` | string (GUID) | Roldefinitie-ID |
| `displayName` | string | Leesbare rolnaam |
| `isBuiltIn` | boolean | Ingebouwd (Microsoft) vs. aangepaste rol |
| `isEnabled` | boolean | Of de rol is ingeschakeld |
| `isPrivileged` | boolean | **Alleen beta.** Of Microsoft deze rol geprivilegieerd beschouwt |
| `allowedPrincipalTypes` | string | **Alleen beta.** `"User"`, `"Group"` of gecombineerd |
| `rolePermissions` | array | Rechten die door deze rol worden verleend |
| `resourceScopes` | array | **Gedeprecieerd.** Niet gebruiken. |

---

### policy.json

**Bron:** `GET /policies/roleManagementPolicyAssignments?$filter=scopeId eq '/' and scopeType eq 'Directory' and roleDefinitionId eq '{id}'&$expand=policy($expand=rules)` (v1.0)

**Inhoud:** Volledig `unifiedRoleManagementPolicyAssignment`-object met uitgebreid beleid en regels.

Veelgebruikte regel-ID's:

| Regel-ID | Type | Beheert |
|---|---|---|
| `Enablement_EndUser_Assignment` | EnablementRule | MFA, motivering, tickets bij activatie |
| `Approval_EndUser_Assignment` | ApprovalRule | Goedkeuringsvereiste en goedkeurderslijst |
| `AuthenticationContext_EndUser_Assignment` | AuthenticationContextRule | Conditional Access-authenticatiecontext |
| `Expiration_EndUser_Assignment` | ExpirationRule | Maximale activatieduur |
| `Expiration_Admin_Eligibility` | ExpirationRule | Maximale duur van eligible assignments |
| `Expiration_Admin_Assignment` | ExpirationRule | Maximale duur van actieve assignments |
| `Notification_*` (9 regels) | NotificationRule | 3 notificatiecategorieën × 3 ontvangertypen |

---

### assignments.json

**Inhoud:**

```json
{
  "permanent": [ /* volledige unifiedRoleAssignment-responses */ ],
  "eligible":  [ /* volledige unifiedRoleEligibilitySchedule-responses */ ],
  "active":    [ /* volledige unifiedRoleAssignmentSchedule-responses */ ]
}
```

Belangrijke velden per entry:

| Veld | Opmerkingen |
|---|---|
| `principalId` | De gebruiker, groep of service-principal die is toegewezen |
| `directoryScopeId` | `"/"` voor tenant-breed; `/administrativeUnits/{id}` voor AE-bereik |
| `memberType` | `"Direct"` of `"Group"` (geerfde via groepslidmaatschap) |
| `scheduleInfo.expiration.endDateTime` | `null` = geen vervaldatum (permanent); anders ISO 8601 |

> [!NOTE]
> `scheduleInfo.startDateTime` wordt verwijderd door `Remove-AssignmentNoise` voor zowel diffing als schrijven. Microsoft Graph werkt dit heartbeat-tijdstempel elke ~30 minuten bij zonder gebruikersactie, wat anders bij elke scan een valse positieve commit zou veroorzaken.

---

## 4. PIM-groepen

### definition.json

**Bron:** `GET /groups/{id}` (v1.0). Volledig `group`-object.

### policy.json

**Inhoud:** Wrapper-object met twee subbeleiden:

```json
{
  "member": { /* volledig policyAssignment-object met uitgebreid beleid + regels */ },
  "owner":  { /* volledig policyAssignment-object met uitgebreid beleid + regels */ }
}
```

**Bron:** `GET /beta/policies/roleManagementPolicyAssignments?$filter=scopeId eq '{groupId}' and scopeType eq 'Group'&$expand=policy($expand=rules)` (beta — `scopeType eq 'Group'`-filter niet beschikbaar in v1.0)

### assignments.json

**Inhoud:**

```json
{
  "member": {
    "permanent": [],
    "eligible":  [],
    "active":    []
  },
  "owner": {
    "permanent": [],
    "eligible":  [],
    "active":    []
  }
}
```

Het `accessId`-veld op elke instance (`"member"` of `"owner"`) bepaalt in welke sectie de entry terechtkomt.

---

## 5. Opzoekentiteiten

```
inventory/authentication-contexts/{slug}/definition.json
inventory/administrative-units/{slug}/definition.json
```

Alleen `definition.json` — geen `policy.json` of `assignments.json`.

**Authenticatiecontexten:** `GET /identity/conditionalAccess/authenticationContextClassReferences` (v1.0). Velden: `id`, `displayName`, `claimValue`, `isAvailable`, etc.

**Beheereenheden:** `GET /directory/administrativeUnits` (v1.0). Velden: `id`, `displayName`, `description`, `visibility`.

---

## 6. Activatieevenementen

```
inventory/activation-events/JJJJ-MM.json
```

Één bestand per kalendermaand. JSON-array van auditlogevent-objecten, gesorteerd op `activityDateTime` oplopend. Het bestand groeit incrementeel; bestanden van voorbije maanden zijn onveranderlijk zodra de maand voorbij is.

**Bron:** `GET /auditLogs/directoryAudits?$filter=loggedByService eq 'PIM'...` (v1.0)

---

## 7. Mapnamen en slugs

Mapnamen worden afgeleid van `displayName` door `Get-InventorySlug`:

```powershell
$Name.ToLower() `
    -replace '[^\w\s-]', '' `
    -replace '\s+', '-' `
    -replace '-+', '-' `
    -replace '^-|-$', ''
```

Voorbeelden:

| displayName | slug |
|---|---|
| `Global Administrator` | `global-administrator` |
| `Exchange Online (Protection) Administrator` | `exchange-online-protection-administrator` |
| `Tier-0 Admins` | `tier-0-admins` |

> [!CAUTION]
> Als twee entiteiten dezelfde slug produceren vanuit verschillende displayNames, overschrijft de tweede de eerste. Hernoem een van de entiteiten als dit zich voordoet.

---

## 8. Inventory-bestanden lezen

```powershell
$path = "inventory/directory-roles/global-administrator/assignments.json"
$data = Get-Content -Path $path -Raw -Encoding utf8 | ConvertFrom-Json
```

Veilige toegang tot een eigenschap die mogelijk ontbreekt:

```powershell
$isPrivileged = $data.PSObject.Properties['isPrivileged']?.Value
```

`ConvertFrom-Json` retourneert standaard `PSCustomObject`. Gebruik `PSObject.Properties['sleutel']?.Value` voor veilige toegang. Gebruik `ConvertFrom-Json -AsHashtable` voor woordenboek-stijl iteratie.
