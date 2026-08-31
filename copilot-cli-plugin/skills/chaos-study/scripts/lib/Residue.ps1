# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    The durable residue ledger: every Azure object a study creates, recorded so
    it can be observed and removed rather than assumed gone.

.DESCRIPTION
    A study creates real resources - a preflight configuration, an execution
    configuration, scenario runs, and (later) role assignments. If cleanup is
    attempted and never observed, a leak is invisible; if it is never recorded,
    it cannot be cleaned up by a later resume at all. The ledger is the single
    place those objects are written down, at the moment they are created, with
    a `cleanup` block that starts life unattempted and is only ever advanced to
    a real, observed outcome.

    This file owns:
      1. The on-disk ledger (`residue-ledger.json`) read/write helpers, keyed by
         the study path so there is exactly one ledger per study.
      2. `New-ChaosResidueEntry` - the entry shape (id + provenance + time +
         cleanup{attemptedAt,status,error,command}).
      3. `Add-ChaosResidueEntry` - append-or-replace by (kind,id), idempotent so
         a re-run does not double-record the same object.
      4. `Add-ChaosPreflightResidueEntry` - the Epic 3 caller: records the
         deterministic preflight configuration created during scope/readiness.

    Epic 3 introduces the ledger with just enough to record the preflight
    configuration. Later epics extend the entry kinds and add observed removal;
    the schema here is deliberately forward-compatible with that.

    Requires Common.ps1 (hashing, JSON, UTC) to be dot-sourced first.
#>

Set-StrictMode -Version Latest

if (-not (Get-Command Get-ChaosUtcNow -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

$ChaosResidueLedgerVersion = 'residue-ledger.v1'

function Get-ChaosResidueLedgerPath {
    <#
    .SYNOPSIS
        The residue-ledger.json path for a study. One ledger per study path.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)
    return Join-Path $StudyPath 'residue-ledger.json'
}

function Get-ChaosResidueLedger {
    <#
    .SYNOPSIS
        Read a study's residue ledger, returning an empty ledger when none has
        been written yet.

    .DESCRIPTION
        A missing ledger is not an error: a study that has created nothing has
        nothing to record. The empty shape matches a written one so callers
        never branch on presence.
    #>
    param([Parameter(Mandatory)][string]$StudyPath)

    $path = Get-ChaosResidueLedgerPath -StudyPath $StudyPath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ ledgerVersion = $ChaosResidueLedgerVersion; entries = @() }
    }

    $ledger = Read-ChaosJsonFile -Path $path
    if ($null -eq $ledger) {
        return [pscustomobject]@{ ledgerVersion = $ChaosResidueLedgerVersion; entries = @() }
    }
    return $ledger
}

function New-ChaosResidueEntry {
    <#
    .SYNOPSIS
        Build one residue-ledger entry.

    .DESCRIPTION
        The cleanup block starts unattempted - never "succeeded" by default -
        so an entry that is never cleaned up reads as exactly that. Only an
        observed removal is allowed to change it.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('workspace', 'preflightConfiguration', 'executionConfiguration', 'scenarioRun', 'roleAssignment')]
        [string]$Kind,
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][AllowEmptyString()][string]$Name = $null,
        [AllowNull()][object]$Provenance = $null
    )

    return [ordered]@{
        kind       = $Kind
        id         = $Id
        name       = if ([string]::IsNullOrWhiteSpace($Name)) { $null } else { $Name }
        provenance = $Provenance
        createdAt  = Get-ChaosUtcNow
        cleanup    = [ordered]@{
            attemptedAt = $null
            status      = 'unattempted'
            error       = $null
            command     = $null
        }
    }
}

function Add-ChaosResidueEntry {
    <#
    .SYNOPSIS
        Append a residue entry to a study's ledger, replacing any existing entry
        with the same (kind,id) so re-recording is idempotent.

    .DESCRIPTION
        Idempotency matters because a resumed study can pass the same creation
        point twice; recording the object twice would inflate the ledger and
        misreport how much residue a run actually left. Refuses a sealed study,
        because a sealed study is immutable and its ledger describes the run it
        was sealed from.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][object]$Entry
    )

    if (Get-Command Test-ChaosStudySealed -ErrorAction SilentlyContinue) {
        if (Test-ChaosStudySealed -StudyPath $StudyPath) {
            throw "StudyAlreadySealed: '$StudyPath' is sealed and its residue ledger cannot be modified."
        }
    }

    $entryKind = if ($Entry -is [System.Collections.IDictionary]) { [string]$Entry['kind'] } else { [string]$Entry.kind }
    $entryId = if ($Entry -is [System.Collections.IDictionary]) { [string]$Entry['id'] } else { [string]$Entry.id }
    if ([string]::IsNullOrWhiteSpace($entryId)) {
        throw 'Add-ChaosResidueEntry: the entry has no id, so it cannot be tracked or later removed.'
    }

    $ledger = Get-ChaosResidueLedger -StudyPath $StudyPath
    $existing = @(@($ledger.entries) | Where-Object {
            $null -ne $_ -and -not (([string]$_.kind -eq $entryKind) -and ([string]$_.id -eq $entryId))
        })

    $updated = [ordered]@{
        ledgerVersion = $ChaosResidueLedgerVersion
        entries       = @($existing + @($Entry))
    }

    $path = Get-ChaosResidueLedgerPath -StudyPath $StudyPath
    Write-ChaosJsonFile -Path $path -InputObject $updated | Out-Null
    return $updated
}

function Add-ChaosPreflightResidueEntry {
    <#
    .SYNOPSIS
        Record the deterministic preflight configuration a study created while
        validating its effective legs, so it is never a silent leak.

    .DESCRIPTION
        The preflight configuration is a real Chaos Studio resource created
        before any fault consent. Recording it here means a later run can reuse
        it, and a later cleanup can remove it, both by a name the study wrote
        down rather than one it has to guess.
    #>
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$ConfigurationName,
        [AllowNull()][object]$Workspace = $null,
        [AllowNull()][AllowEmptyString()][string]$Adapter = $null,
        [AllowNull()][AllowEmptyString()][string]$ValidationStatus = $null,
        [AllowNull()][AllowEmptyString()][string]$EffectivePlanHash = $null
    )

    $provenance = [ordered]@{
        origin            = 'preflight'
        adapter           = if ([string]::IsNullOrWhiteSpace($Adapter)) { $null } else { $Adapter }
        resourceGroup     = if ($Workspace) { $Workspace.resourceGroup } else { $null }
        workspaceName     = if ($Workspace) { $Workspace.name } else { $null }
        scenario          = if ($Workspace -and ($Workspace.PSObject.Properties.Name -contains 'scenario')) { $Workspace.scenario } else { $null }
        validationStatus  = if ([string]::IsNullOrWhiteSpace($ValidationStatus)) { $null } else { $ValidationStatus }
        effectivePlanHash = if ([string]::IsNullOrWhiteSpace($EffectivePlanHash)) { $null } else { $EffectivePlanHash }
    }

    $entry = New-ChaosResidueEntry -Kind 'preflightConfiguration' -Id $ConfigurationName -Name $ConfigurationName -Provenance $provenance
    return Add-ChaosResidueEntry -StudyPath $StudyPath -Entry $entry
}
