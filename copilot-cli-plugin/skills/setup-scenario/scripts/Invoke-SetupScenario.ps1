<#
.SYNOPSIS
    Step driver for the setup-scenario skill.
.DESCRIPTION
    Discovers recommended scenarios, presents them to the user, builds a
    ScenarioConfiguration, validates it, and auto-fixes permissions if needed.
    
    Follows 5 fixed sub-steps: refresh → evaluate → list → configure → validate.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$ParameterMode,                 # 'manual' or 'autofill' — if omitted, script pauses for orchestrator to prompt
    [Parameter()][string]$ScenarioName,                 # e.g. 'EntraOutage-1.0' — bypasses prompt
    [Parameter()][hashtable]$ParameterValues = @{}      # key-value overrides applied on top of defaults (e.g. @{ duration = 'PT5M' })
)

$sharedDir = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) 'scripts'
. (Join-Path $sharedDir 'State.ps1')
. (Join-Path $sharedDir 'Render.ps1')
. (Join-Path $sharedDir 'Invoke-AzChaos.ps1')
. (Join-Path $sharedDir 'Validate-AndFix.ps1')

$state = Read-State

# Short-circuit
if ($state.setup.status -eq 'done') {
    Write-Card -Title 'Setup' -Status '✅ Already complete' -Properties ([ordered]@{
        'Scenario'      = $state.setup.selectedScenarioId
        'Configuration' = $state.setup.configuration.id
    })
    exit 0
}

if ($state.workspace.status -ne 'done') {
    Write-Error-Card -Title 'Workspace Required' -ErrorMessage 'Workspace must be created first.'
    exit 1
}

$rg = $state.context.resourceGroup
$wsName = $state.workspace.name

Set-StateProperty -PropertyPath 'setup.status' -Value 'in_progress'

try {
    # ── Step 1: Evaluate the workspace (discover + recommend) ──
    # `az chaos workspace refresh-recommendation` triggers resource discovery
    # and scenario evaluation and polls the LRO to completion — replacing the
    # manual evaluations/latest check + refreshRecommendations POST + poll loop.
    Write-Card -Title 'Refreshing Recommendations' -Status '🔄' `
        -Body 'Discovering in-scope resources and evaluating which scenarios apply...'

    Invoke-AzChaos -ChaosArgs @('workspace', 'refresh-recommendation', '--resource-group', $rg, '--workspace-name', $wsName) | Out-Null

    # ── Step 2: Report the evaluation summary (best-effort) ──
    $eval = Invoke-AzChaos -ChaosArgs @('workspace', 'show-evaluation', '--resource-group', $rg, '--workspace-name', $wsName) -AllowFailure
    if ($eval) {
        $evalStatus = $eval.properties.status
        Set-StateProperty -PropertyPath 'setup.evaluation.status' -Value $evalStatus
        Set-StateProperty -PropertyPath 'setup.evaluation.lastPolledAt' -Value (Get-Date).ToUniversalTime().ToString('o')
        Write-Card -Title 'Evaluation Complete' -Status "✅ $evalStatus" -Properties ([ordered]@{
            'Scenarios Evaluated' = $eval.properties.numScenariosToEvaluate
            'Succeeded'           = $eval.properties.numScenariosEvaluatedSucceeded
            'Failed'              = $eval.properties.numScenariosEvaluatedFailed
        })
    }

    # ── Step 3: List & filter scenarios ─────────────────
    # `az chaos scenario list` returns a bare JSON array of scenario resources.
    $allScenarios = @(Invoke-AzChaos -ChaosArgs @('scenario', 'list', '--resource-group', $rg, '--workspace-name', $wsName))

    $recommended = @($allScenarios | Where-Object {
        $_.properties.recommendation.recommendationStatus -eq 'Recommended'
    })

    if ($recommended.Count -eq 0) {
        Write-Card -Title 'No Recommended Scenarios' -Status '⚠️' `
            -Body 'No scenarios are recommended for your workspace scope. This typically means no applicable resources were discovered. Try broadening your workspace scope or adding more resources.'
        Set-StateProperty -PropertyPath 'setup.status' -Value 'done'
        Set-StateProperty -PropertyPath 'setup.note' -Value 'no-recommendations'
        exit 0
    }

    # Render the list
    $scenarioTable = @()
    for ($i = 0; $i -lt $recommended.Count; $i++) {
        $s = $recommended[$i]
        $scenarioTable += [ordered]@{
            '#'           = $i + 1
            'Name'        = $s.name
            'Description' = if ($s.properties.description.Length -gt 80) { $s.properties.description.Substring(0,77) + '...' } else { $s.properties.description }
            'Version'     = $s.properties.version
        }
    }
    Write-Table -Data $scenarioTable -Title "Recommended Scenarios ($($recommended.Count))"

    Set-StateProperty -PropertyPath 'setup.recommendedScenarios' -Value @($recommended | ForEach-Object {
        @{ id = $_.id; name = $_.name; description = $_.properties.description }
    })

    # ── Scenario selection ──────────────────────────────
    # Priority: -ScenarioName arg > $env:STARTCHAOS_SCENARIO > auto (only if 1 recommended) > pause-for-user
    $resolvedName = $ScenarioName
    if (-not $resolvedName -and $env:STARTCHAOS_SCENARIO) {
        $resolvedName = $env:STARTCHAOS_SCENARIO
    }

    $selectedScenario = $null
    if ($resolvedName) {
        $selectedScenario = $recommended | Where-Object { $_.name -eq $resolvedName } | Select-Object -First 1
        if (-not $selectedScenario) {
            throw "Requested scenario '$resolvedName' is not in the recommended list. Available: $(($recommended | ForEach-Object { $_.name }) -join ', ')"
        }
    } elseif ($recommended.Count -eq 1) {
        $selectedScenario = $recommended[0]
        Write-Card -Title 'Auto-selected' -Body "Only one recommended scenario: $($selectedScenario.name)"
    } else {
        # Multiple recommended and no explicit choice → pause for orchestrator to prompt user
        Set-StateProperty -PropertyPath 'setup.awaitingSelection' -Value $true
        Set-StateProperty -PropertyPath 'setup.status' -Value 'awaiting_input'
        Write-Card -Title 'Scenario Selection Required' -Status '⏸️' -Body @"
Multiple scenarios are recommended for your workspace scope.
Please choose one and re-invoke this skill with ``-ScenarioName <name>`` (or set ``$env:STARTCHAOS_SCENARIO``).

Available: $(($recommended | ForEach-Object { $_.name }) -join ', ')
"@
        exit 2
    }

    Set-StateProperty -PropertyPath 'setup.selectedScenarioId' -Value $selectedScenario.id
    Set-StateProperty -PropertyPath 'setup.awaitingSelection' -Value $false

    Write-Card -Title 'Selected Scenario' -Status '✅' -Properties ([ordered]@{
        'Name'        = $selectedScenario.name
        'Description' = $selectedScenario.properties.description
        'Version'     = $selectedScenario.properties.version
    })

    # ── Step 4: Build parameters ────────────────────────
    $scenarioParams = @($selectedScenario.properties.parameters)
    $configParams = @()

    if ($scenarioParams.Count -gt 0) {
        Write-Table -Data ($scenarioParams | ForEach-Object {
            [ordered]@{
                'Name'     = $_.name
                'Type'     = $_.type
                'Required' = $_.required
                'Default'  = $_.default
                'Description' = $_.description
            }
        }) -Title 'Scenario Parameters'
    }

    # If ParameterMode was not provided and there are parameters, pause for orchestrator to prompt
    if (-not $ParameterMode -and $scenarioParams.Count -gt 0) {
        Set-StateProperty -PropertyPath 'setup.awaitingParameterMode' -Value $true
        Set-StateProperty -PropertyPath 'setup.status' -Value 'awaiting_input'
        Write-Card -Title 'Parameter Mode Required' -Status '⏸️' -Body @"
The scenario has $($scenarioParams.Count) parameter(s).
Please choose how to fill them and re-invoke this skill with ``-ParameterMode autofill`` or ``-ParameterMode manual``.
"@
        exit 3
    }

    # Default to autofill when there are no parameters (nothing to prompt for)
    if (-not $ParameterMode) { $ParameterMode = 'autofill' }

    foreach ($param in $scenarioParams) {
        $value = $null
        if ($ParameterValues.ContainsKey($param.name)) {
            # Explicit override from caller takes priority
            $value = $ParameterValues[$param.name]
        } elseif ($ParameterMode -eq 'autofill') {
            $value = $param.default
            if (-not $value -and $param.required) {
                # For ARM ID parameters, try workspace scope
                if ($param.type -eq 'string' -and $param.name -match 'resourceId|ResourceId|scope') {
                    $value = $state.workspace.scopes[0]
                }
            }
        }
        # Only add if we have a value
        if ($value) {
            $configParams += @{ key = $param.name; value = "$value" }
        }
    }

    # ── Step 5: Create ScenarioConfiguration ────────────
    $configName = "config-" + [System.Guid]::NewGuid().ToString().Substring(0, 8)
    $scenarioName = $selectedScenario.name

    # `az chaos scenario config create` auto-derives --scenario-id from the
    # workspace + scenario name and polls the create LRO to completion. The
    # parameters array is passed as JSON via a temp file (Invoke-AzChaos
    # -JsonArg) so Windows cmd.exe never mangles the braces/quotes.
    $createCfgArgs = @(
        'scenario', 'config', 'create'
        '--resource-group', $rg
        '--workspace-name', $wsName
        '--scenario-name', $scenarioName
        '--name', $configName
    )

    Write-Card -Title 'Creating Configuration' -Status '🔄' -JsonPreview (@{ scenarioId = $selectedScenario.id; parameters = $configParams })

    if ($configParams.Count -gt 0) {
        # Build the JSON array explicitly so a single parameter is still an array.
        $paramsJson = '[' + (($configParams | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ',') + ']'
        $configObj = Invoke-AzChaos -ChaosArgs $createCfgArgs -JsonArg @{ parameters = $paramsJson }
    } else {
        $configObj = Invoke-AzChaos -ChaosArgs $createCfgArgs
    }

    Set-StateProperty -PropertyPath 'setup.configuration.name' -Value $configName
    Set-StateProperty -PropertyPath 'setup.configuration.id' -Value $configObj.id
    Set-StateProperty -PropertyPath 'setup.configuration.parameters' -Value $configParams

    Write-Card -Title 'Configuration Created' -Status '✅' -Properties ([ordered]@{
        'Name' = $configName
        'ID'   = $configObj.id
    })

    # ── Step 6: Validate + auto-fix permissions ─────────
    # Validation is ALWAYS run; fix-permissions is invoked whenever
    # validation returns anything other than 'Succeeded' or reports validationErrors.
    try {
        Invoke-ValidateAndFix -ResourceGroup $rg -WorkspaceName $wsName -ScenarioName $scenarioName -ConfigName $configName -StateBasePath 'setup.configuration'
    } catch {
        $vfErr = $_.Exception.Message
        Set-StateProperty -PropertyPath 'setup.lastError' -Value $vfErr
        Set-StateProperty -PropertyPath 'setup.status'    -Value 'failed'
        # Error card already rendered by the helper for 403 cases.
        if ($vfErr -notmatch '^fixResourcePermissions 403') {
            Write-Error-Card -Title 'Validation Error' -ErrorMessage $vfErr
        }
        exit 1
    }
    $valStatus = (Read-State).setup.configuration.validation.lastResult

    # ── Step 7: Mark done ───────────────────────────────
    # NOTE: We do not gate setup.status on $valStatus -eq 'Succeeded' — the
    # run-scenario skill enforces the strict pre-execute gate. Setup is "done"
    # as long as configuration was created and validation has been attempted.
    Set-StateProperty -PropertyPath 'setup.status' -Value 'done'

    Write-Card -Title 'SetupScenario Complete' -Status '✅ Done' -Properties ([ordered]@{
        'Scenario'      = $selectedScenario.name
        'Configuration' = $configName
        'Validation'    = $valStatus
    })

    exit 0

} catch {
    $errorMsg = $_.Exception.Message
    Set-StateProperty -PropertyPath 'setup.lastError' -Value $errorMsg
    Set-StateProperty -PropertyPath 'setup.status' -Value 'failed'
    Write-Error-Card -Title 'SetupScenario Error' -ErrorMessage $errorMsg
    exit 1
}
