<#
.SYNOPSIS
    Pester 5 unit tests for permission-blocker normalization, the targeted-grant
    proposal, and the broad-fix consent gate (E3-T2 / E3-T3 / E3-T5).

.DESCRIPTION
    Field evidence F8/CS-6: `config validate` was unreachable from the agent's
    write allow-list, `--skip-validation` was used, and the permission-blocker
    data was forfeited. Once the blockers *are* obtained they arrive in several
    shapes (`properties.errors`, `properties.validationErrors`, per-resource
    nested errors) with inconsistent field spellings, so they are normalized to
    one shape before anything reads them.

    `fixResourcePermissions` is a broad-breadth mutation: it grants whatever the
    service decides is required, across every target resource, in one call. It
    stays available, but only after explicit consent — and the exact, targeted
    `az role assignment create` commands built from `Rbac.ps1` are always
    offered first.

    Lives under `skills/setup-scenario/tests/` so it is discovered by the
    existing CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`)
    without changing or narrowing that path.
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'

    . (Join-Path $script:ScriptsDir 'Render.ps1')
    . (Join-Path $script:ScriptsDir 'Rbac.ps1')
    . (Join-Path $script:ScriptsDir 'Validate-AndFix.ps1')

    $script:VmA = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-a'
    $script:VmB = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-b'
    $script:Principal = '11111111-2222-3333-4444-555555555555'

    # ── Test seams for Invoke-ValidateAndFix ────────────────────────────────
    # State writes are captured in an ordered dictionary so a test can assert
    # *when* a value was persisted relative to an `az chaos` call.
    function Set-StateProperty {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$PropertyPath, [Parameter()]$Value)
        $script:StateWrites[$PropertyPath] = $Value
    }

    function Invoke-AzChaos {
        [CmdletBinding()]
        param(
            [Parameter()][string[]]$ChaosArgs,
            [Parameter()][hashtable]$JsonArg,
            [Parameter()][switch]$AllowFailure
        )
        $verb = ($ChaosArgs -join ' ')
        $script:AzCalls += $verb
        foreach ($rule in $script:AzResponses) {
            if ($verb -like $rule.Match) {
                if ($rule.ContainsKey('Snapshot')) {
                    $script:Snapshots[$rule.Snapshot] = @($script:StateWrites.Keys)
                }
                if ($rule.ContainsKey('Throw')) { throw $rule.Throw }
                if ($rule.ContainsKey('Sequence')) {
                    $i = [Math]::Min($script:SequenceIndex, $rule.Sequence.Count - 1)
                    $script:SequenceIndex++
                    return $rule.Sequence[$i]
                }
                return $rule.Return
            }
        }
        throw "unstubbed az chaos call: $verb"
    }

    function Reset-AzStub {
        $script:AzCalls       = @()
        $script:StateWrites   = [ordered]@{}
        $script:Snapshots     = @{}
        $script:AzResponses   = @()
        $script:SequenceIndex = 0
    }

    function New-ValidationResult {
        param([string]$Status, [object[]]$Errors = @())
        [PSCustomObject]@{ properties = [PSCustomObject]@{ status = $Status; errors = $Errors } }
    }

    function New-FixResult {
        param([int]$Failed = 0)
        [PSCustomObject]@{
            properties = [PSCustomObject]@{
                state      = 'Succeeded'
                whatIfMode = $false
                summary    = [PSCustomObject]@{ totalRequired = 2; succeeded = 2; failed = $Failed; skipped = 0 }
            }
        }
    }

    $script:PermissionError = [PSCustomObject]@{
        errorCode    = 'MissingPermission'
        errorMessage = 'The workspace identity is missing the Virtual Machine Contributor role.'
        resourceId   = $script:VmA
        roleName     = 'Virtual Machine Contributor'
    }
}

Describe 'ConvertTo-ValidationBlocker — normalization' {
    It 'normalizes a permission error from properties.errors' {
        $result   = New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult $result)

        $blockers.Count          | Should -Be 1
        $blockers[0].code        | Should -Be 'MissingPermission'
        $blockers[0].category    | Should -Be 'permission'
        $blockers[0].resourceId  | Should -Be $script:VmA
        $blockers[0].roleName    | Should -Be 'Virtual Machine Contributor'
        $blockers[0].message     | Should -Match 'Virtual Machine Contributor'
    }

    It 'reads the alternate `code`/`message`/`target` field spellings' {
        $result = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                status = 'Failed'
                errors = @([PSCustomObject]@{
                    code    = 'AuthorizationFailed'
                    message = 'Forbidden'
                    target  = $script:VmB
                })
            }
        }
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult $result)
        $blockers[0].code       | Should -Be 'AuthorizationFailed'
        $blockers[0].message    | Should -Be 'Forbidden'
        $blockers[0].resourceId | Should -Be $script:VmB
        $blockers[0].category   | Should -Be 'permission'
    }

    It 'reads `validationErrors` as well as `errors`' {
        $result = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                status           = 'RequiresAttention'
                validationErrors = @([PSCustomObject]@{ errorCode = 'MissingPermission'; resourceId = $script:VmA })
            }
        }
        @(ConvertTo-ValidationBlocker -ValidationResult $result).Count | Should -Be 1
    }

    It 'inherits the resource id from a per-resource error container' {
        $result = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                status    = 'Failed'
                resources = @([PSCustomObject]@{
                    resourceId = $script:VmB
                    errors     = @([PSCustomObject]@{ errorCode = 'AgentNotInstalled'; errorMessage = 'no agent' })
                })
            }
        }
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult $result)
        $blockers[0].resourceId | Should -Be $script:VmB
        $blockers[0].category   | Should -Be 'resource'
    }

    It 'classifies a non-permission, non-resource error as other' {
        $result   = New-ValidationResult -Status 'Failed' -Errors @([PSCustomObject]@{ errorCode = 'InternalError' })
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult $result)
        $blockers[0].category | Should -Be 'other'
    }

    It 'de-duplicates identical blockers reported from two places' {
        $result = [PSCustomObject]@{
            properties = [PSCustomObject]@{
                status           = 'Failed'
                errors           = @($script:PermissionError)
                validationErrors = @($script:PermissionError)
            }
        }
        @(ConvertTo-ValidationBlocker -ValidationResult $result).Count | Should -Be 1
    }

    It 'returns an empty set for a clean validation and for $null' {
        @(ConvertTo-ValidationBlocker -ValidationResult (New-ValidationResult -Status 'Succeeded')).Count | Should -Be 0
        @(ConvertTo-ValidationBlocker -ValidationResult $null).Count | Should -Be 0
    }

    It 'skips error entries that are not objects, exactly as the Python plane does' {
        # `normalize_validation_blockers` in mcp/chaos_mcp/server.py skips any
        # entry that is not a dict. A bare string carries no code, message or
        # resource id, so emitting a code='Unknown' blocker for it here would
        # make the two planes disagree on the blocker count for one payload.
        $result = New-ValidationResult -Status 'Failed' -Errors @('a bare string', 42)
        @(ConvertTo-ValidationBlocker -ValidationResult $result).Count | Should -Be 0

        # A structured entry alongside an unstructured one still normalizes.
        $mixed = New-ValidationResult -Status 'Failed' -Errors @('a bare string', $script:PermissionError)
        @(ConvertTo-ValidationBlocker -ValidationResult $mixed).Count | Should -Be 1
    }

    It 'accepts hashtable and PSCustomObject error entries alike' {
        $asHashtable = New-ValidationResult -Status 'Failed' -Errors @(@{ errorCode = 'MissingPermission'; resourceId = $script:VmA })
        @(ConvertTo-ValidationBlocker -ValidationResult $asHashtable).Count | Should -Be 1
    }
}

Describe 'Build-TargetedGrantProposal — exact grants before the broad fix' {
    It 'builds one az command per distinct permission blocker' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)))
        $proposal = @(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $script:Principal)

        $proposal.Count            | Should -Be 1
        $proposal[0].resourceId    | Should -Be $script:VmA
        $proposal[0].roleName      | Should -Be 'Virtual Machine Contributor'
        $proposal[0].command       | Should -Match 'az role assignment create'
        $proposal[0].command       | Should -Match ([regex]::Escape($script:Principal))
        $proposal[0].command       | Should -Match ([regex]::Escape($script:VmA))
    }

    It 'scopes each grant to the blocked resource, never to the subscription' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)))
        $proposal = @(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $script:Principal)
        $proposal[0].command | Should -Not -Match '--scope "/subscriptions/s1"'
    }

    It 'defaults to Reader when the service did not name a role' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @(
                [PSCustomObject]@{ errorCode = 'MissingPermission'; resourceId = $script:VmA })))
        (@(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $script:Principal))[0].roleName |
            Should -Be 'Reader'
    }

    It 'skips non-permission blockers — no grant can fix a missing agent' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @(
                [PSCustomObject]@{ errorCode = 'AgentNotInstalled'; resourceId = $script:VmA })))
        @(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $script:Principal).Count | Should -Be 0
    }

    It 'skips permission blockers with no resource id — the scope is unknown' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @([PSCustomObject]@{ errorCode = 'MissingPermission' })))
        @(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $script:Principal).Count | Should -Be 0
    }

    It 'emits a visible placeholder rather than an empty --assignee when the principal is unknown' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)))
        (@(Build-TargetedGrantProposal -Blockers $blockers))[0].command | Should -Match '<'
    }

    It 'de-duplicates two blockers that resolve to the same grant' {
        $blockers = @(ConvertTo-ValidationBlocker -ValidationResult (
            New-ValidationResult -Status 'Failed' -Errors @(
                [PSCustomObject]@{ errorCode = 'MissingPermission'; resourceId = $script:VmA; roleName = 'Reader' },
                [PSCustomObject]@{ errorCode = 'AuthorizationFailed'; resourceId = $script:VmA; roleName = 'Reader' })))
        @(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $script:Principal).Count | Should -Be 1
    }

    It 'returns nothing for an empty blocker set' {
        @(Build-TargetedGrantProposal -Blockers @() -PrincipalId $script:Principal).Count | Should -Be 0
    }
}

Describe 'Invoke-ValidateAndFix — consent gate around the broad fix' {
    BeforeEach {
        Reset-AzStub
        Remove-Item Env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item Env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -ErrorAction SilentlyContinue
    }

    It 'validates and returns without touching permissions when validation succeeds' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Return = (New-ValidationResult -Status 'Succeeded') }
        )
        Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
            -StateBasePath 'setup.configuration' | Out-Null

        $script:AzCalls | Should -Not -Contain 'scenario config fix-permissions --resource-group rg --workspace-name ws --scenario-name sc --name cfg'
        $script:StateWrites['setup.configuration.validation.lastResult'] | Should -Be 'Succeeded'
    }

    It 'refuses to run the broad fix without consent and says so' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Return = (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)) }
        )
        {
            Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
                -StateBasePath 'setup.configuration'
        } | Should -Throw -ExpectedMessage 'broadPermissionFixConsentRequired*'

        ($script:AzCalls -join ' ') | Should -Not -Match 'fix-permissions'
        $script:StateWrites['setup.configuration.validation.permissionFix.consent'] | Should -Be 'required'
    }

    It 'persists the normalized blockers and the targeted proposal even when it stops' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Return = (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)) }
        )
        try {
            Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
                -StateBasePath 'setup.configuration' -PrincipalId $script:Principal
        } catch { }

        @($script:StateWrites['setup.configuration.validation.blockers']).Count       | Should -Be 1
        @($script:StateWrites['setup.configuration.validation.targetedGrants']).Count | Should -Be 1
    }

    It 'runs the broad fix once consent is given by switch' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Sequence = @(
                (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)),
                (New-ValidationResult -Status 'Succeeded')) }
            @{ Match = 'scenario config fix-permissions*'; Return = (New-FixResult); Snapshot = 'atFix' }
        )
        Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
            -StateBasePath 'setup.configuration' -PrincipalId $script:Principal `
            -ConsentToBroadPermissionFix | Out-Null

        ($script:AzCalls -join ' ') | Should -Match 'fix-permissions'
        $script:StateWrites['setup.configuration.validation.permissionFix.consent'] | Should -Be 'granted'
        $script:StateWrites['setup.configuration.validation.lastResult']            | Should -Be 'Succeeded'
    }

    It 'accepts consent from STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX=1' {
        $env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = '1'
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Sequence = @(
                (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)),
                (New-ValidationResult -Status 'Succeeded')) }
            @{ Match = 'scenario config fix-permissions*'; Return = (New-FixResult) }
        )
        Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
            -StateBasePath 'setup.configuration' | Out-Null

        ($script:AzCalls -join ' ') | Should -Match 'fix-permissions'
    }

    It 'treats any value other than 1 as no consent' {
        $env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = 'maybe'
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Return = (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)) }
        )
        {
            Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
                -StateBasePath 'setup.configuration'
        } | Should -Throw -ExpectedMessage 'broadPermissionFixConsentRequired*'
    }

    It 'offers the targeted grants BEFORE it calls fix-permissions (targeted-first)' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Sequence = @(
                (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)),
                (New-ValidationResult -Status 'Succeeded')) }
            @{ Match = 'scenario config fix-permissions*'; Return = (New-FixResult); Snapshot = 'atFix' }
        )
        $out = Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
            -StateBasePath 'setup.configuration' -PrincipalId $script:Principal `
            -ConsentToBroadPermissionFix

        # The proposal was already persisted at the moment the broad fix ran.
        $script:Snapshots['atFix'] | Should -Contain 'setup.configuration.validation.targetedGrants'

        $text     = ($out -join "`n")
        $targeted = $text.IndexOf('az role assignment create')
        $broad    = $text.IndexOf('fix-permissions')
        $targeted | Should -BeGreaterThan -1
        $broad    | Should -BeGreaterThan -1
        $targeted | Should -BeLessThan $broad
    }

    It 'renders the normalized blockers rather than the raw payload' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Return = (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)) }
        )
        # `& { }` keeps everything written to the success stream before the throw.
        $out = & {
            try {
                Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
                    -StateBasePath 'setup.configuration' -PrincipalId $script:Principal
            } catch { }
        }
        $text = ($out -join "`n")

        $text | Should -Match 'MissingPermission'
        $text | Should -Match 'permission'
        $text | Should -Match ([regex]::Escape($script:VmA))
        $script:StateWrites['setup.configuration.validation.blockers'][0].category | Should -Be 'permission'
    }

    It 'describes the breadth of the broad fix in the consent prompt' {
        $script:AzResponses = @(
            @{ Match = 'scenario config validate*'; Return = (New-ValidationResult -Status 'Failed' -Errors @($script:PermissionError)) }
        )
        $err = $null
        try {
            Invoke-ValidateAndFix -ResourceGroup rg -WorkspaceName ws -ScenarioName sc -ConfigName cfg `
                -StateBasePath 'setup.configuration'
        } catch { $err = $_.Exception.Message }

        $err | Should -Match 'broadPermissionFixConsentRequired'
        $script:StateWrites['setup.configuration.validation.permissionFix.consentPrompt'] | Should -Match 'every target resource'
    }
}

Describe 'Consent is documented on both MCP-capable skills (E3-T3)' {
    It 'setup-scenario documents the consent gate and exit code 4' {
        $md = Get-Content (Join-Path $script:PluginRoot 'skills' 'setup-scenario' 'SKILL.md') -Raw
        $md | Should -Match 'chaos_fix_resource_permissions'
        $md | Should -Match '(?i)consent'
        $md | Should -Match 'STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX'
        $md | Should -Match '\| \*\*4\*\* \|'
    }

    It 'run-scenario documents the consent gate' {
        $md = Get-Content (Join-Path $script:PluginRoot 'skills' 'run-scenario' 'SKILL.md') -Raw
        $md | Should -Match '(?i)consent'
        $md | Should -Match 'STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX'
    }

    It 'both skills require the targeted grants to be offered first' {
        foreach ($skill in @('setup-scenario', 'run-scenario')) {
            $md = Get-Content (Join-Path $script:PluginRoot 'skills' $skill 'SKILL.md') -Raw
            $md | Should -Match 'az role assignment create'
        }
    }
}

Describe 'blast-radius reference contract (E3-T4)' {
    BeforeAll {
        $script:BlastRadiusMd = Join-Path $script:PluginRoot 'references' 'chaos' 'blast-radius.md'
    }

    It 'ships alongside the other chaos reference contracts' {
        Test-Path $script:BlastRadiusMd | Should -BeTrue
    }

    It 'documents the include/exclude precedence rule' {
        $md = Get-Content $script:BlastRadiusMd -Raw
        $md | Should -Match 'resourceTargeting'
        $md | Should -Match '(?i)exclude .*(wins|precedence)'
    }

    It 'documents leg starvation (CS-7) and the configuration-scoped validation limit (CS-6)' {
        $md = Get-Content $script:BlastRadiusMd -Raw
        $md | Should -Match 'CS-7'
        $md | Should -Match 'CS-6'
        $md | Should -Match '(?i)starv'
    }

    It 'documents the breadth of fixResourcePermissions' {
        $md = Get-Content $script:BlastRadiusMd -Raw
        $md | Should -Match 'fixResourcePermissions'
        $md | Should -Match 'STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX'
    }

    It 'documents that the MCP plane leaves the principal to be substituted' {
        # `chaos_validate_scenario_configuration` has no workspace identity in
        # hand, so its proposal always carries the placeholder — the contract
        # must not claim those commands are runnable as printed.
        $md = Get-Content $script:BlastRadiusMd -Raw
        $md | Should -Match 'workspace-identity-principal-id'
        $md | Should -Match '(?i)substitute'
    }
}
