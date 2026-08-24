<#
.SYNOPSIS
    Pester coverage for the host-visible MCP tool preflight (E1-T3 / E1-T4).

.DESCRIPTION
    Lives under `skills/start-chaos/tests/` so it is discovered by the existing
    CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`) without
    changing or narrowing that path.

    Covers the F5 regression: a `requiredTools` entry that the HOST does not
    expose must produce an exact, named failure — never a substitution and
    never a silent fallback.
#>

BeforeAll {
    $script:PluginRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:PreflightPs1 = Join-Path $script:PluginRoot 'scripts' 'Preflight.ps1'
    . $script:PreflightPs1

    # The 15 tools the chaos-studio MCP server ships today. Kept in lockstep
    # with mcp/tests/test_tool_manifest.py::ORIGINAL_FIFTEEN_TOOLS.
    $script:OriginalFifteenTools = @(
        'chaos_set_auth_mode'
        'chaos_get_auth_mode'
        'chaos_create_workspace'
        'chaos_get_workspace'
        'chaos_refresh_recommendations'
        'chaos_list_recommended_scenarios'
        'chaos_create_scenario_configuration'
        'chaos_validate_scenario_configuration'
        'chaos_fix_resource_permissions'
        'chaos_execute_scenario'
        'chaos_get_scenario_run'
        'chaos_cancel_scenario_run'
        'monitor_query_metrics'
        'monitor_query_logs'
        'monitor_search_activity_log'
    )

    $script:SkillNames = @(
        'start-chaos', 'create-workspace', 'setup-scenario', 'run-scenario', 'chaos-impact'
    )

    function Get-SkillMdPath {
        param([string]$Name)
        Join-Path $script:PluginRoot 'skills' $Name 'SKILL.md'
    }
}

Describe 'Preflight.ps1 contract' {
    It 'ships at the shared scripts path and dot-sources cleanly' {
        Test-Path $script:PreflightPs1 | Should -BeTrue
        Get-Command Get-SkillRequiredTools -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-RequiredTools    -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Assert-RequiredTools  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'never introspects the chaos-studio server for its own inventory' {
        # The tool inventory MUST be host-supplied (`tools/list`). Server
        # self-introspection would report registration, not runtime availability.
        $raw = Get-Content $script:PreflightPs1 -Raw
        $raw | Should -Not -Match 'chaos_mcp'
        $raw | Should -Not -Match 'list_tools'
        $raw | Should -Match 'AvailableTools'
    }
}

Describe 'Get-SkillRequiredTools' {
    It 'reads a requiredTools declaration from every one of the five skills' -ForEach @(
        @{ Name = 'start-chaos' }
        @{ Name = 'create-workspace' }
        @{ Name = 'setup-scenario' }
        @{ Name = 'run-scenario' }
        @{ Name = 'chaos-impact' }
    ) {
        $tools = Get-SkillRequiredTools -SkillPath (Get-SkillMdPath $Name)
        $tools.Count | Should -BeGreaterThan 0
        foreach ($tool in $tools) {
            $script:OriginalFifteenTools | Should -Contain $tool
        }
    }

    It 'returns declarations in order and without duplicates' {
        $tools = Get-SkillRequiredTools -SkillPath (Get-SkillMdPath 'run-scenario')
        $tools | Should -Be @(
            'chaos_execute_scenario', 'chaos_get_scenario_run', 'chaos_cancel_scenario_run'
        )
        ($tools | Select-Object -Unique).Count | Should -Be $tools.Count
    }

    It 'throws when the SKILL.md does not exist' {
        { Get-SkillRequiredTools -SkillPath (Join-Path $script:PluginRoot 'skills' 'nope' 'SKILL.md') } |
            Should -Throw '*no SKILL.md*'
    }
}

Describe 'Test-RequiredTools' {
    It 'passes when the host exposes every declared tool' {
        foreach ($name in $script:SkillNames) {
            $required = Get-SkillRequiredTools -SkillPath (Get-SkillMdPath $name)
            $result = Test-RequiredTools -RequiredTools $required -AvailableTools $script:OriginalFifteenTools
            $result.ok      | Should -BeTrue
            $result.missing | Should -HaveCount 0
        }
    }

    It 'ignores extra host tools it did not ask for' {
        $result = Test-RequiredTools `
            -RequiredTools @('chaos_get_workspace') `
            -AvailableTools ($script:OriginalFifteenTools + @('some_other_server_tool'))
        $result.ok | Should -BeTrue
    }

    # F5 / test_required_tools_preflight_fails_named — registration on the
    # server says nothing about runtime availability on the host.
    It 'test_required_tools_preflight_fails_named: names the missing tool and never substitutes' {
        $required = Get-SkillRequiredTools -SkillPath (Get-SkillMdPath 'run-scenario')
        $hostTools = @($required | Where-Object { $_ -ne 'chaos_cancel_scenario_run' })

        $result = Test-RequiredTools -RequiredTools $required -AvailableTools $hostTools

        $result.ok      | Should -BeFalse
        $result.missing | Should -Be @('chaos_cancel_scenario_run')
        $result.message | Should -BeLike "$(Get-PreflightFailurePrefix)*"
        $result.message | Should -Match 'chaos_cancel_scenario_run'
        # The message must not offer any sibling tool as a stand-in.
        foreach ($sibling in $hostTools) {
            $result.message | Should -Not -Match ([regex]::Escape($sibling))
        }
        $result.message | Should -Match 'Do NOT substitute'
    }

    It 'names every required tool when no MCP server is registered at all' {
        $required = Get-SkillRequiredTools -SkillPath (Get-SkillMdPath 'chaos-impact')
        $result = Test-RequiredTools -RequiredTools $required -AvailableTools @()

        $result.ok | Should -BeFalse
        $result.missing | Should -HaveCount $required.Count
        foreach ($tool in $required) {
            $result.message | Should -Match ([regex]::Escape($tool))
        }
    }

    It 'is case-sensitive: a near-miss name is reported missing, not matched' {
        $result = Test-RequiredTools `
            -RequiredTools @('chaos_get_workspace') `
            -AvailableTools @('Chaos_Get_Workspace')
        $result.ok      | Should -BeFalse
        $result.missing | Should -Be @('chaos_get_workspace')
    }

    It 'passes trivially when a skill declares no tools' {
        $result = Test-RequiredTools -RequiredTools @() -AvailableTools @()
        $result.ok | Should -BeTrue
    }
}

Describe 'Assert-RequiredTools' {
    It 'throws the named failure message so the pipeline stops' {
        { Assert-RequiredTools `
                -RequiredTools @('chaos_execute_scenario') `
                -AvailableTools @('chaos_get_workspace') } |
            Should -Throw '*chaos_execute_scenario*'
    }

    It 'returns the passing result without throwing' {
        $result = Assert-RequiredTools `
            -RequiredTools @('chaos_execute_scenario') `
            -AvailableTools $script:OriginalFifteenTools
        $result.ok | Should -BeTrue
    }
}

Describe 'Skill preflight documentation' {
    It 'documents the host-visible preflight in every SKILL.md' -ForEach @(
        @{ Name = 'start-chaos' }
        @{ Name = 'create-workspace' }
        @{ Name = 'setup-scenario' }
        @{ Name = 'run-scenario' }
        @{ Name = 'chaos-impact' }
    ) {
        $raw = Get-Content (Get-SkillMdPath $Name) -Raw
        $raw | Should -Match '## Tool preflight'
        $raw | Should -Match 'Test-RequiredTools'
    }

    It 'documents the preflight in the start-chaos agent instructions' {
        $agent = Join-Path $script:PluginRoot 'agents' 'start-chaos.md'
        $raw = Get-Content $agent -Raw
        $raw | Should -Match '## Tool Preflight'
        $raw | Should -Match 'requiredTools'
        $raw | Should -Match 'never ask the `chaos-studio` server to describe itself'
    }
}
