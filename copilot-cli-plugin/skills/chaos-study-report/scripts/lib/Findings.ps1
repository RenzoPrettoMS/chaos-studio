#Requires -Version 7.0
<#
.SYNOPSIS
    Turn evidence into findings. Pure logic, no side effects.

.DESCRIPTION
    Every function here is a pure function of its arguments. No file access, no
    network, no clock, no `az`. That is deliberate: interpretation is the part
    of the pipeline most likely to be wrong, and the only way to argue about it
    is to be able to run it on fixed inputs and get a fixed answer.

    Two rules do most of the work.

    A control-plane success is not proof. Chaos Studio reporting an experiment
    as Succeeded means the fault was accepted, not that it reached the data
    plane. Only a data-plane signal that actually moved can set mechanismProven,
    and without it the verdict is Inconclusive rather than a pass.

    A gap is not a zero. A signal that could not be read is null with a caveat,
    and it lowers confidence instead of quietly becoming a healthy number.
#>

Set-StrictMode -Version Latest

$script:ChaosLimitationText = [ordered]@{
    L1 = 'Scope - this study covers one fault, one target and one window'
    L2 = 'Observability coverage - at least one signal source was unavailable'
    L3 = 'Mechanism unproven - the control plane accepted the fault but no data-plane signal confirmed it landed'
    L4 = 'Sampling resolution - metric granularity is coarser than the injection window'
    L5 = 'Environment - conditions were not representative of production load'
    L6 = 'Concurrency - other activity during the window could confound the result'
    L7 = 'Duration - the window may be too short to observe slow failure modes'
    L8 = 'Aborted - the run stopped before the planned window completed'
    L9 = 'Configuration drift - the target changed between planning and execution'
}

function Get-ChaosLimitationText {
    param([Parameter(Mandatory)][string]$Code)
    if ($script:ChaosLimitationText.Contains($Code)) { return $script:ChaosLimitationText[$Code] }
    return $Code
}

function Get-ChaosSignalValue {
    <#
    .SYNOPSIS
        Pull one named measurement out of a collected signal, or $null.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Signal,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Signal -or $null -eq $Signal.values) { return $null }
    $values = $Signal.values
    $names = if ($values -is [System.Collections.IDictionary]) { @($values.Keys) } else { @($values.PSObject.Properties.Name) }
    if ($names -notcontains $Name) { return $null }
    return $(if ($values -is [System.Collections.IDictionary]) { $values[$Name] } else { $values.$Name })
}

function Test-ChaosPredicate {
    <#
    .SYNOPSIS
        Evaluate a steady-state predicate against a measurement.

    .OUTPUTS
        $true held, $false breached, $null not measurable.
    #>
    param(
        [Parameter(Mandatory)][object]$Predicate,
        [AllowNull()][object]$Value
    )
    if ($null -eq $Value) { return $null }
    $threshold = [double]$Predicate.threshold
    $actual = [double]$Value
    switch ([string]$Predicate.comparison) {
        '>=' { return $actual -ge $threshold }
        '>'  { return $actual -gt $threshold }
        '<=' { return $actual -le $threshold }
        '<'  { return $actual -lt $threshold }
        '==' { return $actual -eq $threshold }
        '!=' { return $actual -ne $threshold }
        default { return $null }
    }
}

function Get-ChaosReadinessDelta {
    <#
    .SYNOPSIS
        Did the Kubernetes readiness signal actually move between two windows?

    .DESCRIPTION
        This is the data-plane proof for the Kubernetes vertical. A drop in ready
        pods, or a rise in restarts, means the fault reached the workload.
    #>
    param(
        [AllowNull()][object]$Before,
        [AllowNull()][object]$During
    )

    $readyBefore = Get-ChaosSignalValue -Signal $Before -Name 'readyPods'
    $readyDuring = Get-ChaosSignalValue -Signal $During -Name 'readyPods'
    $restartBefore = Get-ChaosSignalValue -Signal $Before -Name 'restartTotal'
    $restartDuring = Get-ChaosSignalValue -Signal $During -Name 'restartTotal'

    if ($null -eq $readyDuring -and $null -eq $restartDuring) {
        return [pscustomobject]@{ moved = $null; detail = 'No Kubernetes readiness measurement was available during injection.' }
    }

    $readyDropped = ($null -ne $readyBefore -and $null -ne $readyDuring -and [int]$readyDuring -lt [int]$readyBefore)
    $restartsRose = ($null -ne $restartBefore -and $null -ne $restartDuring -and [int]$restartDuring -gt [int]$restartBefore)

    if ($readyDropped -or $restartsRose) {
        $parts = @()
        if ($readyDropped) { $parts += "ready pods fell from $readyBefore to $readyDuring" }
        if ($restartsRose) { $parts += "restarts rose from $restartBefore to $restartDuring" }
        return [pscustomobject]@{ moved = $true; detail = ($parts -join '; ') }
    }

    return [pscustomobject]@{
        moved  = $false
        detail = "Kubernetes readiness did not change during injection (ready pods $readyBefore then $readyDuring)."
    }
}

function New-ChaosFinding {
    <#
    .SYNOPSIS
        Build one finding. Evidence is mandatory - a finding without evidence is
        an opinion, and opinions do not go in the report.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('critical', 'high', 'medium', 'low')][string]$Severity,
        [Parameter(Mandatory)][ValidateSet('high', 'medium', 'low')][string]$Confidence,
        [Parameter(Mandatory)][string]$Observation,
        [Parameter(Mandatory)][string]$Interpretation,
        [Parameter(Mandatory)][object[]]$Evidence,
        [string[]]$Remediation = @()
    )
    if (@($Evidence).Count -eq 0) {
        throw "Finding '$Key' has no evidence reference. Findings must cite the signal and window they rest on."
    }
    return [ordered]@{
        findingKey     = $Key
        title          = $Title
        severity       = $Severity
        confidence     = $Confidence
        observation    = $Observation
        interpretation = $Interpretation
        evidence       = @($Evidence)
        remediation    = @($Remediation)
    }
}

function Get-ChaosFindingKey {
    <#
    .SYNOPSIS
        A stable identity for a finding, so the same issue matches across runs
        even when its wording changes.
    #>
    param(
        [Parameter(Mandatory)][string]$FaultUrn,
        [Parameter(Mandatory)][string]$Signal,
        [Parameter(Mandatory)][string]$Predicate
    )
    return Get-ChaosDigest -InputObject @($FaultUrn, $Signal, $Predicate)
}

function Get-ChaosVerdict {
    <#
    .SYNOPSIS
        One sentence a reader can quote.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][AllowNull()][object]$MechanismProven
    )
    $severities = @($Findings | ForEach-Object { $_.severity })
    if ($severities -contains 'critical') { return 'Steady state breached' }
    if ($MechanismProven -ne $true) { return 'Inconclusive' }
    if ($severities -contains 'high' -or $severities -contains 'medium') { return 'Degraded but recovered' }
    return 'Steady state held'
}

function Build-StudyFindings {
    <#
    .SYNOPSIS
        Interpret one study. Pure: same inputs, same output, always.

    .PARAMETER Plan
        The frozen study plan.

    .PARAMETER RunRecord
        The run record produced by chaos-study-run.

    .PARAMETER Evidence
        A hashtable with pre / during / post keys, each an array of signal
        results.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$RunRecord,
        [Parameter(Mandatory)][object]$Evidence
    )

    $pre = @($Evidence.pre)
    $during = @($Evidence.during)
    $post = @($Evidence.post)

    $k8sPre = $pre | Where-Object { $_.source -eq 'k8s' } | Select-Object -First 1
    $k8sDuring = $during | Where-Object { $_.source -eq 'k8s' } | Select-Object -First 1
    $k8sPost = $post | Where-Object { $_.source -eq 'k8s' } | Select-Object -First 1

    $delta = Get-ChaosReadinessDelta -Before $k8sPre -During $k8sDuring
    $mechanismProven = $delta.moved -eq $true

    $predicate = $Plan.question.steadyState
    $signalName = [string]$predicate.signal

    $findByName = {
        param($set)
        $match = @($set) | Where-Object { $_.source -eq "metrics:$signalName" -or $_.source -eq $signalName } | Select-Object -First 1
        if ($match) { return $match }
        return $null
    }

    $predicateDuring = Test-ChaosPredicate -Predicate $predicate -Value (Get-ChaosSignalValue -Signal (& $findByName $during) -Name 'value')
    $predicatePost = Test-ChaosPredicate -Predicate $predicate -Value (Get-ChaosSignalValue -Signal (& $findByName $post) -Name 'value')

    $findings = @()
    $limitations = @('L1')

    $predicateKey = Get-ChaosFindingKey -FaultUrn $Plan.fault.faultUrn -Signal $signalName -Predicate $predicate.raw

    if ($predicateDuring -eq $false) {
        # Severity is a function of recovery, not of how bad it looked at peak.
        $severity = if ($predicatePost -eq $false) { 'critical' } elseif ($null -eq $predicatePost) { 'high' } else { 'medium' }
        $recovery = switch ($predicatePost) {
            $true   { 'The predicate held again after injection stopped.' }
            $false  { 'The predicate was still breached after the recovery window, so the system did not self-heal.' }
            default { 'Recovery could not be confirmed because the signal was unavailable after injection.' }
        }
        $findings += New-ChaosFinding -Key $predicateKey `
            -Title "Steady state breached: $($predicate.raw)" `
            -Severity $severity -Confidence $(if ($mechanismProven) { 'high' } else { 'medium' }) `
            -Observation "During injection, $signalName violated '$($predicate.raw)'." `
            -Interpretation "The fault produced user-visible degradation. $recovery" `
            -Evidence @(
                [ordered]@{ signal = $signalName; window = 'during'; kind = 'predicate' }
                [ordered]@{ signal = $signalName; window = 'post'; kind = 'predicate' }
            ) `
            -Remediation @(
                "Bound the blast radius of this failure mode for $($Plan.target.resourceName)/$($Plan.target.namespace) - add replicas, spread them across zones, or add a circuit breaker on the dependency the fault interrupted."
                'Add an alert on this predicate so the same degradation is detected without a chaos study.'
            )
    } elseif ($null -eq $predicateDuring) {
        $limitations += 'L2'
        $findings += New-ChaosFinding -Key $predicateKey `
            -Title "Steady state could not be evaluated: $($predicate.raw)" `
            -Severity 'medium' -Confidence 'low' `
            -Observation "No measurement of $signalName was available for the injection window." `
            -Interpretation 'The study cannot say whether the service held, because the signal that defines "held" was not being collected. This is a gap in observability, not a clean result.' `
            -Evidence @([ordered]@{ signal = $signalName; window = 'during'; kind = 'missing' }) `
            -Remediation @(
                "Instrument $signalName and make it queryable before repeating this study - a resilience test without its steady-state signal cannot pass or fail."
            )
    }

    if (-not $mechanismProven) {
        $limitations += 'L3'
        $evidenceRef = @([ordered]@{ signal = 'k8s'; window = 'during'; kind = 'mechanism' })
        $findings += New-ChaosFinding -Key (Get-ChaosFindingKey -FaultUrn $Plan.fault.faultUrn -Signal 'mechanism' -Predicate 'data-plane-proof') `
            -Title 'Fault injection was not proven to reach the workload' `
            -Severity 'low' -Confidence $(if ($null -eq $delta.moved) { 'low' } else { 'medium' }) `
            -Observation $delta.detail `
            -Interpretation 'Chaos Studio reporting success means the fault was accepted by the control plane. Without a data-plane signal that moved, a clean result may mean the service is resilient - or that nothing was ever injected. These are not the same, and this study cannot tell them apart.' `
            -Evidence $evidenceRef `
            -Remediation @(
                'Confirm the in-cluster agent or Chaos Mesh installation is healthy, then repeat the study.'
                'Widen the blast radius slightly (for example mode: fixed-percent) so the effect is large enough to observe.'
            )
    }

    $missing = @(@($pre + $during + $post) | Where-Object { $null -eq $_.values })
    if ($missing.Count -gt 0 -and $limitations -notcontains 'L2') { $limitations += 'L2' }
    if ([int]$Plan.windows.injectMinutes -le 3) { $limitations += 'L7' }
    if ($RunRecord.experiment.outcome -in @('Failed', 'Cancelled')) { $limitations += 'L8' }
    if ($RunRecord.planHash -ne $Plan.frozenConfigHash) { $limitations += 'L9' }
    foreach ($code in @($Plan.readiness.limitationCodes)) {
        if ($code -and $limitations -notcontains $code) { $limitations += $code }
    }

    $order = @{ critical = 0; high = 1; medium = 2; low = 3 }
    $sorted = @($findings | Sort-Object -Property @{ Expression = { $order[$_.severity] } }, @{ Expression = { $_.title } })

    return [ordered]@{
        findingsVersion = 'findings.v1'
        studyId         = $RunRecord.studyId
        scopeHash       = $RunRecord.scopeHash
        planHash        = $Plan.frozenConfigHash
        verdict         = Get-ChaosVerdict -Findings $sorted -MechanismProven $mechanismProven
        mechanismProven = $mechanismProven
        mechanismDetail = $delta.detail
        predicate       = [ordered]@{
            raw    = $predicate.raw
            during = $predicateDuring
            post   = $predicatePost
        }
        findings        = @($sorted)
        limitations     = @(
            foreach ($code in ($limitations | Select-Object -Unique | Sort-Object)) {
                [ordered]@{ code = $code; text = Get-ChaosLimitationText -Code $code }
            }
        )
    }
}
