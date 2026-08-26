#Requires -Version 7.0
<#
.SYNOPSIS
    Reads the fault guides that ship with chaos-study.

.DESCRIPTION
    Fault guides are markdown with YAML front matter. The prose is for the
    model; the front matter is the machine contract - fault URN, blast-radius
    controls, abort conditions, known limitations and the honest assessment of
    whether a data-plane signal can prove the fault landed.

    This file contains a deliberately small YAML subset parser rather than a
    dependency. The subset is exactly what the shipped guides use: scalars,
    nested indented maps, block lists, quoted strings and inline flow
    collections. Anything outside that subset is a parse failure, loudly, so a
    malformed guide can never be silently half-read into a study plan.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..' '..' '..' 'chaos-study' 'scripts' 'lib' 'Common.ps1')

# -- YAML subset parser ---------------------------------------------------

function Split-ChaosFlowItem {
    <#
    .SYNOPSIS
        Split a flow collection body on top-level commas, respecting quotes
        and nesting.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $items = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    $quote = $null
    $buffer = [System.Text.StringBuilder]::new()

    foreach ($ch in $Text.ToCharArray()) {
        if ($quote) {
            [void]$buffer.Append($ch)
            if ($ch -eq $quote) { $quote = $null }
            continue
        }
        switch ($ch) {
            '"' { $quote = $ch; [void]$buffer.Append($ch) }
            "'" { $quote = $ch; [void]$buffer.Append($ch) }
            '[' { $depth++; [void]$buffer.Append($ch) }
            '{' { $depth++; [void]$buffer.Append($ch) }
            ']' { $depth--; [void]$buffer.Append($ch) }
            '}' { $depth--; [void]$buffer.Append($ch) }
            ',' {
                if ($depth -eq 0) {
                    [void]$items.Add($buffer.ToString())
                    [void]$buffer.Clear()
                } else {
                    [void]$buffer.Append($ch)
                }
            }
            default { [void]$buffer.Append($ch) }
        }
    }
    if ($buffer.Length -gt 0) { [void]$items.Add($buffer.ToString()) }
    return , $items.ToArray()
}

function ConvertFrom-ChaosYamlScalar {
    <#
    .SYNOPSIS
        Turn a YAML scalar or inline flow collection into a PowerShell value.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ($null -eq $Text) { return $null }
    $value = $Text.Trim()

    if ($value -eq '') { return '' }
    if ($value -in @('null', '~', 'Null', 'NULL')) { return $null }
    if ($value -in @('true', 'True', 'TRUE', 'yes')) { return $true }
    if ($value -in @('false', 'False', 'FALSE', 'no')) { return $false }

    if ($value.StartsWith('[') -and $value.EndsWith(']')) {
        $inner = $value.Substring(1, $value.Length - 2).Trim()
        if ($inner -eq '') { return , @() }
        $parsed = @(Split-ChaosFlowItem -Text $inner | ForEach-Object { ConvertFrom-ChaosYamlScalar -Text $_ })
        return , $parsed
    }

    if ($value.StartsWith('{') -and $value.EndsWith('}')) {
        $inner = $value.Substring(1, $value.Length - 2).Trim()
        $map = [ordered]@{}
        if ($inner -ne '') {
            foreach ($pair in (Split-ChaosFlowItem -Text $inner)) {
                $split = $pair.IndexOf(':')
                if ($split -lt 0) { throw "Malformed inline map entry: '$pair'" }
                $key = (ConvertFrom-ChaosYamlScalar -Text $pair.Substring(0, $split)).ToString()
                $map[$key] = ConvertFrom-ChaosYamlScalar -Text $pair.Substring($split + 1)
            }
        }
        return $map
    }

    if (($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) -or
        ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2)) {
        return $value.Substring(1, $value.Length - 2)
    }

    if ($value -match '^-?\d+$') { return [int]$value }
    if ($value -match '^-?\d+\.\d+$') { return [double]$value }

    return $value
}

function Get-ChaosYamlIndent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $trimmed = $Line.TrimStart(' ')
    return ($Line.Length - $trimmed.Length)
}

function Test-ChaosYamlSkippable {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $trimmed = $Line.Trim()
    return ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#'))
}

function ConvertFrom-ChaosYamlBlock {
    <#
    .SYNOPSIS
        Parse one indentation block into a map or a list.

    .DESCRIPTION
        $Cursor is advanced past every line consumed. The block ends at the
        first non-skippable line indented less than $Indent.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][ref]$Cursor,
        [Parameter(Mandatory)][int]$Indent
    )

    $isList = $false
    $probe = $Cursor.Value
    while ($probe -lt $Lines.Count -and (Test-ChaosYamlSkippable -Line $Lines[$probe])) { $probe++ }
    if ($probe -lt $Lines.Count -and $Lines[$probe].Trim().StartsWith('- ')) { $isList = $true }

    if ($isList) {
        $items = [System.Collections.Generic.List[object]]::new()
        while ($Cursor.Value -lt $Lines.Count) {
            $line = $Lines[$Cursor.Value]
            if (Test-ChaosYamlSkippable -Line $line) { $Cursor.Value++; continue }
            $lineIndent = Get-ChaosYamlIndent -Line $line
            if ($lineIndent -lt $Indent) { break }
            $trimmed = $line.Trim()
            if (-not $trimmed.StartsWith('- ')) {
                throw "Expected a list item at indent $Indent but found: '$trimmed'"
            }
            [void]$items.Add((ConvertFrom-ChaosYamlScalar -Text $trimmed.Substring(2)))
            $Cursor.Value++
        }
        return , $items.ToArray()
    }

    $map = [ordered]@{}
    while ($Cursor.Value -lt $Lines.Count) {
        $line = $Lines[$Cursor.Value]
        if (Test-ChaosYamlSkippable -Line $line) { $Cursor.Value++; continue }
        $lineIndent = Get-ChaosYamlIndent -Line $line
        if ($lineIndent -lt $Indent) { break }
        if ($lineIndent -gt $Indent) {
            throw "Unexpected indentation at line $($Cursor.Value + 1): expected $Indent, found $lineIndent"
        }

        $trimmed = $line.Trim()
        $split = $trimmed.IndexOf(':')
        if ($split -lt 0) { throw "Expected 'key: value' at line $($Cursor.Value + 1) but found: '$trimmed'" }

        $key = $trimmed.Substring(0, $split).Trim()
        $rest = $trimmed.Substring($split + 1).Trim()
        $Cursor.Value++

        if ($rest -ne '') {
            $map[$key] = ConvertFrom-ChaosYamlScalar -Text $rest
            continue
        }

        # Value lives in the following block, if there is one.
        $probe = $Cursor.Value
        while ($probe -lt $Lines.Count -and (Test-ChaosYamlSkippable -Line $Lines[$probe])) { $probe++ }
        if ($probe -ge $Lines.Count -or (Get-ChaosYamlIndent -Line $Lines[$probe]) -le $Indent) {
            $map[$key] = $null
            continue
        }
        $childIndent = Get-ChaosYamlIndent -Line $Lines[$probe]
        $map[$key] = ConvertFrom-ChaosYamlBlock -Lines $Lines -Cursor $Cursor -Indent $childIndent
    }
    return $map
}

function ConvertFrom-ChaosFrontMatter {
    <#
    .SYNOPSIS
        Extract and parse the YAML front matter from a guide's raw text.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalised = $Text -replace "`r`n", "`n"
    $lines = $normalised.Split("`n")
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') {
        throw 'Guide does not begin with a YAML front-matter fence (---).'
    }

    $closing = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $closing = $i; break }
    }
    if ($closing -lt 0) { throw 'Guide front matter is not closed by a second --- fence.' }

    $body = $lines[1..($closing - 1)]
    $cursor = 0
    $parsed = ConvertFrom-ChaosYamlBlock -Lines $body -Cursor ([ref]$cursor) -Indent 0

    return [pscustomobject]@{
        frontMatter = $parsed
        prose       = ($lines[($closing + 1)..($lines.Count - 1)] -join "`n").Trim()
    }
}

# -- Guide contract -------------------------------------------------------

$ChaosGuideRequiredFields = @(
    'guideSchemaVersion', 'faultUrn', 'displayName', 'vertical', 'faultPath',
    'targetType', 'resourceType', 'capabilityName', 'parameters',
    'steadyStateSignals', 'impactSignals', 'blastRadiusControls',
    'abortConditions', 'knownLimitations', 'dataPlaneProof'
)
$ChaosGuideValidFaultPaths = @('agent', 'service-direct')
$ChaosGuideValidCoverage = @('strong', 'partial', 'weak')

function Test-ChaosFaultGuide {
    <#
    .SYNOPSIS
        Validate a parsed guide against the contract. Returns the list of
        problems; empty means valid.
    #>
    param(
        [Parameter(Mandatory)][object]$Guide,
        [Parameter(Mandatory)][string]$Name
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $fm = $Guide.frontMatter

    foreach ($field in $ChaosGuideRequiredFields) {
        if (-not $fm.Contains($field) -or $null -eq $fm[$field]) {
            [void]$problems.Add("$Name is missing required field '$field'.")
        }
    }
    if ($problems.Count -gt 0) { return , $problems.ToArray() }

    if ($fm['guideSchemaVersion'] -ne 1) {
        [void]$problems.Add("$Name has guideSchemaVersion $($fm['guideSchemaVersion']); this build understands version 1 only.")
    }
    if ($fm['faultPath'] -notin $ChaosGuideValidFaultPaths) {
        [void]$problems.Add("$Name has faultPath '$($fm['faultPath'])'; expected one of: $($ChaosGuideValidFaultPaths -join ', ').")
    }
    if ($fm['faultUrn'] -notmatch '^urn:csci:microsoft:[^:]+:[^/]+/\d+\.\d+$') {
        [void]$problems.Add("$Name has a faultUrn that is not a recognised Chaos Studio capability URN: '$($fm['faultUrn'])'.")
    }

    $proof = $fm['dataPlaneProof']
    if (-not ($proof -is [System.Collections.IDictionary]) -or -not $proof.Contains('coverage')) {
        [void]$problems.Add("$Name has a dataPlaneProof block without a 'coverage' field.")
    } elseif ($proof['coverage'] -notin $ChaosGuideValidCoverage) {
        [void]$problems.Add("$Name declares dataPlaneProof.coverage '$($proof['coverage'])'; expected one of: $($ChaosGuideValidCoverage -join ', ').")
    }

    foreach ($listField in @('steadyStateSignals', 'impactSignals', 'blastRadiusControls', 'abortConditions')) {
        $value = $fm[$listField]
        if ($value -isnot [System.Array] -or $value.Count -eq 0) {
            [void]$problems.Add("$Name has an empty '$listField'; a guide that names no $listField is not usable.")
        }
    }

    return , $problems.ToArray()
}

function Get-ChaosFaultGuidePath {
    param([Parameter(Mandatory)][string]$Name)
    $leaf = if ($Name.EndsWith('.md')) { $Name } else { "$Name.md" }
    return Join-Path (Get-ChaosStudyReferenceRoot) 'faults' $leaf
}

function Get-ChaosFaultGuide {
    <#
    .SYNOPSIS
        Load and validate one fault guide by name (with or without .md).

    .DESCRIPTION
        Throws on a missing or malformed guide. A study plan built on a guide
        that could not be fully read would carry blast-radius controls and
        abort conditions that nobody verified, which is worse than no plan.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $path = Get-ChaosFaultGuidePath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Fault guide '$Name' not found at $path. Run 'chaos-study-scope' with -ListFaults to see what is available."
    }

    $raw = [System.IO.File]::ReadAllText($path)
    try {
        $parsed = ConvertFrom-ChaosFrontMatter -Text $raw
    } catch {
        throw "Fault guide '$Name' could not be parsed: $($_.Exception.Message)"
    }

    $problems = Test-ChaosFaultGuide -Guide $parsed -Name $Name
    if ($problems.Count -gt 0) {
        throw "Fault guide '$Name' is invalid:`n  - $($problems -join "`n  - ")"
    }

    $fm = $parsed.frontMatter
    return [pscustomobject]@{
        name                = [System.IO.Path]::GetFileNameWithoutExtension($path)
        path                = $path
        faultUrn            = $fm['faultUrn']
        displayName         = $fm['displayName']
        vertical            = $fm['vertical']
        faultPath           = $fm['faultPath']
        targetType          = $fm['targetType']
        resourceType        = $fm['resourceType']
        capabilityName      = $fm['capabilityName']
        prerequisites       = @($fm['prerequisites'])
        parameters          = $fm['parameters']
        steadyStateSignals  = @($fm['steadyStateSignals'])
        impactSignals       = @($fm['impactSignals'])
        blastRadiusControls = @($fm['blastRadiusControls'])
        abortConditions     = @($fm['abortConditions'])
        knownLimitations    = @($fm['knownLimitations'])
        dataPlaneProof      = $fm['dataPlaneProof']
        prose               = $parsed.prose
    }
}

function Get-ChaosFaultGuideList {
    <#
    .SYNOPSIS
        Every shippable guide, optionally filtered by vertical. Guides that
        fail validation are reported rather than hidden.
    #>
    param([string]$Vertical)

    $dir = Join-Path (Get-ChaosStudyReferenceRoot) 'faults'
    if (-not (Test-Path -LiteralPath $dir)) { return , @() }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.md' | Sort-Object Name)) {
        if ($file.Name.StartsWith('_')) { continue }
        try {
            $guide = Get-ChaosFaultGuide -Name $file.Name
        } catch {
            [void]$results.Add([pscustomobject]@{
                    name    = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                    path    = $file.FullName
                    invalid = $true
                    reason  = $_.Exception.Message
                })
            continue
        }
        if ($Vertical -and $guide.vertical -ne $Vertical) { continue }
        [void]$results.Add($guide)
    }
    return , $results.ToArray()
}

function Find-ChaosFaultGuide {
    <#
    .SYNOPSIS
        Resolve a guide from a name, a fault URN, or a capability name.
    #>
    param([Parameter(Mandatory)][string]$Reference)

    $direct = Join-Path (Get-ChaosStudyReferenceRoot) 'faults' "$Reference.md"
    if (Test-Path -LiteralPath $direct) { return Get-ChaosFaultGuide -Name $Reference }

    foreach ($guide in (Get-ChaosFaultGuideList)) {
        if ($guide.PSObject.Properties.Name -contains 'invalid') { continue }
        if ($guide.faultUrn -eq $Reference -or $guide.capabilityName -eq $Reference) { return $guide }
    }
    return $null
}
