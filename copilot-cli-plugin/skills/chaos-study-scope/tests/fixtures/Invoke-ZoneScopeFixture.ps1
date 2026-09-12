# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param(
    [Parameter(Mandatory)][string]$Skills,
    [Parameter(Mandatory)][string]$StudyRoot,
    [string]$FilterLocation = 'westus2'
)
$ErrorActionPreference = 'Stop'
if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }
New-Item -ItemType Directory $StudyRoot -Force | Out-Null
$global:FixtureWorkspace = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Chaos/workspaces/ws'
$global:FixtureResources = Get-Content "$PSScriptRoot/live-discovered-resources.json" -Raw
$global:FixtureTarget = ($global:FixtureResources | ConvertFrom-Json)[0].properties.fullyQualifiedIdentifier

function global:az {
    $command = $args -join ' '
    $command | Add-Content "$StudyRoot/az-calls"
    $global:LASTEXITCODE = 0
    if ($command -like 'extension list *') { return 'chaos' }
    if ($command -like 'extension update *') { return }
    if ($command -like 'chaos workspace show *') {
        return (@{ id = $global:FixtureWorkspace; name = 'ws'; location = 'westus2'
            properties = @{ provisioningState = 'Succeeded'; scopes = @('/subscriptions/sub/resourceGroups/rg') }
            identity = @{ type = 'SystemAssigned'; principalId = 'principal' } } | ConvertTo-Json -Depth 10)
    }
    if ($command -like 'chaos discovered-resource list *') { return $global:FixtureResources }
    if ($command -like 'chaos workspace show-evaluation *') {
        return '{"properties":{"status":"Succeeded","numScenariosEvaluatedSucceeded":1,"numScenariosEvaluatedFailed":0}}'
    }
    if ($command -like 'chaos scenario list *') {
        return (@{ value = @(@{ id = "$global:FixtureWorkspace/scenarios/ZoneDown-1.0"; name = 'ZoneDown-1.0'
            properties = @{ displayName = 'Zone down'; version = '1.0'; description = 'offline'
                recommendation = @{ recommendationStatus = 'Recommended' }; parameters = @() } }) } | ConvertTo-Json -Depth 10)
    }
    if ($command -like 'rest *' -and $command -like '*/locations/westus2/actions*') {
        return (@{ value = @(@{ name = 'fixture-action'; properties = @{
            actionName = 'fixture-action'; canonicalId = 'urn:fixture:action'; actionType = 'Continuous'
            displayName = 'Fixture'; description = 'offline'; version = '1.0'
            supportedTargetTypes = @(@{ targetType = 'Microsoft.Compute/virtualMachines'; requiredPermissions = @() })
            parametersSchema = @{ type = 'object'; required = @(); properties = @{} }; recommendedRoles = @()
        } }) } | ConvertTo-Json -Depth 12)
    }
    if ($command -like 'chaos scenario config create *') {
        $body = @{}
        foreach ($field in @('parameters', 'filters', 'exclusions')) {
            $index = [array]::IndexOf($args, "--$field")
            if ($index -ge 0) {
                $body[$field] = Get-Content -LiteralPath $args[$index + 1].Substring(1) -Raw | ConvertFrom-Json -NoEnumerate
            }
        }
        $body | ConvertTo-Json -Depth 20 | Set-Content "$StudyRoot/config-body.json"
        return '{"name":"fixture-config"}'
    }
    if ($command -like 'chaos scenario config validate *') {
        return '{"status":"Succeeded","legs":[{"legSelector":"vm","action":"fixture-action","executable":true}]}'
    }
    throw "Unexpected offline fixture operation: $command"
}

& "$Skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1" `
    -SubscriptionId sub -ResourceGroup rg -WorkspaceName ws -StudyRoot $StudyRoot `
    -Scenario 'ZoneDown-1.0' -Action fixture-action -SteadyState 'Availability >= 1' `
    -SignalSource 'metrics:Availability' -FailureMechanism 'Shutdown changes availability' `
    -MechanismEvidence 'Offline fixture VM' `
    -MechanismProbe @{ signal = 'Availability'; expectedDirection = 'down'; resourceCorrelation = $global:FixtureTarget } `
    -EventRatePerSecond 1 -EligibleFraction 1 -AcceptUnknownFaultDuration `
    -FilterZone 1 -FilterLocation $FilterLocation
exit $LASTEXITCODE
