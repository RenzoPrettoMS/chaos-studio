#Requires -Version 7.0
<#
.SYNOPSIS
    Compare two sealed studies. Pure logic, no side effects.

.DESCRIPTION
    Comparison is only meaningful between studies that asked the same question of
    the same thing. Two runs that used different faults, different targets or a
    different steady-state definition produce numbers that look comparable and
    are not - which is worse than refusing to compare them.

    So comparability is checked first and explicitly. If the studies do not
    match on identity, this returns a refusal with the reasons, and the caller
    exits rather than printing a misleading delta.

    Findings are matched on findingKey, never on title. Titles are prose and
    change; the key is derived from fault, signal and predicate and does not.
#>

Set-StrictMode -Version Latest

function Get-ChaosWindowTolerance {
    <#
    .SYNOPSIS
        Two windows are the same length if they are within 20% of each other.
        Chaos runs never land on exact durations; demanding equality would make
        almost nothing comparable.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Left,
        [Parameter(Mandatory)][AllowNull()][object]$Right
    )
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $a = [double]$Left
    $b = [double]$Right
    if ($a -le 0 -or $b -le 0) { return $a -eq $b }
    $ratio = [Math]::Abs($a - $b) / [Math]::Max($a, $b)
    return $ratio -le 0.20
}

function ConvertTo-ChaosNormalisedPredicate {
    <#
    .SYNOPSIS
        Collapse whitespace and case so 'successRate>=99.5' and
        'successRate >= 99.5' are recognised as the same objective.
    #>
    param([AllowNull()][string]$Raw)
    if (-not $Raw) { return '' }
    return ([regex]::Replace($Raw, '\s+', '')).ToLowerInvariant()
}

function Get-ChaosStudyIdentityFacts {
    <#
    .SYNOPSIS
        The subset of a sealed manifest that decides comparability.
    #>
    param([Parameter(Mandatory)][object]$Study)

    $identity = $Study.identity
    return [pscustomobject]@{
        studyId   = [string]$Study.studyId
        scopeHash = [string]$Study.scopeHash
        target    = [string]$identity.target
        faultUrn  = [string]$identity.faultUrn
        faultPath = [string]$identity.faultPath
        predicate = ConvertTo-ChaosNormalisedPredicate -Raw ([string]$identity.predicate)
        windows   = $identity.windows
        verdict   = [string]$Study.summary.verdict
    }
}

function Test-ChaosStudyComparability {
    <#
    .SYNOPSIS
        Can these two studies be compared at all?

    .OUTPUTS
        An object with `comparable` and the list of `reasons` it is not.
    #>
    param(
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][object]$Candidate
    )

    $a = Get-ChaosStudyIdentityFacts -Study $Baseline
    $b = Get-ChaosStudyIdentityFacts -Study $Candidate
    $reasons = @()

    if ($a.scopeHash -ne $b.scopeHash) { $reasons += "Different scope: $($a.scopeHash) vs $($b.scopeHash)." }
    if ($a.target -ne $b.target) { $reasons += "Different target: $($a.target) vs $($b.target)." }
    if ($a.faultUrn -ne $b.faultUrn) { $reasons += "Different fault: $($a.faultUrn) vs $($b.faultUrn)." }
    if ($a.faultPath -ne $b.faultPath) { $reasons += "Different fault path: $($a.faultPath) vs $($b.faultPath). A fault delivered by a different mechanism is a different experiment." }
    if ($a.predicate -ne $b.predicate) { $reasons += "Different steady-state objective: '$($Baseline.identity.predicate)' vs '$($Candidate.identity.predicate)'." }

    foreach ($window in @('baselineMinutes', 'injectMinutes', 'recoveryMinutes')) {
        $left = if ($a.windows -and $a.windows.PSObject.Properties.Name -contains $window) { $a.windows.$window } else { $null }
        $right = if ($b.windows -and $b.windows.PSObject.Properties.Name -contains $window) { $b.windows.$window } else { $null }
        if (-not (Get-ChaosWindowTolerance -Left $left -Right $right)) {
            $reasons += "Different $window window: $left vs $right (outside the 20% tolerance)."
        }
    }

    return [pscustomobject]@{
        comparable = ($reasons.Count -eq 0)
        reasons    = @($reasons)
    }
}

function Compare-Study {
    <#
    .SYNOPSIS
        Diff two sealed studies. Pure: same inputs, same output, always.

    .PARAMETER Baseline
        The earlier study index entry, with its findings attached as `findings`.

    .PARAMETER Candidate
        The later study index entry, with its findings attached as `findings`.
    #>
    param(
        [Parameter(Mandatory)][object]$Baseline,
        [Parameter(Mandatory)][object]$Candidate
    )

    $comparability = Test-ChaosStudyComparability -Baseline $Baseline -Candidate $Candidate

    $baseFindings = @($Baseline.findings)
    $candFindings = @($Candidate.findings)
    $baseKeys = @($baseFindings | ForEach-Object { [string]$_.findingKey })
    $candKeys = @($candFindings | ForEach-Object { [string]$_.findingKey })

    $resolved = @($baseFindings | Where-Object { $candKeys -notcontains [string]$_.findingKey })
    $introduced = @($candFindings | Where-Object { $baseKeys -notcontains [string]$_.findingKey })

    $persisted = @(
        foreach ($finding in $candFindings) {
            $match = $baseFindings | Where-Object { [string]$_.findingKey -eq [string]$finding.findingKey } | Select-Object -First 1
            if (-not $match) { continue }
            $order = @{ critical = 0; high = 1; medium = 2; low = 3 }
            $movement = if ($order[[string]$finding.severity] -lt $order[[string]$match.severity]) { 'worse' }
                        elseif ($order[[string]$finding.severity] -gt $order[[string]$match.severity]) { 'better' }
                        else { 'unchanged' }
            [ordered]@{
                findingKey   = [string]$finding.findingKey
                title        = [string]$finding.title
                wasSeverity  = [string]$match.severity
                nowSeverity  = [string]$finding.severity
                movement     = $movement
            }
        }
    )

    $verdictChanged = ([string]$Baseline.summary.verdict) -ne ([string]$Candidate.summary.verdict)
    $direction = if (-not $comparability.comparable) { 'unknown' }
                 elseif ($introduced.Count -gt 0) { 'regressed' }
                 elseif ($resolved.Count -gt 0 -and $introduced.Count -eq 0) { 'improved' }
                 elseif (@($persisted | Where-Object { $_.movement -eq 'worse' }).Count -gt 0) { 'regressed' }
                 elseif (@($persisted | Where-Object { $_.movement -eq 'better' }).Count -gt 0) { 'improved' }
                 else { 'stable' }

    return [ordered]@{
        comparisonVersion = 'study-comparison.v1'
        comparable        = $comparability.comparable
        reasons           = @($comparability.reasons)
        baseline          = [ordered]@{ studyId = [string]$Baseline.studyId; sealedAt = [string]$Baseline.sealedAt; verdict = [string]$Baseline.summary.verdict }
        candidate         = [ordered]@{ studyId = [string]$Candidate.studyId; sealedAt = [string]$Candidate.sealedAt; verdict = [string]$Candidate.summary.verdict }
        verdictChanged    = $verdictChanged
        direction         = $direction
        resolved          = @($resolved | ForEach-Object { [ordered]@{ findingKey = [string]$_.findingKey; title = [string]$_.title; severity = [string]$_.severity } })
        introduced        = @($introduced | ForEach-Object { [ordered]@{ findingKey = [string]$_.findingKey; title = [string]$_.title; severity = [string]$_.severity } })
        persisted         = @($persisted)
    }
}
