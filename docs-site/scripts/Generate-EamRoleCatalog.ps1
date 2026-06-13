#requires -Version 7.0
<#
.SYNOPSIS
    Generates the EAM Role Catalog dataset consumed by the Docusaurus reference page.

.DESCRIPTION
    Single source of truth for docs-site/src/data/eam-role-catalog.json.

    Inputs:
      1. inventory/directory-roles/*/definition.json  - AUTHORITATIVE generic facts
         (displayName, templateId, description, isPrivileged). These are Microsoft
         built-in role properties, not tenant secrets. No tenant assignment data,
         tenant policy, or drift is read or published.
      2. docs-site/src/data/eam-role-curated.json     - REVIEWED research overrides
         (EAM plane + security level + discussion note), seeded from
         docs/PIM-EAM-Mapping-v2.xlsx. Hand-maintainable.

    Per role the script derives, transparently:
      - eamPlane:        curated value if present, otherwise a keyword heuristic
                         (flagged reviewNeeded = true).
      - securityLevel:   Rule 1 live isPrivileged = true -> Privileged (authoritative).
                         Rule 2 blast-radius escape clause -> Privileged.
                         Rule 3 otherwise the curated/heuristic plane mapping.
      - recommendedConfig: Microsoft general Securing-Privileged-Access guidance per
                         security level (Microsoft publishes no per-role values).
      - sourceAuthority: tags each field authoritative | curated | heuristic | derived.

    Output is deterministic (stable key order, roles sorted by displayName) so
    re-running produces an identical file - no false-positive git diffs.

.NOTES
    Microsoft publishes neither a per-role EAM plane nor per-role activation values.
    The only authoritative per-role signal is roleDefinition.isPrivileged (Graph beta).
#>
[CmdletBinding()]
param(
    [string] $InventoryPath = (Join-Path $PSScriptRoot '..' '..' 'inventory' 'directory-roles'),
    [string] $CuratedPath   = (Join-Path $PSScriptRoot '..' 'src' 'data' 'eam-role-curated.json'),
    [string] $OutputPath    = (Join-Path $PSScriptRoot '..' 'src' 'data' 'eam-role-catalog.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Rule 2 - blast-radius escape clause. Full service control over an M365 workload
# with direct data impact justifies the Privileged regime regardless of plane.
$EscapeClauseRoles = @(
    'Exchange Administrator', 'SharePoint Administrator', 'Teams Administrator',
    'Yammer Administrator', 'Power Platform Administrator', 'Dynamics 365 Administrator',
    'Fabric Administrator', 'Azure DevOps Administrator', 'Windows 365 Administrator',
    'Knowledge Administrator', 'Knowledge Manager'
)

# Recommended PIM activation policy per security level (general SPA guidance, not per-role).
$ConfigByLevel = @{
    Privileged  = [ordered]@{
        pimRequired = $true; maxActivation = 'PT1H'; maxActivationLabel = '1 hour'
        requireMfa = $true; requireApproval = $true; requireJustification = $true
        authContext = 'Phishing-resistant + sign-in frequency'
        severity = 'High'
    }
    Specialized = [ordered]@{
        pimRequired = $true; maxActivation = 'PT4H'; maxActivationLabel = '4 hours'
        requireMfa = $true; requireApproval = $true; requireJustification = $true
        authContext = 'Phishing-resistant'
        # Severity mirrors Microsoft's three security levels as a clean gradient:
        # Privileged=High, Specialized=Medium, Enterprise=Low. See docs/eam-pim-classification.md.
        severity = 'Medium'
    }
    Enterprise  = [ordered]@{
        pimRequired = $true; maxActivation = 'PT8H'; maxActivationLabel = '8 hours'
        requireMfa = $true; requireApproval = $false; requireJustification = $true
        authContext = 'Standard MFA'
        severity = 'Low'
    }
}

# Keyword signals for the heuristic fallback (uncurated / future roles only).
$ControlSignals = @(
    'global administrator', 'privileged role', 'privileged auth', 'authentication',
    'conditional access', 'application admin', 'directory writers', 'directory readers',
    'directory sync', 'domain name', 'external identity', 'external id', 'hybrid identity',
    'identity governance', 'groups admin', 'user admin', 'helpdesk', 'password admin',
    'security admin', 'security operator', 'security reader', 'lifecycle workflows',
    'guest', 'b2c ief', 'agent id', 'agent registry', 'attribute', 'partner tier',
    'customer delegated', 'lockbox', 'people admin', 'permissions management', 'tenant'
)
$DataSignals = @(
    'reports reader', 'message center', 'usage summary', 'search editor',
    'insights analyst', 'insights business leader', 'user experience success',
    'content reader', 'log reader', 'backup reader', 'comsupport', 'support specialist',
    'support engineer', 'printer technician', 'warranty specialist', 'viva pulse',
    'governance reader', 'teams reader'
)

function Get-HeuristicPlane {
    param([string] $Name)
    $n = $Name.ToLowerInvariant()
    foreach ($s in $DataSignals)    { if ($n.Contains($s)) { return 'Data' } }
    foreach ($s in $ControlSignals) { if ($n.Contains($s)) { return 'Control' } }
    # Anything not identity-related and not pure-read defaults to a workload (Management).
    return 'Management'
}

function Get-FallbackLevel {
    param([string] $Plane, [string] $Name)
    switch ($Plane) {
        'Management' { return 'Specialized' }
        'Data'       { return 'Enterprise' }
        default {
            # Control plane: readers / governance / default user roles -> Enterprise.
            $n = $Name.ToLowerInvariant()
            if ($n -match 'reader|governance|guest|^user$|developer|relationship|approver|branding|creator') {
                return 'Enterprise'
            }
            return 'Specialized'
        }
    }
}

# --- Load curated research overrides (OrderedDictionary under -AsHashtable) ---
$curated = Get-Content -Raw -Path $CuratedPath | ConvertFrom-Json -AsHashtable

# --- Read authoritative facts from inventory definitions ---
$definitionFiles = Get-ChildItem -Path $InventoryPath -Recurse -Filter 'definition.json' -File
if (-not $definitionFiles) { throw "No definition.json files found under $InventoryPath" }

$roles = [System.Collections.Generic.List[object]]::new()

foreach ($file in $definitionFiles) {
    $def = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json

    $displayName = $def.PSObject.Properties['displayName']?.Value
    $templateId  = $def.PSObject.Properties['templateId']?.Value
    if (-not $templateId) { $templateId = $def.PSObject.Properties['id']?.Value }
    $description = $def.PSObject.Properties['description']?.Value
    if (-not $description) { $description = '' }
    $isPrivileged = [bool]($def.PSObject.Properties['isPrivileged']?.Value)

    $isCurated = ($templateId -in $curated.Keys)
    $entry = if ($isCurated) { $curated[$templateId] } else { $null }

    # Plane: curated (reviewed) wins; otherwise keyword heuristic.
    if ($isCurated -and ($entry.Keys -contains 'eamPlane')) {
        $plane = $entry['eamPlane']
        $planeSource = 'curated'
    } else {
        $plane = Get-HeuristicPlane -Name $displayName
        $planeSource = 'heuristic'
    }

    # Security level: Rule 1 (authoritative) -> Rule 2 (escape) -> Rule 3 (plane mapping).
    $escapeApplied = ($displayName -in $EscapeClauseRoles)
    if ($isPrivileged) {
        $level = 'Privileged'; $levelBasis = 'isPrivileged'
    } elseif ($escapeApplied) {
        $level = 'Privileged'; $levelBasis = 'escape-clause'
    } elseif ($isCurated -and ($entry.Keys -contains 'securityLevel')) {
        $level = $entry['securityLevel']; $levelBasis = 'plane-mapping'
    } else {
        $level = Get-FallbackLevel -Plane $plane -Name $displayName; $levelBasis = 'plane-mapping'
    }

    $cfg = $ConfigByLevel[$level]
    $note = if ($isCurated -and ($entry.Keys -contains 'note')) { $entry['note'] } else { $null }
    $reviewNeeded = $escapeApplied -or (-not $isCurated)

    $roles.Add([ordered]@{
        displayName       = $displayName
        templateId        = $templateId
        description       = $description
        isPrivileged      = $isPrivileged
        eamPlane          = $plane
        securityLevel     = $level
        levelBasis        = $levelBasis
        reviewNeeded      = $reviewNeeded
        recommendedConfig = [ordered]@{
            pimRequired         = $cfg.pimRequired
            maxActivation       = $cfg.maxActivation
            maxActivationLabel  = $cfg.maxActivationLabel
            requireMfa          = $cfg.requireMfa
            requireApproval     = $cfg.requireApproval
            requireJustification = $cfg.requireJustification
            authContext         = $cfg.authContext
            severity            = $cfg.severity
        }
        sourceAuthority   = [ordered]@{
            isPrivileged      = 'authoritative'
            eamPlane          = $planeSource
            securityLevel     = 'derived'
            recommendedConfig = 'derived'
        }
        note              = $note
    }) | Out-Null
}

# Deterministic ordering: roles sorted by displayName (stable, culture-invariant).
$sorted = $roles | Sort-Object -Property { $_.displayName }

$payload = [ordered]@{
    '_generated' = 'AUTO-GENERATED by docs-site/scripts/Generate-EamRoleCatalog.ps1. Do not edit by hand. Edit eam-role-curated.json or the generator instead.'
    'roleCount'  = $sorted.Count
    'roles'      = @($sorted)
}

$json = $payload | ConvertTo-Json -Depth 8
# ConvertTo-Json escapes nothing problematic here; normalize line endings.
Set-Content -Path $OutputPath -Value $json -NoNewline -Encoding utf8
Add-Content -Path $OutputPath -Value "`n" -NoNewline -Encoding utf8

# Count via dictionary indexing (Group-Object does not see OrderedDictionary keys as properties).
function Format-Counts {
    param([object[]] $Items, [string] $Key)
    $counts = @{}
    foreach ($i in $Items) { $v = $i[$Key]; $counts[$v] = 1 + ($counts[$v] ?? 0) }
    ($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
}
$heuristicCount = @($sorted | Where-Object { $_['sourceAuthority']['eamPlane'] -eq 'heuristic' }).Count
Write-Host "Wrote $($sorted.Count) roles to $OutputPath"
Write-Host "  Plane: $(Format-Counts -Items $sorted -Key 'eamPlane')"
Write-Host "  Level: $(Format-Counts -Items $sorted -Key 'securityLevel')"
Write-Host "  Heuristic (uncurated) roles: $heuristicCount"
