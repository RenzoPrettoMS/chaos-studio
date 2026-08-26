#Requires -Version 7.0
<#
.SYNOPSIS
    Turn a reliability question into a bounded, executable study plan.

.DESCRIPTION
    Scoping is the step that decides whether a study is worth running, and it
    is deliberately the step that can say no. It writes study-plan.v1.json and
    nothing else - no fault is created, no experiment is started, nothing in
    Azure changes.

    The plan it writes is frozen: chaos-study-run refuses to execute a plan
    whose frozenConfigHash no longer matches its contents, so the thing that
    was consented to is provably the thing that runs.

.PARAMETER SteadyState
    The objective, stated numerically before injection - for example
    'successRate >= 99.5' or 'p95Latency <= 400ms'. Without it there is no
    definition of failure, and scoping refuses to continue.

.PARAMETER SkipDiscovery
    Plan without contacting Azure or the cluster. Every discovery-dependent
    gate becomes 'unknown' and its limitation is carried into the plan. Useful
    for drafting; never sufficient for a study you intend to trust.

.EXAMPLE
    ./Invoke-ChaosStudyScope.ps1 -ListFaults

.EXAMPLE
    ./Invoke-ChaosStudyScope.ps1 `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ResourceGroup rg-prod -ClusterName aks-prod `
        -Namespace payments -Selector 'app=api' `
        -Fault aks-chaosmesh-pod -SteadyState 'successRate >= 99.5'
#>

[CmdletBinding(DefaultParameterSetName = 'Scope')]
param(
    [Parameter(ParameterSetName = 'List', Mandatory)][switch]$ListFaults,
    [Parameter(ParameterSetName = 'List')][string]$Vertical = 'kubernetes',

    [Parameter(ParameterSetName = 'Scope', Mandatory)][string]$SubscriptionId,
    [Parameter(ParameterSetName = 'Scope', Mandatory)][string]$ResourceGroup,
    [Parameter(ParameterSetName = 'Scope', Mandatory)][string]$ClusterName,
    [Parameter(ParameterSetName = 'Scope')][string]$Namespace = 'default',
    [Parameter(ParameterSetName = 'Scope')][string]$Selector,
    [Parameter(ParameterSetName = 'Scope', Mandatory)][string]$Fault,
    [Parameter(ParameterSetName = 'Scope')][string]$SteadyState,
    [Parameter(ParameterSetName = 'Scope')][ValidateRange(1, 60)][int]$DurationMinutes = 3,
    [Parameter(ParameterSetName = 'Scope')][ValidateRange(1, 60)][int]$BaselineMinutes = 5,
    [Parameter(ParameterSetName = 'Scope')][ValidateRange(1, 60)][int]$RecoveryMinutes = 5,
    [Parameter(ParameterSetName = 'Scope')][hashtable]$Parameters,
    [Parameter(ParameterSetName = 'Scope')][string]$Hypothesis,
    [Parameter(ParameterSetName = 'Scope')][string[]]$SignalSource = @(),
    [Parameter(ParameterSetName = 'Scope')][string]$StudyRoot,
    [Parameter(ParameterSetName = 'Scope')][string]$ChaosMeshNamespace = 'chaos-testing',
    [Parameter(ParameterSetName = 'Scope')][switch]$SkipDiscovery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'FaultGuide.ps1')
. (Join-Path $PSScriptRoot 'lib' 'FaultPath.ps1')
. (Join-Path $PSScriptRoot 'lib' 'K8sReadiness.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib' 'Study.ps1')

$ChaosStudyPlanVersion = 'study-plan.v1'

function ConvertFrom-ChaosSteadyState {
    <#
    .SYNOPSIS
        Parse 'signal <op> threshold[unit]' into a structured predicate.
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

function Show-ChaosFaultCatalogue {
    param([string]$Vertical)

    $guides = Get-ChaosFaultGuideList -Vertical $Vertical
    $rows = foreach ($guide in $guides) {
        if ($guide.PSObject.Properties.Name -contains 'invalid') {
            [pscustomobject]@{ Fault = $guide.name; Path = 'INVALID'; Proof = '-'; Delivers = $guide.reason }
            continue
        }
        [pscustomobject]@{
            Fault    = $guide.name
            Path     = $guide.faultPath
            Proof    = $guide.dataPlaneProof['coverage']
            Delivers = $guide.displayName
        }
    }

    if (Get-Command Write-Table -ErrorAction SilentlyContinue) {
        Write-Table -Title "Fault guides ($Vertical)" -Data @($rows)
    } else {
        $rows | Format-Table -AutoSize | Out-String | Write-Output
    }

    Write-Output ''
    Write-Output 'Proof column: how well a data-plane signal can prove the fault actually landed.'
    Write-Output '  strong  - a direct signal exists; a clean result is trustworthy'
    Write-Output '  partial - proof is indirect; a clean result may mean the fault missed'
    Write-Output '  weak    - no reliable proof; treat clean results as inconclusive'
    Write-Output ''
    Write-Output "Read the full guide before choosing: copilot-cli-plugin/skills/chaos-study/references/faults/<name>.md"
}

if ($PSCmdlet.ParameterSetName -eq 'List') {
    Show-ChaosFaultCatalogue -Vertical $Vertical
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

# -- 1. Load and validate the fault guide ---------------------------------

try {
    $guide = Find-ChaosFaultGuide -Reference $Fault
} catch {
    Write-ChaosStudyFailure -Title 'Fault guide could not be read' -Message $_.Exception.Message `
        -Remediation './Invoke-ChaosStudyScope.ps1 -ListFaults'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

if (-not $guide) {
    Write-ChaosStudyFailure -Title 'Unknown fault' `
        -Message "No fault guide matches '$Fault'." `
        -Remediation './Invoke-ChaosStudyScope.ps1 -ListFaults'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

# -- 2. Parse the objective -----------------------------------------------

try {
    $predicate = ConvertFrom-ChaosSteadyState -Text $SteadyState
} catch {
    Write-ChaosStudyFailure -Title 'Steady state is not parseable' -Message $_.Exception.Message `
        -Remediation "-SteadyState 'successRate >= 99.5'"
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

# -- 3. Is the fault path open? -------------------------------------------

$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerService/managedClusters/$ClusterName"
$effectiveSelector = if ($Selector) { $Selector } else { $null }

if ($SkipDiscovery) {
    $pathResolution = [pscustomobject]@{
        faultPath      = $guide.faultPath
        verdict        = 'unverified'
        probes         = @(New-ChaosProbeResult -Check 'discovery-skipped' -Available $null `
                -Detail 'Discovery was skipped, so neither the Chaos Studio target nor the in-cluster mechanism was verified.' `
                -Remediation 'Re-run scoping without -SkipDiscovery before trusting this plan.')
        blockingChecks = @()
        unknownChecks  = @('discovery-skipped')
    }
} else {
    Ensure-AzLogin | Out-Null
    $pathResolution = Resolve-ChaosFaultPath -Guide $guide -ResourceId $resourceId `
        -ClusterName $ClusterName -ResourceGroup $ResourceGroup -ChaosMeshNamespace $ChaosMeshNamespace
    Assert-ChaosFaultPathOpen -Resolution $pathResolution
}

# -- 4. Would the result mean anything? -----------------------------------

$labelSelector = if ($effectiveSelector) { $effectiveSelector } else { '' }
if ($SkipDiscovery) {
    $readiness = [pscustomobject]@{
        gates            = @(Test-ChaosSteadyStatePredicate -Predicate $predicate)
        snapshot         = $null
        ready            = ($null -ne $predicate)
        blockingFailures = @(if ($null -eq $predicate) { Test-ChaosSteadyStatePredicate -Predicate $null })
        limitationCodes  = @('L4')
    }
} else {
    $readiness = Invoke-ChaosReadinessGates -Guide $guide -Namespace $Namespace `
        -LabelSelector $labelSelector -SteadyState $predicate -AvailableSources $SignalSource
}
Assert-ChaosReadiness -Readiness $readiness

# -- 5. Freeze the plan ---------------------------------------------------

$scopeHash = Get-ChaosScopeHash -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -ResourceName $ClusterName -ResourceType $guide.resourceType `
    -Namespace $Namespace -Selector $effectiveSelector

$faultParameters = if ($Parameters) { $Parameters } else { $guide.parameters['jsonSpec'] }

$plan = [ordered]@{
    planVersion = $ChaosStudyPlanVersion
    createdAt   = Get-ChaosUtcNow
    scopeHash   = $scopeHash
    question    = [ordered]@{
        hypothesis  = if ($Hypothesis) { $Hypothesis } else { "Injecting $($guide.displayName) does not breach the steady-state objective, and the system returns to steady state within the recovery window." }
        steadyState = $predicate
    }
    target      = [ordered]@{
        subscriptionId = $SubscriptionId
        resourceGroup  = $ResourceGroup
        resourceName   = $ClusterName
        resourceId     = $resourceId
        resourceType   = $guide.resourceType
        namespace      = $Namespace
        selector       = $effectiveSelector
    }
    fault       = [ordered]@{
        guide          = $guide.name
        faultUrn       = $guide.faultUrn
        displayName    = $guide.displayName
        faultPath      = $guide.faultPath
        targetType     = $guide.targetType
        capabilityName = $guide.capabilityName
        parameters     = $faultParameters
    }
    windows     = [ordered]@{
        baselineMinutes = $BaselineMinutes
        injectMinutes   = $DurationMinutes
        recoveryMinutes = $RecoveryMinutes
        interval        = 'half-open [start, end)'
    }
    safety      = [ordered]@{
        blastRadiusControls = $guide.blastRadiusControls
        abortConditions     = $guide.abortConditions
        requiresConsent     = $true
    }
    signals     = [ordered]@{
        steadyStateSignals = $guide.steadyStateSignals
        impactSignals      = $guide.impactSignals
        dataPlaneProof     = $guide.dataPlaneProof
        configuredSources  = @($SignalSource)
    }
    readiness   = [ordered]@{
        gates           = $readiness.gates
        faultPath       = $pathResolution
        limitationCodes = @($readiness.limitationCodes + $(if ($pathResolution.verdict -eq 'unverified') { @('L4') } else { @() }) | Select-Object -Unique)
    }
    knownLimitations = $guide.knownLimitations
}

# The hash covers everything above it. Anything edited afterwards invalidates
# the consent that will be given against it.
$plan['frozenConfigHash'] = Get-ChaosDigest -InputObject $plan

# -- 6. Persist -----------------------------------------------------------

$study = New-ChaosStudy -ScopeHash $scopeHash -StudyRoot $StudyRoot
Save-ChaosStudyArtifact -StudyPath $study.path -RelativePath 'study-plan.v1.json' -Content $plan | Out-Null
Add-ChaosCommandTrailEntry -StudyPath $study.path -Phase 'scope' `
    -Command 'Invoke-ChaosStudyScope.ps1' `
    -Arguments ([ordered]@{ fault = $guide.name; namespace = $Namespace; selector = $effectiveSelector; skipDiscovery = [bool]$SkipDiscovery }) `
    -ExitCode 0 -Note "Plan frozen at $($plan['frozenConfigHash'])" | Out-Null

# -- 7. Report to the operator --------------------------------------------

$advisories = @($readiness.gates | Where-Object { $_.status -ne 'pass' })

$summary = @(
    "Study      $($study.studyId)"
    "Scope      $scopeHash"
    "Fault      $($guide.displayName)  [$($guide.faultPath), proof: $($guide.dataPlaneProof['coverage'])]"
    "Target     $Namespace/$($effectiveSelector ?? '(all)') in $ClusterName"
    "Objective  $($predicate.raw)"
    "Windows    $BaselineMinutes m baseline, $DurationMinutes m inject, $RecoveryMinutes m recovery"
    "Frozen at  $($plan['frozenConfigHash'])"
    "Plan       $(Resolve-ChaosStudyPath -StudyRoot $study.studyRoot -ScopeHash $scopeHash -StudyId $study.studyId -Artifact 'plan')"
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
