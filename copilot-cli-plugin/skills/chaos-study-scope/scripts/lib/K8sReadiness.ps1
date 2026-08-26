#Requires -Version 7.0
<#
.SYNOPSIS
    Readiness gates for a Kubernetes reliability study.

.DESCRIPTION
    A study is only worth running if its result will mean something. These
    gates check the preconditions that decide that, before any fault is
    planned:

      replicas         one replica makes every result "total outage", which is
                       a configuration fact, not a finding
      steady state     without a stated numeric objective there is nothing to
                       breach, so there is no such thing as a failure
      observability    without a data-plane signal the study can only prove the
                       control plane accepted the experiment
      disruption       a PDB is what makes graceful faults test anything

    Gates are `blocking` or `advisory`. Blocking gates stop scoping with exit
    code 10. Advisory gates become limitations on the report instead - they
    weaken the conclusion without invalidating it.

    Every gate that cannot be evaluated returns status 'unknown', never 'pass'.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')

function New-ChaosReadinessGate {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'unknown')][string]$Status,
        [Parameter(Mandatory)][ValidateSet('blocking', 'advisory')][string]$Severity,
        [Parameter(Mandatory)][string]$Detail,
        [AllowNull()][AllowEmptyString()][string]$Remediation = $null,
        [AllowNull()][AllowEmptyString()][string]$LimitationCode = $null
    )
    return [pscustomobject]@{
        id             = $Id
        title          = $Title
        status         = $Status
        severity       = $Severity
        detail         = $Detail
        remediation    = $Remediation
        limitationCode = $LimitationCode
    }
}

function Get-ChaosWorkloadSnapshot {
    <#
    .SYNOPSIS
        Read the workload's current replica shape. Returns $null when kubectl
        cannot answer - never a fabricated zero.
    #>
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$LabelSelector
    )

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { return $null }

    $output = & kubectl get pods -n $Namespace -l $LabelSelector -o json 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }

    try {
        $pods = @(($output | Out-String | ConvertFrom-Json).items)
    } catch {
        return $null
    }

    $ready = @($pods | Where-Object {
            $conditions = @($_.status.conditions)
            ($conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        })

    $nodes = @($pods | ForEach-Object { $_.spec.nodeName } | Where-Object { $_ } | Select-Object -Unique)

    return [pscustomobject]@{
        total       = $pods.Count
        ready       = $ready.Count
        distinctNodes = $nodes.Count
        nodeNames   = $nodes
    }
}

function Test-ChaosReplicaReadiness {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot) {
        return New-ChaosReadinessGate -Id 'replica-count' -Title 'Workload has redundancy' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail 'Replica count could not be read, so redundancy is unverified. If the workload runs a single replica, every result of this study will read as a total outage caused by the fault rather than by the topology.' `
            -Remediation 'kubectl get pods -n <namespace> -l <selector>' `
            -LimitationCode 'L4'
    }

    if ($Snapshot.ready -le 1) {
        return New-ChaosReadinessGate -Id 'replica-count' -Title 'Workload has redundancy' `
            -Status 'fail' -Severity 'blocking' `
            -Detail "Only $($Snapshot.ready) ready replica(s). With one replica there is no resilience to measure - the fault will cause a total outage and the study will have proved only that the workload is not replicated, which you already know." `
            -Remediation 'kubectl scale deployment/<name> --replicas=3 -n <namespace>'
    }

    return New-ChaosReadinessGate -Id 'replica-count' -Title 'Workload has redundancy' `
        -Status 'pass' -Severity 'blocking' `
        -Detail "$($Snapshot.ready) of $($Snapshot.total) replicas ready across $($Snapshot.distinctNodes) node(s)."
}

function Test-ChaosAntiAffinity {
    <#
    .SYNOPSIS
        Advisory: are all replicas on one node? If so the study will measure
        scheduling topology rather than resilience.
    #>
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot) {
        return New-ChaosReadinessGate -Id 'replica-spread' -Title 'Replicas are spread across nodes' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail 'Pod-to-node placement could not be read.' `
            -LimitationCode 'L4'
    }

    if ($Snapshot.ready -gt 1 -and $Snapshot.distinctNodes -le 1) {
        return New-ChaosReadinessGate -Id 'replica-spread' -Title 'Replicas are spread across nodes' `
            -Status 'fail' -Severity 'advisory' `
            -Detail "All $($Snapshot.ready) ready replicas are on a single node. This is itself a reliability finding: a node-level fault will take the workload to zero availability regardless of replica count." `
            -Remediation 'Add topologySpreadConstraints or podAntiAffinity to the pod spec.' `
            -LimitationCode 'L6'
    }

    return New-ChaosReadinessGate -Id 'replica-spread' -Title 'Replicas are spread across nodes' `
        -Status 'pass' -Severity 'advisory' `
        -Detail "Replicas span $($Snapshot.distinctNodes) node(s)."
}

function Test-ChaosSteadyStatePredicate {
    <#
    .SYNOPSIS
        Blocking: a study without a stated objective cannot fail, so it cannot
        pass either.
    #>
    param([AllowNull()][object]$Predicate)

    if ($null -eq $Predicate -or -not $Predicate.signal -or $null -eq $Predicate.threshold) {
        return New-ChaosReadinessGate -Id 'steady-state' -Title 'Steady state is defined numerically' `
            -Status 'fail' -Severity 'blocking' `
            -Detail 'No steady-state predicate was supplied. Without a signal, a comparison and a threshold stated before injection, there is no definition of "breached", so the study cannot produce a verdict - only a narrative.' `
            -Remediation 'Re-run with -SteadyState "successRate >= 99.5" (or a latency objective).'
    }

    return New-ChaosReadinessGate -Id 'steady-state' -Title 'Steady state is defined numerically' `
        -Status 'pass' -Severity 'blocking' `
        -Detail "Steady state: $($Predicate.signal) $($Predicate.comparison) $($Predicate.threshold)$($Predicate.unit)."
}

function Test-ChaosObservabilityCoverage {
    <#
    .SYNOPSIS
        Advisory: can any data-plane signal prove the fault landed?
    #>
    param(
        [Parameter(Mandatory)][object]$Guide,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AvailableSources
    )

    $coverage = $Guide.dataPlaneProof['coverage']

    if ($AvailableSources.Count -eq 0) {
        return New-ChaosReadinessGate -Id 'observability' -Title 'A data-plane signal can prove the fault landed' `
            -Status 'fail' -Severity 'advisory' `
            -Detail 'No data-plane signal source was configured. The study can still run, but it will only be able to prove that the control plane accepted the experiment - never that the fault reached the workload. Every finding will carry mechanismProven: false.' `
            -Remediation 'Attach a Log Analytics workspace or an Azure Monitor workspace, or make kubectl available.' `
            -LimitationCode 'L3'
    }

    if ($coverage -eq 'weak') {
        return New-ChaosReadinessGate -Id 'observability' -Title 'A data-plane signal can prove the fault landed' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail "The selected fault has weak data-plane proof ($($Guide.dataPlaneProof['signal'])). Even with signal sources available, a clean result may mean the fault did not land rather than that the workload absorbed it." `
            -LimitationCode 'L3'
    }

    return New-ChaosReadinessGate -Id 'observability' -Title 'A data-plane signal can prove the fault landed' `
        -Status 'pass' -Severity 'advisory' `
        -Detail "Proof signal ($coverage coverage): $($Guide.dataPlaneProof['signal']). Sources: $($AvailableSources -join ', ')."
}

function Test-ChaosDisruptionBudget {
    <#
    .SYNOPSIS
        Advisory: without a PDB, graceful faults behave like abrupt ones.
    #>
    param([Parameter(Mandatory)][string]$Namespace)

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        return New-ChaosReadinessGate -Id 'disruption-budget' -Title 'Pod disruption budget exists' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail 'kubectl is unavailable, so pod disruption budgets could not be checked.' `
            -LimitationCode 'L4'
    }

    $output = & kubectl get pdb -n $Namespace -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        return New-ChaosReadinessGate -Id 'disruption-budget' -Title 'Pod disruption budget exists' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail "Pod disruption budgets in namespace '$Namespace' could not be read." `
            -LimitationCode 'L4'
    }

    try {
        $budgets = @(($output | Out-String | ConvertFrom-Json).items)
    } catch {
        return New-ChaosReadinessGate -Id 'disruption-budget' -Title 'Pod disruption budget exists' `
            -Status 'unknown' -Severity 'advisory' `
            -Detail 'Pod disruption budget output could not be parsed.' `
            -LimitationCode 'L4'
    }

    if ($budgets.Count -eq 0) {
        $pdbCommand = "kubectl create poddisruptionbudget <name> --min-available=1 --selector=<selector> -n $Namespace"
        return New-ChaosReadinessGate -Id 'disruption-budget' -Title 'Pod disruption budget exists' `
            -Status 'fail' -Severity 'advisory' `
            -Detail "No pod disruption budget in namespace '$Namespace'. Graceful, drain-based faults will behave identically to abrupt ones, so a graceful study will test less than its name suggests." `
            -Remediation $pdbCommand `
            -LimitationCode 'L7'
    }

    return New-ChaosReadinessGate -Id 'disruption-budget' -Title 'Pod disruption budget exists' `
        -Status 'pass' -Severity 'advisory' `
        -Detail "$($budgets.Count) pod disruption budget(s) in namespace '$Namespace'."
}

function Invoke-ChaosReadinessGates {
    <#
    .SYNOPSIS
        Run every gate and return the collected verdict.
    #>
    param(
        [Parameter(Mandatory)][object]$Guide,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$LabelSelector,
        [AllowNull()][object]$SteadyState,
        [AllowEmptyCollection()][string[]]$AvailableSources = @()
    )

    $snapshot = Get-ChaosWorkloadSnapshot -Namespace $Namespace -LabelSelector $LabelSelector

    $gates = @(
        Test-ChaosSteadyStatePredicate -Predicate $SteadyState
        Test-ChaosReplicaReadiness -Snapshot $snapshot
        Test-ChaosAntiAffinity -Snapshot $snapshot
        Test-ChaosObservabilityCoverage -Guide $Guide -AvailableSources $AvailableSources
        Test-ChaosDisruptionBudget -Namespace $Namespace
    )

    $blockingFailures = @($gates | Where-Object { $_.severity -eq 'blocking' -and $_.status -eq 'fail' })
    $limitations = @($gates | Where-Object { $_.status -ne 'pass' -and $_.limitationCode } | ForEach-Object { $_.limitationCode } | Select-Object -Unique)

    return [pscustomobject]@{
        gates            = $gates
        snapshot         = $snapshot
        ready            = ($blockingFailures.Count -eq 0)
        blockingFailures = $blockingFailures
        limitationCodes  = $limitations
    }
}

function Assert-ChaosReadiness {
    <#
    .SYNOPSIS
        Fail loudly with exit code 10 when a blocking gate failed.
    #>
    param([Parameter(Mandatory)][object]$Readiness)

    if ($Readiness.ready) { return }

    $lines = $Readiness.blockingFailures | ForEach-Object { "  - [$($_.id)] $($_.detail)" }
    $remediation = ($Readiness.blockingFailures | Where-Object { $_.remediation } | Select-Object -First 1).remediation

    Write-ChaosStudyFailure -Title 'Study preconditions not met' `
        -Message ("This study would not produce an interpretable result:`n" + ($lines -join "`n") + "`n`nScoping stopped before writing a study plan.") `
        -Remediation $remediation

    exit (Get-ChaosStudyExitCode -Name 'ReadinessFailed')
}
