#Requires -Version 7.0
<#
.SYNOPSIS
    Render a sealed study as one self-contained HTML file.

.DESCRIPTION
    The template owns presentation; this file owns content. Every value that
    originates from Azure or from the plan passes through HTML escaping on the
    way in, so a resource name containing a bracket cannot alter the document.

    Missing measurements render as "not measured" with their caveat. They are
    never rendered as zero and never quietly dropped - a reader must be able to
    tell the difference between "we measured nothing happened" and "we did not
    measure".

    Output is deterministic apart from the generated timestamp: fixed section
    order, sorted keys, no random ids.
#>

Set-StrictMode -Version Latest

function Get-ChaosReportTemplatePath {
    return (Join-Path $PSScriptRoot '..' '..' 'templates' 'study-report.html.tmpl')
}

function ConvertTo-ChaosReportValue {
    <#
    .SYNOPSIS
        Render one measurement, honestly.
    #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '<span class="notmeasured">not measured</span>' }
    if ($Value -is [bool]) { return $(if ($Value) { 'yes' } else { 'no' }) }
    if ($Value -is [double] -or $Value -is [single]) {
        return (ConvertTo-ChaosHtmlText -Text ([string][Math]::Round([double]$Value, 4)))
    }
    return (ConvertTo-ChaosHtmlText -Text ([string]$Value))
}

function New-ChaosReportRow {
    param([Parameter(Mandatory)][string]$Label, [AllowNull()][object]$Value)
    $rendered = if ($Value -is [string]) { ConvertTo-ChaosHtmlText -Text $Value } else { ConvertTo-ChaosReportValue -Value $Value }
    return "  <dt>$(ConvertTo-ChaosHtmlText -Text $Label)</dt><dd>$rendered</dd>"
}

function New-ChaosReportList {
    param([AllowNull()][object[]]$Items, [string]$Empty = 'None recorded.')
    $all = @($Items | Where-Object { $_ })
    if ($all.Count -eq 0) { return "<p class=`"notmeasured`">$(ConvertTo-ChaosHtmlText -Text $Empty)</p>" }
    $lines = foreach ($item in $all) { "  <li>$(ConvertTo-ChaosHtmlText -Text ([string]$item))</li>" }
    return "<ul class=`"tight`">`n$($lines -join "`n")`n</ul>"
}

function Get-ChaosVerdictVisual {
    <#
    .SYNOPSIS
        Verdict styling and an inline SVG glyph. Inline so the report stays a
        single file with no external requests.
    #>
    param([Parameter(Mandatory)][string]$Verdict)

    $shapes = @{
        'Steady state held'     = @{ class = 'held'; color = '#1a7f37'; path = 'M5 10.5l3.2 3.2L15 7' }
        'Degraded but recovered' = @{ class = 'degraded'; color = '#9a6700'; path = 'M10 5v6M10 14h.01' }
        'Steady state breached' = @{ class = 'breached'; color = '#b3261e'; path = 'M6 6l8 8M14 6l-8 8' }
        'Inconclusive'          = @{ class = 'inconclusive'; color = '#6639ba'; path = 'M7.5 7.5a2.5 2.5 0 113.4 2.3c-.6.3-.9.8-.9 1.4M10 14h.01' }
    }
    $shape = if ($shapes.ContainsKey($Verdict)) { $shapes[$Verdict] } else { $shapes['Inconclusive'] }
    $svg = @"
<svg width="28" height="28" viewBox="0 0 20 20" role="img" aria-label="$(ConvertTo-ChaosHtmlText -Text $Verdict)" focusable="false"><circle cx="10" cy="10" r="9" fill="none" stroke="$($shape.color)" stroke-width="1.5"/><path d="$($shape.path)" fill="none" stroke="$($shape.color)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
"@
    return [pscustomobject]@{ class = $shape.class; svg = $svg.Trim() }
}

function New-ChaosSignalTable {
    <#
    .SYNOPSIS
        One row per signal per window, with the caveat visible next to the value.
    #>
    param([Parameter(Mandatory)][object]$Evidence)

    $rows = @()
    foreach ($window in @('pre', 'during', 'post')) {
        foreach ($signal in @($Evidence.$window)) {
            $valueCell = if ($null -eq $signal.values) {
                '<span class="notmeasured">not measured</span>'
            } else {
                $map = Get-ChaosSignalValueMap -Signal $signal
                if ($map.Count -eq 0) {
                    '<span class="notmeasured">not measured</span>'
                } else {
                    $parts = foreach ($name in @($map.Keys)) {
                        "$(ConvertTo-ChaosHtmlText -Text $name) = $(ConvertTo-ChaosReportValue -Value $map[$name])"
                    }
                    ($parts -join '<br>')
                }
            }
            $caveat = if ($signal.caveat) { ConvertTo-ChaosHtmlText -Text ([string]$signal.caveat) } else { '&mdash;' }
            $rows += "  <tr><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$signal.source))</td><td>$window</td><td class=`"num`">$valueCell</td><td>$caveat</td></tr>"
        }
    }
    if ($rows.Count -eq 0) { return '<p class="notmeasured">No signals were collected.</p>' }
    return @"
<table>
<thead><tr><th>Signal</th><th>Window</th><th>Value</th><th>Caveat</th></tr></thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
"@
}

function New-ChaosFindingsHtml {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings)

    if (@($Findings).Count -eq 0) {
        return '<p>No findings. Every signal that was measured stayed within its objective for the whole study.</p>'
    }

    $blocks = foreach ($finding in $Findings) {
        $evidence = foreach ($ref in @($finding.evidence)) {
            "$(ConvertTo-ChaosHtmlText -Text ([string]$ref.signal)) during the <strong>$(ConvertTo-ChaosHtmlText -Text ([string]$ref.window))</strong> window"
        }
        $remediation = if (@($finding.remediation).Count -gt 0) {
            "<dt>Remediation</dt><dd>$(New-ChaosReportList -Items $finding.remediation)</dd>"
        } else { '' }
        @"
<article class="finding">
  <h3><span class="pill $(ConvertTo-ChaosHtmlText -Text $finding.severity)">$(ConvertTo-ChaosHtmlText -Text $finding.severity)</span> $(ConvertTo-ChaosHtmlText -Text $finding.title) <span class="pill ghost">$(ConvertTo-ChaosHtmlText -Text $finding.confidence) confidence</span></h3>
  <dl>
    <dt>Observation</dt><dd>$(ConvertTo-ChaosHtmlText -Text $finding.observation)</dd>
    <dt>Interpretation</dt><dd>$(ConvertTo-ChaosHtmlText -Text $finding.interpretation)</dd>
    <dt>Evidence</dt><dd>$($evidence -join '; ')</dd>
    $remediation
  </dl>
</article>
"@
    }
    return ($blocks -join "`n")
}

function New-ChaosStudyReportHtml {
    <#
    .SYNOPSIS
        Build the whole report.
    #>
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$RunRecord,
        [Parameter(Mandatory)][object]$Findings,
        [Parameter(Mandatory)][object]$Evidence,
        [object]$Manifest,
        [object[]]$CommandTrail = @()
    )

    $template = [System.IO.File]::ReadAllText((Get-ChaosReportTemplatePath))
    $visual = Get-ChaosVerdictVisual -Verdict $Findings.verdict
    $target = [string]$Plan.target.resourceName

    $verdictDetail = switch ($Findings.verdict) {
        'Steady state held'      { "$($Plan.question.steadyState.raw) held throughout injection and recovery." }
        'Degraded but recovered' { 'The service degraded during injection and returned to its objective afterwards.' }
        'Steady state breached'  { 'The service breached its objective and did not recover within the study window.' }
        default                  { 'This study cannot support a pass or a fail. Read the limitations before drawing a conclusion.' }
    }

    $headerFacts = @(
        New-ChaosReportRow -Label 'Target' -Value $target
        New-ChaosReportRow -Label 'Action' -Value ([string]$Plan.fault.displayName)
        New-ChaosReportRow -Label 'Steady state' -Value ([string]$Plan.question.steadyState.raw)
        New-ChaosReportRow -Label 'Injection window' -Value "$($Plan.windows.injectMinutes) minutes"
        New-ChaosReportRow -Label 'Run started' -Value ([string]$RunRecord.startedAt)
        New-ChaosReportRow -Label 'Sealed' -Value $(if ($Manifest) { [string]$Manifest.sealedAt } else { $null })
    ) -join "`n"

    $mechanismSentence = if ($Findings.mechanismProven) {
        'The fault was proven to reach the system: measured signals moved during injection.'
    } else {
        'The fault was not proven to reach the system, so a clean result cannot be read as resilience.'
    }

    $summary = @"
<p>$(ConvertTo-ChaosHtmlText -Text $Plan.question.hypothesis)</p>
<p><strong>$(ConvertTo-ChaosHtmlText -Text $Findings.verdict).</strong> $(ConvertTo-ChaosHtmlText -Text $verdictDetail)
$(ConvertTo-ChaosHtmlText -Text $mechanismSentence)</p>
<p>$(ConvertTo-ChaosHtmlText -Text "Evidence covers $($RunRecord.coverage.measured) of $($RunRecord.coverage.total) signal readings across the baseline, injection and recovery windows.") $(
    if (@($Findings.findings).Count -eq 0) { 'No findings were raised.' }
    else { ConvertTo-ChaosHtmlText -Text "$(@($Findings.findings).Count) finding(s) were raised; the most severe is $(@($Findings.findings)[0].severity)." }
)</p>
"@

    $parameterRows = @()
    $paramNames = if ($null -eq $Plan.fault.parameters) {
        @()
    } elseif ($Plan.fault.parameters -is [System.Collections.IDictionary]) {
        @($Plan.fault.parameters.Keys)
    } else {
        @($Plan.fault.parameters.PSObject.Properties | ForEach-Object { $_.Name })
    }
    foreach ($name in ($paramNames | Sort-Object)) {
        $value = if ($Plan.fault.parameters -is [System.Collections.IDictionary]) { $Plan.fault.parameters[$name] } else { $Plan.fault.parameters.$name }
        $rendered = if ($value -is [string] -or $value -is [bool] -or $value -is [int] -or $value -is [long] -or $value -is [double]) {
            ConvertTo-ChaosReportValue -Value $value
        } else {
            "<code>$(ConvertTo-ChaosHtmlText -Text (ConvertTo-ChaosCanonicalJson -InputObject $value))</code>"
        }
        $parameterRows += "  <tr><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text $name)</td><td>$rendered</td></tr>"
    }

    $tested = @"
<dl class="kv">
$(New-ChaosReportRow -Label 'Resource' -Value ([string]$Plan.target.resourceId))
$(New-ChaosReportRow -Label 'Region' -Value ([string]$Plan.target.region))
$(New-ChaosReportRow -Label 'Action URN' -Value ([string]$Plan.fault.faultUrn))
$(New-ChaosReportRow -Label 'Action type' -Value ([string]$Plan.fault.actionType))
$(New-ChaosReportRow -Label 'Target type' -Value ([string]$Plan.fault.targetType))
$(New-ChaosReportRow -Label 'Action metadata' -Value $(if ([string]$Plan.fault.source -eq 'live-discovery') { 'discovered live from Microsoft.Chaos/locations/{region}/actions' } else { $null }))
$(New-ChaosReportRow -Label 'Windows' -Value "baseline $($Plan.windows.baselineMinutes) min, injection $($Plan.windows.injectMinutes) min, recovery $($Plan.windows.recoveryMinutes) min")
</dl>
<h3>Action parameters</h3>
<table><thead><tr><th>Parameter</th><th>Value</th></tr></thead><tbody>
$($parameterRows -join "`n")
</tbody></table>
<h3>Abort conditions</h3>
$(New-ChaosReportList -Items $Plan.safety.abortConditions)
"@

    $statusRows = foreach ($observation in @($RunRecord.experiment.observations)) {
        "  <tr><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$observation.at))</td><td>$(ConvertTo-ChaosHtmlText -Text ([string]$observation.status))</td></tr>"
    }

    $happened = @"
<dl class="kv">
$(New-ChaosReportRow -Label 'Experiment' -Value ([string]$RunRecord.experiment.name))
$(New-ChaosReportRow -Label 'Outcome' -Value ([string]$RunRecord.experiment.outcome))
$(New-ChaosReportRow -Label 'Mechanism proven' -Value $Findings.mechanismProven)
$(New-ChaosReportRow -Label 'Mechanism evidence' -Value ([string]$Findings.mechanismDetail))
$(New-ChaosReportRow -Label 'Predicate during' -Value $Findings.predicate.during)
$(New-ChaosReportRow -Label 'Predicate after' -Value $Findings.predicate.post)
</dl>
$(if (@($statusRows).Count -gt 0) { "<h3>Experiment status</h3>`n<table><thead><tr><th>At</th><th>Status</th></tr></thead><tbody>`n$($statusRows -join "`n")`n</tbody></table>" } else { '' })
<h3>Signals</h3>
$(New-ChaosSignalTable -Evidence $Evidence)
"@

    $limitationRows = foreach ($limitation in @($Findings.limitations)) {
        "  <tr><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$limitation.code))</td><td>$(ConvertTo-ChaosHtmlText -Text ([string]$limitation.text))</td></tr>"
    }
    $limitations = "<table><thead><tr><th>Code</th><th>Limitation</th></tr></thead><tbody>`n$($limitationRows -join "`n")`n</tbody></table>"

    $remediationItems = @($Findings.findings | ForEach-Object { $_.remediation } | Where-Object { $_ })
    $remediation = New-ChaosReportList -Items $remediationItems -Empty 'No remediation is indicated by this study.'

    $trailRows = foreach ($entry in @($CommandTrail)) {
        "  <tr><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$entry.at))</td><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$entry.command))</td><td>$(ConvertTo-ChaosHtmlText -Text ([string]$entry.note))</td></tr>"
    }
    $artifactRows = if ($Manifest -and $Manifest.PSObject.Properties.Name -contains 'artifacts') {
        foreach ($artifact in @($Manifest.artifacts)) {
            "  <tr><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$artifact.path))</td><td class=`"mono`">$(ConvertTo-ChaosHtmlText -Text ([string]$artifact.sha256))</td></tr>"
        }
    } else { @() }

    $appendix = @"
<dl class="kv">
$(New-ChaosReportRow -Label 'Study id' -Value ([string]$RunRecord.studyId))
$(New-ChaosReportRow -Label 'Scope hash' -Value ([string]$RunRecord.scopeHash))
$(New-ChaosReportRow -Label 'Frozen config hash' -Value ([string]$Plan.frozenConfigHash))
$(New-ChaosReportRow -Label 'Chaos api-version' -Value (Get-ChaosApiVersion -Name 'chaosClassic'))
$(New-ChaosReportRow -Label 'Metrics api-version' -Value (Get-ChaosApiVersion -Name 'metrics'))
</dl>
$(if (@($artifactRows).Count -gt 0) { "<h3>Artifact hashes</h3>`n<table><thead><tr><th>Artifact</th><th>SHA-256</th></tr></thead><tbody>`n$($artifactRows -join "`n")`n</tbody></table>" } else { '' })
$(if (@($trailRows).Count -gt 0) { "<h3>Command trail</h3>`n<table><thead><tr><th>At</th><th>Command</th><th>Note</th></tr></thead><tbody>`n$($trailRows -join "`n")`n</tbody></table>" } else { '<p class="notmeasured">No command trail was recorded.</p>' })
"@

    $tokens = [ordered]@{
        '{{TITLE}}'          = ConvertTo-ChaosHtmlText -Text "Chaos study: $($Plan.fault.displayName) on $target"
        '{{STUDY_ID}}'       = ConvertTo-ChaosHtmlText -Text ([string]$RunRecord.studyId)
        '{{VERDICT}}'        = ConvertTo-ChaosHtmlText -Text ([string]$Findings.verdict)
        '{{VERDICT_CLASS}}'  = $visual.class
        '{{VERDICT_ICON}}'   = $visual.svg
        '{{VERDICT_DETAIL}}' = ConvertTo-ChaosHtmlText -Text $verdictDetail
        '{{HEADER_FACTS}}'   = $headerFacts
        '{{SUMMARY}}'        = $summary
        '{{TESTED}}'         = $tested
        '{{HAPPENED}}'       = $happened
        '{{FINDINGS}}'       = New-ChaosFindingsHtml -Findings @($Findings.findings)
        '{{LIMITATIONS}}'    = $limitations
        '{{REMEDIATION}}'    = $remediation
        '{{APPENDIX}}'       = $appendix
        '{{GENERATED_AT}}'   = ConvertTo-ChaosHtmlText -Text (Get-ChaosUtcNow)
    }

    $html = $template
    foreach ($token in $tokens.Keys) { $html = $html.Replace($token, [string]$tokens[$token]) }

    if ($html -match '\{\{[A-Z_]+\}\}') {
        throw "Report template has unreplaced tokens: $($Matches[0]). The renderer and the template are out of sync."
    }
    if ($html -match '(?i)<script') {
        throw 'Report contains a script tag. Reports are evidence, not applications.'
    }
    return $html
}
