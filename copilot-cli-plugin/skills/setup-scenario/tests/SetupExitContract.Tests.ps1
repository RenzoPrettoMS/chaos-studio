<#
.SYNOPSIS
    Pester 5 behavioural tests for the setup-scenario exit contract (E3-T1/T3/T5).

.DESCRIPTION
    `Invoke-SetupScenario.ps1` is run for real, in a child pwsh, against a staged
    temp tree: the entry script is the genuine one, `Render.ps1`, `Rbac.ps1` and
    `Validate-AndFix.ps1` are the genuine shared scripts, and only `State.ps1`
    and `Invoke-AzChaos.ps1` are replaced by stubs (the same staging pattern
    `skills/chaos-impact/tests/Invoke-ChaosImpact.Tests.ps1` uses for its
    exit-code contract).

    That makes these assertions about *reachability*, not about source text:
      * exit 2 with `setup.awaitingSelection` set, when multiple scenarios are
        recommended and none was chosen;
      * exit 3 with `setup.awaitingParameterMode` set, when the scenario has
        parameters and no `-ParameterMode` was supplied;
      * exit 4 with `setup.status = awaiting_input` and the configuration
        preserved, when the broad permission fix needs consent;
      * exit 1 with no `scenario config create` at all, when caller-supplied
        targeting starved the blast radius (CS-7);
      * the Blast Radius card is emitted strictly before the first mutation (F8);
      * `fix-permissions` runs only once consent is explicit.

    The `0`-`4` block is frozen: these codes are shipped and are never
    reassigned, so any new exit code must be additive.

    The staged `Render.ps1` gets a logging wrapper appended around the genuine
    `Write-BlastRadiusCard` so card emission and `az chaos` calls land in one
    ordered log. The wrapper calls straight through — if the card call in the
    entry script were ever unreachable, nothing would be logged and the ordering
    test would fail rather than pass vacuously.

    Lives under `skills/setup-scenario/tests/` so it is discovered by the
    existing CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`)
    without changing or narrowing that path.
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:SharedDir  = Join-Path $script:PluginRoot 'scripts'
    $script:EntrySrc   = Join-Path $script:PluginRoot 'skills' 'setup-scenario' 'scripts' 'Invoke-SetupScenario.ps1'

    $script:VmA = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-a'
    $script:VmB = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-b'
    $script:PrincipalId = '11111111-2222-3333-4444-555555555555'

    $script:StateStub = @'
function Read-State { Get-Content -Raw -LiteralPath '__STATE__' | ConvertFrom-Json }
function Save-State { param($State) }
function Set-StateProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PropertyPath, [Parameter()]$Value)
    Add-Content -LiteralPath '__WRITES__' -Value ("$PropertyPath=" + ($Value | ConvertTo-Json -Compress -Depth 12))
}
'@

    $script:AzStub = @'
$script:__Seq = @{}
function Initialize-ChaosExtension { }
function Invoke-AzChaos {
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$ChaosArgs,
        [Parameter()][hashtable]$JsonArg,
        [Parameter()][switch]$AllowFailure
    )
    $verb = ($ChaosArgs -join ' ')
    Add-Content -LiteralPath '__ORDER__' -Value "az:$verb"
    $rules = Get-Content -Raw -LiteralPath '__RULES__' | ConvertFrom-Json
    foreach ($rule in @($rules)) {
        if ($verb -like $rule.match) {
            $names = $rule.PSObject.Properties.Name
            if ($names -contains 'throw') { throw $rule.throw }
            if ($names -contains 'sequence') {
                $i = 0
                if ($script:__Seq.ContainsKey($rule.match)) { $i = $script:__Seq[$rule.match] }
                $script:__Seq[$rule.match] = $i + 1
                $items = @($rule.sequence)
                if ($i -ge $items.Count) { $i = $items.Count - 1 }
                return $items[$i]
            }
            return $rule.return
        }
    }
    if ($AllowFailure) { return $null }
    throw "unstubbed az chaos call: $verb"
}
'@

    $script:RenderProbe = @'

# ── Test instrumentation (staged copy only) ─────────────
# Wraps the genuine Write-BlastRadiusCard so card emission is recorded in the
# same ordered log as the `az chaos` calls. Calls straight through.
$script:__RealBlastCard = ${function:Write-BlastRadiusCard}
function Write-BlastRadiusCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$BlastRadius,
        [Parameter()][string]$Title = 'Blast Radius',
        [Parameter()][string]$Note
    )
    Add-Content -LiteralPath '__ORDER__' -Value 'card:blast-radius'
    & $script:__RealBlastCard @PSBoundParameters
}
'@

    # One parent for every staged tree so AfterAll can remove them all; repeated
    # local runs would otherwise accumulate directories under TEMP.
    $script:HarnessParent = Join-Path ([System.IO.Path]::GetTempPath()) "setup-exit-$([guid]::NewGuid())"

    function New-SetupHarness {
        <# Stages the temp tree and returns the paths the tests assert on. #>
        param([Parameter(Mandatory)][object[]]$Rules)

        $root    = Join-Path $script:HarnessParent ([guid]::NewGuid().ToString('N'))
        $scripts = Join-Path $root 'skills/setup-scenario/scripts'
        $shared  = Join-Path $root 'scripts'
        New-Item -ItemType Directory -Path $scripts, $shared -Force | Out-Null

        $stateFile = Join-Path $root 'state.json'
        $writesLog = Join-Path $root 'writes.log'
        $orderLog  = Join-Path $root 'order.log'
        $rulesFile = Join-Path $root 'rules.json'

        Copy-Item $script:EntrySrc (Join-Path $scripts 'Invoke-SetupScenario.ps1')
        foreach ($f in 'Rbac.ps1', 'Validate-AndFix.ps1') {
            Copy-Item (Join-Path $script:SharedDir $f) (Join-Path $shared $f)
        }

        $render = (Get-Content -Raw -LiteralPath (Join-Path $script:SharedDir 'Render.ps1')) +
                  $script:RenderProbe.Replace('__ORDER__', $orderLog)
        Set-Content -LiteralPath (Join-Path $shared 'Render.ps1') -Value $render -Encoding utf8

        Set-Content -LiteralPath (Join-Path $shared 'State.ps1') -Encoding utf8 `
            -Value $script:StateStub.Replace('__STATE__', $stateFile).Replace('__WRITES__', $writesLog)
        Set-Content -LiteralPath (Join-Path $shared 'Invoke-AzChaos.ps1') -Encoding utf8 `
            -Value $script:AzStub.Replace('__ORDER__', $orderLog).Replace('__RULES__', $rulesFile)

        $state = @{
            context   = @{ subscriptionId = 's1'; resourceGroup = 'rg1' }
            workspace = @{
                status   = 'done'
                name     = 'ws1'
                scopes   = @('/subscriptions/s1/resourceGroups/rg1')
                identity = @{ principalId = $script:PrincipalId }
            }
            setup     = @{ status = 'pending' }
        }
        ($state | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $stateFile -Encoding utf8
        ($Rules | ConvertTo-Json -Depth 24 -AsArray) | Set-Content -LiteralPath $rulesFile -Encoding utf8

        [PSCustomObject]@{
            Root      = $root
            Entry     = Join-Path $scripts 'Invoke-SetupScenario.ps1'
            WritesLog = $writesLog
            OrderLog  = $orderLog
        }
    }

    function Invoke-SetupHarness {
        <# Runs the staged entry script in a child pwsh and collects the result. #>
        param(
            [Parameter(Mandatory)][object]$Harness,
            [Parameter()][string]$Arguments = ''
        )
        $cmd = "& '$($Harness.Entry)' $Arguments; exit `$LASTEXITCODE"
        $out = & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1
        $exit = $LASTEXITCODE

        [PSCustomObject]@{
            ExitCode = $exit
            Output   = ($out | ForEach-Object { "$_" }) -join "`n"
            Writes   = if (Test-Path $Harness.WritesLog) { @(Get-Content $Harness.WritesLog) } else { @() }
            Order    = if (Test-Path $Harness.OrderLog)  { @(Get-Content $Harness.OrderLog)  } else { @() }
        }
    }

    function New-ScenarioListResponse {
        param([string[]]$ResourceIds)
        , @(
            @{
                id         = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Chaos/workspaces/ws1/scenarios/ZoneDown-1.0'
                name       = 'ZoneDown-1.0'
                properties = @{
                    description    = 'Take an availability zone down.'
                    version        = '1.0'
                    parameters     = @()
                    recommendation = @{ recommendationStatus = 'Recommended'; resourceIds = $ResourceIds }
                }
            }
        )
    }

    function New-BaseRules {
        param([Parameter(Mandatory)][object]$ValidateRule)
        @(
            @{ match = 'workspace show-evaluation*'; return = @{ properties = @{ status = 'Succeeded'; numScenariosToEvaluate = 1; numScenariosEvaluatedSucceeded = 1; numScenariosEvaluatedFailed = 0 } } }
            @{ match = 'scenario list*'; return = (New-ScenarioListResponse -ResourceIds @($script:VmA, $script:VmB)) }
            @{ match = 'scenario config create*'; return = @{ id = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Chaos/workspaces/ws1/scenarios/ZoneDown-1.0/configurations/config-1' } }
            $ValidateRule
            @{ match = 'scenario config fix-permissions*'; return = @{ properties = @{ state = 'Succeeded'; whatIfMode = $false; summary = @{ totalRequired = 1; succeeded = 1; failed = 0; skipped = 0 } } } }
        )
    }

    $script:PermissionBlockedValidation = @{
        properties = @{
            status = 'Failed'
            errors = @(
                @{
                    errorCode    = 'MissingPermission'
                    errorMessage = 'The workspace identity is not authorized on this resource.'
                    resourceId   = $script:VmA
                    roleName     = 'Chaos Studio Target Contributor'
                }
            )
        }
    }

    # A stray consent variable in the developer's shell must not leak into the
    # child process and turn the broad mutation on.
    $script:OriginalConsent = $env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX
    Remove-Item env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -ErrorAction SilentlyContinue

    # `-ScenarioName` is resolved from $env:STARTCHAOS_SCENARIO when the
    # parameter is absent, so a stray value in the developer's shell would skip
    # the selection pause and make the exit-2 assertion vacuous. Every Describe
    # in this file invokes the entry script without `-ScenarioName`, so the
    # guard is file-scoped like the consent one above.
    $script:OriginalScenarioEnv = $env:STARTCHAOS_SCENARIO
    Remove-Item env:STARTCHAOS_SCENARIO -ErrorAction SilentlyContinue
}

AfterAll {
    if ($script:HarnessParent -and (Test-Path $script:HarnessParent)) {
        Remove-Item -LiteralPath $script:HarnessParent -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:OriginalConsent) {
        $env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = $script:OriginalConsent
    } else {
        Remove-Item env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:OriginalScenarioEnv) {
        $env:STARTCHAOS_SCENARIO = $script:OriginalScenarioEnv
    } else {
        Remove-Item env:STARTCHAOS_SCENARIO -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-SetupScenario — blast radius is rendered before the first mutation (F8)' {
    BeforeAll {
        $rules = New-BaseRules -ValidateRule @{ match = 'scenario config validate*'; return = @{ properties = @{ status = 'Succeeded' } } }
        $script:CleanHarness = New-SetupHarness -Rules $rules
        $script:CleanRun     = Invoke-SetupHarness -Harness $script:CleanHarness
    }

    It 'completes the shipped setup path' {
        $script:CleanRun.ExitCode | Should -Be 0
        $script:CleanRun.Writes   | Should -Contain 'setup.status="done"'
    }

    It 'emits the card at runtime, strictly before `scenario config create`' {
        $order  = $script:CleanRun.Order
        $card   = [array]::IndexOf($order, 'card:blast-radius')
        $create = ($order | Select-String -SimpleMatch 'az:scenario config create' | Select-Object -First 1).LineNumber - 1

        $card   | Should -BeGreaterThan -1
        $create | Should -BeGreaterThan -1
        $card   | Should -BeLessThan $create
    }

    It 'shows the resources the configuration will affect' {
        $script:CleanRun.Output | Should -Match '## Blast Radius'
        $script:CleanRun.Output | Should -Match 'vm-a'
        $script:CleanRun.Output | Should -Match 'vm-b'
    }

    It 'persists the resolved blast radius' {
        ($script:CleanRun.Writes -join "`n") | Should -Match '(?m)^setup\.blastRadius='
    }

    It 'validates before it reports done' {
        $order    = $script:CleanRun.Order
        $validate = ($order | Select-String -SimpleMatch 'az:scenario config validate' | Select-Object -First 1).LineNumber - 1
        $create   = ($order | Select-String -SimpleMatch 'az:scenario config create' | Select-Object -First 1).LineNumber - 1
        $validate | Should -BeGreaterThan $create
    }
}

Describe 'Invoke-SetupScenario — exit 1 when caller targeting starves the blast radius (CS-7)' {
    BeforeAll {
        $rules = New-BaseRules -ValidateRule @{ match = 'scenario config validate*'; return = @{ properties = @{ status = 'Succeeded' } } }
        $harness = New-SetupHarness -Rules $rules
        $targeting = "-ResourceTargeting @{ exclude = @('$($script:VmA)','$($script:VmB)') }"
        $script:StarvedRun = Invoke-SetupHarness -Harness $harness -Arguments $targeting
    }

    It 'exits 1' {
        $script:StarvedRun.ExitCode | Should -Be 1
    }

    It 'refuses to create a configuration that would exercise nothing' {
        @($script:StarvedRun.Order | Where-Object { $_ -like 'az:scenario config create*' }) | Should -BeNullOrEmpty
    }

    It 'records the failure and points at the contract' {
        $script:StarvedRun.Writes | Should -Contain 'setup.status="failed"'
        $script:StarvedRun.Output | Should -Match 'references/chaos/blast-radius.md'
    }
}

Describe 'Invoke-SetupScenario — the shipped 0–4 exit block is frozen' {
    BeforeAll {
        $twoRecommended = @(
            @{
                id         = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Chaos/workspaces/ws1/scenarios/ZoneDown-1.0'
                name       = 'ZoneDown-1.0'
                properties = @{
                    description    = 'Take an availability zone down.'
                    version        = '1.0'
                    parameters     = @()
                    recommendation = @{ recommendationStatus = 'Recommended'; resourceIds = @($script:VmA) }
                }
            }
            @{
                id         = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Chaos/workspaces/ws1/scenarios/CpuPressure-1.0'
                name       = 'CpuPressure-1.0'
                properties = @{
                    description    = 'Apply CPU pressure.'
                    version        = '1.0'
                    parameters     = @()
                    recommendation = @{ recommendationStatus = 'Recommended'; resourceIds = @($script:VmB) }
                }
            }
        )

        $parameterised = @(
            @{
                id         = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Chaos/workspaces/ws1/scenarios/ZoneDown-1.0'
                name       = 'ZoneDown-1.0'
                properties = @{
                    description    = 'Take an availability zone down.'
                    version        = '1.0'
                    parameters     = @(
                        @{ name = 'duration'; type = 'string'; required = $true; default = 'PT5M'; description = 'How long the fault runs.' }
                    )
                    recommendation = @{ recommendationStatus = 'Recommended'; resourceIds = @($script:VmA, $script:VmB) }
                }
            }
        )

        $evalRule = @{ match = 'workspace show-evaluation*'; return = @{ properties = @{ status = 'Succeeded'; numScenariosToEvaluate = 2; numScenariosEvaluatedSucceeded = 2; numScenariosEvaluatedFailed = 0 } } }

        $selectionHarness = New-SetupHarness -Rules @(
            $evalRule
            @{ match = 'scenario list*'; return = $twoRecommended }
        )
        $script:SelectionRun = Invoke-SetupHarness -Harness $selectionHarness

        $paramHarness = New-SetupHarness -Rules @(
            $evalRule
            @{ match = 'scenario list*'; return = $parameterised }
        )
        $script:ParameterModeRun = Invoke-SetupHarness -Harness $paramHarness
    }

    It 'exits 2 when scenario selection is required' {
        $script:SelectionRun.ExitCode | Should -Be 2
    }

    It 'parks in awaiting_input rather than guessing a scenario' {
        $script:SelectionRun.Writes | Should -Contain 'setup.awaitingSelection=true'
        $script:SelectionRun.Writes | Should -Contain 'setup.status="awaiting_input"'
        @($script:SelectionRun.Order | Where-Object { $_ -like 'az:scenario config create*' }) | Should -BeNullOrEmpty
    }

    It 'exits 3 when parameter mode is required' {
        $script:ParameterModeRun.ExitCode | Should -Be 3
    }

    It 'parks in awaiting_input rather than guessing parameter values' {
        $script:ParameterModeRun.Writes | Should -Contain 'setup.awaitingParameterMode=true'
        $script:ParameterModeRun.Writes | Should -Contain 'setup.status="awaiting_input"'
        @($script:ParameterModeRun.Order | Where-Object { $_ -like 'az:scenario config create*' }) | Should -BeNullOrEmpty
    }

    It 'keeps 2 and 3 distinct from each other and from the consent code' {
        $script:SelectionRun.ExitCode     | Should -Not -Be $script:ParameterModeRun.ExitCode
        $script:SelectionRun.ExitCode     | Should -Not -Be 4
        $script:ParameterModeRun.ExitCode | Should -Not -Be 4
    }
}

Describe 'Invoke-SetupScenario — exit 4 when the broad permission fix needs consent' {
    BeforeAll {
        $rules = New-BaseRules -ValidateRule @{ match = 'scenario config validate*'; return = $script:PermissionBlockedValidation }
        $harness = New-SetupHarness -Rules $rules
        $script:ConsentRun = Invoke-SetupHarness -Harness $harness
    }

    It 'exits 4' {
        $script:ConsentRun.ExitCode | Should -Be 4
    }

    It 'parks the skill in awaiting_input rather than failing' {
        $script:ConsentRun.Writes | Should -Contain 'setup.status="awaiting_input"'
        $script:ConsentRun.Writes | Should -Not -Contain 'setup.status="failed"'
    }

    It 'preserves the configuration it already created' {
        ($script:ConsentRun.Writes -join "`n") | Should -Match '(?m)^setup\.configuration\.id="/subscriptions/s1/.*/configurations/config-1"'
        ($script:ConsentRun.Writes -join "`n") | Should -Match '(?m)^setup\.configuration\.name='
    }

    It 'never calls fix-permissions without consent' {
        @($script:ConsentRun.Order | Where-Object { $_ -like '*fix-permissions*' }) | Should -BeNullOrEmpty
    }

    It 'offers targeted grants carrying the real workspace identity, not a placeholder' {
        $script:ConsentRun.Output | Should -Match 'az role assignment create'
        $script:ConsentRun.Output | Should -Match ([regex]::Escape($script:PrincipalId))
        $script:ConsentRun.Output | Should -Not -Match 'workspace-identity-principal-id'
    }

    It 'persists the consent prompt for the orchestrator to render' {
        ($script:ConsentRun.Writes -join "`n") | Should -Match 'setup\.configuration\.validation\.permissionFix\.consent="required"'
        ($script:ConsentRun.Writes -join "`n") | Should -Match 'setup\.configuration\.validation\.permissionFix\.consentPrompt='
    }
}

Describe 'Invoke-SetupScenario — the broad fix runs once consent is explicit' {
    BeforeAll {
        $validateRule = @{
            match    = 'scenario config validate*'
            sequence = @($script:PermissionBlockedValidation, @{ properties = @{ status = 'Succeeded' } })
        }
        $harness = New-SetupHarness -Rules (New-BaseRules -ValidateRule $validateRule)
        $script:ConsentedRun = Invoke-SetupHarness -Harness $harness -Arguments '-ConsentToBroadPermissionFix'
    }

    It 'completes' {
        $script:ConsentedRun.ExitCode | Should -Be 0
    }

    It 'calls fix-permissions and re-validates' {
        @($script:ConsentedRun.Order | Where-Object { $_ -like '*fix-permissions*' }).Count | Should -Be 1
        @($script:ConsentedRun.Order | Where-Object { $_ -like 'az:scenario config validate*' }).Count | Should -Be 2
    }

    It 'still offered the minimum-scope grants first' {
        $order  = $script:ConsentedRun.Order
        $fix    = ($order | Select-String -SimpleMatch 'fix-permissions' | Select-Object -First 1).LineNumber - 1
        $create = ($order | Select-String -SimpleMatch 'az:scenario config create' | Select-Object -First 1).LineNumber - 1
        $fix | Should -BeGreaterThan $create
        $script:ConsentedRun.Output | Should -Match 'Targeted Grants'
        ($script:ConsentedRun.Writes -join "`n") | Should -Match 'setup\.configuration\.validation\.permissionFix\.consent="granted"'
    }
}
