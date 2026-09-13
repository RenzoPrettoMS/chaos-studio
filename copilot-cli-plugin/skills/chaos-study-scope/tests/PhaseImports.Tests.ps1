# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
BeforeAll {
    if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }
    $script:Skills = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:Pwsh = (Get-Process -Id $PID).Path
}

Describe 'Fresh-process phase shared-library import closure' {
    It 'resolves all statically referenced shared functions in <Phase> and its callees' -ForEach @(
        @{ Phase = 'Design'; Skill = 'chaos-study-design'; Entry = 'Invoke-ChaosStudyDesign.ps1' }
        @{ Phase = 'Scope'; Skill = 'chaos-study-scope'; Entry = 'Invoke-ChaosStudyScope.ps1' }
        @{ Phase = 'Run'; Skill = 'chaos-study-run'; Entry = 'Invoke-ChaosStudyRun.ps1' }
        @{ Phase = 'Report'; Skill = 'chaos-study-report'; Entry = 'Invoke-ChaosStudyReport.ps1' }
        @{ Phase = 'History'; Skill = 'chaos-study-history'; Entry = 'Invoke-ChaosStudyHistory.ps1' }
        @{ Phase = 'Front door'; Skill = 'chaos-study'; Entry = 'Invoke-ChaosStudy.ps1' }
    ) {
        $output = & $script:Pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Test-PhaseImports.ps1" `
            -EntryPoint "$script:Skills/$Skill/scripts/$Entry" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'Shared import closure satisfied:'
    }

    It 'executes the run-side effective-plan hash with a fixture validation object without loading scope' {
        $output = & $script:Pwsh -NoProfile -NonInteractive -File "$PSScriptRoot/fixtures/Test-PhaseImports.ps1" `
            -EntryPoint "$script:Skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1" -ReplayRunHash 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        ($output | Out-String) | Should -Match 'Run effective-plan hash resolved:'
    }
}
