#requires -Version 7
Set-StrictMode -Version Latest

<#
Architectural contract test: enforces the "one notification channel = one file" rule
documented in architecture.md §6.1 and ADR-006.

Adding a new webhook platform requires ONE new file (notifications-webhook-<platform>.ps1)
containing exactly ONE Build-<Platform>Payload and ONE Build-ScanError<Platform>Payload.
This test fails if those constraints are violated, preventing 700-line multi-builder files.

Also verifies dispatcher coverage: every platform file must be dispatched by both
Send-WebhookNotification and Send-ScanErrorNotification.
#>

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")

    # Collect all platform files: notifications-webhook-<platform>.ps1
    $script:platformFiles = @(Get-ChildItem -Path $srcPath -Filter "notifications-webhook-*.ps1" |
        Where-Object { $_.Name -ne "notifications-webhook.ps1" })

    # Parse a file and return all top-level function definition names.
    function Get-FunctionNames {
        param([Parameter(Mandatory)] [string] $FilePath)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$null)
        $functionDefs = $ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
            $false
        )
        return @($functionDefs | ForEach-Object { $_.Name })
    }

    # Parse a file and return all string literals that appear as switch case values.
    function Get-SwitchCaseValues {
        param([Parameter(Mandatory)] [string] $FilePath)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$null, [ref]$null)
        $switchStatements = $ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.SwitchStatementAst] },
            $true
        )
        $caseValues = [System.Collections.Generic.List[string]]::new()
        foreach ($sw in $switchStatements) {
            # SwitchStatementAst.Clauses is a collection of Tuple<ExpressionAst, StatementBlockAst>
            foreach ($clause in $sw.Clauses) {
                $item = $clause.Item1  # Item1 = condition, Item2 = body
                if ($item -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $caseValues.Add($item.Value)
                }
            }
        }
        return @($caseValues)
    }

    # Derive capitalized platform name from a file basename.
    # notifications-webhook-teams.ps1 → Teams
    function Get-PlatformName {
        param([Parameter(Mandatory)] [string] $BaseName)
        $p = $BaseName -replace '^notifications-webhook-', ''
        return $p.Substring(0,1).ToUpper() + $p.Substring(1)
    }

    $script:webhookDispatcherPath = Join-Path $srcPath "notifications-webhook.ps1"
    $script:errorDispatcherPath   = Join-Path $srcPath "notifications-error.ps1"
}

# ─── One Build-*Payload per platform file ────────────────────────────────────

Describe "Notification channel structure — one Build-*Payload per platform file" {
    It "each notifications-webhook-<platform>.ps1 defines exactly one Build-<Platform>Payload" {
        foreach ($file in $script:platformFiles) {
            $platformCapitalized = Get-PlatformName -BaseName $file.BaseName
            $expectedBuilder = "Build-${platformCapitalized}Payload"

            $functions = Get-FunctionNames -FilePath $file.FullName
            $matchingBuilders = @($functions | Where-Object { $_ -eq $expectedBuilder })

            $matchingBuilders.Count | Should -Be 1 `
                -Because "$($file.Name) must define exactly one $expectedBuilder (one channel = one file rule)"
        }
    }

    It "each notifications-webhook-<platform>.ps1 defines exactly one Build-ScanError<Platform>Payload" {
        foreach ($file in $script:platformFiles) {
            $platformCapitalized = Get-PlatformName -BaseName $file.BaseName
            $expectedErrorBuilder = "Build-ScanError${platformCapitalized}Payload"

            $functions = Get-FunctionNames -FilePath $file.FullName
            $matchingBuilders = @($functions | Where-Object { $_ -eq $expectedErrorBuilder })

            $matchingBuilders.Count | Should -Be 1 `
                -Because "$($file.Name) must define exactly one $expectedErrorBuilder"
        }
    }

    It "no platform file defines a Build-*Payload belonging to a different platform" {
        $allPlatforms = @($script:platformFiles | ForEach-Object { Get-PlatformName -BaseName $_.BaseName })

        foreach ($file in $script:platformFiles) {
            $ownPlatform = Get-PlatformName -BaseName $file.BaseName
            $functions = Get-FunctionNames -FilePath $file.FullName

            foreach ($fn in $functions) {
                if ($fn -match '^Build-(ScanError)?(\w+)Payload$') {
                    $fnPlatform = $Matches[2]
                    if ($fnPlatform -ne $ownPlatform -and $fnPlatform -in $allPlatforms) {
                        $fn | Should -BeNullOrEmpty `
                            -Because "$($file.Name) must not define a builder for platform '$fnPlatform' (that belongs in notifications-webhook-$($fnPlatform.ToLower()).ps1)"
                    }
                }
            }
        }
    }
}

# ─── Dispatcher coverage ─────────────────────────────────────────────────────

Describe "Notification channel structure — dispatcher covers all platform files" {
    It "Send-WebhookNotification has a switch case for every platform" {
        $dispatcherCases = Get-SwitchCaseValues -FilePath $script:webhookDispatcherPath

        foreach ($file in $script:platformFiles) {
            $platformCapitalized = Get-PlatformName -BaseName $file.BaseName
            $dispatcherCases | Should -Contain $platformCapitalized `
                -Because "Send-WebhookNotification must have a '$platformCapitalized' switch case for $($file.Name)"
        }
    }

    It "Send-ScanErrorNotification has a switch case for every platform" {
        $errorCases = Get-SwitchCaseValues -FilePath $script:errorDispatcherPath

        foreach ($file in $script:platformFiles) {
            $platformCapitalized = Get-PlatformName -BaseName $file.BaseName
            $errorCases | Should -Contain $platformCapitalized `
                -Because "Send-ScanErrorNotification must have a '$platformCapitalized' switch case for $($file.Name)"
        }
    }
}

# ─── At least 3 platform files (Teams, Slack, Discord) ───────────────────────

Describe "Notification channel structure — known platforms exist" {
    It "has at least 3 platform files" {
        $script:platformFiles.Count | Should -BeGreaterOrEqual 3 `
            -Because "Teams, Slack, and Discord files must exist"
    }

    It "has notifications-webhook-<platform>.ps1 for each known platform" -TestCases @(
        @{ Platform = 'teams'   }
        @{ Platform = 'slack'   }
        @{ Platform = 'discord' }
    ) {
        $exists = $script:platformFiles | Where-Object { $_.BaseName -eq "notifications-webhook-$Platform" }
        $exists | Should -Not -BeNullOrEmpty -Because "notifications-webhook-$Platform.ps1 must exist"
    }
}
