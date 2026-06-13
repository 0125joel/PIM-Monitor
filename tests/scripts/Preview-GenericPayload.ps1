#requires -Version 7
<#
.SYNOPSIS
    Renders Build-GenericPayload against a synthetic fixture for visual review.

.DESCRIPTION
    Writes the JSON payload to tests/output/generic-payload.json AND validates it
    against schemas/notification-payload-v1.json before exiting. Useful for spotting
    schema drift while developing consumer integrations.
    Pass -WithReportUrl to simulate REPORT_ARTIFACT=true on Azure DevOps.
#>
[CmdletBinding()]
param(
    [switch] $WithReportUrl
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = Resolve-Path (Join-Path $PSScriptRoot '../../src')
. (Join-Path $src 'helpers.ps1')
. (Join-Path $src 'diff.ps1')
. (Join-Path $src 'notifications-shared.ps1')
. (Join-Path $src 'notifications-webhook.ps1')

$changes = [ordered]@{
    High          = @(
        @{ severity='High'; changeType='added'; description='Directory Roles > Global Administrator > assignment'; context='Global Administrator'; fileType='git'; roleId='62e90394-69f5-4237-9190-012177145e10'; old=$null; new=@{ principalId='abc123'; directoryScopeId='/' } }
        @{ severity='High'; changeType='modified'; description='Directory Roles > Privileged Role Administrator > policy'; context='Privileged Role Administrator'; fileType='git'; old=@{ requireMfa=$false; maxDuration='PT8H' }; new=@{ requireMfa=$true; maxDuration='PT2H' } }
        @{ severity='High'; changeType='modified'; description='Tier-0 Admins (member) > authContext'; context='Tier-0 Admins'; fileType='access-model-compliance'; old=@{ authContext='none' }; new=@{ authContext='phish-resistant-sif' } }
    )
    Medium        = @(
        @{ severity='Medium'; changeType='modified'; description='Directory Roles > Exchange Administrator > expiration'; context='Exchange Administrator'; fileType='git'; old=@{ maximumDuration='PT8H' }; new=@{ maximumDuration='PT4H' } }
        @{ severity='Medium'; changeType='added'; description='PIM Groups > SOC Tier-1 > eligible member'; context='SOC Tier-1'; fileType='git'; groupId='1f4a8d3b-2c1a-4f5c-9a45-1b6f9c6df0f2'; old=$null; new=@{ principalId='def456' } }
    )
    Low           = @()
    Informational = @()
    Coverage      = @(
        @{ severity='Informational'; context='Attack Payload Author'; entity='9c6df0f2-1b6f-4f5c-9a45-1f4a8d3b2c1a'; fileType='coverage'; description='Role not in any access model' }
    )
    Total         = 6
}

if ($WithReportUrl) {
    $env:REPORT_ARTIFACT                    = 'true'
    $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI = 'https://dev.azure.com/contoso/'
    $env:SYSTEM_TEAMPROJECT                 = 'PIM-Monitor'
    $env:BUILD_BUILDID                      = '12345'
}

try {
    $payload = Build-GenericPayload `
        -ChangesBySeverity $changes `
        -RelevantCount 6 `
        -MinSeverity 'Low' `
        -CommitSha 'a1b2c3d4e5' `
        -TenantName 'Contoso Demo'
} finally {
    if ($WithReportUrl) {
        $env:REPORT_ARTIFACT                    = $null
        $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI = $null
        $env:SYSTEM_TEAMPROJECT                 = $null
        $env:BUILD_BUILDID                      = $null
    }
}

$outPath = Join-Path $PSScriptRoot '../output/generic-payload.json'
$json    = $payload | ConvertTo-Json -Depth 30
Set-Content -Path $outPath -Value $json -Encoding UTF8

$schemaPath = Resolve-Path (Join-Path $PSScriptRoot '../../schemas/notification-payload-v1.json')
$valid      = Test-Json -Json $json -SchemaFile $schemaPath

Write-Host "Preview written:    $outPath"
Write-Host "Schema validates:   $valid"
Write-Host "Payload size:       $($json.Length) chars"
Write-Host "Report URL injected: $WithReportUrl"
