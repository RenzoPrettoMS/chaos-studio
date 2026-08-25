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
    [Parameter()][hashtable]$ParameterValues = @{},     # key-value overrides applied on top of defaults (e.g. @{ duration = 'PT5M' })
    [Parameter()][hashtable]$ResourceTargeting = @{},   # @{ include = @(<armId>...); exclude = @(<armId>...) } — exclude wins
    [Parameter()][switch]$ConsentToBroadPermissionFix   # explicit consent for the broad fixResourcePermissions mutation
)

$sharedDir = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) 'scripts'
. (Join-Path $sharedDir 'State.ps1')
. (Join-Path $sharedDir 'Render.ps1')
. (Join-Path $sharedDir 'Invoke-AzChaos.ps1')
. (Join-Path $sharedDir 'Rbac.ps1')
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
    # ── Step 1: Ensure the workspace has a current scenario evaluation ──
    # Probe the latest evaluation first and only trigger a (potentially
    # minutes-long) discovery+evaluation refresh when there isn't already a
    # successful one. This mirrors the original behavior and keeps the re-runs
    # after an exit-2/exit-3 prompt fast instead of re-evaluating every round-trip.
    # NOTE: `show-evaluation` / `show-discovery` only accept `--name`/`-n` for the
    # workspace name (no `--workspace-name` alias, unlike the other workspace commands).
    $eval = Invoke-AzChaos -ChaosArgs @('workspace', 'show-evaluation', '--name', $wsName, '--resource-group', $rg) -AllowFailure
    $evalStatus = if ($eval) { $eval.properties.status } else { $null }
    $needsRefresh = (-not $eval) -or ($evalStatus -notin @('Succeeded', 'PartiallySucceeded'))

    if ($needsRefresh) {
        Write-Card -Title 'Refreshing Recommendations' -Status '🔄' `
            -Body 'Discovering in-scope resources and evaluating which scenarios apply...'
        # `refresh-recommendation` triggers discovery + evaluation and polls the
        # LRO to completion (it accepts the `--workspace-name` alias).
        Invoke-AzChaos -ChaosArgs @('workspace', 'refresh-recommendation', '--workspace-name', $wsName, '--resource-group', $rg) | Out-Null
        $eval = Invoke-AzChaos -ChaosArgs @('workspace', 'show-evaluation', '--name', $wsName, '--resource-group', $rg) -AllowFailure
        $evalStatus = if ($eval) { $eval.properties.status } else { $null }
    }

    # ── Step 2: Report the evaluation summary ──
    if ($eval) {
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

    # ── Step 5: Resolve and show the blast radius ───────
    # F8: the affected-resource set and the exclusions that shaped it must be
    # visible BEFORE the first mutation. Candidates come from the service's own
    # recommendation payload, falling back to the workspace scopes. Precedence
    # rules live in `references/chaos/blast-radius.md`.
    #
    # IMPORTANT: `az chaos scenario config create` accepts no target filter, so
    # $ResourceTargeting is NOT transmitted to the service — it feeds this
    # preview and the starvation refusal below only. Write-BlastRadiusCard says
    # so on every rendering; do not soften that wording.
    $candidateResources = @()
    $usedFallback = $false
    $candidateSources = @(
        $selectedScenario.properties.recommendation.resourceIds
        $selectedScenario.properties.recommendation.matchedResources
        $selectedScenario.properties.recommendation.resources
        $selectedScenario.properties.targetResourceIds
    )
    foreach ($source in $candidateSources) {
        foreach ($item in @($source)) {
            if (-not $item) { continue }
            # Entries are either bare ARM ids or objects carrying one.
            $id = if ($item -is [string]) { $item } elseif ($item.resourceId) { $item.resourceId } else { $item.id }
            if ($id) { $candidateResources += "$id" }
        }
    }
    if ($candidateResources.Count -eq 0) {
        $candidateResources = @($state.workspace.scopes)
        $usedFallback = $true
    }

    $blastRadius = Resolve-BlastRadius -Candidate $candidateResources `
        -Include @($ResourceTargeting['include']) -Exclude @($ResourceTargeting['exclude'])

    $radiusNote = if ($usedFallback) {
        'The recommendation did not enumerate resources; falling back to the workspace scopes.'
    } else {
        'Candidates come from the service recommendation for the selected scenario.'
    }
    Write-BlastRadiusCard -BlastRadius $blastRadius -Note $radiusNote

    Set-StateProperty -PropertyPath 'setup.blastRadius' -Value $blastRadius

    # Only block when the caller's own targeting starved the set: an empty
    # candidate set is an upstream scope problem, already reported above.
    # `.ContainsKey` (not `@(...).Count`) because `@($null).Count` is 1 — an
    # absent key would otherwise read as a supplied filter.
    $hasTargeting = $ResourceTargeting.ContainsKey('include') -or $ResourceTargeting.ContainsKey('exclude')
    if ($blastRadius.isStarved -and $hasTargeting) {
        $starveMsg = 'The supplied resourceTargeting left no resources in scope. Refusing to create a configuration that would exercise nothing (CS-7). See references/chaos/blast-radius.md.'
        Set-StateProperty -PropertyPath 'setup.lastError' -Value $starveMsg
        Set-StateProperty -PropertyPath 'setup.status' -Value 'failed'
        Write-Error-Card -Title 'Targeting Starved the Blast Radius' -ErrorMessage $starveMsg
        exit 1
    }

    # ── Step 6: Create ScenarioConfiguration ────────────
    $configName = "config-" + [System.Guid]::NewGuid().ToString().Substring(0, 8)
    $scenarioName = $selectedScenario.name

    # `az chaos scenario config create` auto-derives --scenario-id from the
    # workspace + scenario name and polls the create LRO to completion. The
    # parameters array is passed as JSON via a temp file (Invoke-AzChaos
    # -JsonArg) so Windows cmd.exe never mangles the braces/quotes.
    #
    # There is no include/exclude argument on this command: the configuration
    # the service creates covers the full recommendation set regardless of
    # $ResourceTargeting. That is why the blast-radius card labels itself a
    # prediction — see `references/chaos/blast-radius.md` §2.
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

    # ── Step 7: Validate + consent-gated permission fix ─
    # Validation is ALWAYS run. When it reports blockers, the shared helper
    # normalizes them, offers the exact per-resource grants first, and only
    # runs the broad fixResourcePermissions mutation with explicit consent.
    try {
        Invoke-ValidateAndFix -ResourceGroup $rg -WorkspaceName $wsName -ScenarioName $scenarioName `
            -ConfigName $configName -StateBasePath 'setup.configuration' `
            -PrincipalId $state.workspace.identity.principalId `
            -ConsentToBroadPermissionFix:$ConsentToBroadPermissionFix
    } catch {
        $vfErr = $_.Exception.Message
        Set-StateProperty -PropertyPath 'setup.lastError' -Value $vfErr
        if ($vfErr -match '^broadPermissionFixConsentRequired') {
            # Not a failure: the configuration exists and the blockers are
            # recorded. Pause for the orchestrator to obtain consent.
            Set-StateProperty -PropertyPath 'setup.status' -Value 'awaiting_input'
            exit 4
        }
        Set-StateProperty -PropertyPath 'setup.status'    -Value 'failed'
        # Error card already rendered by the helper for 403 cases.
        if ($vfErr -notmatch '^fixResourcePermissions 403') {
            Write-Error-Card -Title 'Validation Error' -ErrorMessage $vfErr
        }
        exit 1
    }
    $valStatus = (Read-State).setup.configuration.validation.lastResult

    # ── Step 8: Mark done ───────────────────────────────
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
