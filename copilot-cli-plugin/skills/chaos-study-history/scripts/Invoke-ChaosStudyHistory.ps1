#Requires -Version 7.0
<#
.SYNOPSIS
    List, inspect, compare and rerun past studies.

.DESCRIPTION
    A single chaos study is an anecdote. The value comes from the series - the
    same question asked of the same target over time, so a change in the answer
    means something changed in the system.

    This skill never mutates a sealed study. `-Action rerun` prints the plan
    needed to repeat one; it does not inject anything itself, because rerunning
    is an execution decision and execution requires consent from the run skill.

.EXAMPLE
    ./Invoke-ChaosStudyHistory.ps1
    Lists every sealed study, newest first.

.EXAMPLE
    ./Invoke-ChaosStudyHistory.ps1 -Action compare -StudyId latest -Against previous
    Diffs the two most recent studies of the same scope.
#>

[CmdletBinding()]
param(
    [ValidateSet('list', 'show', 'compare', 'rerun')]
    [string]$Action = 'list',
    [string]$StudyId = 'latest',
    [string]$Against = 'previous',
    [string]$ScopeHash,
    [string]$StudyRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedLib = Join-Path $PSScriptRoot '..' '..' 'chaos-study' 'scripts' 'lib'
. (Join-Path $sharedLib 'Common.ps1')
. (Join-Path $sharedLib 'Study.ps1')
. (Join-Path $PSScriptRoot 'lib' 'Compare.ps1')

$indexArgs = @{}
if ($StudyRoot) { $indexArgs['StudyRoot'] = $StudyRoot }
$index = @(Get-ChaosStudyIndex @indexArgs -Rebuild)

if ($ScopeHash) { $index = @($index | Where-Object { $_.scopeHash -eq $ScopeHash }) }

function Get-StudyFindings {
    param([Parameter(Mandatory)][object]$Entry)
    $path = Join-Path $Entry.path 'findings.v1.json'
    $findings = Read-ChaosJsonFile -Path $path
    if (-not $findings) { return ,@() }
    # A study with no findings round-trips as $null through @(); filter it out so
    # callers always get a clean array rather than an array containing nothing.
    return ,@(@($findings.findings) | Where-Object { $null -ne $_ })
}

function Resolve-Entry {
    <#
    .SYNOPSIS
        Resolve 'latest', 'previous' or an explicit id against the index.
    #>
    param([Parameter(Mandatory)][string]$Selector, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pool)
    $ordered = @($Pool | Sort-Object -Property studyId -Descending)
    switch ($Selector) {
        'latest'   { return ($ordered | Select-Object -First 1) }
        'previous' { return ($ordered | Select-Object -Skip 1 -First 1) }
        default    { return ($ordered | Where-Object { $_.studyId -eq $Selector } | Select-Object -First 1) }
    }
}

if ($index.Count -eq 0) {
    Write-Card -Title 'No studies yet' -Status 'info' -Body @"
No studies were found under the study root. History becomes useful after the
first sealed study - run the chaos-study skill to create one.
"@
    exit (Get-ChaosStudyExitCode -Name 'Success')
}

switch ($Action) {

    'list' {
        $rows = foreach ($entry in ($index | Sort-Object -Property studyId -Descending)) {
            [pscustomobject]@{
                Study    = $entry.studyId
                State    = $entry.state
                Target   = $(if ($entry.identity) { [string]$entry.identity.target } else { '-' })
                Fault    = $(if ($entry.identity) { [string]$entry.identity.fault } else { '-' })
                Verdict  = $(if ($entry.summary) { [string]$entry.summary.verdict } else { '-' })
                Findings = $(if ($entry.summary) { $entry.summary.findingCount } else { '-' })
                Scope    = $entry.scopeHash
            }
        }
        if ($Json) { $rows | ConvertTo-Json -Depth 6; exit (Get-ChaosStudyExitCode -Name 'Success') }
        Write-Table -Title "Studies ($($index.Count))" -Data @($rows)
        $scopes = @($index | Group-Object scopeHash)
        Write-ChaosStudyNote -Message "$($scopes.Count) distinct scope(s). Compare within a scope: -Action compare -ScopeHash <hash>."
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    'show' {
        $entry = Resolve-Entry -Selector $StudyId -Pool $index
        if (-not $entry) {
            Write-ChaosStudyFailure -Title 'Study not found' -Message "No study matched '$StudyId'." -Remediation 'Run this skill with -Action list to see available studies.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        $findings = Get-StudyFindings -Entry $entry
        if ($Json) {
            [ordered]@{ study = $entry; findings = @($findings) } | ConvertTo-Json -Depth 8
            exit (Get-ChaosStudyExitCode -Name 'Success')
        }
        Write-Card -Title "Study $($entry.studyId)" -Status 'info' -Body @"
$(if ($entry.summary) { [string]$entry.summary.verdict } else { 'Not yet reported.' })
"@ -Properties ([ordered]@{
            'State'     = $entry.state
            'Sealed'    = $entry.sealedAt
            'Target'    = $(if ($entry.identity) { [string]$entry.identity.target } else { '-' })
            'Fault'     = $(if ($entry.identity) { [string]$entry.identity.faultUrn } else { '-' })
            'Predicate' = $(if ($entry.identity) { [string]$entry.identity.predicate } else { '-' })
            'Report'    = (Join-Path $entry.path 'report.html')
        })
        if (@($findings).Count -gt 0) {
            Write-Table -Title 'Findings' -Data @($findings | ForEach-Object {
                [pscustomobject]@{ Severity = $_.severity; Confidence = $_.confidence; Finding = $_.title }
            })
        }
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    'compare' {
        $sealed = @($index | Where-Object { $_.state -eq 'SEALED' })
        $candidate = Resolve-Entry -Selector $StudyId -Pool $sealed
        if (-not $candidate) {
            Write-ChaosStudyFailure -Title 'Nothing to compare' -Message "No sealed study matched '$StudyId'." -Remediation 'Seal a study by running the chaos-study-report skill.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        # Restrict the pool to the same scope before picking 'previous', otherwise
        # 'previous' would happily select an unrelated study.
        $pool = @($sealed | Where-Object { $_.scopeHash -eq $candidate.scopeHash -and $_.studyId -ne $candidate.studyId })
        $baseline = Resolve-Entry -Selector $(if ($Against -eq 'previous') { 'latest' } else { $Against }) -Pool $pool

        if (-not $baseline) {
            Write-Card -Title 'Only one study in this scope' -Status 'info' -Body @"
Study $($candidate.studyId) is the only sealed study for scope $($candidate.scopeHash).
A comparison needs two. Run the same study again later and compare then - that
series is where the value is.
"@
            exit (Get-ChaosStudyExitCode -Name 'Success')
        }

        $baseline | Add-Member -NotePropertyName findings -NotePropertyValue (Get-StudyFindings -Entry $baseline) -Force
        $candidate | Add-Member -NotePropertyName findings -NotePropertyValue (Get-StudyFindings -Entry $candidate) -Force

        $comparison = Compare-Study -Baseline $baseline -Candidate $candidate

        if ($Json) { $comparison | ConvertTo-Json -Depth 8; exit $(if ($comparison.comparable) { 0 } else { Get-ChaosStudyExitCode -Name 'StudyIncomparable' }) }

        if (-not $comparison.comparable) {
            Write-ChaosStudyFailure -Title 'These studies are not comparable' -Message @"
$($baseline.studyId) and $($candidate.studyId) did not ask the same question, so
any difference between them would be noise dressed as a signal.

$(@($comparison.reasons | ForEach-Object { "  - $_" }) -join "`n")
"@ -Remediation 'Compare studies that share a scope, a fault, a fault path, a steady-state objective and comparable window lengths.'
            exit (Get-ChaosStudyExitCode -Name 'StudyIncomparable')
        }

        $status = switch ($comparison.direction) {
            'improved'  { 'success' }
            'regressed' { 'error' }
            'stable'    { 'info' }
            default     { 'warning' }
        }
        Write-Card -Title "Comparison: $($comparison.direction)" -Status $status -Body @"
$($baseline.studyId) ($($comparison.baseline.verdict))
  -> $($candidate.studyId) ($($comparison.candidate.verdict))
"@ -Properties ([ordered]@{
            'Verdict changed' = $comparison.verdictChanged
            'Introduced'      = @($comparison.introduced).Count
            'Resolved'        = @($comparison.resolved).Count
            'Persisted'       = @($comparison.persisted).Count
        })

        foreach ($group in @(
            @{ label = 'Introduced'; items = $comparison.introduced }
            @{ label = 'Resolved'; items = $comparison.resolved }
        )) {
            if (@($group.items).Count -gt 0) {
                Write-Table -Title $group.label -Data @($group.items | ForEach-Object {
                    [pscustomobject]@{ Severity = $_.severity; Finding = $_.title }
                })
            }
        }
        if (@($comparison.persisted).Count -gt 0) {
            Write-Table -Title 'Persisted' -Data @($comparison.persisted | ForEach-Object {
                [pscustomobject]@{ Movement = $_.movement; Was = $_.wasSeverity; Now = $_.nowSeverity; Finding = $_.title }
            })
        }
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }

    'rerun' {
        $entry = Resolve-Entry -Selector $StudyId -Pool $index
        if (-not $entry) {
            Write-ChaosStudyFailure -Title 'Study not found' -Message "No study matched '$StudyId'." -Remediation 'Run this skill with -Action list to see available studies.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        $plan = Read-ChaosJsonFile -Path (Join-Path $entry.path 'study-plan.v1.json')
        if (-not $plan) {
            Write-ChaosStudyFailure -Title 'Study has no plan' -Message "Study $($entry.studyId) has no study-plan.v1.json to repeat." -Remediation 'Plan a fresh study with the chaos-study-scope skill.'
            exit (Get-ChaosStudyExitCode -Name 'Error')
        }
        $scope = Join-Path $PSScriptRoot '..' '..' 'chaos-study-scope' 'scripts' 'Invoke-ChaosStudyScope.ps1'
        $selectorLine = if ($plan.target.selector) { "`n    -Selector '$($plan.target.selector)' ``" } else { '' }
        $command = @(
            "& '$scope' ``"
            "    -SubscriptionId '$($plan.target.subscriptionId)' ``"
            "    -ResourceGroup '$($plan.target.resourceGroup)' ``"
            "    -ClusterName '$($plan.target.resourceName)' ``"
            "    -Namespace '$($plan.target.namespace)' ``$selectorLine"
            "    -Fault '$($plan.fault.guide)' ``"
            "    -SteadyState '$($plan.question.steadyState.raw)' ``"
            "    -DurationMinutes $($plan.windows.injectMinutes) ``"
            "    -BaselineMinutes $($plan.windows.baselineMinutes) ``"
            "    -RecoveryMinutes $($plan.windows.recoveryMinutes)"
        ) -join "`n"

        Write-Card -Title "Rerun study $($entry.studyId)" -Status 'info' -Body @"
Rerunning creates a new study rather than overwriting this one, so the pair can
be compared afterwards. Nothing has been injected - run the command below, then
the chaos-study-run skill with explicit consent.
"@ -Properties ([ordered]@{
            'Target'    = "$($plan.target.resourceName)/$($plan.target.namespace)"
            'Fault'     = [string]$plan.fault.displayName
            'Predicate' = [string]$plan.question.steadyState.raw
        })
        Write-Card -Title 'Command' -Status 'info' -Body $command
        exit (Get-ChaosStudyExitCode -Name 'Success')
    }
}
