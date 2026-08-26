#Requires -Version 7.0
<#
.SYNOPSIS
    Decides whether a discovered action can actually be delivered to a resource.

.DESCRIPTION
    Discovery answers "does this action exist?". It does not answer "can it
    reach this resource?" - that depends on onboarding state which is per
    resource, not per region. A plan that names an action the platform cannot
    deliver is worse than no plan: it burns a change window and produces a null
    result that looks like a pass.

    Two things must be true. The Chaos Studio target must be enabled on the
    resource, and the capability behind the action must be registered under it.
    Both are read from ARM; neither is assumed.

    Every probe returns an explicit `available` tri-state: $true, $false, or
    $null for "could not determine". $null is never coerced to $false, because
    "we could not check" and "it is not there" lead to different next actions.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')
. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'ApiVersions.ps1')

function New-ChaosProbeResult {
    <#
    .SYNOPSIS
        The one shape every delivery probe returns.
    #>
    param(
        [Parameter(Mandatory)][string]$Check,
        [AllowNull()][object]$Available = $null,
        [AllowNull()][AllowEmptyString()][string]$Detail = $null,
        [AllowNull()][AllowEmptyString()][string]$Remediation = $null,
        [AllowNull()][object]$Evidence = $null
    )
    if ($null -eq $Available -and [string]::IsNullOrWhiteSpace($Detail)) {
        throw "New-ChaosProbeResult: an indeterminate result for check '$Check' must carry a detail explaining why."
    }
    return [pscustomobject]@{
        check       = $Check
        available   = $Available
        detail      = $Detail
        remediation = $Remediation
        evidence    = $Evidence
    }
}

function Get-ChaosTargetsUri {
    param([Parameter(Mandatory)][string]$ResourceId)
    return "$($ResourceId.TrimEnd('/'))/providers/Microsoft.Chaos/targets"
}

function Test-ChaosTargetEnabled {
    <#
    .SYNOPSIS
        Is a Chaos Studio target enabled on this resource?

    .DESCRIPTION
        The enabled targets are listed rather than guessed by name. Target
        resource names are assigned by Chaos Studio and are not the ARM resource
        type, so constructing one from the type the actions endpoint reports
        would be a guess dressed up as a fact. Listing returns the real names,
        which is what the experiment body has to address.

        Exactly one enabled target is the unambiguous case. Several enabled
        targets is not a failure, but it is not automatically resolvable either,
        so it is reported as indeterminate rather than resolved by heuristic.
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$TargetType
    )

    $uri = Get-ChaosTargetsUri -ResourceId $ResourceId
    $apiVersion = Get-ChaosApiVersion -Name 'chaosStudio'

    try {
        $response = Invoke-AzRest -Method GET -Uri $uri -ApiVersion $apiVersion
    } catch {
        $message = $_.Exception.Message
        if ($message -match '(?i)notfound|404|ResourceNotFound') {
            return New-ChaosProbeResult -Check 'target-enabled' -Available $false `
                -Detail "No Chaos Studio target is enabled on $ResourceId." `
                -Remediation "Onboard the resource to Chaos Studio, then re-run scoping."
        }
        return New-ChaosProbeResult -Check 'target-enabled' -Available $null `
            -Detail "Could not list Chaos Studio targets on $ResourceId`: $message" `
            -Remediation 'Confirm the signed-in principal has Reader on the resource, then re-run scoping.'
    }

    $targets = @()
    if ($response.body -and $response.body.PSObject.Properties.Name -contains 'value') {
        $targets = @($response.body.value | Where-Object { $null -ne $_ })
    }

    if ($targets.Count -eq 0) {
        return New-ChaosProbeResult -Check 'target-enabled' -Available $false `
            -Detail "No Chaos Studio target is enabled on $ResourceId, so '$TargetType' actions cannot be delivered to it." `
            -Remediation "Onboard the resource to Chaos Studio, then re-run scoping."
    }

    if ($targets.Count -gt 1) {
        $names = @($targets | ForEach-Object { $_.name }) -join ', '
        return New-ChaosProbeResult -Check 'target-enabled' -Available $null `
            -Detail "More than one Chaos Studio target is enabled on $ResourceId ($names), so the one this study should address is ambiguous." `
            -Remediation 'Disable the targets this study is not about, or scope the study to a resource with a single enabled target.' `
            -Evidence $targets
    }

    return New-ChaosProbeResult -Check 'target-enabled' -Available $true `
        -Detail "Chaos Studio target '$($targets[0].name)' is enabled." `
        -Evidence $targets[0]
}

function Test-ChaosCapabilityEnabled {
    <#
    .SYNOPSIS
        Is a capability registered under the target whose URN matches the
        action the service advertised?

    .DESCRIPTION
        The match is on the canonical URN the actions endpoint returned, not on
        a name pattern. If the enabled capability reports a different version
        than the action being planned, that is a mismatch worth stopping for:
        the study would document one fault and inject another.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetUri,
        [Parameter(Mandatory)][string]$ExpectedFaultUrn
    )

    $uri = "$($TargetUri.TrimEnd('/'))/capabilities"
    $apiVersion = Get-ChaosApiVersion -Name 'chaosStudio'

    try {
        $response = Invoke-AzRest -Method GET -Uri $uri -ApiVersion $apiVersion
    } catch {
        return New-ChaosProbeResult -Check 'capability-enabled' -Available $null `
            -Detail "Could not list capabilities under $TargetUri`: $($_.Exception.Message)" `
            -Remediation 'Confirm the target is enabled and the principal has Reader, then re-run scoping.'
    }

    $capabilities = @()
    if ($response.body -and $response.body.PSObject.Properties.Name -contains 'value') {
        $capabilities = @($response.body.value)
    }

    $urns = @()
    foreach ($capability in $capabilities) {
        if ($null -eq $capability) { continue }
        if ($capability.PSObject.Properties.Name -notcontains 'properties') { continue }
        if ($capability.properties.PSObject.Properties.Name -notcontains 'urn') { continue }
        $urns += [string]$capability.properties.urn
    }

    $match = $capabilities | Where-Object {
        $_.PSObject.Properties.Name -contains 'properties' -and
        $_.properties.PSObject.Properties.Name -contains 'urn' -and
        ([string]$_.properties.urn) -eq $ExpectedFaultUrn
    } | Select-Object -First 1

    if ($match) {
        return New-ChaosProbeResult -Check 'capability-enabled' -Available $true `
            -Detail "A capability with URN '$ExpectedFaultUrn' is enabled on this target." `
            -Evidence $match
    }

    # No exact URN match. Distinguish "the fault is absent" from "a different
    # version of it is enabled" - the remediation differs.
    $family = ($ExpectedFaultUrn -split '/')[0]
    $sameFamily = @($urns | Where-Object { $_ -like "$family/*" })

    if ($sameFamily.Count -gt 0) {
        return New-ChaosProbeResult -Check 'capability-enabled' -Available $false `
            -Detail "The service advertises '$ExpectedFaultUrn', but the capability enabled on this target reports '$($sameFamily -join ', ')'. Running this study would inject a different version of the fault than the plan documents." `
            -Remediation 'Re-enable the capability so its version matches the advertised action, or plan the action the target actually has enabled.' `
            -Evidence $urns
    }

    $enabled = if ($urns.Count -gt 0) { $urns -join ', ' } else { '(none)' }
    return New-ChaosProbeResult -Check 'capability-enabled' -Available $false `
        -Detail "No capability matching '$ExpectedFaultUrn' is enabled on this target. Enabled capability URNs: $enabled" `
        -Remediation "Enable the capability under $uri, then re-run scoping." `
        -Evidence $urns
}

function Resolve-ChaosDeliveryPath {
    <#
    .SYNOPSIS
        Run every delivery probe and return a verdict.

    .DESCRIPTION
        Verdict is one of:
          open        every required probe passed
          blocked     at least one probe definitively failed
          unverified  no probe failed, but at least one was indeterminate

        'unverified' is deliberately not 'open'. It plans, but it carries a
        limitation into the report rather than pretending the mechanism was
        confirmed.
    #>
    param(
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$TargetType
    )

    $probes = [System.Collections.Generic.List[object]]::new()
    $targetProbe = Test-ChaosTargetEnabled -ResourceId $ResourceId -TargetType $TargetType
    [void]$probes.Add($targetProbe)

    # Only a verified target yields a usable target resource id. Anything else
    # leaves it null so nothing downstream can address a target that was never
    # confirmed to exist.
    $targetUri = $null
    if ($targetProbe.available -eq $true -and $null -ne $targetProbe.evidence -and
        $targetProbe.evidence.PSObject.Properties.Name -contains 'id') {
        $targetUri = [string]$targetProbe.evidence.id
    }

    if ($targetUri) {
        [void]$probes.Add((Test-ChaosCapabilityEnabled -TargetUri $targetUri `
                    -ExpectedFaultUrn $Action.canonicalId))
    }

    $blocked = @($probes | Where-Object { $_.available -eq $false })
    $unknown = @($probes | Where-Object { $null -eq $_.available })

    $verdict = if ($blocked.Count -gt 0) { 'blocked' }
    elseif ($unknown.Count -gt 0) { 'unverified' }
    else { 'open' }

    return [pscustomobject]@{
        targetType     = $TargetType
        targetUri      = $targetUri
        targetVerified = ($null -ne $targetUri)
        verdict        = $verdict
        probes         = $probes.ToArray()
        blockingChecks = @($blocked | ForEach-Object { $_.check })
        unknownChecks  = @($unknown | ForEach-Object { $_.check })
    }
}

function Assert-ChaosDeliveryPathOpen {
    <#
    .SYNOPSIS
        Fail loudly with exit code 14 when the action cannot be delivered.
    #>
    param([Parameter(Mandatory)][object]$Resolution)

    if ($Resolution.verdict -ne 'blocked') { return }

    $blocked = @($Resolution.probes | Where-Object { $_.available -eq $false })
    $lines = $blocked | ForEach-Object { "  - [$($_.check)] $($_.detail)" }
    $remediation = ($blocked | Where-Object { $_.remediation } | Select-Object -First 1).remediation

    Write-ChaosStudyFailure -Title 'Action cannot be delivered to this target' `
        -Message ("Chaos Studio advertises this action for the region, but it cannot reach this resource as configured:`n" + ($lines -join "`n") + "`n`nScoping stopped before writing a study plan. A plan built on a closed delivery path would consume a change window and produce a null result that reads like a pass.") `
        -Remediation $remediation

    exit (Get-ChaosStudyExitCode -Name 'FaultPathUnavailable')
}
