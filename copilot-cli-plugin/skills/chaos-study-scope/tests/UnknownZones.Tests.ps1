# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Port of c64fc8b's discovery policy tests onto the f6377ab scope seam.
BeforeAll {
    if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }
    . "$PSScriptRoot/../scripts/lib/Workspace.ps1"
    $script:LiveResources = @(
        Get-Content "$PSScriptRoot/fixtures/live-discovered-resources.json" -Raw | ConvertFrom-Json |
            ForEach-Object { ConvertTo-ChaosScopedResourceRecord $_ }
    )
}

Describe 'Conservative zone and location projection' {
    It 'uses the byte-identical live listing with no zone or location metadata' {
        (Get-FileHash "$PSScriptRoot/fixtures/live-discovered-resources.json").Hash |
            Should -Be 'a5712a596f71cd5880b580e9f395ef3457024157eaa5b36f78efbc0fc66b36dc'
        $script:LiveResources.Count | Should -Be 20
        @($script:LiveResources | Where-Object { $_.location -or $_.zones.Count }).Count | Should -Be 0
    }

    It 'retains all live resources for <Axis> instead of producing the old filter error' -ForEach @(
        @{ Axis = 'zone'; Bounds = @{ Zones = @('1') } }
        @{ Axis = 'location'; Bounds = @{ Locations = @('westus2') } }
        @{ Axis = 'both'; Bounds = @{ Zones = @('1'); Locations = @('westus2') } }
    ) {
        $blast = New-ChaosBlastRadius @Bounds
        { Resolve-ChaosBlastRadiusResource -ScopedResources $script:LiveResources -BlastRadius $blast } | Should -Not -Throw
        $result = Resolve-ChaosBlastRadiusResource -ScopedResources $script:LiveResources -BlastRadius $blast
        $result.Count | Should -Be 20
        $result.resourceId | Should -Be $script:LiveResources.resourceId
    }

    It 'excludes known mismatches but retains matching, partially matching and unknown zones' {
        $resources = @(
            [pscustomobject]@{ resourceId = '/two'; zones = @('2') }
            [pscustomobject]@{ resourceId = '/one'; zones = @('1') }
            [pscustomobject]@{ resourceId = '/multi'; zones = @('1', '2') }
            [pscustomobject]@{ resourceId = '/empty'; zones = @() }
            [pscustomobject]@{ resourceId = '/null'; zones = $null }
            [pscustomobject]@{ resourceId = '/blank'; zones = @('', ' ') }
            [pscustomobject]@{ resourceId = '/omitted' }
        )
        $result = Resolve-ChaosBlastRadiusResource $resources (New-ChaosBlastRadius -Zones '1')
        $result.resourceId | Should -Be @('/one', '/multi', '/empty', '/null', '/blank', '/omitted')
    }

    It 'excludes known location mismatches case-insensitively and retains unknown forms' {
        $resources = @(
            [pscustomobject]@{ resourceId = '/east'; location = 'eastus' }
            [pscustomobject]@{ resourceId = '/west'; location = 'WESTUS2' }
            [pscustomobject]@{ resourceId = '/empty'; location = '' }
            [pscustomobject]@{ resourceId = '/null'; location = $null }
            [pscustomobject]@{ resourceId = '/omitted' }
        )
        $result = Resolve-ChaosBlastRadiusResource $resources (New-ChaosBlastRadius -Locations 'westus2')
        $result.resourceId | Should -Be @('/west', '/empty', '/null', '/omitted')
    }

    It 'keeps resource and type exclusions effective on unknown-zone resources' {
        $resources = @(
            [pscustomobject]@{ resourceId = '/blocked'; resourceType = 'Microsoft.Compute/virtualMachines' }
            [pscustomobject]@{ resourceId = '/type-blocked'; resourceType = 'Microsoft.Storage/storageAccounts' }
            [pscustomobject]@{ resourceId = '/retained'; resourceType = 'Microsoft.Compute/virtualMachines' }
        )
        $blast = New-ChaosBlastRadius -Zones '1' -Locations 'westus2' -ExcludeResources '/BLOCKED' -ExcludeTypes 'microsoft.storage/storageaccounts'
        $result = Resolve-ChaosBlastRadiusResource $resources $blast
        $result.resourceId | Should -Be '/retained'
        $summary = Get-ChaosBlastRadiusSummary $result $blast
        ($summary -join "`n") | Should -Match '1 resource\(s\); these are retained with zone unverified'
        ($summary -join "`n") | Should -Match '1 resource\(s\); these are retained with location unverified'
    }

    It 'leaves the no-filter projection unchanged without a retention warning' {
        $blast = New-ChaosBlastRadius
        $result = Resolve-ChaosBlastRadiusResource $script:LiveResources $blast
        $result.resourceId | Should -Be $script:LiveResources.resourceId
        (Get-ChaosBlastRadiusSummary $result $blast) -join "`n" | Should -Not -Match 'retained'
    }

    It 'does not invent resources when discovery is empty' {
        $result = Resolve-ChaosBlastRadiusResource @() (New-ChaosBlastRadius -Zones '1')
        $result.Count | Should -Be 0
    }
}
