#Requires -Version 7.0
<#
.SYNOPSIS
    Turn a reliability question into a frozen, executable study plan.

.DESCRIPTION
    Scoping is the step that decides whether a study is worth running, and it
    does that before anything is injected. Three questions in order:

      1. What can the platform actually do here?
         The action list is read live from Chaos Studio for the target's
         region. This suite ships no catalogue of faults and never falls back
         to one - if discovery fails, scoping stops.

      2. Can the chosen action reach this resource?
         Advertised is not the same as deliverable. The Chaos Studio target
         and the capability behind the action are probed on the resource.

      3. Would the result mean anything?
         A study with no numeric objective, no signal, or an action whose
         schema is unsatisfied produces a document, not evidence.

    Only when all three hold is a plan written, and the plan is hashed so the
    consent given later provably refers to it.

    Nothing here injects anything.

.EXAMPLE
    ./Invoke-ChaosStudyScope.ps1 -SubscriptionId <sub> -ResourceGroup rg -ResourceName svc -ListActions

.EXAMPLE
    ./Invoke-ChaosStudyScope.ps1 -SubscriptionId <sub> -ResourceGroup rg `
        -ResourceName svc -ResourceType 'Microsoft.Compute/virtualMachines' `
        -Action 'urn:csci:microsoft:virtualMachine:shutdown/1.0.0' `
        -SteadyState 'successRate >= 99.5' -SignalSource 'metrics:Availability'
#>

[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ResourceName,

    # The ARM type of the resource under study, e.g.
    # 'Microsoft.Compute/virtualMachines'. Used to build the resource id and to
    # narrow the live action list.
    [string]$ResourceType,

    # Azure region. Resolved from the target resource when omitted; the actions
    # list is region-scoped, so this has to be right.
    [string]$Region,

    # Print the actions Chaos Studio reports for this region and target type,
    # then exit without planning.
    [Parameter(ParameterSetName = 'List')][switch]$ListActions,

    # The action to study: its name, canonical URN, or display name, as
    # returned by -ListActions. Matched against the live list.
    [Parameter(ParameterSetName = 'Plan', Mandatory)][string]$Action,

    # The numeric objective this study tries to break, e.g. 'successRate >= 99.5'.
    [Parameter(ParameterSetName = 'Plan', Mandatory)][string]$SteadyState,

    [ValidateRange(1, 240)][int]$DurationMinutes = 10,
    [ValidateRange(0, 240)][int]$BaselineMinutes = 5,
    [ValidateRange(0, 240)][int]$RecoveryMinutes = 10,

    # Action parameters, keyed by the names in the action's live schema.
    [hashtable]$Parameters,

    [string]$Hypothesis,

    # Signal sources: 'metrics:<name>' or 'logs:<workspaceId>#<kql>'.
    [string[]]$SignalSource = @(),

    [string]$StudyRoot,

    # Plan without probing Azure. The plan carries limitation L10 and is not
    # evidence that the study can run.
    [switch]$SkipDiscovery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'Study.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ActionDiscovery.ps1')
. (Join-Path $PSScriptRoot 'lib' 'TargetPath.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Readiness.ps1')

$ChaosStudyPlanVersion = 'study-plan.v1'

# -- Steady state ----------------------------------------------------------

function ConvertFrom-ChaosSteadyState {
    <#
    .SYNOPSIS
        Parse 'signal <op> threshold[unit]' into a structured predicate.

    .DESCRIPTION
        The predicate has to be falsifiable, which in practice means it has to
        be a comparison against a number. Free text like "the service is
        healthy" is rejected here rather than at report time, because a study
        whose objective cannot be violated cannot teach anything.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -notmatch '^\s*([A-Za-z][A-Za-z0-9_.]*)\s*(>=|<=|>|<|==)\s*(-?[0-9]+(?:\.[0-9]+)?)\s*([A-Za-z%/]*)\s*$') {
        throw "Steady state '$Text' is not parseable. Use the form 'signal >= number[unit]', for example 'successRate >= 99.5' or 'p95Latency <= 400ms'."
    }
    return [pscustomobject]@{
        raw        = $Text.Trim()
        signal     = $Matches[1]
        comparison = $Matches[2]
        threshold  = [double]$Matches[3]
        unit       = if ($Matches[4]) { $Matches[4] } else { $null }
    }
}

# -- Resource identity -----------------------------------------------------

function Get-ChaosResourceId {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ResourceName,
        [AllowNull()][AllowEmptyString()][string]$ResourceType
    )
    $base = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
    if ([string]::IsNullOrWhiteSpace($ResourceType)) { return $base }
    return "$base/providers/$($ResourceType.Trim('/'))/$ResourceName"
}

$resourceId = Get-ChaosResourceId -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -ResourceName $ResourceName -ResourceType $ResourceType

# -- Live discovery --------------------------------------------------------
#
# This block is the reason the suite has no bundled fault list. Everything the
# plan says about the fault originates here, in a response the service produced
# moments ago.

$liveActions = @()
$effectiveRegion = $Region

if (-not $SkipDiscovery) {
    Ensure-AzLogin | Out-Null

    if ([string]::IsNullOrWhiteSpace($effectiveRegion)) {
        if ([string]::IsNullOrWhiteSpace($ResourceType)) {
            Assert-ChaosActionDiscovery -Reason 'No region was supplied and none could be resolved, because -ResourceType was not given so the target resource could not be read.' `
                -Remediation 'Pass -Region <region>, or pass -ResourceType so the region can be read from the resource.'
        }
        $effectiveRegion = Resolve-ChaosTargetRegion -ResourceId $resourceId
        if ([string]::IsNullOrWhiteSpace($effectiveRegion)) {
            Assert-ChaosActionDiscovery -Reason "The region of '$resourceId' could not be read from ARM, and the action list is region-scoped." `
                -Remediation 'Confirm the resource exists and the principal has Reader on it, or pass -Region explicitly.'
        }
    }

    try {
        $liveActions = @(Get-ChaosAvailableAction -SubscriptionId $SubscriptionId -Region $effectiveRegion)
    } catch {
        Assert-ChaosActionDiscovery -Reason "Chaos Studio's action list for region '$effectiveRegion' could not be read: $($_.Exception.Message)"
    }

    if ($liveActions.Count -eq 0) {
        Assert-ChaosActionDiscovery -Reason "Chaos Studio reports no actions for region '$effectiveRegion'." `
            -Remediation 'Confirm the subscription is onboarded to Chaos Studio and that the region is one it serves.'
    }
}

# -- -ListActions: show what the service says, then stop -------------------

if ($ListActions) {
    if ($SkipDiscovery) {
        Assert-ChaosActionDiscovery -Reason '-ListActions cannot be combined with -SkipDiscovery: the list has no offline source.' `
            -Remediation 'Drop -SkipDiscovery and re-run.'
    }

    $candidates = @(Select-ChaosActionForTarget -Actions $liveActions -TargetType $ResourceType)

    $heading = if ([string]::IsNullOrWhiteSpace($ResourceType)) {
        "$($liveActions.Count) action(s) available in $effectiveRegion"
    } else {
        "$($candidates.Count) of $($liveActions.Count) action(s) in $effectiveRegion apply to $ResourceType"
    }

    Write-Output "## $heading"
    Write-Output ''
    Write-Output 'Read live from Microsoft.Chaos/locations/{region}/actions. This list is the service''s, not the plugin''s.'
    Write-Output ''

    if ($candidates.Count -eq 0) {
        Write-Output "No action in $effectiveRegion declares support for '$ResourceType'."
        Write-Output 'Re-run without -ResourceType to see every action the region offers.'
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    foreach ($candidate in ($candidates | Sort-Object -Property 'name')) {
        Write-Output "### $($candidate.name)"
        Write-Output ''
        Write-Output "- URN: ``$($candidate.canonicalId)``"
        Write-Output "- Type: $($candidate.actionType)"
        if ($candidate.description) { Write-Output "- $($candidate.description)" }
        Write-Output "- Target types: $(@($candidate.supportedTargetTypes | ForEach-Object { $_.targetType }) -join ', ')"

        $specs = @(Get-ChaosActionParameterSpec -Schema $candidate.parametersSchema)
        if ($specs.Count -gt 0) {
            Write-Output '- Parameters:'
            foreach ($spec in $specs) {
                $flag = if ($spec.required) { 'required' } else { 'optional' }
                $enum = if ($spec.enum.Count -gt 0) { " one of: $($spec.enum -join ', ')" } else { '' }
                Write-Output "  - ``$($spec.name)`` ($($spec.type), $flag)$enum"
            }
        }
        Write-Output ''
    }

    exit (Get-ChaosStudyExitCode -Name 'Success')
}

# -- 1. Resolve the action against the live list --------------------------

$selectedAction = $null

if ($SkipDiscovery) {
    # Offline planning still refuses to invent metadata. The plan records the
    # reference verbatim and carries L10 so nothing downstream mistakes it for
    # a verified action.
    $selectedAction = [pscustomobject]@{
        name                 = $Action
        actionName           = $Action
        canonicalId          = $Action
        actionType           = $null
        displayName          = $Action
        description          = $null
        version              = $null
        parametersSchema     = $null
        recommendedRoles     = @()
        supportedTargetTypes = @()
        discovered           = $false
    }
} else {
    try {
        $selectedAction = Find-ChaosAction -Actions $liveActions -Reference $Action
    } catch {
        Write-ChaosStudyFailure -Title 'Ambiguous action reference' -Message $_.Exception.Message `
            -Remediation './Invoke-ChaosStudyScope.ps1 -ListActions'
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }

    if (-not $selectedAction) {
        $names = @($liveActions | Select-Object -First 8 | ForEach-Object { $_.name }) -join ', '
        Write-ChaosStudyFailure -Title 'Unknown action' `
            -Message "Chaos Studio does not report an action matching '$Action' in region '$effectiveRegion'. This suite plans only what the service advertises, so there is nothing to fall back to.`n`nExamples from the live list: $names" `
            -Remediation './Invoke-ChaosStudyScope.ps1 -ListActions'
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }

    $selectedAction | Add-Member -NotePropertyName 'discovered' -NotePropertyValue $true -Force
}

# -- 2. Parse the objective -----------------------------------------------

try {
    $predicate = ConvertFrom-ChaosSteadyState -Text $SteadyState
} catch {
    Write-ChaosStudyFailure -Title 'Steady state is not parseable' -Message $_.Exception.Message `
        -Remediation "-SteadyState 'successRate >= 99.5'"
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

# -- 3. Can the action be delivered here? ---------------------------------

$deliveryTargetType = $ResourceType
if ($selectedAction.discovered -and @($selectedAction.supportedTargetTypes).Count -gt 0) {
    $supported = @($selectedAction.supportedTargetTypes | ForEach-Object { $_.targetType })
    if ([string]::IsNullOrWhiteSpace($deliveryTargetType) -and $supported.Count -eq 1) {
        $deliveryTargetType = $supported[0]
    }
}

if ($SkipDiscovery) {
    $pathResolution = [pscustomobject]@{
        targetType     = $deliveryTargetType
        targetUri      = $null
        targetVerified = $false
        verdict        = 'unverified'
        probes         = @(New-ChaosProbeResult -Check 'discovery-skipped' -Available $null `
                -Detail 'Discovery was skipped, so neither the live action list nor the Chaos Studio target on this resource was verified.' `
                -Remediation 'Re-run scoping without -SkipDiscovery before trusting this plan.')
        blockingChecks = @()
        unknownChecks  = @('discovery-skipped')
    }
} elseif ([string]::IsNullOrWhiteSpace($deliveryTargetType)) {
    $pathResolution = [pscustomobject]@{
        targetType     = $null
        targetUri      = $null
        targetVerified = $false
        verdict        = 'unverified'
        probes         = @(New-ChaosProbeResult -Check 'target-type-unknown' -Available $null `
                -Detail "Action '$($selectedAction.name)' declares more than one supported target type and none was supplied, so delivery could not be probed." `
                -Remediation 'Pass -ResourceType to name the target type this study should use.')
        blockingChecks = @()
        unknownChecks  = @('target-type-unknown')
    }
} else {
    $pathResolution = Resolve-ChaosDeliveryPath -Action $selectedAction -ResourceId $resourceId -TargetType $deliveryTargetType
    Assert-ChaosDeliveryPathOpen -Resolution $pathResolution
}

# -- 4. Would the result mean anything? -----------------------------------

if ($SkipDiscovery) {
    $offlineGates = @(
        Test-ChaosSteadyStatePredicate -Predicate $predicate
        Test-ChaosInjectionWindow -InjectMinutes $DurationMinutes
        Test-ChaosObservabilityCoverage -AvailableSources $SignalSource -SteadyState $predicate
    )
    $offlineBlocking = @($offlineGates | Where-Object { $_.severity -eq 'blocking' -and $_.status -eq 'fail' })
    $offlineLimitations = @($offlineGates | Where-Object { $_.status -ne 'pass' -and $_.limitationCode } | ForEach-Object { $_.limitationCode })
    $readiness = [pscustomobject]@{
        gates            = $offlineGates
        ready            = ($offlineBlocking.Count -eq 0)
        blockingFailures = $offlineBlocking
        limitationCodes  = @(@($offlineLimitations + @('L10')) | Select-Object -Unique)
    }
} else {
    $readiness = Invoke-ChaosReadinessGates -Action $selectedAction -TargetType $deliveryTargetType `
        -Parameters $Parameters -SteadyState $predicate `
        -InjectMinutes $DurationMinutes -AvailableSources $SignalSource
}
Assert-ChaosReadiness -Readiness $readiness

# -- 5. Freeze the plan ---------------------------------------------------

$scopeHash = Get-ChaosScopeHash -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -ResourceName $ResourceName -ResourceType $ResourceType -Region $effectiveRegion

$actionParameters = if ($Parameters) { $Parameters } else { [ordered]@{} }

$requiredPermissions = @()
foreach ($entry in @($selectedAction.supportedTargetTypes)) {
    if ($entry.targetType -eq $deliveryTargetType) { $requiredPermissions = @($entry.requiredPermissions) }
}

$defaultHypothesis = "Injecting $($selectedAction.displayName) does not breach the steady-state objective, and the system returns to steady state within the recovery window."

$plan = [ordered]@{
    planVersion = $ChaosStudyPlanVersion
    createdAt   = Get-ChaosUtcNow
    scopeHash   = $scopeHash
    question    = [ordered]@{
        hypothesis  = if ($Hypothesis) { $Hypothesis } else { $defaultHypothesis }
        steadyState = $predicate
    }
    target      = [ordered]@{
        subscriptionId = $SubscriptionId
        resourceGroup  = $ResourceGroup
        resourceName   = $ResourceName
        resourceId     = $resourceId
        resourceType   = $ResourceType
        region         = $effectiveRegion
    }
    fault       = [ordered]@{
        # Every field below came from the service's own action record.
        source              = if ($selectedAction.discovered) { 'live-discovery' } else { 'unverified-offline' }
        action              = $selectedAction.name
        faultUrn            = $selectedAction.canonicalId
        displayName         = $selectedAction.displayName
        description         = $selectedAction.description
        actionType          = $selectedAction.actionType
        version             = $selectedAction.version
        targetType          = $deliveryTargetType
        parameters          = $actionParameters
        parametersSchema    = $selectedAction.parametersSchema
        requiredPermissions = $requiredPermissions
        recommendedRoles    = @($selectedAction.recommendedRoles)
    }
    windows     = [ordered]@{
        baselineMinutes = $BaselineMinutes
        injectMinutes   = $DurationMinutes
        recoveryMinutes = $RecoveryMinutes
        interval        = 'half-open [start, end)'
    }
    safety      = [ordered]@{
        reversible      = ($selectedAction.actionType -and $selectedAction.actionType -ine 'Discrete')
        abortConditions = @(
            'The steady-state signal degrades further than the study was authorised to accept.'
            'An unrelated incident opens during the window.'
        )
        requiresConsent = $true
    }
    signals     = [ordered]@{
        configuredSources = @($SignalSource)
    }
    readiness   = [ordered]@{
        gates           = $readiness.gates
        deliveryPath    = $pathResolution
        limitationCodes = @(@($readiness.limitationCodes) + $(if ($pathResolution.verdict -eq 'unverified') { @('L10') } else { @() }) | Select-Object -Unique)
    }
    discovery   = [ordered]@{
        region       = $effectiveRegion
        endpoint     = "/subscriptions/$SubscriptionId/providers/Microsoft.Chaos/locations/$effectiveRegion/actions"
        apiVersion   = Get-ChaosApiVersion -Name 'chaosActions'
        actionsFound = $liveActions.Count
        performedAt  = if ($SkipDiscovery) { $null } else { Get-ChaosUtcNow }
    }
}

# The hash covers everything above it. Anything edited afterwards invalidates
# the consent that will be given against it.
$plan['frozenConfigHash'] = Get-ChaosDigest -InputObject $plan

# -- 6. Persist -----------------------------------------------------------

$study = New-ChaosStudy -ScopeHash $scopeHash -StudyRoot $StudyRoot
Save-ChaosStudyArtifact -StudyPath $study.path -RelativePath 'study-plan.v1.json' -Content $plan | Out-Null
Add-ChaosCommandTrailEntry -StudyPath $study.path -Phase 'scope' `
    -Command 'Invoke-ChaosStudyScope.ps1' `
    -Arguments ([ordered]@{ action = $selectedAction.name; region = $effectiveRegion; skipDiscovery = [bool]$SkipDiscovery }) `
    -ExitCode 0 -Note "Plan frozen at $($plan['frozenConfigHash'])" | Out-Null

# -- 7. Report to the operator --------------------------------------------

$advisories = @($readiness.gates | Where-Object { $_.status -ne 'pass' })
$actionTypeText = if ($selectedAction.actionType) { $selectedAction.actionType } else { 'unknown type' }
$planPath = Resolve-ChaosStudyPath -StudyRoot $study.studyRoot -ScopeHash $scopeHash -StudyId $study.studyId -Artifact 'plan'

$summary = @(
    "Study      $($study.studyId)"
    "Scope      $scopeHash"
    "Action     $($selectedAction.displayName)  [$actionTypeText]"
    "URN        $($selectedAction.canonicalId)"
    "Target     $ResourceName ($(if ($deliveryTargetType) { $deliveryTargetType } else { 'target type not resolved' })) in $effectiveRegion"
    "Objective  $($predicate.raw)"
    "Windows    $BaselineMinutes m baseline, $DurationMinutes m inject, $RecoveryMinutes m recovery"
    "Frozen at  $($plan['frozenConfigHash'])"
    "Plan       $planPath"
) -join "`n"

if (Get-Command Write-Card -ErrorAction SilentlyContinue) {
    Write-Card -Title 'Study planned - nothing has been injected' -Body $summary
} else {
    Write-Output '## Study planned - nothing has been injected'
    Write-Output ''
    Write-Output $summary
}

if ($advisories.Count -gt 0) {
    Write-Output ''
    Write-Output '### Caveats carried into this study'
    foreach ($gate in $advisories) {
        Write-Output "- **$($gate.title)** ($($gate.status)): $($gate.detail)"
    }
}

Write-Output ''
Write-Output 'Next: review the plan, then run it with explicit consent.'
Write-Output "  chaos-study-run  -StudyId $($study.studyId) -DryRun:`$false -Consent '<typed consent>'"

exit (Get-ChaosStudyExitCode -Name 'Success')
