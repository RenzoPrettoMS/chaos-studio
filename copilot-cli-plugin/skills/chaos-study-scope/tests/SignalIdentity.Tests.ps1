# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    . "$script:Skills/chaos-study-run/scripts/lib/Signals.ps1"
    . "$PSScriptRoot/../scripts/lib/Readiness.ps1"
    . "$script:Skills/chaos-study/scripts/lib/Exercise.ps1"
    $script:Replay = Get-Content "$PSScriptRoot/fixtures/live-signal-readiness.json" -Raw | ConvertFrom-Json
}

Describe 'One metric source identity contract' {
    It 'shares collector parsing for documented <Label> syntax' -ForEach @(
        @{ Label = 'bare metric'; Source = 'metrics:Availability'; Resource = $null; Aggregation = 'Average' }
        @{ Label = 'resource pin'; Source = 'metrics:Availability@/vm'; Resource = '/vm'; Aggregation = 'Average' }
        @{ Label = 'aggregation'; Source = 'metrics:Availability|Maximum'; Resource = $null; Aggregation = 'Maximum' }
        @{ Label = 'pin and aggregation'; Source = 'metrics:Availability@/vm|Maximum'; Resource = '/vm'; Aggregation = 'Maximum' }
    ) {
        $spec = ConvertFrom-ChaosSignalSourceSpec $Source
        $identity = Get-ChaosSignalSourceIdentity $Source
        $identity.names | Should -Contain 'Availability'
        $identity.id | Should -Be $spec.id
        $identity.resourceId | Should -Be $Resource
        $identity.aggregation | Should -Be $Aggregation
        $identity.metricName | Should -Be $spec.metricName
    }

    It 'matches <Signal> to the same pinned metric' -ForEach @(
        @{ Signal = 'Availability' }
        @{ Signal = 'Availability@/vm|Average' }
        @{ Signal = 'Availability@/vm' }
        @{ Signal = 'metrics:Availability@/vm|Average' }
    ) {
        (Test-ChaosSourceProducesSignal -Spec 'metrics:Availability@/vm|Average' -SignalName $Signal).matched | Should -BeTrue
    }

    It 'keeps a different resource or aggregation from matching a qualified name' -ForEach @(
        @{ Signal = 'Availability@/another-vm' }
        @{ Signal = 'Availability@/vm|Maximum' }
    ) {
        (Test-ChaosSourceProducesSignal -Spec 'metrics:Availability@/vm|Average' -SignalName $Signal).matched | Should -BeFalse
    }

    It 'keeps logs split on the first hash and aliases unchanged' {
        $source = 'logs:workspace#requests | where url contains "#fragment" | summarize Availability = count()'
        $spec = ConvertFrom-ChaosSignalSourceSpec $source
        $identity = Get-ChaosSignalSourceIdentity $source
        $identity.workspaceId | Should -Be 'workspace'
        $identity.query | Should -Be 'requests | where url contains "#fragment" | summarize Availability = count()'
        $identity.query | Should -Be $spec.query
        $identity.id | Should -Be $spec.id
        (Test-ChaosSourceProducesSignal $source 'Availability').matched | Should -BeTrue
    }

    It 'rejects a bare name pinned on different resources and identifies both sources' {
        $sources = @('metrics:Availability@/vm-a|Average', 'metrics:Availability@/vm-b|Average')
        $match = Resolve-ChaosSignalSourceMatch -Sources $sources -SignalName 'Availability'
        $match.ambiguous | Should -BeTrue
        foreach ($source in $sources) { $match.reason | Should -Match ([regex]::Escape($source)) }
    }

    It 'allows qualification to disambiguate <Signal>' -ForEach @(
        @{ Signal = 'Availability@/vm-b'; Expected = 'metrics:Availability@/vm-b|Average' }
        @{ Signal = 'Availability@/vm-b|Average'; Expected = 'metrics:Availability@/vm-b|Average' }
    ) {
        $sources = @('metrics:Availability@/vm-a|Average', 'metrics:Availability@/vm-b|Average')
        $match = Resolve-ChaosSignalSourceMatch -Sources $sources -SignalName $Signal
        $match.ambiguous | Should -BeFalse
        $match.matched | Should -Be @($Expected)
    }
}

Describe 'Live F17 readiness replay' {
    It 'matches the exact public-IP objective and VMSS probe from the driver' {
        $objective = Test-ChaosObservabilityCoverage -AvailableSources $script:Replay.sources -SteadyState $script:Replay.steadyState
        $probe = Test-ChaosMechanismTraceable -AvailableSources $script:Replay.sources `
            -FailureMechanism $script:Replay.failureMechanism -MechanismEvidence $script:Replay.mechanismEvidence `
            -MechanismProbe $script:Replay.mechanismProbe -ScopedResourceIds @($script:Replay.mechanismProbe.resourceCorrelation)
        $objective.status | Should -Be 'pass' -Because $objective.detail
        $probe.status | Should -Be 'pass' -Because $probe.detail
        $objective.detail | Should -Match ([regex]::Escape($script:Replay.sources[0]))
        $probe.detail | Should -Match ([regex]::Escape($script:Replay.sources[1]))
        $objective.detail | Should -Not -Match ([regex]::Escape($script:Replay.sources[1]))

        $scopeAst = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../scripts/Invoke-ChaosStudyScope.ps1", [ref]$null, [ref]$null)
        $renderLoop = $scopeAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
                $node.Condition.Extent.Text -eq '$readiness.gates'
        }, $false)
        $readiness = [pscustomobject]@{ gates = @($objective, $probe) }
        Mock Write-ChaosStudyNote { param($Message) $Message }
        $output = & ([scriptblock]::Create($renderLoop.Extent.Text)) | Out-String
        foreach ($source in $script:Replay.sources) {
            $output | Should -Match ([regex]::Escape($source))
        }
    }

    It 'rejects ambiguous bare <Gate> names even when the probe correlation names one resource' -ForEach @(
        @{ Gate = 'objective' }
        @{ Gate = 'probe' }
    ) {
        $sources = @('metrics:Availability@/vm-a|Average', 'metrics:Availability@/vm-b|Average')
        if ($Gate -eq 'objective') {
            $result = Test-ChaosObservabilityCoverage -AvailableSources $sources -SteadyState ([pscustomobject]@{ signal = 'Availability' })
        } else {
            $probe = [pscustomobject]@{ signal = 'Availability'; expectedDirection = 'down'; resourceCorrelation = '/vm-a' }
            $result = Test-ChaosMechanismTraceable -AvailableSources $sources -FailureMechanism 'Compute shutdown' `
                -MechanismEvidence 'fixture' -MechanismProbe $probe -ScopedResourceIds @('/vm-a', '/vm-b')
        }
        $result.status | Should -Be 'fail'
        $result.severity | Should -Be 'blocking'
        $result.detail | Should -Match 'ambiguous'
        foreach ($source in $sources) { $result.detail | Should -Match ([regex]::Escape($source)) }
    }
}

Describe 'Resource-pinned collected signal selection' {
    BeforeAll {
        $script:Collected = @(
            [pscustomobject]@{ source = 'metrics:Availability'; values = @(@{ value = 1 }); query = @{ metric = 'Availability'; resourceId = '/vm-a'; aggregation = 'Average' } }
            [pscustomobject]@{ source = 'metrics:Availability'; values = @(@{ value = 0 }); query = @{ metric = 'Availability'; resourceId = '/vm-b'; aggregation = 'Average' } }
        )
        $script:Sources = @('metrics:Availability@/vm-a|Average', 'metrics:Availability@/vm-b|Average')
    }

    It 'does not select the first result for an ambiguous bare name' {
        { Select-ChaosSignalByName -Signals $script:Collected -Sources $script:Sources -SignalName 'Availability' } |
            Should -Throw '*ambiguous*'
    }

    It 'selects the qualified resource from recorded query attributes, including a measured zero' {
        $selected = Select-ChaosSignalByName -Signals $script:Collected -Sources $script:Sources -SignalName 'Availability@/vm-b'
        $selected.query.resourceId | Should -Be '/vm-b'
        $selected.values[0].value | Should -Be 0
    }

    It 'keeps log-column selection working when there are no metric results' {
        $log = [pscustomobject]@{ source = 'logs:workspace'; values = @{ Availability = 0 } }
        $result = Select-ChaosSignalByName -Signals @($log) -SignalName 'Availability'
        $result.source | Should -Be 'logs:workspace'
    }

    It 'does not invent a pin when a collected metric has only a bare source and query digest' {
        $signal = New-ChaosSignalResult -Source 'metrics:Availability' -Window 'during' `
            -Values @([ordered]@{ value = 1 }) -Query @{ metric = 'Availability'; resourceId = '/vm-b'; aggregation = 'Average' }
        $signal.PSObject.Properties.Name | Should -Not -Contain 'query'
        $result = Select-ChaosSignalByName -Signals @($signal) -Sources $script:Sources -SignalName 'Availability@/vm-b'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Shared parser phase loading' {
    It 'loads the shared parser through the actual <Phase> entry point import' -ForEach @(
        @{ Phase = 'Scope'; Library = 'Readiness.ps1' }
        @{ Phase = 'Run'; Library = 'Signals.ps1' }
        @{ Phase = 'Report'; Library = 'Findings.ps1' }
    ) {
        $phaseRoot = "$script:Skills/chaos-study-$($Phase.ToLowerInvariant())/scripts"
        $entry = Get-Content "$phaseRoot/Invoke-ChaosStudy$Phase.ps1" -Raw
        $entry | Should -Match ('(?m)^\.\s.*' + [regex]::Escape("'$Library'"))
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -NonInteractive -Command @"
. '$phaseRoot/lib/$Library'
(Get-Command ConvertFrom-ChaosSignalSourceSpec).ScriptBlock.File
"@ 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        ($output | Out-String).Trim() | Should -Be "$script:Skills/chaos-study/scripts/lib/SignalSource.ps1"
    }
}
