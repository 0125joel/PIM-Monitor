# 09 — Authenticatie

## Inhoudsopgave

1. [Workload Identity Federation](#1-workload-identity-federation)
2. [App-registratie instellen](#2-app-registratie-instellen)
3. [Vereiste applicatierechten](#3-vereiste-applicatierechten)
4. [Serviceverbinding instellen](#4-serviceverbinding-instellen)
5. [Tokenacquisitie in de pipeline](#5-tokenacquisitie-in-de-pipeline)
6. [SecureString uitpakken](#6-securestring-uitpakken)
7. [Tokengebruik in scripts](#7-tokengebruik-in-scripts)
8. [Mail.Send beperken tot specifieke postbus](#8-mailsend-beperken-tot-specifieke-postbus)

---

## 1. Workload Identity Federation

PIM Monitor gebruikt **Workload Identity Federation (WIF)** voor authenticatie. Geen client secrets, geen certificaten, geen rotatie, geen lekrisico.

Hoe WIF werkt:

```
Azure DevOps Pipeline (run)
        │
        │  OIDC-token (ondertekend door ADO)
        ▼
Microsoft Entra ID (OIDC-uitwisseling)
        │
        │  Verifieert: issuer + subject claim komen overeen met federatieve credential op app-registratie
        │
        ▼
Toegangstoken uitgegeven (app-registratie-identiteit, applicatierechten)
        │
        ▼
Microsoft Graph API
```

Dit is dezelfde aanpak als [Maester.dev](https://maester.dev/docs/monitoring/azure-devops/) voor Azure DevOps-gebaseerde monitoringpipelines. Het is de door Microsoft aanbevolen authenticatiepatroon voor CI/CD-pipelines die toegang hebben tot de Graph API.

---

## 2. App-registratie instellen

1. In de Azure-portal of het Entra-beheercentrum: **App-registraties** → **Nieuwe registratie**.
2. Naam: `pim-monitor` (of een andere naam; uitsluitend voor weergave).
3. Ondersteunde accounttypen: **Enkelvoudige tenant** (de tenant die u wilt bewaken).
4. Omleidings-URI: leeg laten (niet nodig voor applicatierechten).
5. Klik op **Registreren**.
6. Noteer de **Toepassings-ID (client-ID)** en **Map-ID (tenant-ID)** voor de serviceverbinding.

---

## 3. Vereiste applicatierechten

Op de app-registratie: **API-machtigingen** → **Een machtiging toevoegen** → **Microsoft Graph** → **Toepassingsmachtigingen**.

| Machtiging | Doel |
|---|---|
| `RoleManagement.Read.Directory` | Roldefinities en permanente assignments |
| `RoleAssignmentSchedule.Read.Directory` | Actieve (PIM-geactiveerde) assignment-schema's |
| `RoleEligibilitySchedule.Read.Directory` | Eligible assignment-schema's |
| `RoleManagementPolicy.Read.Directory` | PIM-beleidsregels |
| `AuditLog.Read.All` | PIM-activatieevenementen (auditlog) |
| `PrivilegedAccess.Read.AzureADGroup` | PIM-groepsassignments en -beleid |
| `Mail.Send` | E-mailnotificaties (optioneel) |

Klik na het toevoegen op **Beheerdersconsent verlenen voor {tenant}**. Alle machtigingen moeten een groen vinkje tonen.

> [!NOTE]
> `AuditLog.Read.All` is vereist voor de activatieevenementen-sectie. Als dit recht niet is verleend, logt de scan een waarschuwing en slaat activatieevenementen over. Alle andere secties gaan normaal door.

---

## 4. Serviceverbinding instellen

In Azure DevOps: **Projectinstellingen** → **Serviceverbindingen** → **Nieuwe serviceverbinding** → **Azure Resource Manager** → **Workload Identity Federation (handmatig)**.

> [!TIP]
> Kies **handmatig** (niet automatisch). Automatisch maakt een nieuwe app-registratie aan; handmatig gebruikt de app-registratie die u al hebt aangemaakt.

Vereiste velden:

| Veld | Waarde |
|---|---|
| Omgeving | Azure Cloud |
| Bereikniveau | Abonnement (kies een beschikbaar abonnement) |
| Naam serviceverbinding | `pim-monitor-service-connection` (moet overeenkomen met `monitor-pipeline.yml`) |

Na aanmaken: kopieer de **Issuer** en **Onderwerp-ID** uit de ADO-gebruikersinterface. Voeg in de app-registratie een federatieve credential toe:
- **Federatief credentialscenario**: Andere issuer
- **Issuer**: de issuer-URL uit ADO
- **Onderwerp-ID**: de onderwerp-ID uit ADO
- **Naam**: een beschrijvende naam naar keuze

---

## 5. Tokenacquisitie in de pipeline

De `AzurePowerShell@5`-taak voert de OIDC-uitwisseling uit en maakt de Az PowerShell-context beschikbaar:

```yaml
- task: AzurePowerShell@5
  inputs:
    azureSubscription: "pim-monitor-service-connection"
    ScriptType: "FilePath"
    ScriptPath: "$(Build.SourcesDirectory)/src/Scan-PimState.ps1"
    azurePowerShellVersion: "LatestVersion"
    pwsh: true
```

Binnen de taakcontext kan `Get-AzAccessToken` een token aanvragen voor elke resource waarvoor de app-registratie rechten heeft:

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
```

`-ResourceTypeName MSGraph` is een vriendelijke alias voor de Microsoft Graph-resource-ID (`https://graph.microsoft.com`).

---

## 6. SecureString uitpakken

Vanaf Az.Accounts 3.0 (Az-module 12.0+) retourneert `Get-AzAccessToken` `.Token` als `SecureString`. PIM Monitor pakt dit veilig uit:

```powershell
$rawToken = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
$token = if ($rawToken -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new('', $rawToken).Password
} else {
    $rawToken  # oudere Az-versies retourneren een plaintext-string
}
```

`NetworkCredential::new('', $secureString).Password` extraheert de plaintext uit een `SecureString` zonder het naar schijf te schrijven. De `else`-tak zorgt voor compatibiliteit met oudere Az-versies.

---

## 7. Tokengebruik in scripts

Het plaintext-token is opgeslagen in `$token` (een lokale variabele in de orchestrator) en wordt expliciet doorgegeven aan functies die het nodig hebben. Het wordt nooit opgeslagen in een bestand of omgevingsvariabele.

Alle Graph API-aanroepen gebruiken het token als Bearer-header:

```powershell
$headers = @{ Authorization = "Bearer $token" }
Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
```

---

## 8. Mail.Send beperken tot specifieke postbus

`Mail.Send` als applicatierecht staat de app-registratie toe e-mail te verzenden als elke postbus in de tenant. Om dit te beperken tot een specifieke verzenderspostbus, configureert u een [applicatietoegangsbeleid](https://learn.microsoft.com/en-us/graph/auth-limit-mailbox-access):

```powershell
# Vereist Exchange Online PowerShell
New-ApplicationAccessPolicy `
    -AppId "<App-registratie client-ID>" `
    -PolicyScopeGroupId "<postbus of mail-enabled beveiligingsgroep>" `
    -AccessRight RestrictAccess `
    -Description "Beperk PIM Monitor tot pim-monitor@contoso.com"
```

Dit beleid beperkt `sendMail` tot de opgegeven postbus zonder de machtiging op de app-registratie te wijzigen.
