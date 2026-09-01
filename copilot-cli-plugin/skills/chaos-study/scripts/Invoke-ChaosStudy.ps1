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
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$SubscriptionId,
    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$ResourceGroup,

    # The workspace is the lifecycle root: scopes, discovered resources,
    # scenarios and runs all hang off one.
    [Parameter(ParameterSetName = 'ListActions', Mandatory)]
    [Parameter(ParameterSetName = 'ListScenarios', Mandatory)]
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$WorkspaceName,

    # Create the workspace when it does not exist, over the given ARM scopes.
    [Parameter(ParameterSetName = 'Study')][switch]$CreateWorkspace,
    [Parameter(ParameterSetName = 'Study')][string[]]$Scope = @(),
    [Parameter(ParameterSetName = 'ListActions')]
    [Parameter(ParameterSetName = 'Study')][string]$Location,

    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$Scenario,
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$Action,
    [Parameter(ParameterSetName = 'Study', Mandatory)][string]$SteadyState,
    [Parameter(ParameterSetName = 'Study')][ValidateRange(1, 240)][int]$DurationMinutes = 10,
    [Parameter(ParameterSetName = 'Study')][ValidateRange(0, 240)][int]$BaselineMinutes = 5,
    [Parameter(ParameterSetName = 'Study')][ValidateRange(0, 240)][int]$RecoveryMinutes = 10,
    [Parameter(ParameterSetName = 'Study')][hashtable]$Parameters,
    [Parameter(ParameterSetName = 'Study')][string]$Hypothesis,
    [Parameter(ParameterSetName = 'Study')][string[]]$SignalSource = @(),

    # Blast radius, forwarded to the scenario configuration.
    [Parameter(ParameterSetName = 'Study')][string[]]$FilterLocation = @(),
    [Parameter(ParameterSetName = 'Study')][string[]]$ExcludeResource = @(),
    [Parameter(ParameterSetName = 'Study')][string[]]$ExcludeType = @(),

    [Parameter(ParameterSetName = 'Study')][string]$StudyRoot,
    [Parameter(ParameterSetName = 'Study')][bool]$DryRun = $true,
    [Parameter(ParameterSetName = 'Study')][string]$Consent,
    [Parameter(ParameterSetName = 'Study')][string]$ApprovePermissions,
    [Parameter(ParameterSetName = 'Study')][switch]$KeepConfiguration,
    [Parameter(ParameterSetName = 'Study')][switch]$SkipDiscovery,
    [Parameter(ParameterSetName = 'Study')][switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'Common.ps1')
. (Join-Path $libDir 'Study.ps1')

$skillsRoot = Join-Path $PSScriptRoot '..' '..'
$scopeScript = Join-Path $skillsRoot 'chaos-study-scope' 'scripts' 'Invoke-ChaosStudyScope.ps1'
$runScript = Join-Path $skillsRoot 'chaos-study-run' 'scripts' 'Invoke-ChaosStudyRun.ps1'
$reportScript = Join-Path $skillsRoot 'chaos-study-report' 'scripts' 'Invoke-ChaosStudyReport.ps1'

foreach ($required in @($scopeScript, $runScript, $reportScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Error-Card -Title 'Skill suite incomplete' -Body @"
Expected phase script not found:

  $required

chaos-study chains the focused skills rather than duplicating them, so all four
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
    $code = Invoke-ChaosPhase -Name $phaseName -Script $scopeScript -Arguments $listArgs
    exit $code
}

# ---------------------------------------------------------------------------
# Phase 1 - scope
# ---------------------------------------------------------------------------

$scopeArgs = @{
    SubscriptionId  = $SubscriptionId
    ResourceGroup   = $ResourceGroup
    WorkspaceName   = $WorkspaceName
    Scenario        = $Scenario
    Action          = $Action
    SteadyState     = $SteadyState
    DurationMinutes = $DurationMinutes
    BaselineMinutes = $BaselineMinutes
    RecoveryMinutes = $RecoveryMinutes
}
if ($CreateWorkspace) { $scopeArgs['CreateWorkspace'] = [switch]::Present }
if ($Scope.Count -gt 0) { $scopeArgs['Scope'] = $Scope }
if ($Location) { $scopeArgs['Location'] = $Location }
if ($Hypothesis) { $scopeArgs['Hypothesis'] = $Hypothesis }
if ($StudyRoot) { $scopeArgs['StudyRoot'] = $StudyRoot }
if ($SignalSource.Count -gt 0) { $scopeArgs['SignalSource'] = $SignalSource }
if ($FilterLocation.Count -gt 0) { $scopeArgs['FilterLocation'] = $FilterLocation }
if ($ExcludeResource.Count -gt 0) { $scopeArgs['ExcludeResource'] = $ExcludeResource }
if ($ExcludeType.Count -gt 0) { $scopeArgs['ExcludeType'] = $ExcludeType }
if ($SkipDiscovery) { $scopeArgs['SkipDiscovery'] = [switch]::Present }
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
Stop-OnPhaseFailure -Name 'chaos-study-scope' -ExitCode $scopeExit -Guidance @"
Scoping decides whether the study is worth running at all: it resolves the
workspace, reads what is actually in its scopes, and checks the action applies to
those resources. A failure here is a real answer, not an obstacle to work around.

  exit 10  readiness gates failed - the scope is empty or already unhealthy
  exit 14  discovery failed - the action or scenario is not offered here
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

$runExit = Invoke-ChaosPhase -Name 'chaos-study-run' -Script $runScript -Arguments $runArgs

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
Stop-OnPhaseFailure -Name 'chaos-study-report' -ExitCode $reportExit -Guidance @"
The injection already happened and the evidence is on disk. Reporting is a pure
read of what was collected, so it is safe to retry:

  chaos-study-report -StudyId $studyId
"@

Write-ChaosStudyNote -Message "Next: compare this study with earlier runs - chaos-study-history -Action compare"
exit 0
