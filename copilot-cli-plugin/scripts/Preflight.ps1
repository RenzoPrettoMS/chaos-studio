<#
.SYNOPSIS
    Host-visible MCP tool preflight for the startchaos skills.

.DESCRIPTION
    Every skill declares the MCP tools it depends on in its SKILL.md
    frontmatter under `requiredTools:`. Before a skill takes an MCP-backed
    path, the orchestrator compares that declaration against the tool
    inventory the **host** reports (the MCP `tools/list` response surfaced by
    the CLI) and stops with a named failure when anything is missing.

    The inventory is ALWAYS supplied by the caller. This file never asks the
    chaos-studio server to describe itself: server self-introspection would
    report what the server *registers*, not what the host actually exposes,
    which is exactly the registration-vs-runtime gap this preflight exists to
    catch (F5).

    Dot-source this file from any skill script or orchestrator step:
        . "$PSScriptRoot/../../scripts/Preflight.ps1"
#>

# Prefix of every preflight failure message. Mirrored by
# `mcp/tests/test_tool_manifest.py::PREFLIGHT_FAILURE_PREFIX`; the two are
# asserted to stay in sync.
function Get-PreflightFailurePrefix {
    <# Returns the invariant prefix of the named preflight failure message. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'Preflight failed: the MCP host does not expose required tool(s):'
}

function Get-SkillRequiredTools {
    <#
    .SYNOPSIS
        Reads the `requiredTools:` list from a SKILL.md frontmatter block.
    .PARAMETER SkillPath
        Path to a SKILL.md file.
    .OUTPUTS
        [string[]] declared tool names, in declaration order. Empty when the
        skill declares no MCP tools.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$SkillPath
    )

    if (-not (Test-Path -LiteralPath $SkillPath)) {
        throw "Get-SkillRequiredTools: no SKILL.md at $SkillPath"
    }

    $lines = Get-Content -LiteralPath $SkillPath -Encoding utf8
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') {
        throw "Get-SkillRequiredTools: $SkillPath has no YAML frontmatter."
    }

    $tools = [System.Collections.Generic.List[string]]::new()
    $inRequired = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim() -eq '---') { break }
        if ($line -match '^requiredTools:\s*$') { $inRequired = $true; continue }
        if ($inRequired) {
            if ($line -match '^\s+-\s*(\S+)\s*(#.*)?$') {
                $tools.Add($Matches[1])
                continue
            }
            # Any non-list line ends the block.
            $inRequired = $false
        }
    }

    return , $tools.ToArray()
}

function Test-RequiredTools {
    <#
    .SYNOPSIS
        Compares declared required tools against the host's tool inventory.
    .DESCRIPTION
        Returns a result object rather than throwing so callers can render a
        card. `missing` preserves the exact declared names — the preflight
        never proposes or silently swaps in a substitute tool.
    .PARAMETER RequiredTools
        Tool names the skill declared (see Get-SkillRequiredTools).
    .PARAMETER AvailableTools
        Tool names the HOST reported via MCP `tools/list`. Pass an empty array
        when no MCP server is registered.
    .OUTPUTS
        [ordered] @{ ok = [bool]; missing = [string[]]; message = [string] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RequiredTools,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AvailableTools
    )

    $available = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$AvailableTools, [System.StringComparer]::Ordinal)

    $missing = @($RequiredTools | Where-Object { -not $available.Contains($_) })

    if ($missing.Count -eq 0) {
        return [ordered]@{
            ok      = $true
            missing = @()
            message = "Preflight passed: all $($RequiredTools.Count) required MCP tool(s) are present in the host inventory."
        }
    }

    $names = ($missing | Sort-Object) -join ', '
    return [ordered]@{
        ok      = $false
        missing = $missing
        message = "$(Get-PreflightFailurePrefix) $names. Register the 'chaos-studio' MCP server with the host (see mcp/README.md) and retry. Do NOT substitute another tool or improvise."
    }
}

function Assert-RequiredTools {
    <#
    .SYNOPSIS
        Test-RequiredTools, but throws the named failure message.
    .DESCRIPTION
        Convenience wrapper for skill scripts that must stop the pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$RequiredTools,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AvailableTools
    )

    $result = Test-RequiredTools -RequiredTools $RequiredTools -AvailableTools $AvailableTools
    if (-not $result.ok) {
        throw $result.message
    }
    return $result
}

# When imported via Import-Module, all functions are exported by default.
# When dot-sourced, functions are available in the calling scope.
