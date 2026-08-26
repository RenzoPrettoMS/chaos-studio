#Requires -Version 7.0
<#
.SYNOPSIS
    Execute a frozen chaos study plan and record what happened.

.DESCRIPTION
    This is the only script in the suite that changes production. It is
    therefore the most conservative one:

      * It refuses to run a plan that changed after it was frozen.
      * It does nothing without an explicit, plan-specific consent phrase.
      * It defaults to a dry run, so the unarmed path is the default path.
      * It cancels and deletes the experiment it created, even on failure.

    Evidence is collected in three windows - before, during and after - and
    written verbatim. A signal that could not be read is recorded as null with
    a reason. Nothing is inferred, interpolated or filled in.

.EXAMPLE
    ./Invoke-ChaosStudyRun.ps1
    Previews the latest planned study without touching anything.

.EXAMPLE
    ./Invoke-ChaosStudyRun.ps1 -DryRun:$false -Consent 'inject aks-chaosmesh-pod into aks-prod/payments 3d1f87dd'
    Runs it.
#>

[CmdletBinding()]
param(
    [string]$StudyId = 'latest',
    [string]$StudyRoot,
    [bool]$DryRun = $true,
    [string]$Consent,
    [string]$Location,
    [string[]]$SignalSource = @(),
    [int]$PollSeconds = 20,
    [switch]$KeepExperiment,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
$sharedLib = Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib'
. (Join-Path $sharedLib 'Common.ps1')
. (Join-Path $sharedLib 'ApiVersions.ps1')
. (Join-Path $sharedLib 'Study.ps1')
. (Join-Path $libDir 'Signals.ps1')
. (Join-Path $libDir 'Execute.ps1')

# -- Locate the study ------------------------------------------------------

$findArgs = @{ StudyId = $StudyId }
if ($StudyRoot) { $findArgs['StudyRoot'] = $StudyRoot }
$study = Find-ChaosStudy @findArgs

if (-not $study) {
    Write-ChaosStudyFailure -Title 'No study to run' -Message @"
Could not find a study matching '$StudyId'.
"@ -Remediation 'Run the chaos-study-scope skill first to plan a study.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

$studyPath = $study.path
$plan = Read-ChaosJsonFile -Path (Join-Path $studyPath 'study-plan.v1.json')

if (-not $plan) {
    Write-ChaosStudyFailure -Title 'Study has no plan' -Message @"
Study $($study.studyId) exists but contains no study-plan.v1.json, so there is
nothing to execute.
"@ -Remediation 'Re-run the chaos-study-scope skill for this target.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

if ($study.state -eq 'SEALED') {
    Write-ChaosStudyFailure -Title 'Study is sealed' -Message @"
Study $($study.studyId) has already been reported and sealed. Sealed studies are
immutable so that a report always describes the run it was generated from.
"@ -Remediation 'Run the chaos-study-scope skill to plan a fresh study, then run that one.'
    exit (Get-ChaosStudyExitCode -Name 'StudyAlreadySealed')
}

if ($study.state -eq 'EXECUTED' -and -not $Force -and -not $DryRun) {
    Write-ChaosStudyFailure -Title 'Study has already been executed' -Message @"
Study $($study.studyId) already holds a run record. Running it again would
overwrite evidence from the first execution.
"@ -Remediation 'Plan a new study, or pass -Force if you intend to overwrite this one.'
    exit (Get-ChaosStudyExitCode -Name 'Error')
}

Assert-ChaosPlanIntegrity -Plan $plan | Out-Null

$experimentName = Get-ChaosStudyExperimentName -StudyId $study.studyId
$sources = @($SignalSource)
if ($sources.Count -eq 0 -and $plan.signals.configuredSources) {
    $sources = @($plan.signals.configuredSources)
}

# -- Dry run ---------------------------------------------------------------

if ($DryRun) {
    $phrase = Get-ChaosConsentPhrase -Plan $plan
    $definition = New-ChaosExperimentDefinition -Plan $plan -Location ($Location ? $Location : '<cluster region>')
    $previewWindow = New-ChaosWindow -Name 'preview' -Start (ConvertTo-ChaosUtcIso -Instant (Get-Date).ToUniversalTime().AddMinutes(-1)) -End (Get-ChaosUtcNow)
    $preview = Invoke-ChaosSignalCollection -Plan $plan -Window $previewWindow -Sources $sources -DryRun

    Write-Card -Title "Dry run - study $($study.studyId)" -Status 'info' -Body @"
Nothing has been injected. This is what would happen.

$($plan.question.hypothesis)
"@ -Properties ([ordered]@{
        'Target'      = "$($plan.target.resourceName)/$($plan.target.namespace)"
        'Selector'    = if ($plan.target.selector) { $plan.target.selector } else { '(whole namespace)' }
        'Fault'       = $plan.fault.displayName
        'Injection'   = "$($plan.windows.injectMinutes) minutes"
        'Baseline'    = "$($plan.windows.baselineMinutes) minutes before injection"
        'Recovery'    = "$($plan.windows.recoveryMinutes) minutes after injection"
        'Experiment'  = $experimentName
        'Fault path'  = $plan.readiness.faultPath.verdict
    })

    Write-Table -Title 'Evidence that would be collected' -Data @(
        foreach ($signal in $preview) {
            [pscustomobject]@{
                Source = $signal.source
                Status = if ($signal.caveat) { $signal.caveat } else { 'would be collected' }
            }
        }
    )

    if (@($plan.safety.abortConditions).Count -gt 0) {
        Write-Card -Title 'Abort if any of these happen' -Status 'warning' -Body (
            @($plan.safety.abortConditions | ForEach-Object { "  - $_" }) -join "`n"
        )
    }

    Write-Card -Title 'To run it' -Status 'info' -Body @"
Injection requires a consent phrase that names the blast radius and pins this
exact plan. Type it exactly:

  $phrase
"@ -JsonPreview ($definition | ConvertTo-Json -Depth 20)

    Write-ChaosStudyNote -Message "Dry run complete. Nothing was changed."
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

# -- Armed path ------------------------------------------------------------

Assert-ChaosConsent -Plan $plan -Consent $Consent | Out-Null

if ($plan.readiness.faultPath.verdict -ne 'open' -and -not $Force) {
    Write-ChaosStudyFailure -Title 'Fault path was never verified as open' -Message @"
The plan records the fault path as '$($plan.readiness.faultPath.verdict)'. Injecting
without a verified path usually produces a failed experiment and no evidence,
which costs a production window for nothing.
"@ -Remediation 'Re-run chaos-study-scope without -SkipDiscovery, or pass -Force to proceed anyway.'
    exit (Get-ChaosStudyExitCode -Name 'FaultPathUnavailable')
}

if (Get-Command Ensure-AzLogin -ErrorAction SilentlyContinue) { Ensure-AzLogin | Out-Null }

if (-not $Location) {
    $Location = (az resource show --ids $plan.target.resourceId --query location -o tsv 2>$null)
    if (-not $Location) {
        Write-ChaosStudyFailure -Title 'Could not determine the cluster region' -Message @"
The experiment resource must be created in a region and the target cluster's
region could not be read.
"@ -Remediation 'Pass -Location <region> explicitly.'
        exit (Get-ChaosStudyExitCode -Name 'Error')
    }
}

$startedAt = Get-ChaosUtcNow
Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'Invoke-ChaosStudyRun' -Note "consented; experiment $experimentName in $Location"

# Baseline is read retrospectively over the window that just ended, so the
# study does not have to idle for it.
$preWindow = New-ChaosWindow -Name 'pre' -Start (ConvertTo-ChaosUtcIso -Instant (Get-Date).ToUniversalTime().AddMinutes(-1 * $plan.windows.baselineMinutes)) -End $startedAt
Write-ChaosStudyNote -Message "Collecting baseline evidence over the last $($plan.windows.baselineMinutes) minutes."
$preEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $preWindow -Sources $sources
Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/pre/signals.json' -Content $preEvidence | Out-Null

$statusObservations = @()
$injectStart = $null
$injectEnd = $null
$experimentCreated = $false
$outcome = 'unknown'
$failureMessage = $null

try {
    Write-ChaosStudyNote -Message "Creating experiment $experimentName."
    New-ChaosStudyExperiment -Plan $plan -ExperimentName $experimentName -Location $Location | Out-Null
    $experimentCreated = $true
    Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'PUT Microsoft.Chaos/experiments' -Arguments @($experimentName) -ExitCode 0

    Write-ChaosStudyNote -Message 'Starting injection.'
    $injectStart = Get-ChaosUtcNow
    Start-ChaosStudyExperiment -Plan $plan -ExperimentName $experimentName | Out-Null
    Add-ChaosCommandTrailEntry -StudyPath $studyPath -Phase 'run' -Command 'POST experiments/start' -Arguments @($experimentName) -ExitCode 0

    $statusObservations = Wait-ChaosExperimentWindow -Plan $plan -ExperimentName $experimentName -Minutes $plan.windows.injectMinutes -PollSeconds $PollSeconds
    $injectEnd = Get-ChaosUtcNow
    $outcome = ([string](@($statusObservations)[-1].status))

    Write-ChaosStudyNote -Message 'Collecting evidence from the injection window.'
    $duringWindow = New-ChaosWindow -Name 'during' -Start $injectStart -End $injectEnd
    $duringEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $duringWindow -Sources $sources
    Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/during/signals.json' -Content $duringEvidence | Out-Null
} catch {
    $failureMessage = $_.Exception.Message
    $outcome = 'Failed'
    Write-ChaosStudyNote -Message "Injection failed: $failureMessage" -Level 'warn'
} finally {
    if ($experimentCreated) {
        Write-ChaosStudyNote -Message 'Cancelling experiment.'
        Stop-ChaosStudyExperiment -Plan $plan -ExperimentName $experimentName | Out-Null
        if (-not $KeepExperiment) {
            Remove-ChaosStudyExperiment -Plan $plan -ExperimentName $experimentName | Out-Null
        }
    }
}

if (-not $injectStart) { $injectStart = $startedAt }
if (-not $injectEnd) { $injectEnd = Get-ChaosUtcNow }
if (-not (Test-Path -LiteralPath (Join-Path $studyPath 'evidence' 'during' 'signals.json'))) {
    $duringWindow = New-ChaosWindow -Name 'during' -Start $injectStart -End $injectEnd
    $duringEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $duringWindow -Sources $sources -DryRun
    Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/during/signals.json' -Content $duringEvidence | Out-Null
}

Write-ChaosStudyNote -Message "Waiting $($plan.windows.recoveryMinutes) minutes for recovery."
Start-Sleep -Seconds ($plan.windows.recoveryMinutes * 60)
$postWindow = New-ChaosWindow -Name 'post' -Start $injectEnd -End (Get-ChaosUtcNow)
$postEvidence = Invoke-ChaosSignalCollection -Plan $plan -Window $postWindow -Sources $sources
Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'evidence/post/signals.json' -Content $postEvidence | Out-Null

# -- Run record ------------------------------------------------------------

$allSignals = @($preEvidence) + @($duringEvidence) + @($postEvidence)
$coverage = Test-ChaosSignalCoverage -Signals $allSignals

$runRecord = [ordered]@{
    recordVersion  = 'run-record.v1'
    studyId        = $study.studyId
    scopeHash      = $study.scopeHash
    planHash       = $plan.frozenConfigHash
    startedAt      = $startedAt
    completedAt    = Get-ChaosUtcNow
    experiment     = [ordered]@{
        name        = $experimentName
        location    = $Location
        outcome     = $outcome
        observations = @($statusObservations)
        retained    = [bool]$KeepExperiment
        failure     = $failureMessage
    }
    windows        = [ordered]@{
        pre    = $preWindow
        during = New-ChaosWindow -Name 'during' -Start $injectStart -End $injectEnd
        post   = $postWindow
    }
    evidence       = [ordered]@{
        pre    = 'evidence/pre/signals.json'
        during = 'evidence/during/signals.json'
        post   = 'evidence/post/signals.json'
    }
    coverage       = $coverage
}

Save-ChaosStudyArtifact -StudyPath $studyPath -RelativePath 'run-record.v1.json' -Content $runRecord | Out-Null

$status = if ($failureMessage) { 'error' } elseif ($coverage.missing -gt 0) { 'warning' } else { 'success' }
Write-Card -Title "Run complete - study $($study.studyId)" -Status $status -Body @"
Injection has stopped and the experiment has been cleaned up. Evidence is
recorded; it has not yet been interpreted.
"@ -Properties ([ordered]@{
    'Experiment outcome' = $outcome
    'Signals measured'   = "$($coverage.measured) of $($coverage.total)"
    'Study directory'    = $studyPath
})

if ($coverage.missing -gt 0) {
    Write-Card -Title 'Some evidence is missing' -Status 'warning' -Body (
        @($coverage.caveats | ForEach-Object { "  - $_" }) -join "`n"
    )
}

Write-ChaosStudyNote -Message "Next: run the chaos-study-report skill to interpret this run."

if ($failureMessage) { exit (Get-ChaosStudyExitCode -Name 'Error') }
exit (Get-ChaosStudyExitCode -Name 'Success')
