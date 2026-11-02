#requires -Version 7
Set-StrictMode -Version Latest

<#
Regression: a stored inventory file with a JSON null property (for example
"richDescription": null) made the diff fail with "Cannot bind argument to parameter 'Left'
because it is null" as soon as the entity changed. Test-ObjectEqual now accepts null on both sides.
#>

BeforeAll {
    $srcPath = Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "../src")
    . (Join-Path -Path $srcPath -ChildPath "helpers.ps1")
    . (Join-Path -Path $srcPath -ChildPath "diff.ps1")
}

Describe 'Test-ObjectEqual with null values' {
    It 'treats null and null as equal' {
        Test-ObjectEqual -Left $null -Right $null | Should -BeTrue
    }

    It 'treats null and a value as different' {
        Test-ObjectEqual -Left $null -Right 'x' | Should -BeFalse
    }
}

Describe 'Compare-InventoryFolder with a null-valued property' {
    It 'reports the change instead of throwing' {
        $folder = Join-Path -Path $TestDrive -ChildPath "inventory/directory-roles/test-role"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $old = @{ displayName = 'Role'; richDescription = $null }
        Set-Content -Path (Join-Path $folder 'definition.json') `
            -Value (ConvertTo-DeterministicJson -InputObject $old) -Encoding utf8NoBOM

        $new = [pscustomobject]@{ displayName = 'Role changed'; richDescription = $null }
        $changes = @(Compare-InventoryFolder -FolderPath $folder -NewData @{ definition = $new } -EntityName 'Role')

        $changes.Count | Should -BeGreaterThan 0
    }
}
