<#
.SYNOPSIS
    Pester 5 behavioural test for the run-scenario pre-execute gate (E3-T2/T5).

.DESCRIPTION
    The pre-execute gate always validates, and when validation reports permission
    blockers it offers the exact, minimum-scope `az role assignment create`
    commands before the broad `fix-permissions` mutation. Those commands are only
    useful if they carry the workspace identity's object ID: with the principal
    missing they render the literal `<workspace-identity-principal-id>`
    placeholder and the "minimum-scope alternative" is copy-paste-broken.

    `Invoke-RunScenario.ps1` is run for real in a child pwsh against a staged
    temp tree (the same pattern as `SetupExitContract.Tests.ps1`): the entry
    script, `Render.ps1`, `Rbac.ps1` and `Validate-AndFix.ps1` are genuine, and
    only `State.ps1` and `Invoke-AzChaos.ps1` are stubbed. Validation reports a
    permission blocker and no consent is given, so the run stops at the gate
    without executing anything.

    Lives under `skills/run-scenario/tests/` so it is discovered by the existing
    CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`) without
    changing or narrowing that path.
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:SharedDir  = Join-Path $script:PluginRoot 'scripts'
    $script:EntrySrc   = Join-Path $script:PluginRoot 'skills' 'run-scenario' 'scripts' 'Invoke-RunScenario.ps1'

    $script:VmA         = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-a'
    $script:PrincipalId = '99999999-8888-7777-6666-555555555555'

    $script:OriginalConsent = $env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX
    Remove-Item env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -ErrorAction SilentlyContinue

    $script:HarnessRoot = Join-Path ([System.IO.Path]::GetTempPath()) "run-gate-$([guid]::NewGuid())"
    $root    = $script:HarnessRoot
    $scripts = Join-Path $root 'skills/run-scenario/scripts'
    $shared  = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Path $scripts, $shared -Force | Out-Null

    $stateFile = Join-Path $root 'state.json'
    $callLog   = Join-Path $root 'calls.log'

    Copy-Item $script:EntrySrc (Join-Path $scripts 'Invoke-RunScenario.ps1')
    foreach ($f in 'Render.ps1', 'Rbac.ps1', 'Validate-AndFix.ps1') {
        Copy-Item (Join-Path $script:SharedDir $f) (Join-Path $shared $f)
    }
    # Not reached: the gate stops the run before execution/reporting.
    Set-Content -LiteralPath (Join-Path $shared 'Invoke-AzRest.ps1') -Value '' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $shared 'New-RunReport.ps1') -Value '' -Encoding utf8

    $stateStub = @'
function Read-State { Get-Content -Raw -LiteralPath '__STATE__' | ConvertFrom-Json }
function Save-State { param($State) }
function Set-StateProperty {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PropertyPath, [Parameter()]$Value)
}
'@
    Set-Content -LiteralPath (Join-Path $shared 'State.ps1') -Encoding utf8 `
        -Value $stateStub.Replace('__STATE__', $stateFile)

    $azStub = @'
function Initialize-ChaosExtension { }
function Invoke-AzChaos {
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$ChaosArgs,
        [Parameter()][hashtable]$JsonArg,
        [Parameter()][switch]$AllowFailure
    )
    $verb = ($ChaosArgs -join ' ')
    Add-Content -LiteralPath '__CALLS__' -Value $verb
    if ($verb -like 'scenario config validate*') {
        return [pscustomobject]@{
            properties = [pscustomobject]@{
                status = 'Failed'
                errors = @(
                    [pscustomobject]@{
                        errorCode    = 'MissingPermission'
                        errorMessage = 'The workspace identity is not authorized on this resource.'
                        resourceId   = '__VM__'
                        roleName     = 'Chaos Studio Target Contributor'
                    }
                )
            }
        }
    }
    throw "unstubbed az chaos call: $verb"
}
'@
    Set-Content -LiteralPath (Join-Path $shared 'Invoke-AzChaos.ps1') -Encoding utf8 `
        -Value $azStub.Replace('__CALLS__', $callLog).Replace('__VM__', $script:VmA)

    $state = @{
        context   = @{ subscriptionId = 's1'; resourceGroup = 'rg1' }
        workspace = @{
            status   = 'done'
            name     = 'ws1'
            scopes   = @('/subscriptions/s1/resourceGroups/rg1')
            identity = @{ principalId = $script:PrincipalId }
        }
        setup     = @{
            status             = 'done'
            selectedScenarioId = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Chaos/workspaces/ws1/scenarios/ZoneDown-1.0'
            configuration      = @{ name = 'config-1'; parameters = @() }
        }
        run       = @{ status = 'pending' }
    }
    ($state | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $stateFile -Encoding utf8

    $entry = Join-Path $scripts 'Invoke-RunScenario.ps1'
    $out = & pwsh -NoProfile -NonInteractive -Command "& '$entry'; exit `$LASTEXITCODE" 2>&1
    $script:GateExit   = $LASTEXITCODE
    $script:GateOutput = ($out | ForEach-Object { "$_" }) -join "`n"
    $script:GateCalls  = if (Test-Path $callLog) { @(Get-Content $callLog) } else { @() }
}

AfterAll {
    # Repeated local runs would otherwise accumulate staged trees under TEMP.
    if ($script:HarnessRoot -and (Test-Path $script:HarnessRoot)) {
        Remove-Item -LiteralPath $script:HarnessRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:OriginalConsent) {
        $env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = $script:OriginalConsent
    } else {
        Remove-Item env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-RunScenario — pre-execute gate offers runnable targeted grants' {
    It 'stops at the gate instead of executing' {
        $script:GateExit | Should -Be 1
        @($script:GateCalls | Where-Object { $_ -like 'scenario run start*' }) | Should -BeNullOrEmpty
    }

    It 'never runs the broad fix without consent' {
        @($script:GateCalls | Where-Object { $_ -like '*fix-permissions*' }) | Should -BeNullOrEmpty
        $script:GateOutput | Should -Match 'broadPermissionFixConsentRequired|Consent Required'
    }

    It 'renders the targeted grant with the workspace identity, not the placeholder' {
        $script:GateOutput | Should -Match 'az role assignment create'
        $script:GateOutput | Should -Match ([regex]::Escape($script:PrincipalId))
        $script:GateOutput | Should -Not -Match 'workspace-identity-principal-id'
    }

    It 'scopes that grant to the blocked resource only' {
        $script:GateOutput | Should -Match ([regex]::Escape("--scope `"$($script:VmA)`""))
    }
}
