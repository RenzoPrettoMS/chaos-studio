<#
.SYNOPSIS
    Runs a complete Chaos reliability study: scope -> run -> report.

.DESCRIPTION
    This is the opinionated front door. It answers one question end to end:

        "Does <steady state> hold when I execute <action> across <workspace scope>?"

    It does not reimplement any phase. It chains the three focused entry points,
    each of which remains independently usable:

        chaos-study-scope   frames the question and freezes a plan
        chaos-study-run     asks for consent, injects, collects evidence
        chaos-study-report  interprets the evidence and writes the report

    Safety posture, inherited from the phase scripts rather than reinvented here:

      * -DryRun defaults to $true. Nothing is injected unless the caller both
        passes -DryRun:$false AND types the consent phrase the plan prints.
      * The plan is frozen and hashed before anything is armed. If the plan
        changes between scope and run, the run refuses.
      * Any non-zero exit from a phase stops the chain immediately. A partial
        study is left on disk, correctly stated, for inspection or resumption.

    Three exits are deliberate pauses rather than failures, and the chain reports
    them as such because treating them as errors invites exactly the wrong
    reaction - working around the stop by inventing the missing part:

      * 18  the phase needs an Azure call it cannot make in-process. It wrote the
            request to the study directory. Execute it with your own tooling,
            write the result back, and re-run the same command.
      * 19  role assignments are required. Granting them is a separate decision
            from approving the fault, so it needs its own approval phrase.
      * 21  the exposure arithmetic says the run would not exercise the failure.
            Strengthen the exercise, or accept a weak one explicitly.

    Resumption matters: because each phase persists its own output, a chain that
    fails in `run` can be resumed by invoking `run` directly against the same
    study id. Nothing here is a transaction that must be restarted from scratch.

.EXAMPLE
    ./Invoke-ChaosStudy.ps1 -SubscriptionId $sub -ResourceGroup rg-prod `
        -WorkspaceName ws-payments `
        -Scenario 'zone-down' -Action 'urn:csci:microsoft:...' `
        -SteadyState 'successRate >= 99.5'

    Plans the study against an existing workspace and previews the run.
    Executes nothing.

.EXAMPLE
    ./Invoke-ChaosStudy.ps1 ... -DryRun:$false -Consent '<phrase the dry run prints>'

    Runs the study for real, then reports and seals it.

.EXAMPLE
    ./Invoke-ChaosStudy.ps1 -ListActions -SubscriptionId $sub -ResourceGroup rg-prod `
        -WorkspaceName ws-payments

    Lists the actions Chaos Studio actually offers for that workspace's region,
    read live from the service. This suite ships no action catalogue.
#>

[CmdletBinding(DefaultParameterSetName = 'Study')]
param(
    [Parameter(ParameterSetName = 'ListActions', Mandatory)][switch]$ListActions,
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)][switch]$ListScenarios,

    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Brief', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$SubscriptionId,
    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Brief', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$ResourceGroup,

    # The workspace is the lifecycle root: scopes, discovered resources,
    # scenarios and runs all hang off one.
    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Brief', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$WorkspaceName,

    # Create the workspace when it does not exist, over the given ARM scopes.
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][switch]$CreateWorkspace,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string[]]$Scope = @(),
    [Parameter(ParameterSetName = 'ListActions')]
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$Location,

    [Parameter(ParameterSetName = 'Study', Mandatory)]
    [Parameter(ParameterSetName = 'Brief')][string]$Scenario,
    [Parameter(ParameterSetName = 'Study', Mandatory)]
    [Parameter(ParameterSetName = 'Brief')][string]$Action,
    [Parameter(ParameterSetName = 'Study', Mandatory)]
    [Parameter(ParameterSetName = 'Brief')][string]$SteadyState,

    # A confirmed brief from chaos-study-design. Supplies every study input the
    # customer already agreed, so the decision reached in the design phase is
    # the decision that runs. Anything passed explicitly still wins.
    [Parameter(ParameterSetName = 'Brief', Mandatory)][string]$Brief,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][ValidateRange(1, 240)][int]$DurationMinutes = 10,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][ValidateRange(0, 240)][int]$BaselineMinutes = 5,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][ValidateRange(0, 240)][int]$RecoveryMinutes = 10,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][hashtable]$Parameters,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$Hypothesis,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string[]]$SignalSource = @(),

    # Falsifiability inputs (Req B). Readiness blocks without them, so the front
    # door has to be able to carry them; a study whose mechanism cannot be stated
    # is a guess, and the entry point should not be the reason it slips through.
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$FailureMechanism,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$MechanismEvidence,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][hashtable]$MechanismProbe,

    # Exercise arithmetic (Req E). Unsupplied values stay unsupplied.
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][double]$EventRatePerSecond,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][double]$VulnerableWindowSeconds,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][ValidateRange(0, 1)][double]$EligibleFraction,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][switch]$AcceptWeakExercise,

    # Blast radius, forwarded to the scenario configuration.
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string[]]$FilterLocation = @(),
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string[]]$ExcludeResource = @(),
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string[]]$ExcludeType = @(),

    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$StudyRoot,
    [Parameter(ParameterSetName = 'ListActions')]
    [Parameter(ParameterSetName = 'ListScenarios')]
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][ValidateSet('local-az', 'external')][string]$Adapter,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$AcceptPartialScenario,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][bool]$DryRun = $true,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$Consent,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][string]$ApprovePermissions,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][switch]$KeepConfiguration,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][switch]$SkipDiscovery,
    [Parameter(ParameterSetName = 'Study')][Parameter(ParameterSetName = 'Brief')][switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Common.ps1')
. (Join-Path $libDir 'Study.ps1')

$skillsRoot = Join-Path $PSScriptRoot '..' '..'
$designScript = Join-Path $skillsRoot 'chaos-study-design' 'scripts' 'Invoke-ChaosStudyDesign.ps1'
$scopeScript = Join-Path $skillsRoot 'chaos-study-scope' 'scripts' 'Invoke-ChaosStudyScope.ps1'
$runScript = Join-Path $skillsRoot 'chaos-study-run' 'scripts' 'Invoke-ChaosStudyRun.ps1'
$reportScript = Join-Path $skillsRoot 'chaos-study-report' 'scripts' 'Invoke-ChaosStudyReport.ps1'

foreach ($required in @($designScript, $scopeScript, $runScript, $reportScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Error-Card -Title 'Skill suite incomplete' -Body @"
Expected phase script not found:

  $required

chaos-study chains the focused skills rather than duplicating them, so all six
skill directories must be installed together.
"@
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }
}

# ---------------------------------------------------------------------------
# Phase invocation
# ---------------------------------------------------------------------------

function Invoke-ChaosPhase {
    <#
        Runs one phase in a child pwsh so that a phase which calls `exit` cannot
        terminate this orchestrator. Output streams through to the console live;
        only the exit code is interpreted here.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.Add('-NoProfile')
    $argv.Add('-File')
    $argv.Add($Script)
    foreach ($key in ($Arguments.Keys | Sort-Object)) {
        $value = $Arguments[$key]
        if ($null -eq $value) { continue }
        if ($value -is [switch]) {
            if ($value.IsPresent) { $argv.Add("-$key") }
            continue
        }
        if ($value -is [bool]) {
            $argv.Add("-${key}:`$$($value.ToString().ToLowerInvariant())")
            continue
        }
        if ($value -is [array]) {
            if ($value.Count -eq 0) { continue }
            $argv.Add("-$key")
            $argv.Add(($value -join ','))
            continue
        }
        $argv.Add("-$key")
        $argv.Add([string]$value)
    }

    Write-ChaosStudyNote -Message "phase: $Name"
    # The child's output is written straight through rather than returned, so the
    # function's only return value is the exit code.
    & pwsh @argv | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}

function Stop-OnResumableOperation {
    <#
    .SYNOPSIS
    Reports a deliberate pause rather than a failure when a phase cannot reach
    Azure in-process.

    .DESCRIPTION
    Under the external adapter a phase stops the moment it needs an Azure call it
    cannot make itself. That is not an error: the phase wrote a canonical
    operation request into the study directory and everything it had already
    established is still on disk. The caller is expected to execute the pending
    request with its own authenticated tooling, write the result back, and re-run
    the very same command. Resuming is idempotent, so nothing is repeated and the
    plan, run record and command trail stay intact.

    Presenting this as a failure would be actively harmful, because the obvious
    reaction to a failure is to work around it - and the only available
    workaround is to hand-write the evidence, which destroys the study's
    provenance.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ExitCode
    )
    if ($ExitCode -ne (Get-ChaosStudyExitCode -Name 'ResumableOperation')) { return }
    Write-Card -Title "Study paused for a host operation: $Name" -Status 'warning' -Body @"
$Name needs an Azure call it cannot make in this process, so it stopped and wrote
the request to the study directory instead of guessing.

Nothing failed and nothing was skipped. To continue:

  1. Read the pending request under the study's operations directory.
  2. Execute exactly that call with your own authenticated Azure tooling.
  3. Write the response back as the matching result file.
  4. Re-run this same command - the phase picks up where it stopped.

The result is bound to the request hash and folded into the study's provenance,
so a resumed study is as auditable as one that never paused. Do not reconstruct
the outcome by hand: an invented result cannot be sealed as compliant.
"@
    exit $ExitCode
}

function Stop-OnPhaseFailure {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Guidance
    )
    if ($ExitCode -eq 0) { return }
    Write-Error-Card -Title "Study stopped in phase: $Name" -Body @"
$Name exited with code $ExitCode.

$Guidance

Nothing further has run. Whatever the phase persisted is still on disk and the
study state reflects exactly how far it got, so you can inspect it or resume
from this phase without re-planning.
"@
    exit $ExitCode
}

# ---------------------------------------------------------------------------
# Action listing short-circuits the chain
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -in @('ListActions', 'ListScenarios')) {
    $listArgs = @{
        SubscriptionId = $SubscriptionId
        ResourceGroup  = $ResourceGroup
        WorkspaceName  = $WorkspaceName
    }
    if ($PSCmdlet.ParameterSetName -eq 'ListActions') {
        $listArgs['ListActions'] = [switch]::Present
        if ($Location) { $listArgs['Location'] = $Location }
        $phaseName = 'chaos-study-scope (list actions)'
    } else {
        $listArgs['ListScenarios'] = [switch]::Present
        $phaseName = 'chaos-study-scope (list scenarios)'
    }
    if ($Adapter) { $listArgs['Adapter'] = $Adapter }
    $code = Invoke-ChaosPhase -Name $phaseName -Script $scopeScript -Arguments $listArgs
    Stop-OnResumableOperation -Name $phaseName -ExitCode $code
    exit $code
}
# ---------------------------------------------------------------------------
# Phase 1 - scope
# ---------------------------------------------------------------------------

$scopeArgs = @{
    SubscriptionId  = $SubscriptionId
    ResourceGroup   = $ResourceGroup
    WorkspaceName   = $WorkspaceName
    DurationMinutes = $DurationMinutes
    BaselineMinutes = $BaselineMinutes
    RecoveryMinutes = $RecoveryMinutes
}
# In Brief mode these three may be absent here and supplied by the brief, so
# only forward what was actually stated. Passing an empty string would look
# explicit to the hydrator and suppress the brief's value.
if ($Scenario) { $scopeArgs['Scenario'] = $Scenario }
if ($Action) { $scopeArgs['Action'] = $Action }
if ($SteadyState) { $scopeArgs['SteadyState'] = $SteadyState }
if ($PSCmdlet.ParameterSetName -eq 'Brief') { $scopeArgs['Brief'] = $Brief }
if ($CreateWorkspace) { $scopeArgs['CreateWorkspace'] = [switch]::Present }
if ($Scope.Count -gt 0) { $scopeArgs['Scope'] = $Scope }
if ($Location) { $scopeArgs['Location'] = $Location }
if ($Hypothesis) { $scopeArgs['Hypothesis'] = $Hypothesis }
if ($StudyRoot) { $scopeArgs['StudyRoot'] = $StudyRoot }
if ($SignalSource.Count -gt 0) { $scopeArgs['SignalSource'] = $SignalSource }
if ($FailureMechanism) { $scopeArgs['FailureMechanism'] = $FailureMechanism }
if ($MechanismEvidence) { $scopeArgs['MechanismEvidence'] = $MechanismEvidence }
if ($MechanismProbe) { $scopeArgs['MechanismProbe'] = $MechanismProbe }
if ($PSBoundParameters.ContainsKey('EventRatePerSecond')) { $scopeArgs['EventRatePerSecond'] = $EventRatePerSecond }
if ($PSBoundParameters.ContainsKey('VulnerableWindowSeconds')) { $scopeArgs['VulnerableWindowSeconds'] = $VulnerableWindowSeconds }
if ($PSBoundParameters.ContainsKey('EligibleFraction')) { $scopeArgs['EligibleFraction'] = $EligibleFraction }
if ($AcceptWeakExercise) { $scopeArgs['AcceptWeakExercise'] = [switch]::Present }
if ($FilterLocation.Count -gt 0) { $scopeArgs['FilterLocation'] = $FilterLocation }
if ($ExcludeResource.Count -gt 0) { $scopeArgs['ExcludeResource'] = $ExcludeResource }
if ($ExcludeType.Count -gt 0) { $scopeArgs['ExcludeType'] = $ExcludeType }
if ($SkipDiscovery) { $scopeArgs['SkipDiscovery'] = [switch]::Present }
if ($Adapter) { $scopeArgs['Adapter'] = $Adapter }
if ($AcceptPartialScenario) { $scopeArgs['AcceptPartialScenario'] = $AcceptPartialScenario }
if ($Parameters -and $Parameters.Count -gt 0) {
    # Hashtables cannot cross the pwsh -File boundary, so parameterised scenarios
    # are planned by calling the scope skill directly rather than through this chain.
    Write-Error-Card -Title 'Use the scope skill for parameterised scenarios' -Body @"
-Parameters cannot be forwarded through the chained entry point.

Plan the study with the scope skill directly, then continue here or with the run
skill against the resulting study id:

  chaos-study-scope -Scenario $Scenario -Action $Action -Parameters @{ ... }
"@
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

$scopeExit = Invoke-ChaosPhase -Name 'chaos-study-scope' -Script $scopeScript -Arguments $scopeArgs
Stop-OnResumableOperation -Name 'chaos-study-scope' -ExitCode $scopeExit

if ($scopeExit -eq (Get-ChaosStudyExitCode -Name 'InsufficientExposure')) {
    # Not a failure. Scoping did the exposure arithmetic and concluded the run
    # would not exercise the vulnerable path often enough for a clean result to
    # mean anything. Running anyway would produce a false pass.
    Write-Card -Title 'Study stopped: the run would not exercise the failure' -Status 'warning' -Body @"
The exposure model says the fault window is very unlikely to catch the code path
you are testing, so a study that reported no impact would be measuring nothing.

Change the exercise rather than the verdict:

  - raise -EventRatePerSecond or lengthen -DurationMinutes so real work meets the fault
  - widen -EligibleFraction if more of the traffic is genuinely vulnerable
  - drive load against the scope while the study runs

If you accept a weak exercise deliberately, re-run with -AcceptWeakExercise. The
study then records the arithmetic and reports "Not exercised" rather than
claiming resilience it did not demonstrate.
"@
    exit $scopeExit
}

if ($scopeExit -eq (Get-ChaosStudyExitCode -Name 'PartialScenarioUnaccepted')) {
    # Not a failure. Preflight validation revealed the service would run fewer
    # legs than the scenario declares, and the default is to fail closed rather
    # than let the scenario name imply coverage that will not happen.
    Write-Card -Title 'Study stopped: the scenario would run fewer legs than it declares' -Status 'warning' -Body @"
Preflight validation returned an execution plan in which some legs would be
skipped. A partial scenario still produces a report, and that report would carry
the scenario's full name while testing less than it claims.

Read the skipped legs and the service's reason for each, then either fix the
scope so every leg applies, or accept the reduced scenario explicitly with
-AcceptPartialScenario '<phrase the scope printed>'. The acceptance is bound to
this exact effective plan, so it cannot silently carry over to a different one.
"@
    exit $scopeExit
}

Stop-OnPhaseFailure -Name 'chaos-study-scope' -ExitCode $scopeExit -Guidance @"
Scoping decides whether the study is worth running at all: it resolves the
workspace, reads what is actually in its scopes, and checks the action applies to
those resources. A failure here is a real answer, not an obstacle to work around.

  exit 10  readiness gates failed - the scope is empty or already unhealthy
  exit 14  discovery failed - the action or scenario is not offered here
  exit 20  the scenario would run fewer legs than it declares
  exit 21  the exposure arithmetic says nothing would be exercised
"@

$store = if ($StudyRoot) { $StudyRoot } else { (Get-ChaosStudyRoot).path }
$latest = Find-ChaosStudy -StudyId 'latest' -StudyRoot $store
if (-not $latest) {
    Write-Error-Card -Title 'Plan not found' -Body 'Scoping reported success but no study was recorded. Refusing to continue.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}
$studyId = $latest.studyId

if ($PlanOnly) {
    Write-Card -Title 'Plan frozen' -Status 'success' -Body @"
Study $studyId is planned and frozen. Nothing has been executed.

Review the plan, then run it when you are ready:

  chaos-study-run -StudyId $studyId -DryRun:`$false -Consent '<phrase from the plan>'
"@
    exit 0
}

# ---------------------------------------------------------------------------
# Phase 2 - run
# ---------------------------------------------------------------------------

$runArgs = @{
    StudyId = $studyId
    DryRun  = $DryRun
}
if ($StudyRoot) { $runArgs['StudyRoot'] = $StudyRoot }
if ($Consent) { $runArgs['Consent'] = $Consent }
if ($ApprovePermissions) { $runArgs['ApprovePermissions'] = $ApprovePermissions }
if ($KeepConfiguration) { $runArgs['KeepConfiguration'] = [switch]::Present }
if ($SignalSource.Count -gt 0) { $runArgs['SignalSource'] = $SignalSource }
if ($Adapter) { $runArgs['Adapter'] = $Adapter }

$runExit = Invoke-ChaosPhase -Name 'chaos-study-run' -Script $runScript -Arguments $runArgs
Stop-OnResumableOperation -Name 'chaos-study-run' -ExitCode $runExit

if ($runExit -eq (Get-ChaosStudyExitCode -Name 'PermissionApprovalRequired')) {
    # Not a failure. The run stopped deliberately because the workspace identity
    # needs role assignments this study has not been authorised to create.
    # Nothing was granted and nothing was injected; the preview is on disk.
    Write-Card -Title 'Study paused for permission approval' -Status 'warning' -Body @"
The scenario configuration could not validate because the workspace identity is
missing access, and granting it is a separate decision from approving the fault.

The run printed the exact approval phrase and wrote the preview to the study
directory. Approving role assignments widens access beyond this study, so read
the preview before you approve it, then resume:

  chaos-study ... -DryRun:`$false -Consent '<phrase>' -ApprovePermissions '<phrase the run printed>'
"@
    exit $runExit
}

Stop-OnPhaseFailure -Name 'chaos-study-run' -ExitCode $runExit -Guidance @"
  exit 11  consent was not given - re-run with the exact phrase the plan printed
  exit 12  the plan changed after it was frozen - re-scope rather than force it
  exit 13  this study is already sealed - scope a new one to re-test
  exit 17  the scenario configuration did not validate - fix what it reported
"@

if ($DryRun) {
    Write-Card -Title 'Dry run complete' -Status 'success' -Body @"
Study $studyId was previewed end to end. Nothing was executed, so there is no
evidence to interpret and no report to write.

When the preview matches your intent, arm it:

  chaos-study ... -DryRun:`$false -Consent '<phrase from the preview>'
"@
    exit 0
}

# ---------------------------------------------------------------------------
# Phase 3 - report
# ---------------------------------------------------------------------------

$reportArgs = @{ StudyId = $studyId }
if ($StudyRoot) { $reportArgs['StudyRoot'] = $StudyRoot }

$reportExit = Invoke-ChaosPhase -Name 'chaos-study-report' -Script $reportScript -Arguments $reportArgs
Stop-OnResumableOperation -Name 'chaos-study-report' -ExitCode $reportExit
Stop-OnPhaseFailure -Name 'chaos-study-report' -ExitCode $reportExit -Guidance @"
The injection already happened and the evidence is on disk. Reporting is a pure
read of what was collected, so it is safe to retry:

  chaos-study-report -StudyId $studyId
"@

Write-ChaosStudyNote -Message "Next: compare this study with earlier runs - chaos-study-history -Action compare"
exit 0
