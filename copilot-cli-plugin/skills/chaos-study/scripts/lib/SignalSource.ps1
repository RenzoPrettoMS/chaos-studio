# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
Set-StrictMode -Version Latest

function ConvertFrom-ChaosSignalSourceSpec {
    <#
    .SYNOPSIS
        Parse a signal source string into a structured spec.

    .DESCRIPTION
        Accepted forms:
          metrics:<name>             Azure Monitor metric on the single scoped
                                     resource, when the scope holds exactly one
          metrics:<name>@<resourceId>   ... on a named resource
          metrics:<name>|<aggregation> ... with an explicit aggregation
          logs:<workspaceId>#<kql>   Log Analytics query

        There is deliberately no resource-specific collector here. What counts
        as evidence depends on the system under study, so the operator names it.
    #>
    param([Parameter(Mandatory)][string]$Spec)

    $text = $Spec.Trim()

    if ($text -like 'metrics:*') {
        $rest = $text.Substring('metrics:'.Length)
        $aggregation = 'Average'
        if ($rest.Contains('|')) {
            $parts = $rest.Split('|', 2)
            $rest = $parts[0]
            $aggregation = $parts[1]
        }
        $resourceId = $null
        if ($rest.Contains('@')) {
            $parts = $rest.Split('@', 2)
            $rest = $parts[0]
            $resourceId = $parts[1]
        }
        if ([string]::IsNullOrWhiteSpace($rest)) {
            throw "Signal source '$Spec' is missing a metric name. Use 'metrics:<metricName>'."
        }
        return [pscustomobject]@{
            kind        = 'metrics'
            id          = "metrics:$rest"
            metricName  = $rest
            aggregation = $aggregation
            resourceId  = $resourceId
            raw         = $text
        }
    }

    if ($text -like 'logs:*') {
        $rest = $text.Substring('logs:'.Length)
        if (-not $rest.Contains('#')) {
            throw "Signal source '$Spec' is missing its query. Use 'logs:<workspaceId>#<kql>'."
        }
        $parts = $rest.Split('#', 2)
        if ([string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            throw "Signal source '$Spec' needs both a workspace id and a query."
        }
        return [pscustomobject]@{
            kind        = 'logs'
            id          = "logs:$($parts[0])"
            workspaceId = $parts[0]
            query       = $parts[1]
            raw         = $text
        }
    }

    throw "Signal source '$Spec' is not recognised. Use 'metrics:<name>' or 'logs:<workspaceId>#<kql>'."
}
