<#
.SYNOPSIS
    Markdown rendering helpers for the startchaos plugin.

.DESCRIPTION
    All user-facing output uses fixed Markdown card templates.
    No ANSI colours — output is designed for Copilot CLI rendering.

    Functions:
      Write-Card          — general-purpose info/status card
      Write-Table         — renders a table from objects or arrays
      Write-Error-Card    — error card with optional remediation command
      Resolve-BlastRadius — resolves include/exclude targeting to an affected set
      Write-BlastRadiusCard — renders that resolved set (an advisory preview) before any mutation

.NOTES
    Design principle D4: Output is Markdown with fixed card templates.
#>

function Write-Card {
    <#
    .SYNOPSIS
        Renders a Markdown card with a title, optional status badge, body text,
        and optional JSON preview.
    .PARAMETER Title
        Card heading (rendered as ## heading).
    .PARAMETER Status
        Optional status string shown as a badge after the title (e.g. "✅ Done").
    .PARAMETER Body
        Main body text — Markdown-formatted.
    .PARAMETER JsonPreview
        Optional object to render as a fenced JSON code block.
    .PARAMETER Properties
        Optional ordered hashtable rendered as a key-value list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter()]
        [string]$Status,

        [Parameter()]
        [string]$Body,

        [Parameter()]
        [object]$JsonPreview,

        [Parameter()]
        [hashtable]$Properties
    )

    $lines = @()

    # Title with optional status
    if ($Status) {
        $lines += "## $Title — $Status"
    } else {
        $lines += "## $Title"
    }
    $lines += ''

    # Properties as key-value list
    if ($Properties -and $Properties.Count -gt 0) {
        foreach ($key in $Properties.Keys) {
            $lines += "- **${key}:** $($Properties[$key])"
        }
        $lines += ''
    }

    # Body text
    if ($Body) {
        $lines += $Body
        $lines += ''
    }

    # JSON preview in fenced block
    if ($null -ne $JsonPreview) {
        $json = if ($JsonPreview -is [string]) {
            $JsonPreview
        } else {
            $JsonPreview | ConvertTo-Json -Depth 16
        }
        $lines += '```json'
        $lines += $json
        $lines += '```'
        $lines += ''
    }

    $output = $lines -join "`n"
    Write-Output $output
}

function Write-Table {
    <#
    .SYNOPSIS
        Renders a Markdown table from an array of objects or hashtables.
    .PARAMETER Data
        Array of objects (or hashtables) to render as rows.
    .PARAMETER Columns
        Optional array of column names. If omitted, uses the keys from the
        first item.
    .PARAMETER Title
        Optional heading above the table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Data,

        [Parameter()]
        [string[]]$Columns,

        [Parameter()]
        [string]$Title
    )

    if ($Data.Count -eq 0) {
        Write-Output '*(empty)*'
        return
    }

    # Resolve columns
    if (-not $Columns) {
        $first = $Data[0]
        if ($first -is [System.Collections.IDictionary]) {
            $Columns = @($first.Keys)
        } elseif ($first -is [hashtable]) {
            $Columns = @($first.Keys)
        } else {
            $Columns = @($first.PSObject.Properties.Name)
        }
    }

    $lines = @()

    if ($Title) {
        $lines += "### $Title"
        $lines += ''
    }

    # Header row
    $lines += '| ' + ($Columns -join ' | ') + ' |'
    $lines += '| ' + (($Columns | ForEach-Object { '---' }) -join ' | ') + ' |'

    # Data rows
    foreach ($item in $Data) {
        $cells = foreach ($col in $Columns) {
            $val = if ($item -is [System.Collections.IDictionary]) { $item[$col] } elseif ($item -is [hashtable]) { $item[$col] } else { $item.$col }
            if ($null -eq $val) { '' } else { "$val" }
        }
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }

    $lines += ''
    $output = $lines -join "`n"
    Write-Output $output
}

function Write-Error-Card {
    <#
    .SYNOPSIS
        Renders a Markdown error card with a title, error message, and optional
        remediation command.
    .PARAMETER Title
        Error card heading.
    .PARAMETER ErrorMessage
        The error description.
    .PARAMETER RemediationCommand
        Optional shell command the user can run to fix the problem.
    .PARAMETER Details
        Optional additional context or stack trace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$ErrorMessage,

        [Parameter()]
        [string]$RemediationCommand,

        [Parameter()]
        [string]$Details
    )

    $lines = @()

    $lines += "## ❌ $Title"
    $lines += ''
    $lines += "**Error:** $ErrorMessage"
    $lines += ''

    if ($Details) {
        $lines += $Details
        $lines += ''
    }

    if ($RemediationCommand) {
        $lines += '**Remediation:**'
        $lines += ''
        $lines += '```bash'
        $lines += $RemediationCommand
        $lines += '```'
        $lines += ''
    }

    $output = $lines -join "`n"
    Write-Output $output
}

# ── Blast radius (E3-T1) ────────────────────────────────
# The contract these two functions implement is written down in
# `references/chaos/blast-radius.md`. Field evidence F8: the affected-resource
# set and the exclusions that shaped it were never shown before the
# ScenarioConfiguration was created, so an exclusion that starved a whole fault
# leg (CS-7) was undiscoverable until the run produced nothing.

function Resolve-BlastRadius {
    <#
    .SYNOPSIS
        Resolves `resourceTargeting` include/exclude filters against a candidate
        resource set into the exact list of resources a scenario would affect.
    .DESCRIPTION
        Pure function — no ARM calls, no state writes. Precedence:

          1. An empty/absent include list means every candidate is in scope.
          2. A non-empty include list narrows the candidate set to its members.
          3. Exclude is applied last and always wins over include.
          4. ARM ids compare case-insensitively, ignoring surrounding whitespace
             and a trailing slash.
          5. Candidate order is preserved and duplicates collapse.

        Filters that matched no candidate are reported rather than dropped: a
        typo in an exclusion silently widens the blast radius otherwise.
    .PARAMETER Candidate
        Resource ids discovered in scope (the set before any filtering).
    .PARAMETER Include
        Optional `resourceTargeting.include` filter.
    .PARAMETER Exclude
        Optional `resourceTargeting.exclude` filter.
    .OUTPUTS
        [PSCustomObject] with candidates, include, exclude, included, excluded,
        notIncluded, unmatchedInclude, unmatchedExclude, the three counts, and
        the isStarved / starvedByExclusion flags.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Candidate = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Include = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Exclude = @()
    )

    # ARM resource ids are case-insensitive; a trailing slash is not meaningful.
    $normalize = { param([string]$Value) ("$Value").Trim().TrimEnd('/').ToLowerInvariant() }

    $candidates = @()
    $seen = @{}
    foreach ($item in $Candidate) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $key = & $normalize $item
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $candidates += ("$item").Trim()
    }

    $includeFilters = @($Include | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ("$_").Trim() })
    $excludeFilters = @($Exclude | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ("$_").Trim() })

    $includeKeys = @{}
    foreach ($f in $includeFilters) { $includeKeys[(& $normalize $f)] = $false }
    $excludeKeys = @{}
    foreach ($f in $excludeFilters) { $excludeKeys[(& $normalize $f)] = $false }

    $included    = @()
    $excluded    = @()
    $notIncluded = @()

    foreach ($item in $candidates) {
        $key = & $normalize $item
        # Exclude is evaluated first so it wins over an overlapping include.
        if ($excludeKeys.ContainsKey($key)) {
            $excludeKeys[$key] = $true
            $excluded += $item
            continue
        }
        if ($includeKeys.Count -gt 0) {
            if ($includeKeys.ContainsKey($key)) {
                $includeKeys[$key] = $true
                $included += $item
            } else {
                $notIncluded += $item
            }
            continue
        }
        $included += $item
    }

    $unmatchedInclude = @($includeFilters | Where-Object { -not $includeKeys[(& $normalize $_)] })
    $unmatchedExclude = @($excludeFilters | Where-Object { -not $excludeKeys[(& $normalize $_)] })

    # Nothing discovered is a scope problem, not a targeting problem — it must
    # not be reported as starvation.
    $isStarved = ($candidates.Count -gt 0) -and ($included.Count -eq 0)

    [PSCustomObject]@{
        candidates         = $candidates
        include            = $includeFilters
        exclude            = $excludeFilters
        included           = $included
        excluded           = $excluded
        notIncluded        = $notIncluded
        unmatchedInclude   = $unmatchedInclude
        unmatchedExclude   = $unmatchedExclude
        candidateCount     = $candidates.Count
        includedCount      = $included.Count
        excludedCount      = $excluded.Count
        isStarved          = $isStarved
        starvedByExclusion = ($isStarved -and $excluded.Count -gt 0)
    }
}

function Write-BlastRadiusCard {
    <#
    .SYNOPSIS
        Renders a resolved blast radius as Markdown, before any mutation.
    .DESCRIPTION
        The card is a *prediction*, never an enforcement. `az chaos scenario
        config create` accepts no target filter, so `resourceTargeting` is not
        transmitted to Azure Chaos Studio: it shapes this preview and the
        starvation refusal (CS-7) only. Every rendering here says so, because a
        card that implies an exclusion was applied when it was not is strictly
        worse than rendering nothing (F8).
    .PARAMETER BlastRadius
        The object returned by Resolve-BlastRadius.
    .PARAMETER Title
        Card heading. Defaults to 'Blast Radius (Predicted)'.
    .PARAMETER Note
        Optional extra body line (e.g. where the candidate set came from).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$BlastRadius,

        [Parameter()]
        [string]$Title = 'Blast Radius (Predicted)',

        [Parameter()]
        [string]$Note
    )

    $br = $BlastRadius
    $status = if ($br.isStarved) {
        '⚠️ Nothing in scope'
    } elseif ($br.candidateCount -eq 0) {
        # Not starvation (blast-radius.md §4 row 3) — but never a green check
        # either: "this will touch nothing" is the same silent no-op as CS-7.
        'ℹ️ Nothing discovered in scope'
    } else {
        "✅ $($br.includedCount) predicted affected"
    }

    $advisory = @'
**This is a preview of what the service is expected to target — it is not an
enforced filter.** `resourceTargeting` is **advisory only**: it is not
transmitted to Azure Chaos Studio, so an exclusion shown below is **not**
enforced by the service. To actually spare a resource, remove it from the
workspace scope or disable its Chaos target before running. See
`references/chaos/blast-radius.md`.
'@
    $body = if ($Note) { "$advisory`n`n$Note" } else { $advisory }

    Write-Card -Title $Title -Status $status -Body $body -Properties ([ordered]@{
        'Discovered'            = $br.candidateCount
        'Predicted affected'    = $br.includedCount
        'Excluded (advisory)'   = $br.excludedCount
        'Not included (advisory)' = @($br.notIncluded).Count
    })

    if (@($br.included).Count -gt 0) {
        Write-Table -Data @($br.included | ForEach-Object { [ordered]@{ 'Predicted Affected Resource' = $_ } }) `
            -Title 'Predicted Affected Resources'
    } else {
        Write-Output '### Predicted Affected Resources'
        Write-Output ''
        Write-Output '*(none)*'
        Write-Output ''
    }

    $dropped = @()
    foreach ($item in @($br.excluded))    { $dropped += [ordered]@{ 'Resource' = $item; 'Reason' = 'Excluded by resourceTargeting.exclude (advisory — not enforced by the service)' } }
    foreach ($item in @($br.notIncluded)) { $dropped += [ordered]@{ 'Resource' = $item; 'Reason' = 'Not listed in resourceTargeting.include (advisory — not enforced by the service)' } }
    if ($dropped.Count -gt 0) {
        Write-Table -Data $dropped -Title 'Excluded / Not Included (advisory — not enforced by the service)'
    }

    $unmatched = @($br.unmatchedInclude) + @($br.unmatchedExclude)
    if ($unmatched.Count -gt 0) {
        Write-Card -Title 'Targeting Filters That Matched Nothing' -Status '⚠️' -Body @"
These ``resourceTargeting`` entries did not match any discovered resource. A
mistyped exclusion silently widens the blast radius, so they are named here
rather than dropped:

$(($unmatched | ForEach-Object { "- ``$_``" }) -join "`n")
"@
    }

    if ($br.isStarved) {
        $cause = if ($br.starvedByExclusion) {
            'Every discovered resource was removed by ``resourceTargeting.exclude``.'
        } else {
            '``resourceTargeting.include`` matched none of the discovered resources.'
        }
        Write-Card -Title 'Leg Starvation' -Status '⚠️' -Body @"
$cause

A scenario with no affected resources will start and finish without exercising
anything (CS-7). Widen the targeting or remove the exclusion before continuing.
See ``references/chaos/blast-radius.md`` for the precedence rules and the
per-fault exclusion recipes.
"@
    }
}

# When imported via Import-Module, all functions are exported by default.
# When dot-sourced, functions are available in the calling scope.
