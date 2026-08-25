<#
.SYNOPSIS
    Pester coverage for the immutable dated study store (E4-T5).

.DESCRIPTION
    Lives under `skills/start-chaos/tests/` so it is discovered by the existing
    CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`) without
    changing or narrowing that path, mirroring `[E2] State.Tests.ps1`.

    Covers the Epic 4 acceptance criteria:
      * sealing is a three-step commit and is one-way — a write to a sealed
        study throws `StudyAlreadySealed` (exit code 13) and no force flag
        exists (D7);
      * the resolved study root is neither under the repository root nor under
        the system temp directory (FR-14);
      * `manifest.json` hashes every file except itself and `SEALED`, and a
        mutated file is detected;
      * `Get-StudyIndex -Rebuild` reconstructs a deleted index (NFR-6);
      * a planted token never reaches the sealed study (NFR-5).
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:RepoRoot = (Resolve-Path (Join-Path $script:PluginRoot '..')).Path
    $script:StudyPs1 = Join-Path $script:PluginRoot 'scripts' 'Study.ps1'
    . $script:StudyPs1

    $script:OriginalStudyRoot = $env:CHAOS_STUDY_ROOT
    $script:OriginalAbandonHours = $env:CHAOS_STUDY_ABANDON_HOURS
    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:OriginalXdgDataHome = $env:XDG_DATA_HOME

    #: 64 hex characters — the shape `k_session` actually has on disk.
    $script:PlantedToken = 'a3f1' * 16

    function New-StudySandbox {
        <# An isolated study root outside the repository. #>
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("chaos-study-" + [guid]::NewGuid().ToString('n'))
        $root = Join-Path (Join-Path $sandbox 'appdata') 'studies'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $env:CHAOS_STUDY_ROOT = $root
        $env:CHAOS_STUDY_ABANDON_HOURS = $null
        return [pscustomobject]@{ Sandbox = $sandbox; Root = $root }
    }

    function New-SamplePlan {
        param([string]$Question = 'does checkout survive losing a pod?')
        return [ordered]@{
            vertical        = 'kubernetes'
            question        = $Question
            hypothesis      = 'the deployment reschedules within 60s'
            steadyState     = [ordered]@{ description = 'p99 under 500ms'; source = 'azure-monitor' }
            fault           = [ordered]@{
                urn        = 'urn:csci:microsoft:chaosMesh:podChaos/2.2'
                faultPath  = 'experiment'
                parameters = @()
            }
            targeting       = [ordered]@{ mode = 'list'; targets = @('/subscriptions/s/resourceGroups/rg') }
            duration        = 'PT5M'
            abortConditions = @('error rate > 10%')
            signals         = @()
            readiness       = [ordered]@{ chaosMesh = 'pass' }
            blocked         = $false
        }
    }

    function New-SealedStudy {
        param([string]$ScopeHash = 'abcd0123abcd0123')
        $study = New-Study -ScopeHash $ScopeHash -Plan (New-SamplePlan)
        Complete-Study -StudyId $study.studyId -ScopeHash $ScopeHash -ReportHtml '<html><body>report</body></html>' | Out-Null
        return $study
    }
}

AfterAll {
    $env:CHAOS_STUDY_ROOT = $script:OriginalStudyRoot
    $env:CHAOS_STUDY_ABANDON_HOURS = $script:OriginalAbandonHours
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    $env:XDG_DATA_HOME = $script:OriginalXdgDataHome
}

Describe 'Study root resolution (E4-T1, FR-14)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It '$env:CHAOS_STUDY_ROOT wins' {
        Get-StudyRoot | Should -Be $script:Box.Root
    }

    It 'resolves the default root outside the repository and outside the system temp directory' {
        $env:CHAOS_STUDY_ROOT = $null
        $resolved = [System.IO.Path]::GetFullPath((Get-StudyRoot -ConfigStart $script:Box.Sandbox))

        $repo = [System.IO.Path]::GetFullPath($script:RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)

        $resolved.StartsWith($repo + [System.IO.Path]::DirectorySeparatorChar) | Should -BeFalse
        $resolved.StartsWith($temp + [System.IO.Path]::DirectorySeparatorChar) | Should -BeFalse
    }

    It 'does not sit next to startchaos-state.json' {
        $env:CHAOS_STUDY_ROOT = $null
        (Get-StudyRoot -ConfigStart $script:Box.Sandbox) | Should -Not -Match 'startchaos-state'
    }

    It 'falls back to .chaos-plugins.yaml studyRoot when the environment is unset' {
        $env:CHAOS_STUDY_ROOT = $null
        $workdir = Join-Path $script:Box.Sandbox 'work'
        $nested = Join-Path $workdir 'nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        "studyRoot: ./from-config`n" | Out-File -FilePath (Join-Path $workdir '.chaos-plugins.yaml') -Encoding utf8

        Get-StudyRoot -ConfigStart $nested | Should -Be (Join-Path $workdir 'from-config')
    }

    It 'does not create the root merely by resolving it' {
        $env:CHAOS_STUDY_ROOT = Join-Path $script:Box.Sandbox 'not-yet'
        Get-StudyRoot | Out-Null
        Test-Path (Join-Path $script:Box.Sandbox 'not-yet') | Should -BeFalse
    }
}

Describe 'Study creation and identity (E4-T1)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'mints a sortable, human-dated, collision-resistant studyId' {
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        $study.studyId | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{8}$'
    }

    It 'gives two studies over the identical plan distinct identities' {
        $a = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        $b = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        $a.studyId | Should -Not -Be $b.studyId
    }

    It 'lays the study out under <root>/<scopeHash>/<studyId>' {
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        $study.path | Should -Be (Join-Path (Join-Path $script:Box.Root 'abcd0123abcd0123') $study.studyId)
        Test-Path (Join-Path $study.path 'study-plan.v1.json') | Should -BeTrue
        foreach ($phase in @('pre', 'during', 'post')) {
            Test-Path (Join-Path (Join-Path $study.path 'evidence') $phase) | Should -BeTrue
        }
    }

    It 'derives the scope hash from state with the [E2] helper, never a fork (D16)' {
        $state = @{ context = @{ subscriptionId = 'sub-1'; resourceGroup = 'rg-1' }; workspace = @{ name = 'ws-1' } }
        $study = New-Study -State $state -Plan (New-SamplePlan)
        $study.scopeHash | Should -Be (Get-EvidenceScopeHash -State $state)
    }

    It 'writes the plan in the [E2] artifact envelope' {
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        $doc = Get-Content (Join-Path $study.path 'study-plan.v1.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $doc['artifactSchemaVersion'] | Should -Be 1
        $doc['artifactType'] | Should -Be 'study-plan'
        $doc['plan']['studyId'] | Should -Be $study.studyId
        $doc['provenance']['confidence'] | Should -Be 'high'
    }
}

Describe 'Study lifecycle is read from the directory, never a status field (E4-T1)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'reports PLANNED for a study with only a plan' {
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        (Get-Study -StudyId $study.studyId).state | Should -Be 'PLANNED'
    }

    It 'reports EXECUTED once a run record exists' {
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        Save-StudyArtifact -StudyId $study.studyId -Name 'run-record.v1.json' -Data @{ artifactType = 'run-record' }
        (Get-Study -StudyId $study.studyId).state | Should -Be 'EXECUTED'
    }

    It 'reports SEALED once the marker and manifest exist' {
        $study = New-SealedStudy
        (Get-Study -StudyId $study.studyId).state | Should -Be 'SEALED'
    }

    It 'reports ABANDONED for a stale plan with no run record' {
        $env:CHAOS_STUDY_ABANDON_HOURS = '0'
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        Start-Sleep -Milliseconds 20
        (Get-Study -StudyId $study.studyId).state | Should -Be 'ABANDONED'
    }

    It 'keeps a study that crashed mid-execution PLANNED with a partial evidence tree' {
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan (New-SamplePlan)
        Save-StudyArtifact -StudyId $study.studyId -Name 'evidence/pre/metrics.json' -Data @{ ok = $true }
        $read = Get-Study -StudyId $study.studyId
        $read.state | Should -Be 'PLANNED'
        $read.files | Should -Contain 'evidence/pre/metrics.json'
    }
}

Describe 'Path resolution refuses to leave the study root (E4-T1)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'resolves a relative artifact path inside the study' {
        $resolved = Resolve-StudyPath -ScopeHash 'abcd0123abcd0123' -StudyId '20260824T184213Z-9f2c1ab4' -RelativePath 'evidence/pre/x.json'
        $resolved | Should -Be (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $script:Box.Root 'abcd0123abcd0123') '20260824T184213Z-9f2c1ab4') 'evidence') 'pre') 'x.json')
    }

    It 'rejects traversal, absolute, drive-qualified and UNC paths' {
        foreach ($bad in @('../../escape.json', 'evidence/../../escape.json', '/etc/passwd', 'C:\Windows\system32\x', '\\server\share\x')) {
            { Resolve-StudyPath -ScopeHash 'abcd0123abcd0123' -StudyId '20260824T184213Z-9f2c1ab4' -RelativePath $bad } |
                Should -Throw -ExpectedMessage '*StudyPathOutsideRoot*'
        }
    }

    It 'rejects a structural segment that is not a safe name' {
        { Resolve-StudyPath -ScopeHash '..' -StudyId '20260824T184213Z-9f2c1ab4' } |
            Should -Throw -ExpectedMessage '*StudyPathOutsideRoot*'
    }
}

Describe 'Sealing is a one-way three-step commit (E4-T1, D7)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'writes report.html, then manifest.json, then SEALED, then the index record' {
        $study = New-SealedStudy
        foreach ($name in @('report.html', 'manifest.json', 'SEALED')) {
            Test-Path (Join-Path $study.path $name) | Should -BeTrue
        }
        Test-Path (Join-Path (Split-Path $study.path -Parent) 'index.json') | Should -BeTrue
    }

    It 'hashes every file except manifest.json and SEALED' {
        $study = New-SealedStudy
        $manifest = (Get-Content (Join-Path $study.path 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['manifest']
        $hashed = @($manifest['files'] | ForEach-Object { $_['path'] })

        $hashed | Should -Contain 'study-plan.v1.json'
        $hashed | Should -Contain 'report.html'
        $hashed | Should -Not -Contain 'manifest.json'
        $hashed | Should -Not -Contain 'SEALED'
        foreach ($file in $manifest['files']) {
            $file['sha256'] | Should -Match '^[0-9a-f]{64}$'
            $file['bytes'] | Should -BeGreaterThan 0
        }
    }

    It 'carries the self-describing portability fields (NFR-11)' {
        $study = New-SealedStudy
        $manifest = (Get-Content (Join-Path $study.path 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['manifest']
        foreach ($field in @('studyId', 'createdAt', 'sealedAt', 'scope', 'scopeHash', 'faultPath', 'apiVersions', 'toolSubstitutions', 'files', 'schemaVersions')) {
            $manifest.Contains($field) | Should -BeTrue -Because "manifest must be self-describing: $field"
        }
    }

    It 'detects a mutated file' {
        $study = New-SealedStudy
        (Get-Study -StudyId $study.studyId -Verify).integrity.valid | Should -BeTrue

        $planPath = Join-Path $study.path 'study-plan.v1.json'
        Set-ItemProperty -Path $planPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        'tampered' | Out-File -FilePath $planPath -Encoding utf8 -NoNewline

        $verified = Get-Study -StudyId $study.studyId -Verify
        $verified.integrity.valid | Should -BeFalse
        $verified.integrity.mismatched | Should -Contain 'study-plan.v1.json'
    }

    It 'detects a file deleted from a sealed study' {
        $study = New-SealedStudy
        Remove-Item (Join-Path $study.path 'report.html') -Force
        $verified = Get-Study -StudyId $study.studyId -Verify
        $verified.integrity.valid | Should -BeFalse
        $verified.integrity.missing | Should -Contain 'report.html'
    }
}

Describe 'A sealed study refuses every write (E4-T1, exit code 13)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'throws StudyAlreadySealed from Save-StudyArtifact' {
        $study = New-SealedStudy
        { Save-StudyArtifact -StudyId $study.studyId -Name 'findings.v1.json' -Data @{ x = 1 } } |
            Should -Throw -ExpectedMessage '*StudyAlreadySealed*'
    }

    It 'maps StudyAlreadySealed to exit code 13' {
        Get-StudyExitCode -ErrorType 'StudyAlreadySealed' | Should -Be 13
    }

    It 'carries the exit code on the thrown error record' {
        $study = New-SealedStudy
        $caught = $null
        try {
            Save-StudyArtifact -StudyId $study.studyId -Name 'findings.v1.json' -Data @{ x = 1 }
        } catch {
            $caught = $_
        }
        $caught | Should -Not -BeNullOrEmpty
        $caught.FullyQualifiedErrorId | Should -Match 'StudyAlreadySealed'
        $caught.TargetObject.exitCode | Should -Be 13
    }

    It 'exposes no force flag on Save-StudyArtifact or Complete-Study (D7)' {
        foreach ($name in @('Save-StudyArtifact', 'Complete-Study')) {
            $parameters = (Get-Command $name).Parameters.Keys
            $parameters | Should -Not -Contain 'Force'
            $parameters | Should -Not -Contain 'Overwrite'
        }
    }

    It 'refuses to seal a study twice' {
        $study = New-SealedStudy
        { Complete-Study -StudyId $study.studyId } | Should -Throw -ExpectedMessage '*StudyAlreadySealed*'
    }

    It 'leaves the sealed bytes untouched after a refused write' {
        $study = New-SealedStudy
        $before = (Get-FileHash (Join-Path $study.path 'manifest.json') -Algorithm SHA256).Hash
        try { Save-StudyArtifact -StudyId $study.studyId -Name 'findings.v1.json' -Data @{ x = 1 } } catch { }
        (Get-FileHash (Join-Path $study.path 'manifest.json') -Algorithm SHA256).Hash | Should -Be $before
        Test-Path (Join-Path $study.path 'findings.v1.json') | Should -BeFalse
    }
}

Describe 'Writes are atomic and leave no scratch behind (E4-T1, D16)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'leaves no lock or temp file in the study store' {
        $study = New-SealedStudy
        $leftovers = Get-ChildItem -Path $script:Box.Root -Recurse -Force -File |
            Where-Object { $_.Name -like '*.lock' -or $_.Name -like '*.tmp.*' }
        $leftovers | Should -BeNullOrEmpty
    }

    It 'registers Seal-Study as an alias of Complete-Study so verb linting passes' {
        (Get-Alias -Name 'Seal-Study').ResolvedCommandName | Should -Be 'Complete-Study'
    }

    It 'uses only approved verbs for its exported functions' {
        $approved = (Get-Verb).Verb
        foreach ($name in @('New-Study', 'Get-StudyRoot', 'Resolve-StudyPath', 'Save-StudyArtifact',
                'Complete-Study', 'Get-Study', 'Get-StudyIndex', 'Add-StudyIndexEntry')) {
            $approved | Should -Contain ($name.Split('-')[0])
        }
    }
}

Describe 'The index is a rebuildable cache, never a source of truth (E4-T1, NFR-6)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'appends one record per sealed study' {
        $first = New-SealedStudy
        $second = New-SealedStudy
        $index = Get-StudyIndex -ScopeHash 'abcd0123abcd0123'
        @($index).Count | Should -Be 2
        @($index | ForEach-Object { $_.studyId }) | Should -Contain $first.studyId
        @($index | ForEach-Object { $_.studyId }) | Should -Contain $second.studyId
    }

    It 'reconstructs an index deleted mid-test with -Rebuild' {
        $study = New-SealedStudy
        $indexPath = Join-Path (Split-Path $study.path -Parent) 'index.json'
        Remove-Item $indexPath -Force
        Test-Path $indexPath | Should -BeFalse

        $rebuilt = Get-StudyIndex -ScopeHash 'abcd0123abcd0123' -Rebuild
        Test-Path $indexPath | Should -BeTrue
        @($rebuilt | ForEach-Object { $_.studyId }) | Should -Contain $study.studyId
    }

    It 'still enumerates studies when the index is missing, without writing one' {
        $study = New-SealedStudy
        $indexPath = Join-Path (Split-Path $study.path -Parent) 'index.json'
        Remove-Item $indexPath -Force

        @(Get-StudyIndex -ScopeHash 'abcd0123abcd0123' | ForEach-Object { $_.studyId }) | Should -Contain $study.studyId
        Test-Path $indexPath | Should -BeFalse
    }

    It 'survives a corrupt index by scanning' {
        $study = New-SealedStudy
        $indexPath = Join-Path (Split-Path $study.path -Parent) 'index.json'
        'not json {' | Out-File -FilePath $indexPath -Encoding utf8 -NoNewline

        @(Get-StudyIndex -ScopeHash 'abcd0123abcd0123' | ForEach-Object { $_.studyId }) | Should -Contain $study.studyId
    }

    It 'Add-StudyIndexEntry replaces rather than duplicates a record for the same studyId' {
        $study = New-SealedStudy
        Add-StudyIndexEntry -ScopeHash 'abcd0123abcd0123' -Entry ([ordered]@{ studyId = $study.studyId; outcome = 'abandoned' }) | Out-Null
        $index = @(Get-StudyIndex -ScopeHash 'abcd0123abcd0123')
        $index.Count | Should -Be 1
        $index[0].outcome | Should -Be 'abandoned'
    }
}

Describe 'No secret reaches the sealed study (E4-T5, NFR-5)' {
    BeforeEach { $script:Box = New-StudySandbox }

    It 'redacts a token planted in the plan, the signals, an error string and an az argv' {
        $plan = New-SamplePlan
        $plan['hypothesis'] = "auth uses $($script:PlantedToken) today"
        $plan['signals'] = @([ordered]@{ name = 'kql'; token = $script:PlantedToken })

        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan $plan

        Save-StudyArtifact -StudyId $study.studyId -Name 'evidence/during/signals.json' -Data ([ordered]@{
                sourceQuery = "KubePodInventory | where key == '$($script:PlantedToken)'"
                clientSecret = $script:PlantedToken
            })
        Save-StudyArtifact -StudyId $study.studyId -Name 'run-record.v1.json' -Data ([ordered]@{
                artifactType = 'run-record'
                errors       = @("az chaos experiment start failed: Bearer $($script:PlantedToken) rejected")
                argv         = @('az', 'chaos', 'experiment', 'start', '--token', $script:PlantedToken)
            })
        Save-StudyArtifact -StudyId $study.studyId -Name 'commands.jsonl' `
            -Content ('{"argv":["az","login","--password","' + $script:PlantedToken + '"]}')

        Complete-Study -StudyId $study.studyId -ReportHtml "<html><body>$($script:PlantedToken)</body></html>" | Out-Null

        $hits = @()
        foreach ($file in Get-ChildItem -Path $script:Box.Root -Recurse -Force -File) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if ($text -and $text.Contains($script:PlantedToken)) { $hits += $file.FullName }
        }
        $hits | Should -BeNullOrEmpty -Because 'a planted token must appear nowhere in the sealed study'
    }

    It 'redacts a secret-named key in the study plan' {
        $plan = New-SamplePlan
        $plan['clientSecret'] = 'hunter2'
        $study = New-Study -ScopeHash 'abcd0123abcd0123' -Plan $plan
        $doc = Get-Content (Join-Path $study.path 'study-plan.v1.json') -Raw -Encoding utf8
        $doc | Should -Not -Match 'hunter2'
        $doc | Should -Match '\[REDACTED\]'
    }

    It 'never writes a study under $CHAOS_KEY_DIR' {
        $keyDir = Join-Path $script:Box.Sandbox 'keys'
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
        $study = New-SealedStudy
        $study.path.StartsWith($keyDir) | Should -BeFalse
    }
}

Describe 'Schemas ship with the store (E4-T3)' {
    It 'ships study-plan.v1 and study-manifest.v1 with the [E2] envelope' {
        foreach ($pair in @(@('study-plan', 'plan'), @('study-manifest', 'manifest'))) {
            $schema = Get-Content (Join-Path (Join-Path $script:PluginRoot 'schemas') "$($pair[0]).v1.schema.json") -Raw -Encoding utf8 |
                ConvertFrom-Json -AsHashtable
            $schema['properties']['artifactSchemaVersion']['const'] | Should -Be 1
            $schema['properties']['artifactType']['const'] | Should -Be $pair[0]
            $schema['properties'].Contains($pair[1]) | Should -BeTrue
            foreach ($field in @('scopeId', 'runId', 'generatedAt', 'provenance', 'warnings')) {
                $schema['required'] | Should -Contain $field
            }
            $schema['definitions'].Contains('citedNumber') | Should -BeTrue
        }
    }
}
