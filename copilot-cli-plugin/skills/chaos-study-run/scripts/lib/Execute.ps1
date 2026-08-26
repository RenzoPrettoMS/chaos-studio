#Requires -Version 7.0
<#
.SYNOPSIS
    Consent, plan integrity, and the Chaos Studio experiment lifecycle.

.DESCRIPTION
    Three ideas govern this file.

    Nothing runs without consent. Consent is a phrase the operator types, and
    the phrase contains the cluster, the namespace and a hash of the plan. It
    cannot be given by accident, it cannot be given in advance, and it cannot
    be inherited from an environment variable - this suite deliberately ignores
    STARTCHAOS_NONINTERACTIVE, because "unattended" is not a reason to skip the
    one gate that bounds production risk.

    Consent applies to a specific plan. If the plan changed after it was shown,
    the hash no longer matches and execution stops. The thing consented to is
    provably the thing that runs.

    Injection is always reversible. The experiment is created with a bounded
    duration, and cleanup runs in a finally block so an interrupted study still
    cancels the experiment it started.

    Fault injection uses the Microsoft.Chaos/experiments surface through the
    shared Invoke-AzRest helper (az rest under the hood). The `az chaos`
    extension covers the newer workspace/scenario surface, which is a different
    resource model from the experiment used here.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')

# -- Plan integrity --------------------------------------------------------

function Get-ChaosPlanFingerprint {
    <#
    .SYNOPSIS
        Recompute the plan hash over everything except the hash itself.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $copy = [ordered]@{}
    $names = if ($Plan -is [System.Collections.IDictionary]) { @($Plan.Keys) } else { @($Plan.PSObject.Properties.Name) }
    foreach ($name in $names) {
        if ($name -eq 'frozenConfigHash') { continue }
        $copy["$name"] = if ($Plan -is [System.Collections.IDictionary]) { $Plan[$name] } else { $Plan.$name }
    }
    return Get-ChaosDigest -InputObject $copy
}

function Assert-ChaosPlanIntegrity {
    <#
    .SYNOPSIS
        Refuse to run a plan that was edited after it was frozen.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $declared = $Plan.frozenConfigHash
    $actual = Get-ChaosPlanFingerprint -Plan $Plan
    if ($declared -eq $actual) { return $true }

    Write-ChaosStudyFailure -Title 'The plan changed after it was frozen' -Message @"
This plan declares frozenConfigHash $declared but its current contents hash to $actual.

Consent is bound to a specific plan. Because the contents no longer match, any
consent given for this study refers to something other than what would run, so
execution stops here.
"@ -Remediation 'Re-run chaos-study-scope to produce a fresh, self-consistent plan.'
    exit (Get-ChaosStudyExitCode -Name 'ConfigurationDrift')
}

# -- Consent ---------------------------------------------------------------

function Get-ChaosConsentPhrase {
    <#
    .SYNOPSIS
        The exact phrase the operator must type to authorise injection.

    .DESCRIPTION
        The phrase names the blast radius (cluster and namespace) so it cannot
        be typed without reading it, and carries the plan hash so it cannot be
        reused for a different plan.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $shortHash = ([string]$Plan.frozenConfigHash).Substring(0, 8)
    return "inject $($Plan.fault.guide) into $($Plan.target.resourceName)/$($Plan.target.namespace) $shortHash"
}

function Assert-ChaosConsent {
    <#
    .SYNOPSIS
        Stop unless the operator supplied the exact consent phrase.

    .DESCRIPTION
        Deliberately ignores STARTCHAOS_NONINTERACTIVE. Every other gate in
        this suite can be relaxed for automation; this one cannot, because it
        is the only thing standing between a script and a production incident.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [AllowNull()][AllowEmptyString()][string]$Consent
    )

    $expected = Get-ChaosConsentPhrase -Plan $Plan
    if ($Consent -and $Consent.Trim() -ceq $expected) { return $true }

    $reason = if ([string]::IsNullOrWhiteSpace($Consent)) {
        'No consent phrase was supplied.'
    } else {
        'The consent phrase did not match this plan exactly (comparison is case-sensitive).'
    }

    Write-ChaosStudyFailure -Title 'Injection not authorised' -Message @"
$reason

This study would inject $($Plan.fault.displayName) into
  cluster   $($Plan.target.resourceName)
  namespace $($Plan.target.namespace)
  selector  $(if ($Plan.target.selector) { $Plan.target.selector } else { '(all workloads in the namespace)' })
for $($Plan.windows.injectMinutes) minutes.

To authorise it, pass this phrase exactly:

  $expected
"@ -Remediation "-DryRun:`$false -Consent '$expected'"
    exit (Get-ChaosStudyExitCode -Name 'ConsentDeclined')
}

# -- Experiment definition -------------------------------------------------

function ConvertTo-ChaosFaultParameters {
    <#
    .SYNOPSIS
        Turn a plan's parameter map into the key/value list the experiment API
        expects.

    .DESCRIPTION
        Chaos Mesh faults take the whole specification as a single jsonSpec
        string. Service-direct faults take flat key/value pairs, with non-scalar
        values JSON-encoded.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan
    )

    $parameters = $Plan.fault.parameters
    $isChaosMesh = ([string]$Plan.fault.targetType) -like '*ChaosMesh*'

    if ($isChaosMesh) {
        $spec = ConvertTo-ChaosCanonical -InputObject $parameters
        return @(@{ key = 'jsonSpec'; value = ($spec | ConvertTo-Json -Depth 32 -Compress) })
    }

    $pairs = @()
    $names = if ($parameters -is [System.Collections.IDictionary]) { @($parameters.Keys) } else { @($parameters.PSObject.Properties.Name) }
    foreach ($name in $names) {
        $value = if ($parameters -is [System.Collections.IDictionary]) { $parameters[$name] } else { $parameters.$name }
        $encoded = if ($value -is [string]) {
            $value
        } elseif ($value -is [bool]) {
            $value.ToString().ToLowerInvariant()
        } elseif ($value -is [System.Collections.IEnumerable]) {
            ConvertTo-ChaosCanonicalJson -InputObject $value
        } else {
            [string]$value
        }
        $pairs += @{ key = "$name"; value = $encoded }
    }
    return ,@($pairs)
}

function New-ChaosExperimentDefinition {
    <#
    .SYNOPSIS
        Build the experiment body for this plan.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$Location
    )

    $targetId = "$($Plan.target.resourceId)/providers/Microsoft.Chaos/targets/$($Plan.fault.targetType)"
    $duration = "PT$($Plan.windows.injectMinutes)M"

    return [ordered]@{
        location   = $Location
        identity   = [ordered]@{ type = 'SystemAssigned' }
        properties = [ordered]@{
            selectors = @(
                [ordered]@{
                    type    = 'List'
                    id      = 'studySelector'
                    targets = @([ordered]@{ type = 'ChaosTarget'; id = $targetId })
                }
            )
            steps     = @(
                [ordered]@{
                    name     = 'inject'
                    branches = @(
                        [ordered]@{
                            name    = 'primary'
                            actions = @(
                                [ordered]@{
                                    type       = 'continuous'
                                    name       = $Plan.fault.faultUrn
                                    selectorId = 'studySelector'
                                    duration   = $duration
                                    parameters = @(ConvertTo-ChaosFaultParameters -Plan $Plan)
                                }
                            )
                        }
                    )
                }
            )
        }
    }
}

# -- Experiment lifecycle --------------------------------------------------

function Get-ChaosExperimentUri {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName
    )
    return "/subscriptions/$($Plan.target.subscriptionId)/resourceGroups/$($Plan.target.resourceGroup)/providers/Microsoft.Chaos/experiments/$ExperimentName"
}

function New-ChaosStudyExperiment {
    <#
    .SYNOPSIS
        Create (or replace) the experiment resource for this study.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName,
        [Parameter(Mandatory)][string]$Location
    )
    $body = New-ChaosExperimentDefinition -Plan $Plan -Location $Location
    $uri = Get-ChaosExperimentUri -Plan $Plan -ExperimentName $ExperimentName
    $response = Invoke-AzRest -Method PUT -Uri $uri -Body $body -ApiVersion (Get-ChaosApiVersion -Name 'chaosClassic')
    return $response.body
}

function Start-ChaosStudyExperiment {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName
    )
    $uri = "$(Get-ChaosExperimentUri -Plan $Plan -ExperimentName $ExperimentName)/start"
    $response = Invoke-AzRest -Method POST -Uri $uri -ApiVersion (Get-ChaosApiVersion -Name 'chaosClassic')
    return $response.body
}

function Stop-ChaosStudyExperiment {
    <#
    .SYNOPSIS
        Cancel a running experiment. Best effort by design: this runs on the
        failure path, where throwing again would hide the original fault.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName
    )
    try {
        $uri = "$(Get-ChaosExperimentUri -Plan $Plan -ExperimentName $ExperimentName)/cancel"
        Invoke-AzRest -Method POST -Uri $uri -ApiVersion (Get-ChaosApiVersion -Name 'chaosClassic') | Out-Null
        return $true
    } catch {
        Write-ChaosStudyNote -Message "Could not cancel experiment '$ExperimentName': $($_.Exception.Message)" -Level 'warn'
        return $false
    }
}

function Remove-ChaosStudyExperiment {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName
    )
    try {
        $uri = Get-ChaosExperimentUri -Plan $Plan -ExperimentName $ExperimentName
        Invoke-AzRest -Method DELETE -Uri $uri -ApiVersion (Get-ChaosApiVersion -Name 'chaosClassic') | Out-Null
        return $true
    } catch {
        Write-ChaosStudyNote -Message "Could not delete experiment '$ExperimentName': $($_.Exception.Message)" -Level 'warn'
        return $false
    }
}

function Get-ChaosExperimentExecution {
    <#
    .SYNOPSIS
        The latest execution's status, or $null when it cannot be read.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName
    )
    try {
        $uri = "$(Get-ChaosExperimentUri -Plan $Plan -ExperimentName $ExperimentName)/executions"
        $response = Invoke-AzRest -Method GET -Uri $uri -ApiVersion (Get-ChaosApiVersion -Name 'chaosClassic')
        $executions = @($response.body.value)
        if ($executions.Count -eq 0) { return $null }
        return ($executions | Sort-Object -Property { $_.properties.startedAt } -Descending | Select-Object -First 1)
    } catch {
        return $null
    }
}

function Wait-ChaosExperimentWindow {
    <#
    .SYNOPSIS
        Hold for the injection window, watching the experiment as it runs.

    .DESCRIPTION
        Returns the observed status transitions. A status that cannot be read
        is recorded as unknown rather than assumed healthy - the report needs to
        be able to say "we could not see it" instead of implying success.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ExperimentName,
        [Parameter(Mandatory)][int]$Minutes,
        [int]$PollSeconds = 20
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes($Minutes)
    $observations = @()
    $seen = @{}

    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $execution = Get-ChaosExperimentExecution -Plan $Plan -ExperimentName $ExperimentName
        $status = if ($execution -and $execution.properties) { [string]$execution.properties.status } else { 'unknown' }
        if (-not $seen.ContainsKey($status)) {
            $seen[$status] = $true
            $observations += [ordered]@{ at = Get-ChaosUtcNow; status = $status }
            Write-ChaosStudyNote -Message "Experiment status: $status"
        }
        if ($status -in @('Failed', 'Cancelled')) { break }

        $remaining = ($deadline - (Get-Date).ToUniversalTime()).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([Math]::Min($PollSeconds, [Math]::Max(1, [int]$remaining)))
    }

    if ($observations.Count -eq 0) {
        $observations += [ordered]@{ at = Get-ChaosUtcNow; status = 'unknown' }
    }
    return ,@($observations)
}

function Get-ChaosStudyExperimentName {
    <#
    .SYNOPSIS
        A deterministic, collision-resistant experiment name for a study.
    #>
    param([Parameter(Mandatory)][string]$StudyId)
    $suffix = ($StudyId -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if ($suffix.Length -gt 40) { $suffix = $suffix.Substring($suffix.Length - 40) }
    return "chaos-study-$suffix"
}
