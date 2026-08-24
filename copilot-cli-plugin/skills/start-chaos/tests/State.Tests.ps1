<#
.SYNOPSIS
    Pester coverage for compatible state and durable evidence (E2-T5).

.DESCRIPTION
    Lives under `skills/start-chaos/tests/` so it is discovered by the existing
    CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`) without
    changing or narrowing that path.

    Covers the three Epic 2 acceptance criteria on the PowerShell side:
      * an existing startchaos-state.json resumes unchanged and is MIRRORED,
        never relocated;
      * evidence survives deletion of repo/session temporary content (F12);
      * no secret reaches the evidence store.
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:StatePs1 = Join-Path $script:PluginRoot 'scripts' 'State.ps1'
    . $script:StatePs1

    $script:OriginalStatePath = $env:STARTCHAOS_STATE_PATH
    $script:OriginalEvidenceRoot = $env:CHAOS_EVIDENCE_ROOT
    $script:OriginalEvidenceDisabled = $env:CHAOS_EVIDENCE_DISABLED
    $script:OriginalRunId = $env:CHAOS_RUN_ID

    function New-TestSandbox {
        <# Creates an isolated repo/tmp + durable evidence root pair. #>
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("chaos-state-" + [guid]::NewGuid().ToString('n'))
        $repoTmp = Join-Path (Join-Path $sandbox 'repo') 'tmp'
        $evidence = Join-Path (Join-Path $sandbox 'appdata') 'evidence'
        New-Item -ItemType Directory -Path $repoTmp -Force | Out-Null
        New-Item -ItemType Directory -Path $evidence -Force | Out-Null

        $env:STARTCHAOS_STATE_PATH = Join-Path $repoTmp 'startchaos-state.json'
        $env:CHAOS_EVIDENCE_ROOT = $evidence
        $env:CHAOS_EVIDENCE_DISABLED = $null
        $env:CHAOS_RUN_ID = $null

        return [pscustomobject]@{
            Sandbox   = $sandbox
            RepoTmp   = $repoTmp
            Evidence  = $evidence
            StatePath = $env:STARTCHAOS_STATE_PATH
        }
    }

    function Get-MirroredStatePath {
        param([hashtable]$State)
        return (Join-Path (Join-Path (Join-Path (Join-Path $env:CHAOS_EVIDENCE_ROOT `
                        $State['evidence']['scopeHash']) $State['evidence']['runId']) 'artifacts') 'state.json')
    }
}

AfterAll {
    $env:STARTCHAOS_STATE_PATH = $script:OriginalStatePath
    $env:CHAOS_EVIDENCE_ROOT = $script:OriginalEvidenceRoot
    $env:CHAOS_EVIDENCE_DISABLED = $script:OriginalEvidenceDisabled
    $env:CHAOS_RUN_ID = $script:OriginalRunId
}

Describe 'State.ps1 backward-compatible import (E2-T1)' {
    BeforeEach { $script:Box = New-TestSandbox }

    It 'keeps the shipped state schema at version 1' {
        (New-EmptyState)['stateSchemaVersion'] | Should -Be 1
    }

    It 'resumes an existing v1 state file unchanged' {
        $legacy = @{
            stateSchemaVersion = 1
            createdAt          = '2020-01-01T00:00:00.0000000Z'
            updatedAt          = '2020-01-02T00:00:00.0000000Z'
            context            = @{ subscriptionId = 'sub-1'; resourceGroup = 'rg-1'; location = 'eastus' }
            auth               = @{ status = 'done'; method = 'cli' }
            workspace          = @{ status = 'done'; name = 'ws-1' }
            setup              = @{ status = 'done'; selectedScenarioId = 'scenario-9' }
            run                = @{ status = 'done'; scenarioRunId = 'run-abc' }
        }
        ($legacy | ConvertTo-Json -Depth 32) | Out-File -FilePath $script:Box.StatePath -Encoding utf8 -NoNewline

        $state = Read-State

        # Every value the file already carried survives verbatim.
        $state['context']['subscriptionId'] | Should -Be 'sub-1'
        $state['context']['location']       | Should -Be 'eastus'
        $state['auth']['status']            | Should -Be 'done'
        $state['workspace']['name']         | Should -Be 'ws-1'
        $state['setup']['selectedScenarioId'] | Should -Be 'scenario-9'
        $state['run']['scenarioRunId']      | Should -Be 'run-abc'
        $state['createdAt']                 | Should -Be ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime()
        $state['stateSchemaVersion']        | Should -Be 1
    }

    It 'fills sections the older file never had without inventing values' {
        '{"stateSchemaVersion":1,"auth":{"status":"done"}}' |
            Out-File -FilePath $script:Box.StatePath -Encoding utf8 -NoNewline

        $state = Read-State

        $state['auth']['status'] | Should -Be 'done'
        # Missing leaves come from the defaults, not from a guess.
        $state['auth']['method'] | Should -BeNullOrEmpty
        $state['context']        | Should -Not -BeNullOrEmpty
        $state['workspace']['identity'] | Should -Not -BeNullOrEmpty
        $state['run']['status']  | Should -Be 'pending'
        $state['evidence']['runId'] | Should -Not -BeNullOrEmpty
    }

    It 'preserves keys this version does not recognise' {
        '{"stateSchemaVersion":1,"futureSection":{"a":1},"run":{"customField":"keep-me"}}' |
            Out-File -FilePath $script:Box.StatePath -Encoding utf8 -NoNewline

        $state = Read-State

        $state['futureSection']['a']     | Should -Be 1
        $state['run']['customField']     | Should -Be 'keep-me'
        $state['run']['status']          | Should -Be 'pending'
    }

    It 'never overwrites a recorded $null with a default' {
        # "recorded null" and "never collected" are different facts.
        $existing = @{ stateSchemaVersion = 1; context = @{ location = $null } }
        ($existing | ConvertTo-Json -Depth 32) | Out-File -FilePath $script:Box.StatePath -Encoding utf8 -NoNewline

        (Read-State)['context']['location'] | Should -BeNullOrEmpty
    }

    It 'round-trips a state through Save-State and Read-State' {
        $state = New-EmptyState
        $state['context']['subscriptionId'] = 'sub-round-trip'
        $state['run']['actions'] = @(@{ name = 'a1'; status = 'success' })
        Save-State -State ([hashtable]$state)

        $reloaded = Read-State
        $reloaded['context']['subscriptionId'] | Should -Be 'sub-round-trip'
        $reloaded['run']['actions'][0]['name'] | Should -Be 'a1'
    }

    It 'keeps the same evidence runId across a resume' {
        $state = [hashtable](New-EmptyState)
        Save-State -State $state
        $first = (Read-State)['evidence']['runId']
        Save-State -State (Read-State)
        (Read-State)['evidence']['runId'] | Should -Be $first
    }
}

Describe 'Evidence root location (E2-T2, F12)' {
    It 'honours $env:CHAOS_EVIDENCE_ROOT when set' {
        $script:Box = New-TestSandbox
        Get-EvidenceRoot | Should -Be $script:Box.Evidence
    }

    It 'defaults to a per-user application-data path, never a repo or tmp path' {
        $saved = $env:CHAOS_EVIDENCE_ROOT
        $env:CHAOS_EVIDENCE_ROOT = $null
        try {
            $root = Get-EvidenceRoot
            $root | Should -Match 'chaos-studio'
            $root | Should -Match 'evidence$'
            $root | Should -Not -Match '(?i)[\\/]tmp[\\/]'
            $root.StartsWith($script:PluginRoot) | Should -BeFalse
        } finally {
            $env:CHAOS_EVIDENCE_ROOT = $saved
        }
    }

    It 'derives a stable scope hash that separates different scopes' {
        $a = [hashtable](New-EmptyState)
        $a['context']['subscriptionId'] = 'sub-a'
        $a['context']['resourceGroup'] = 'rg-a'
        $b = [hashtable](New-EmptyState)
        $b['context']['subscriptionId'] = 'sub-b'
        $b['context']['resourceGroup'] = 'rg-a'

        (Get-EvidenceScopeHash -State $a) | Should -Be (Get-EvidenceScopeHash -State $a)
        (Get-EvidenceScopeHash -State $a) | Should -Not -Be (Get-EvidenceScopeHash -State $b)
        (Get-EvidenceScopeHash -State $a) | Should -Match '^[0-9a-f]{16}$'
    }
}

Describe 'State mirroring (E2-T2)' {
    BeforeEach { $script:Box = New-TestSandbox }

    It 'mirrors the state without relocating it' {
        $state = [hashtable](New-EmptyState)
        $state['context']['subscriptionId'] = 'sub-mirror'
        Save-State -State $state

        # Source of truth stays exactly where it was configured.
        Test-Path $script:Box.StatePath | Should -BeTrue
        $onDisk = Get-Content $script:Box.StatePath -Raw | ConvertFrom-Json -AsHashtable
        $onDisk['context']['subscriptionId'] | Should -Be 'sub-mirror'

        # And a mirror exists in the durable store.
        $mirror = Get-MirroredStatePath -State $state
        Test-Path $mirror | Should -BeTrue
        $envelope = Get-Content $mirror -Raw | ConvertFrom-Json -AsHashtable
        $envelope['evidenceSchemaVersion'] | Should -Be 1
        $envelope['kind']                  | Should -Be 'artifacts'
        $envelope['revision']              | Should -Be 1
        $envelope['data']['context']['subscriptionId'] | Should -Be 'sub-mirror'
    }

    It 'survives deletion of repo/session temporary content' {
        $state = [hashtable](New-EmptyState)
        $state['run']['scenarioRunId'] = 'run-survives'
        Save-State -State $state
        $mirror = Get-MirroredStatePath -State $state

        # F12: tmp/ was wiped twice mid-run.
        Remove-Item -Recurse -Force $script:Box.RepoTmp
        Test-Path $script:Box.StatePath | Should -BeFalse

        Test-Path $mirror | Should -BeTrue
        $envelope = Get-Content $mirror -Raw | ConvertFrom-Json -AsHashtable
        $envelope['data']['run']['scenarioRunId'] | Should -Be 'run-survives'
    }

    It 'increments the revision counter on every write and leaves no scratch files' {
        $state = [hashtable](New-EmptyState)
        Save-State -State $state
        Save-State -State $state
        Save-State -State $state

        $mirror = Get-MirroredStatePath -State $state
        (Get-Content $mirror -Raw | ConvertFrom-Json -AsHashtable)['revision'] | Should -Be 3

        $scratch = Get-ChildItem (Split-Path $mirror -Parent) |
            Where-Object { $_.Name -like '*.lock' -or $_.Name -like '*.tmp.*' }
        $scratch | Should -BeNullOrEmpty
    }

    It 'writes each artifact kind under its own directory' {
        $written = Write-EvidenceArtifact -Name 'metrics.json' -Data @{ a = 1 } -Kind 'raw' `
            -ScopeHash 'scopehash01' -RunId 'run-1'
        $written['relativePath'] | Should -Be 'scopehash01/run-1/raw/metrics.json'
        Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $script:Box.Evidence 'scopehash01') 'run-1') 'raw') 'metrics.json') |
            Should -BeTrue
    }

    It 'supersedes an unreadable prior revision instead of failing the phase' {
        $target = Join-Path (Join-Path (Join-Path (Join-Path $script:Box.Evidence 'scopehash01') 'run-1') 'artifacts') 'x.json'
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        '{not json' | Out-File -FilePath $target -Encoding utf8 -NoNewline

        $written = Write-EvidenceArtifact -Name 'x.json' -Data @{ ok = $true } -ScopeHash 'scopehash01' -RunId 'run-1'
        $written['revision'] | Should -Be 1
        (Get-Content $target -Raw | ConvertFrom-Json -AsHashtable)['data']['ok'] | Should -BeTrue
    }

    It 'skips mirroring when CHAOS_EVIDENCE_DISABLED is set but still saves state' {
        $env:CHAOS_EVIDENCE_DISABLED = '1'
        try {
            $state = [hashtable](New-EmptyState)
            Save-State -State $state
            Test-Path $script:Box.StatePath | Should -BeTrue
            Test-Path (Get-MirroredStatePath -State $state) | Should -BeFalse
        } finally {
            $env:CHAOS_EVIDENCE_DISABLED = $null
        }
    }

    It 'never fails a phase when the evidence store is unwritable' {
        # Point the root at a path that cannot be created.
        $env:CHAOS_EVIDENCE_ROOT = Join-Path $script:Box.StatePath 'not-a-directory'
        try {
            $state = [hashtable](New-EmptyState)
            { Save-State -State $state } | Should -Not -Throw
        } finally {
            $env:CHAOS_EVIDENCE_ROOT = $script:Box.Evidence
        }
    }
}

Describe 'Evidence redaction (E2-T3)' {
    BeforeEach { $script:Box = New-TestSandbox }

    It 'redacts secret-bearing keys before anything reaches disk' {
        $data = @{
            clientSecret     = 'plaintext-secret'
            connectionString = 'Endpoint=sb://x;SharedAccessKey=abc'
            accessToken      = 'aaaa'
            keep             = 'visible'
            nested           = @{ approvalKey = 'nope' }
        }
        $written = Write-EvidenceArtifact -Name 'a.json' -Data $data -ScopeHash 'scopehash01' -RunId 'run-1'
        $raw = Get-Content $written['path'] -Raw

        $raw | Should -Not -Match 'plaintext-secret'
        $raw | Should -Not -Match 'SharedAccessKey=abc'
        $raw | Should -Match 'visible'

        $envelope = $raw | ConvertFrom-Json -AsHashtable
        $envelope['data']['clientSecret']          | Should -Be '[REDACTED]'
        $envelope['data']['nested']['approvalKey'] | Should -Be '[REDACTED]'
        $envelope['data']['keep']                  | Should -Be 'visible'
        $envelope['redacted']                      | Should -BeTrue
    }

    It 'redacts secret-shaped values hidden under innocuous key names' {
        $key = 'a3f1' * 16
        $written = Write-EvidenceArtifact -Name 'b.json' `
            -Data @{ note = $key; header = 'Bearer abcdefghijklmnopqrstuvwxyz0123456789' } `
            -ScopeHash 'scopehash01' -RunId 'run-1'
        $raw = Get-Content $written['path'] -Raw

        $raw | Should -Not -Match $key
        ($raw | ConvertFrom-Json -AsHashtable)['data']['header'] | Should -Be '[REDACTED]'
    }

    It 'leaves ordinary Azure values and measured zeros intact' {
        $resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Chaos/workspaces/ws'
        $written = Write-EvidenceArtifact -Name 'c.json' `
            -Data @{ resourceId = $resourceId; collectedAt = '2020-01-01T00:00:00Z'; count = 0 } `
            -ScopeHash 'scopehash01' -RunId 'run-1'
        $envelope = Get-Content $written['path'] -Raw | ConvertFrom-Json -AsHashtable

        $envelope['data']['resourceId']  | Should -Be $resourceId
        # ConvertFrom-Json rehydrates ISO-8601 as [datetime]; the point is that
        # a timestamp is never mistaken for key material.
        ([datetime]$envelope['data']['collectedAt']).ToUniversalTime().ToString('o') |
            Should -Be '2020-01-01T00:00:00.0000000Z'
        # A measured zero is a measurement, not missing data (NFR-3).
        $envelope['data']['count']       | Should -Be 0
    }

    It 'never mirrors a secret carried in the state file' {
        $state = [hashtable](New-EmptyState)
        $state['auth']['token'] = 'super-secret-token'
        Save-State -State $state

        $raw = Get-Content (Get-MirroredStatePath -State $state) -Raw
        $raw | Should -Not -Match 'super-secret-token'
    }
}
