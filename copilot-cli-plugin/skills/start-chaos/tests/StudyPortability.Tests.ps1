<#
.SYNOPSIS
    Offline portability of a sealed study (E4-T6, NFR-11).

.DESCRIPTION
    Seals a study, zips it, unzips it under a completely different study root
    on a machine with no Azure credentials in the environment, and asserts that
    `Get-Study` reads it back and verifies its integrity with no network and no
    credentials. `manifest.json` is self-describing, so the copy is readable on
    its own terms.
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:PluginRoot 'scripts' 'Study.ps1')

    $script:CredentialVariables = @(
        'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID',
        'AZURE_ACCESS_TOKEN', 'ARM_CLIENT_SECRET', 'CHAOS_KEY_DIR', 'AZURE_CONFIG_DIR'
    )
    $script:SavedEnvironment = @{}
    $script:OriginalStudyRoot = $env:CHAOS_STUDY_ROOT
    $script:ScopeHash = 'abcd0123abcd0123'
}

AfterAll {
    $env:CHAOS_STUDY_ROOT = $script:OriginalStudyRoot
    foreach ($name in $script:SavedEnvironment.Keys) {
        Set-Item -Path "env:$name" -Value $script:SavedEnvironment[$name]
    }
}

Describe 'A zipped study opens on another machine (E4-T6, NFR-11)' {
    BeforeAll {
        $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("chaos-study-portability-" + [guid]::NewGuid().ToString('n'))
        $script:OriginRoot = Join-Path (Join-Path $script:Sandbox 'origin') 'studies'
        $script:ElsewhereRoot = Join-Path (Join-Path $script:Sandbox 'elsewhere') 'studies'
        New-Item -ItemType Directory -Path $script:OriginRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:ElsewhereRoot $script:ScopeHash) -Force | Out-Null

        $env:CHAOS_STUDY_ROOT = $script:OriginRoot
        $plan = [ordered]@{
            vertical        = 'kubernetes'
            question        = 'does checkout survive losing a pod?'
            hypothesis      = 'the deployment reschedules within 60s'
            steadyState     = [ordered]@{ description = 'p99 under 500ms' }
            fault           = [ordered]@{ urn = 'urn:csci:microsoft:chaosMesh:podChaos/2.2'; faultPath = 'experiment'; parameters = @() }
            targeting       = [ordered]@{ mode = 'list'; targets = @() }
            duration        = 'PT5M'
            abortConditions = @()
            signals         = @()
            readiness       = [ordered]@{}
            blocked         = $false
        }
        $study = New-Study -ScopeHash $script:ScopeHash -Plan $plan -Scope ([ordered]@{ subscriptionId = 'sub-1'; resourceGroup = 'rg-1' })
        Save-StudyArtifact -StudyId $study.studyId -Name 'evidence/pre/metrics.json' -Data ([ordered]@{ p99 = 410 }) | Out-Null
        Complete-Study -StudyId $study.studyId -ReportHtml '<html><body>report</body></html>' | Out-Null
        $script:StudyId = $study.studyId
        $script:OriginPath = $study.path

        $script:Zip = Join-Path $script:Sandbox 'study.zip'
        Compress-Archive -Path (Join-Path $script:OriginPath '*') -DestinationPath $script:Zip -Force

        $script:ElsewherePath = Join-Path (Join-Path $script:ElsewhereRoot $script:ScopeHash) $script:StudyId
        Expand-Archive -Path $script:Zip -DestinationPath $script:ElsewherePath -Force

        # Simulate a different machine: a different root and no credentials.
        foreach ($name in $script:CredentialVariables) {
            $script:SavedEnvironment[$name] = (Get-Item -Path "env:$name" -ErrorAction SilentlyContinue).Value
            Set-Item -Path "env:$name" -Value $null
        }
        $env:CHAOS_STUDY_ROOT = $script:ElsewhereRoot
    }

    AfterAll {
        if (Test-Path $script:Sandbox) { Remove-Item $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reads the unzipped study back by id under the new root' {
        $read = Get-Study -StudyId $script:StudyId
        $read.state | Should -Be 'SEALED'
        $read.studyId | Should -Be $script:StudyId
        $read.path | Should -Be $script:ElsewherePath
    }

    It 'reads the unzipped study back by path, independent of any root' {
        $read = Get-Study -Path $script:ElsewherePath
        $read.state | Should -Be 'SEALED'
        $read.plan.question | Should -Be 'does checkout survive losing a pod?'
    }

    It 'verifies integrity offline, with no credentials in the environment' {
        foreach ($name in $script:CredentialVariables) {
            (Get-Item -Path "env:$name" -ErrorAction SilentlyContinue).Value | Should -BeNullOrEmpty
        }
        (Get-Study -Path $script:ElsewherePath -Verify).integrity.valid | Should -BeTrue
    }

    It 'carries every field a cold reader needs in the manifest' {
        $read = Get-Study -Path $script:ElsewherePath
        $read.manifest.studyId | Should -Be $script:StudyId
        $read.manifest.scopeHash | Should -Be $script:ScopeHash
        $read.manifest.schemaVersions | Should -Not -BeNullOrEmpty
        $read.manifest.sealedAt | Should -Not -BeNullOrEmpty
        $read.manifest.scope.resourceGroup | Should -Be 'rg-1'
    }

    It 'rebuilds an index for the copied study under the new root' {
        $rebuilt = Get-StudyIndex -ScopeHash $script:ScopeHash -Rebuild
        @($rebuilt | ForEach-Object { $_.studyId }) | Should -Contain $script:StudyId
    }

    It 'reads the evidence tree that travelled with the study' {
        $read = Get-Study -Path $script:ElsewherePath
        $read.files | Should -Contain 'evidence/pre/metrics.json'
    }
}
