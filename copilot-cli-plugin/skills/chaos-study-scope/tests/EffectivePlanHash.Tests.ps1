# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . "$script:Skills/chaos-study-run/scripts/lib/Execute.ps1"
    . "$script:Skills/chaos-study/scripts/lib/Study.ps1"
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Preflight = Get-Content "$PSScriptRoot/fixtures/live-preflight-validation-0134.json" -Raw | ConvertFrom-Json
    $script:RunValidation = Get-Content "$PSScriptRoot/fixtures/live-run-validation-2056.json" -Raw | ConvertFrom-Json
    $script:LiveProjection = [ordered]@{
        total = 2; executable = 1; skipped = @('vmZoneShutdown'); undetermined = @()
    }
}

Describe 'Canonical effective-plan hash shape' {
    It 'hashes the exact live projection identically as an object or singleton array' {
        $projection = Get-ChaosEffectivePlanProjection -EffectiveLegs (Resolve-ChaosEffectiveLeg -ExecutionPlan $script:Preflight)
        (ConvertTo-ChaosCanonicalJson -InputObject $projection) |
            Should -Be (ConvertTo-ChaosCanonicalJson -InputObject $script:LiveProjection)
        Mock Get-ChaosEffectivePlanProjection { return $script:LiveProjection }
        $objectHash = Get-ChaosEffectivePlanHash -ExecutionPlan $script:Preflight
        Mock Get-ChaosEffectivePlanProjection { return , @($script:LiveProjection) }
        $arrayHash = Get-ChaosEffectivePlanHash -ExecutionPlan $script:Preflight
        $objectHash | Should -Be '08b4052ece722e88'
        $arrayHash | Should -Be $objectHash
    }

    It 'normalizes a singleton raw validation envelope before reading its plan' {
        Mock Resolve-ChaosEffectiveLeg {
            if ($ExecutionPlan -is [array]) { throw 'The raw envelope was not normalized.' }
            [pscustomobject]@{
                total = 2; executable = 1
                skipped = @([pscustomobject]@{ legSelector = 'vmZoneShutdown' }); undetermined = @()
            }
        }
        (Get-ChaosEffectivePlanHash -ExecutionPlan @($script:Preflight)) |
            Should -Be (Get-ChaosEffectivePlanHash -ExecutionPlan $script:Preflight)
    }

    It 'preserves the count gate when both live legs become executable' {
        $twoLegs = $script:RunValidation.properties.executionPlanJson | ConvertFrom-Json
        $twoLegs.actions.vmZoneShutdown.skip = $false
        $oneHash = Get-ChaosEffectivePlanHash -ExecutionPlan $script:RunValidation
        $twoHash = Get-ChaosEffectivePlanHash -ExecutionPlan $twoLegs
        $twoHash | Should -Be (Get-ChaosDigest -InputObject ([ordered]@{
            total = 2; executable = 2; skipped = @(); undetermined = @()
        }))
        $twoHash | Should -Not -Be $oneHash
    }
}

Describe 'Captured scope freeze and run recomputation' {
    It 'freezes 01:34 preflight through the scope entry point and accepts the 20:56 run hash' {
        $root = "$TestDrive/live-hash-replay"
        $output = & $script:Pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Invoke-ZoneScopeFixture.ps1" `
            -Skills $script:Skills -StudyRoot $root -ValidationFixture "$PSScriptRoot/fixtures/live-preflight-validation-0134.json" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $planFile = @(Get-ChildItem $root -Recurse -Filter 'study-plan.v3.json')[0]
        $plan = Read-ChaosJsonFile $planFile.FullName
        $script:Preflight.properties.executionPlanJson | Should -Be $script:RunValidation.properties.executionPlanJson
        $frozen = $plan.declaredVsEffective.effectivePlanHash
        $recomputed = Get-ChaosRunEffectivePlanHash -Validation $script:RunValidation
        $frozen | Should -Be $recomputed
        $frozen | Should -Be '08b4052ece722e88'
        Assert-ChaosEffectivePlanEquality -Expected $frozen -Actual $recomputed -ConfigurationName 'offline-f29' |
            Should -BeTrue
        $legacyArrayHash = Get-ChaosDigest -InputObject @($script:LiveProjection)
        $legacyArrayHash | Should -Be 'abd9acdab51ead91'
        $frozen | Should -Not -Be $legacyArrayHash
    }
}
