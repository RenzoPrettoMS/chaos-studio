#Requires -Version 7.0
<#
.SYNOPSIS
    Decides whether a fault can actually be delivered to a resource.

.DESCRIPTION
    A study plan that names a fault the platform cannot deliver is worse than
    no plan: it burns a change window and produces a null result that looks
    like a pass. This file answers one question - is this fault path open? -
    and refuses to guess when it cannot tell.

    Two paths exist and they fail for different reasons:

      agent           the fault runs inside the cluster (Chaos Mesh). Needs the
                      target enabled AND the in-cluster controller present.
      service-direct  the fault runs against the ARM resource. Needs the target
                      enabled and the capability registered.

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
        The one shape every fault-path probe returns.
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

function Get-ChaosTargetUri {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$TargetType
    )
    return "$($ResourceId.TrimEnd('/'))/providers/Microsoft.Chaos/targets/$TargetType"
}

function Test-ChaosTargetEnabled {
    <#
    .SYNOPSIS
        Is the Chaos Studio target enabled on this resource?
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$TargetType
    )

    $uri = Get-ChaosTargetUri -ResourceId $ResourceId -TargetType $TargetType
    $apiVersion = Get-ChaosApiVersion -Name 'chaosStudio'

    try {
        $response = Invoke-AzRest -Method GET -Uri $uri -ApiVersion $apiVersion
    } catch {
        $message = $_.Exception.Message
        if ($message -match '(?i)notfound|404|ResourceNotFound|TargetNotFound') {
            return New-ChaosProbeResult -Check 'target-enabled' -Available $false `
                -Detail "Target '$TargetType' is not enabled on $ResourceId." `
                -Remediation "az rest --method PUT --url '$uri?api-version=$apiVersion' --body '{\`"properties\`":{}}'"
        }
        return New-ChaosProbeResult -Check 'target-enabled' -Available $null `
            -Detail "Could not read target '$TargetType': $message" `
            -Remediation 'Confirm the signed-in principal has Reader on the resource, then re-run scoping.'
    }

    return New-ChaosProbeResult -Check 'target-enabled' -Available $true `
        -Detail "Target '$TargetType' is enabled." `
        -Evidence ($response.body)
}

function Test-ChaosCapabilityEnabled {
    <#
    .SYNOPSIS
        Is the specific capability registered under the target, and does the
        capability's URN match what the guide expects?
    #>
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$TargetType,
        [Parameter(Mandatory)][string]$CapabilityName,
        [Parameter(Mandatory)][string]$ExpectedFaultUrn
    )

    $uri = "$(Get-ChaosTargetUri -ResourceId $ResourceId -TargetType $TargetType)/capabilities"
    $apiVersion = Get-ChaosApiVersion -Name 'chaosStudio'

    try {
        $response = Invoke-AzRest -Method GET -Uri $uri -ApiVersion $apiVersion
    } catch {
        return New-ChaosProbeResult -Check 'capability-enabled' -Available $null `
            -Detail "Could not list capabilities under target '$TargetType': $($_.Exception.Message)" `
            -Remediation 'Confirm the target is enabled and the principal has Reader, then re-run scoping.'
    }

    $capabilities = @()
    if ($response.body -and $response.body.PSObject.Properties.Name -contains 'value') {
        $capabilities = @($response.body.value)
    }

    $match = $capabilities | Where-Object { $_.name -eq $CapabilityName } | Select-Object -First 1
    if (-not $match) {
        $names = if ($capabilities.Count -gt 0) { ($capabilities | ForEach-Object { $_.name }) -join ', ' } else { '(none)' }
        $enableCommand = "az rest --method PUT --url '$uri/$CapabilityName" + "?api-version=$apiVersion' --body '{}'"
        return New-ChaosProbeResult -Check 'capability-enabled' -Available $false `
            -Detail "Capability '$CapabilityName' is not enabled. Enabled capabilities: $names" `
            -Remediation $enableCommand
    }

    $actualUrn = $null
    if ($match.PSObject.Properties.Name -contains 'properties' -and
        $match.properties.PSObject.Properties.Name -contains 'urn') {
        $actualUrn = $match.properties.urn
    }

    if ($actualUrn -and $actualUrn -ne $ExpectedFaultUrn) {
        return New-ChaosProbeResult -Check 'capability-enabled' -Available $false `
            -Detail "Capability '$CapabilityName' is enabled but reports URN '$actualUrn'; the guide targets '$ExpectedFaultUrn'. Running this study would inject a different fault version than the plan documents." `
            -Remediation 'Update the fault guide to the deployed capability version, or pick a guide that matches.' `
            -Evidence $match
    }

    return New-ChaosProbeResult -Check 'capability-enabled' -Available $true `
        -Detail "Capability '$CapabilityName' is enabled with URN '$($actualUrn ?? $ExpectedFaultUrn)'." `
        -Evidence $match
}

function Test-ChaosMeshPresent {
    <#
    .SYNOPSIS
        Is the Chaos Mesh controller actually running in the cluster?

    .DESCRIPTION
        The agent fault path has a failure mode that no ARM call can see: the
        target is enabled, the capability is registered, and Chaos Mesh was
        never installed. The experiment then starts, reports success, and
        injects nothing.

        kubectl is optional. When it is absent this returns $null - not $false -
        because an unverified cluster is a limitation on the study, not a
        reason to refuse to plan one.
    #>
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [string]$Namespace = 'chaos-testing'
    )

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $null `
            -Detail 'kubectl is not on PATH, so the in-cluster Chaos Mesh controller could not be verified. The study can still be planned, but limitation L4 (unverified fault mechanism) will apply to every finding.' `
            -Remediation 'Install kubectl and run: kubectl get pods -n chaos-testing'
    }

    $output = & kubectl get pods -n $Namespace -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($output | Out-String).Trim()
        if ($text -match '(?i)not found|NotFound|no such') {
            return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $false `
                -Detail "Namespace '$Namespace' does not exist in cluster '$ClusterName'. Chaos Mesh is not installed." `
                -Remediation "helm install chaos-mesh chaos-mesh/chaos-mesh -n $Namespace --create-namespace"
        }
        return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $null `
            -Detail "kubectl could not reach cluster '$ClusterName': $text" `
            -Remediation "az aks get-credentials --resource-group $ResourceGroup --name $ClusterName"
    }

    try {
        $pods = ($output | Out-String | ConvertFrom-Json).items
    } catch {
        return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $null `
            -Detail "kubectl returned output that could not be parsed as JSON: $($_.Exception.Message)"
    }

    $controllers = @($pods | Where-Object { $_.metadata.name -like 'chaos-controller-manager*' })
    if ($controllers.Count -eq 0) {
        return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $false `
            -Detail "Namespace '$Namespace' exists but contains no chaos-controller-manager pod." `
            -Remediation "helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh -n $Namespace"
    }

    $running = @($controllers | Where-Object { $_.status.phase -eq 'Running' })
    if ($running.Count -eq 0) {
        $phases = ($controllers | ForEach-Object { "$($_.metadata.name)=$($_.status.phase)" }) -join ', '
        return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $false `
            -Detail "Chaos Mesh controller pods exist but none are Running: $phases" `
            -Remediation "kubectl describe pods -n $Namespace -l app.kubernetes.io/component=controller-manager"
    }

    return New-ChaosProbeResult -Check 'chaos-mesh-present' -Available $true `
        -Detail "$($running.Count) chaos-controller-manager pod(s) Running in namespace '$Namespace'." `
        -Evidence @($running | ForEach-Object { $_.metadata.name })
}

function Resolve-ChaosFaultPath {
    <#
    .SYNOPSIS
        Run every probe the guide's fault path requires and return a verdict.

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
        [Parameter(Mandatory)][object]$Guide,
        [Parameter(Mandatory)][string]$ResourceId,
        [string]$ClusterName,
        [string]$ResourceGroup,
        [string]$ChaosMeshNamespace = 'chaos-testing'
    )

    $probes = [System.Collections.Generic.List[object]]::new()
    [void]$probes.Add((Test-ChaosTargetEnabled -ResourceId $ResourceId -TargetType $Guide.targetType))

    if ($probes[0].available -eq $true) {
        [void]$probes.Add((Test-ChaosCapabilityEnabled -ResourceId $ResourceId `
                    -TargetType $Guide.targetType `
                    -CapabilityName $Guide.capabilityName `
                    -ExpectedFaultUrn $Guide.faultUrn))
    }

    if ($Guide.faultPath -eq 'agent' -and $ClusterName -and $ResourceGroup) {
        [void]$probes.Add((Test-ChaosMeshPresent -ClusterName $ClusterName -ResourceGroup $ResourceGroup -Namespace $ChaosMeshNamespace))
    }

    $blocked = @($probes | Where-Object { $_.available -eq $false })
    $unknown = @($probes | Where-Object { $null -eq $_.available })

    $verdict = if ($blocked.Count -gt 0) { 'blocked' }
    elseif ($unknown.Count -gt 0) { 'unverified' }
    else { 'open' }

    return [pscustomobject]@{
        faultPath      = $Guide.faultPath
        verdict        = $verdict
        probes         = $probes.ToArray()
        blockingChecks = @($blocked | ForEach-Object { $_.check })
        unknownChecks  = @($unknown | ForEach-Object { $_.check })
    }
}

function Assert-ChaosFaultPathOpen {
    <#
    .SYNOPSIS
        Fail loudly with exit code 14 when the fault path is blocked.
    #>
    param([Parameter(Mandatory)][object]$Resolution)

    if ($Resolution.verdict -ne 'blocked') { return }

    $blocked = @($Resolution.probes | Where-Object { $_.available -eq $false })
    $lines = $blocked | ForEach-Object { "  - [$($_.check)] $($_.detail)" }
    $remediation = ($blocked | Where-Object { $_.remediation } | Select-Object -First 1).remediation

    Write-ChaosStudyFailure -Title 'Fault path unavailable' `
        -Message ("This fault cannot be delivered to the target as configured:`n" + ($lines -join "`n") + "`n`nScoping stopped before writing a study plan. A plan built on a closed fault path would consume a change window and produce a null result that reads like a pass.") `
        -Remediation $remediation

    exit (Get-ChaosStudyExitCode -Name 'FaultPathUnavailable')
}
