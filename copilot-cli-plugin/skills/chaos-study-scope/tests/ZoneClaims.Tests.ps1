# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Ports the declared-filter/display policy of 4aaa2ce and 7ef1da1, not their
# later execution-plan guards (outside this f6377ab projection patch).
BeforeAll {
    if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . "$PSScriptRoot/../scripts/lib/Workspace.ps1"
    . "$script:Skills/chaos-study/scripts/lib/ConfigurationPayload.ps1"
    . "$script:Skills/chaos-study/scripts/lib/Study.ps1"
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:LiveResources = @(
        Get-Content "$PSScriptRoot/fixtures/live-discovered-resources.json" -Raw | ConvertFrom-Json |
            ForEach-Object { ConvertTo-ChaosScopedResourceRecord $_ }
    )
}

Describe 'Declared zone claims and service configuration' {
    It 'reads the captured service binding rather than treating the scenario version as a zone' {
        $scenario = Get-Content "$PSScriptRoot/fixtures/live-zone-down-scenario.json" -Raw | ConvertFrom-Json
        $scenario.name | Should -Be 'ZoneDown-1.0'
        ($scenario.properties.actions | Where-Object name -eq vmZoneDown).parameters[0].value | Should -Be '%%{filters.zones}%%'
        (Get-ChaosBlastRadiusSummary $script:LiveResources (New-ChaosBlastRadius)) -join "`n" |
            Should -Match 'Declared zone filter: none - no zone claim'
    }

    It 'preserves the declared zones verbatim as a JSON array (<Label>)' -ForEach @(
        @{ Label = 'one'; Zones = @('1') }
        @{ Label = 'multiple'; Zones = @('2', '1') }
    ) {
        $blast = New-ChaosBlastRadius -Zones $Zones -Locations 'westus2'
        foreach ($shape in @($blast, ($blast | ConvertTo-Json -Depth 10 | ConvertFrom-Json))) {
            $body = New-ChaosConfigurationBody -BlastRadius $shape
            $json = $body | ConvertTo-Json -Depth 10 -Compress
            $json | Should -Match ('"zones":' + [regex]::Escape((ConvertTo-Json -InputObject $Zones -Compress)))
            $body.filters.zones | Should -Be $Zones
            $body.filters.locations | Should -Be @('westus2')
            $summary = (Get-ChaosBlastRadiusSummary $script:LiveResources $shape) -join "`n"
            $summary | Should -Match ([regex]::Escape("Declared zone filter: $(ConvertTo-Json -InputObject $Zones -Compress)"))
            $summary | Should -Match 'zone confinement is enforced by the service from filters.zones'
            $summary | Should -Match '20 resource\(s\); these are retained with zone unverified'
        }
    }
}

Describe 'Offline scope and consent preview' {
    It 'plans the zero-zone discovery fixture without the former exit-1 message and shows the advisory before consent' {
        $root = "$TestDrive/study"
        $output = & $script:Pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-ZoneScopeFixture.ps1" `
            -Skills $script:Skills -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $text = $output | Out-String
        $text | Should -Not -Match 'Cannot filter by zone|Blast-radius filter cannot be evaluated|Drop -FilterZone'
        $text | Should -Match '20 resource\(s\); these are retained with zone unverified'
        $text | Should -Match '20 resource\(s\); these are retained with location unverified'
        $body = Get-Content "$root/config-body.json" -Raw | ConvertFrom-Json
        $body.filters.zones | Should -Be @('1')
        $body.filters.locations | Should -Be @('westus2')
        $planFile = @(Get-ChildItem $root -Recurse -Filter 'study-plan.v3.json')[0]
        $plan = Read-ChaosJsonFile $planFile.FullName
        $plan.scope.projectedResourceCount | Should -Be 20
        $plan.scope.blastRadius.filters.zones | Should -Be @('1')
        $preview = & $script:Pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($preview | Out-String)
        $previewText = $preview | Out-String
        $previewText | Should -Match ([regex]::Escape('Declared zone filter: ["1"]'))
        $previewText | Should -Match 'zone confinement is enforced by the service from filters.zones'
        $previewText | Should -Match '20 resource\(s\); these are retained with zone unverified'
        $previewText | Should -Match 'location confinement is enforced by the service from filters.locations'
        $previewText | Should -Match '(?s)retained with zone unverified.*Injection requires a consent phrase'
    }

    It 'omits the new preview lines for older frozen plans without the optional summary' {
        $root = "$TestDrive/legacy"
        $output = & $script:Pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-ZoneScopeFixture.ps1" `
            -Skills $script:Skills -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $planFile = @(Get-ChildItem $root -Recurse -Filter 'study-plan.v3.json')[0]
        $plan = Read-ChaosJsonFile $planFile.FullName
        $plan.scope.PSObject.Properties.Remove('projectionSummary')
        $plan.PSObject.Properties.Remove('frozenConfigHash')
        $plan | Add-Member frozenConfigHash (Get-ChaosDigest -InputObject $plan)
        $plan | ConvertTo-Json -Depth 50 | Set-Content $planFile.FullName
        $preview = & $script:Pwsh -NoProfile -NonInteractive -File "$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -StudyRoot $root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($preview | Out-String)
        ($preview | Out-String) | Should -Not -Match 'Declared zone filter|retained with zone unverified'
    }
}
