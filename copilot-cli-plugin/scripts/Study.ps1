<#
.SYNOPSIS
    The immutable dated study store (EPIC-004).

.DESCRIPTION
    A study is a named, dated, reproducible unit of work. This script creates,
    seals, enumerates and re-reads one, entirely offline:

        $CHAOS_STUDY_ROOT/<scopeHash>/index.json
        $CHAOS_STUDY_ROOT/<scopeHash>/<studyId>/
            manifest.json          sealed; SHA-256 over every file below,
                                   excluding itself and SEALED
            study-plan.v1.json
            run-record.v1.json
            findings.v1.json
            report.html
            commands.jsonl
            evidence/{pre,during,post}/*.json
            SEALED                 presence = immutable

    The store deliberately lives outside the repository, outside `$env:TEMP`
    and never next to `startchaos-state.json` (FR-14). Field evidence F12
    recorded two `tmp/` wipes that cost two runs of evidence.

    Sealing is one-way (D7): once `SEALED` exists, `Save-StudyArtifact` refuses
    every write with `StudyAlreadySealed` (exit code 13). There is no force
    flag, by design.

    The store is built on the `[E2]` evidence primitives, not beside them
    (D16): `State.ps1` supplies the scope hash, the redaction denylists, the
    exclusive lock and the atomic temp-file + rename write. What this script
    adds is *sealing*, *dating* and *enumeration*.

.NOTES
    Study schema version: 1.
    `Add-CommandTrailEntry` (the redacted `commands.jsonl` writer, FR-22)
    lands in EPIC-006 and is deliberately not here.
#>

# The [E2] primitives. Dot-sourced, so a caller that dot-sources this script
# gets both surfaces in one scope and the redaction vocabulary is shared rather
# than forked (D16).
. (Join-Path $PSScriptRoot 'State.ps1')

# ── Constants ───────────────────────────────────────────
$script:StudySchemaVersion = 1
$script:StudyAppDir = 'chaos-studio'
$script:StudyRootLeaf = 'studies'
$script:StudySealMarker = 'SEALED'
$script:StudyManifestName = 'manifest.json'
$script:StudyIndexName = 'index.json'
$script:StudyPlanName = 'study-plan.v1.json'
$script:StudyRunRecordName = 'run-record.v1.json'
$script:StudyFindingsName = 'findings.v1.json'
$script:StudyReportName = 'report.html'
$script:StudyEvidencePhases = @('pre', 'during', 'post')
$script:StudyConfigFileName = '.chaos-plugins.yaml'
$script:StudyDefaultRetentionDays = 365
$script:StudyDefaultAbandonHours = 72

# A structural path segment: must start alphanumeric, and may then carry only
# characters that cannot express traversal or a drive/UNC qualifier.
$script:StudySegmentPattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Exit codes owned by the study store. The shipped 0–4 block is frozen by
# EPIC-003 and is not touched here.
$script:StudyExitCodes = [ordered]@{
    StudyAlreadySealed = 13
}

# Files that are never part of the sealed content: the manifest cannot hash
# itself, the marker is written after the manifest, and lock/scratch files are
# transient by construction.
$script:StudyUnhashedNames = @($script:StudyManifestName, $script:StudySealMarker)

function Get-StudyExitCode {
    <#
    .SYNOPSIS
        Maps a study error type to its process exit code.
    .PARAMETER ErrorType
        e.g. 'StudyAlreadySealed'.
    .OUTPUTS
        The integer exit code, or 1 for an error type this store does not own.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ErrorType)

    if ($script:StudyExitCodes.Contains($ErrorType)) {
        return [int]$script:StudyExitCodes[$ErrorType]
    }
    return 1
}

function New-StudyErrorRecord {
    <#
    .SYNOPSIS
        Builds a typed error record carrying the error type and its exit code.
    .DESCRIPTION
        The error type leads the message so a caller that only sees the string
        can still identify it, and it is also the FullyQualifiedErrorId. The
        exit code rides on TargetObject so a skill wrapper can exit with it
        without re-deriving anything from prose.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ErrorType,
        [Parameter(Mandatory)][string]$Message
    )

    $exception = [System.InvalidOperationException]::new("${ErrorType}: $Message")
    $record = [System.Management.Automation.ErrorRecord]::new(
        $exception, $ErrorType,
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        [ordered]@{ errorType = $ErrorType; exitCode = (Get-StudyExitCode -ErrorType $ErrorType) })
    return $record
}

function Get-StudyRootFromConfig {
    <#
    .SYNOPSIS
        Reads `studyRoot` from the nearest `.chaos-plugins.yaml`, or $null.
    .DESCRIPTION
        Walks up from $StartDirectory to the filesystem root. Only a top-level,
        unindented `studyRoot:` key is honoured, so a nested key of the same
        name in some other block cannot silently relocate the store. A relative
        value resolves against the directory holding the config file, so the
        answer does not depend on the caller's working directory.
    #>
    [CmdletBinding()]
    param([string]$StartDirectory)

    if (-not $StartDirectory) { $StartDirectory = (Get-Location).Path }
    $current = [System.IO.Path]::GetFullPath($StartDirectory)

    while ($current) {
        $candidate = Join-Path $current $script:StudyConfigFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            foreach ($line in (Get-Content -LiteralPath $candidate -Encoding utf8)) {
                if ($line -match '^studyRoot\s*:\s*(.+?)\s*$') {
                    $value = $Matches[1] -replace '\s+#.*$', ''
                    $value = $value.Trim().Trim('"').Trim("'")
                    if (-not $value) { continue }
                    if ([System.IO.Path]::IsPathRooted($value)) {
                        return [System.IO.Path]::GetFullPath($value)
                    }
                    return [System.IO.Path]::GetFullPath((Join-Path $current $value))
                }
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $null
}

function Get-StudyRoot {
    <#
    .SYNOPSIS
        Returns the study root directory (not created here).
    .DESCRIPTION
        Resolution order (FR-14):
          1. $env:CHAOS_STUDY_ROOT
          2. `studyRoot` in the nearest `.chaos-plugins.yaml`
          3. per-user application data (Q7):
             %LOCALAPPDATA%\chaos-studio\studies,
             ~/Library/Application Support/chaos-studio/studies,
             ${XDG_DATA_HOME:-~/.local/share}/chaos-studio/studies

        Never the repository, never $env:TEMP, never next to
        `startchaos-state.json`. Nothing is created: the root comes into
        existence on the first study.
    .PARAMETER ConfigStart
        Directory to begin the `.chaos-plugins.yaml` search from. Defaults to
        the current location.
    #>
    [CmdletBinding()]
    param([string]$ConfigStart)

    if ($env:CHAOS_STUDY_ROOT) {
        return $env:CHAOS_STUDY_ROOT
    }

    $configured = Get-StudyRootFromConfig -StartDirectory $ConfigStart
    if ($configured) { return $configured }

    $isWin = $IsWindows -or ($env:OS -eq 'Windows_NT')
    if ($isWin) {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }
    } elseif ($IsMacOS) {
        $base = Join-Path $HOME 'Library/Application Support'
    } else {
        $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
    }

    return (Join-Path (Join-Path $base $script:StudyAppDir) $script:StudyRootLeaf)
}

function Get-StudyRetentionDays {
    <# Retention in days; purge is always explicit and never implicit. #>
    [CmdletBinding()]
    param()

    $days = $script:StudyDefaultRetentionDays
    if ($env:CHAOS_STUDY_RETENTION_DAYS -and
        [int]::TryParse($env:CHAOS_STUDY_RETENTION_DAYS, [ref]$days) -and $days -ge 0) {
        return $days
    }
    return $script:StudyDefaultRetentionDays
}

function Get-StudyAbandonHours {
    <# Hours after which a PLANNED study with no run record reads ABANDONED. #>
    [CmdletBinding()]
    param()

    $hours = $script:StudyDefaultAbandonHours
    if ($null -ne $env:CHAOS_STUDY_ABANDON_HOURS -and $env:CHAOS_STUDY_ABANDON_HOURS -ne '' -and
        [int]::TryParse($env:CHAOS_STUDY_ABANDON_HOURS, [ref]$hours) -and $hours -ge 0) {
        return $hours
    }
    return $script:StudyDefaultAbandonHours
}

function Resolve-StudyPath {
    <#
    .SYNOPSIS
        Resolves a path inside the study store, refusing to leave it.
    .DESCRIPTION
        Structural segments (`ScopeHash`, `StudyId`) must be safe names.
        `RelativePath` is rejected before resolution when it is absolute,
        drive-qualified, UNC, or contains a `..` segment — the same rules the
        `[E2]` evidence tools apply. The canonicalized result is then asserted
        to sit under the canonicalized root, so a mistake in the rules above
        still cannot write outside the store.
    .OUTPUTS
        The absolute path. The file need not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScopeHash,
        [string]$StudyId,
        [string]$RelativePath,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    $target = $fullRoot
    foreach ($segment in @($ScopeHash, $StudyId)) {
        if (-not $segment) { continue }
        if ($segment -notmatch $script:StudySegmentPattern) {
            throw (New-StudyErrorRecord -ErrorType 'StudyPathOutsideRoot' `
                    -Message "'$segment' is not a safe study path segment.")
        }
        $target = Join-Path $target $segment
    }

    if ($RelativePath) {
        if ([System.IO.Path]::IsPathRooted($RelativePath) -or
            $RelativePath -match '^[A-Za-z]:' -or
            $RelativePath.StartsWith('\\') -or $RelativePath.StartsWith('//')) {
            throw (New-StudyErrorRecord -ErrorType 'StudyPathOutsideRoot' `
                    -Message "'$RelativePath' is absolute, drive-qualified or UNC.")
        }
        $parts = $RelativePath -split '[\\/]+' | Where-Object { $_ -ne '' -and $_ -ne '.' }
        foreach ($part in $parts) {
            if ($part -eq '..' -or $part -notmatch $script:StudySegmentPattern) {
                throw (New-StudyErrorRecord -ErrorType 'StudyPathOutsideRoot' `
                        -Message "'$RelativePath' escapes the study directory.")
            }
            $target = Join-Path $target $part
        }
    }

    $resolved = [System.IO.Path]::GetFullPath($target)
    if ($resolved -ne $fullRoot -and
        -not $resolved.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar)) {
        throw (New-StudyErrorRecord -ErrorType 'StudyPathOutsideRoot' `
                -Message "'$resolved' resolves outside the study root '$fullRoot'.")
    }
    return $resolved
}

function Protect-StudyText {
    <#
    .SYNOPSIS
        Scrubs secret-shaped tokens EMBEDDED in a string.
    .DESCRIPTION
        `Protect-EvidenceData` redacts secret-bearing keys and values that are
        secrets in their entirety. A token pasted into an error message or an
        `az` argv is neither, so it would otherwise survive. This applies the
        same shapes — read from `Get-EvidenceRedactionList`, never a private
        copy (D16) — to any substring (NFR-5).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if (-not $Text) { return $Text }
    $lists = Get-EvidenceRedactionList
    $out = $Text
    foreach ($pattern in $lists['secretValuePatterns']) {
        $out = [System.Text.RegularExpressions.Regex]::Replace($out, $pattern, $lists['redacted'])
    }
    return $out
}

function ConvertTo-StudyJson {
    <# Redacts an object by key, by value shape and by embedded token, then serializes. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Data)

    return (Protect-StudyText -Text ((Protect-EvidenceData -Data $Data) | ConvertTo-Json -Depth 32))
}

function New-StudyProvenance {
    <# The mandatory `[E2]` provenance stanza for artifacts this script writes. #>
    [CmdletBinding()]
    param([string]$Tool = 'Study.ps1')

    return [ordered]@{
        source        = [ordered]@{ tool = $Tool; apiVersion = $null; query = $null }
        collectedAt   = (Get-Date).ToUniversalTime().ToString('o')
        confidence    = 'high'
        maxAgeMinutes = $null
        stale         = $false
    }
}

function ConvertTo-StudyTimestamp {
    <#
    .SYNOPSIS
        Normalises a timestamp read back from JSON to an ISO 8601 UTC string.
    .DESCRIPTION
        `ConvertFrom-Json` coerces an ISO 8601 string into a [datetime], so a
        naive round-trip re-serializes it in the current culture's format and
        loses the offset. Every timestamp this store re-reads goes through
        here, so `createdAt` and `sealedAt` mean the same instant on every
        machine a study travels to (NFR-11). A value with no zone is read as
        UTC, because that is the only zone this store ever writes.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [datetime]) {
        $moment = [datetime]$Value
    } else {
        $moment = [datetime]::MinValue
        $parsed = [datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$moment)
        if (-not $parsed) { return [string]$Value }
    }

    if ($moment.Kind -eq [System.DateTimeKind]::Unspecified) {
        $moment = [datetime]::SpecifyKind($moment, [System.DateTimeKind]::Utc)
    }
    return $moment.ToUniversalTime().ToString('o')
}

function Test-StudySealed {
    <# True when the SEALED marker is present. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StudyPath)

    return (Test-Path -LiteralPath (Join-Path $StudyPath $script:StudySealMarker) -PathType Leaf)
}

function Assert-StudyUnsealed {
    <# Throws StudyAlreadySealed when the study is sealed. No force flag (D7). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$StudyId
    )

    if (Test-StudySealed -StudyPath $StudyPath) {
        throw (New-StudyErrorRecord -ErrorType 'StudyAlreadySealed' `
                -Message "study '$StudyId' is sealed; sealing is one-way and there is no force flag. Create a new study instead.")
    }
}

function Get-StudyRelativeFile {
    <#
    .SYNOPSIS
        Every real file under a study, as sorted POSIX-relative paths.
    .DESCRIPTION
        Lock and scratch files are transient by construction and are never part
        of a study. Sorting makes the manifest byte-identical for identical
        content on every OS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [string[]]$Exclude = @()
    )

    if (-not (Test-Path -LiteralPath $StudyPath)) { return @() }
    $prefix = [System.IO.Path]::GetFullPath($StudyPath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    $names = foreach ($file in (Get-ChildItem -LiteralPath $StudyPath -Recurse -Force -File)) {
        if ($file.Name -like '*.lock' -or $file.Name -like '*.tmp.*') { continue }
        $relative = $file.FullName.Substring($prefix.Length + 1) -replace '\\', '/'
        if ($Exclude -contains $relative) { continue }
        $relative
    }
    return @($names | Sort-Object -CaseSensitive)
}

function Get-StudyFileDigest {
    <# {path, sha256, bytes} for one file, hashes lower-cased for stable diffing. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $full = Join-Path $StudyPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    return [ordered]@{
        path   = $RelativePath
        sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes  = (Get-Item -LiteralPath $full).Length
    }
}

function New-Study {
    <#
    .SYNOPSIS
        Creates a new unsealed study directory and writes its plan.
    .DESCRIPTION
        `studyId = <UTC yyyyMMddTHHmmssZ>-<8 hex of scopeHash‖plan digest‖nonce>`:
        sortable, human-dated and collision-resistant, so two studies over an
        identical plan never share an identity (D7 — a rerun is a new study).

        The plan is written in the `[E2]` artifact envelope, redacted on the
        way to disk, with the evidence/{pre,during,post} tree created up front
        so a study that crashes mid-execution is still a well-formed PLANNED
        study with a partial evidence tree.
    .PARAMETER ScopeHash
        The `[E2]` scope hash. Derived from -State when omitted.
    .PARAMETER State
        Plugin state, used only to derive the scope hash via the shared
        `Get-EvidenceScopeHash` (D16).
    .PARAMETER Plan
        The `study-plan.v1` payload.
    .PARAMETER Scope
        Human-readable scope descriptor recorded in the plan and the manifest.
    .PARAMETER DerivedFrom
        The studyId this plan was copied from, for a rerun.
    .OUTPUTS
        A hashtable: studyId, scopeHash, path, root, state, createdAt.
    #>
    [CmdletBinding()]
    param(
        [string]$ScopeHash,
        [System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [System.Collections.IDictionary]$Scope,
        [string]$DerivedFrom,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }
    if (-not $ScopeHash) { $ScopeHash = Get-EvidenceScopeHash -State $State }

    $createdAt = (Get-Date).ToUniversalTime()
    $stamp = $createdAt.ToString("yyyyMMdd'T'HHmmss'Z'")

    $planDigest = Get-StudyStringHash -Value ($Plan | ConvertTo-Json -Depth 32)
    $nonce = [guid]::NewGuid().ToString('n')
    $suffix = (Get-StudyStringHash -Value (@($ScopeHash, $planDigest, $nonce) -join '|')).Substring(0, 8)
    $studyId = "$stamp-$suffix"

    $studyPath = Resolve-StudyPath -ScopeHash $ScopeHash -StudyId $studyId -Root $Root
    New-Item -ItemType Directory -Path $studyPath -Force | Out-Null
    foreach ($phase in $script:StudyEvidencePhases) {
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $studyPath 'evidence') $phase) -Force | Out-Null
    }

    $payload = [ordered]@{}
    $payload['studyId'] = $studyId
    foreach ($key in @($Plan.Keys)) {
        if ($key -eq 'studyId') { continue }
        $payload[[string]$key] = $Plan[$key]
    }

    $scopeId = if ($Scope -and $Scope['scopeId']) { [string]$Scope['scopeId'] } else { $ScopeHash }
    $envelope = [ordered]@{
        artifactSchemaVersion = 1
        artifactType          = 'study-plan'
        scopeId               = $scopeId
        runId                 = $studyId
        generatedAt           = $createdAt.ToString('o')
        provenance            = (New-StudyProvenance)
        warnings              = @()
        scope                 = $Scope
        derivedFrom           = $DerivedFrom
        plan                  = $payload
    }

    Save-StudyArtifact -StudyId $studyId -ScopeHash $ScopeHash -Root $Root `
        -Name $script:StudyPlanName -Data $envelope | Out-Null

    [Console]::Error.WriteLine("[Study] Created $studyId at $studyPath")
    return [ordered]@{
        studyId   = $studyId
        scopeHash = $ScopeHash
        path      = $studyPath
        root      = $Root
        state     = 'PLANNED'
        createdAt = $createdAt.ToString('o')
    }
}

function Get-StudyStringHash {
    <# Lower-case SHA-256 of a UTF-8 string. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    } finally {
        $sha.Dispose()
    }
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Save-StudyArtifact {
    <#
    .SYNOPSIS
        Writes one artifact into an unsealed study, atomically and redacted.
    .DESCRIPTION
        Refuses every write to a sealed study with `StudyAlreadySealed` (exit
        code 13). **There is no force flag** — a sealed study is terminal, and
        a rerun creates a new study (D7).

        The write itself reuses the `[E2]` primitives: the exclusive lock and
        the temp-file + rename commit, so a reader never sees a partial
        artifact and a failed write leaves no scratch behind.
    .PARAMETER Name
        Artifact name, optionally with a relative subpath such as
        'evidence/pre/metrics.json'.
    .PARAMETER Data
        An object to serialize. Redacted by key, by value shape and by embedded
        token before it reaches disk.
    .PARAMETER Content
        Pre-rendered text (report.html, commands.jsonl). Scrubbed for embedded
        tokens before it reaches disk.
    .OUTPUTS
        A hashtable describing the written item.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Data')]
    param(
        [Parameter(Mandatory)][string]$StudyId,
        [Parameter(Mandatory)][string]$Name,
        [string]$ScopeHash,
        [Parameter(ParameterSetName = 'Data')][AllowNull()][object]$Data,
        [Parameter(Mandatory, ParameterSetName = 'Content')][AllowEmptyString()][string]$Content,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }
    if (-not $ScopeHash) { $ScopeHash = Find-StudyScopeHash -StudyId $StudyId -Root $Root }

    $studyPath = Resolve-StudyPath -ScopeHash $ScopeHash -StudyId $StudyId -Root $Root
    if (-not (Test-Path -LiteralPath $studyPath -PathType Container)) {
        throw (New-StudyErrorRecord -ErrorType 'StudyNotFound' -Message "no study '$StudyId' under '$Root'.")
    }
    Assert-StudyUnsealed -StudyPath $studyPath -StudyId $StudyId

    $target = Resolve-StudyPath -ScopeHash $ScopeHash -StudyId $StudyId -RelativePath $Name -Root $Root
    $directory = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $text = if ($PSCmdlet.ParameterSetName -eq 'Content') {
        Protect-StudyText -Text $Content
    } else {
        ConvertTo-StudyJson -Data $Data
    }

    Invoke-WithEvidenceLock -LockPath "${target}.lock" -Action {
        # Re-checked under the lock: a concurrent Complete-Study may have
        # sealed the study between the check above and this commit.
        Assert-StudyUnsealed -StudyPath $studyPath -StudyId $StudyId
        Write-EvidenceFileAtomic -Path $target -Content $text
    }

    $relative = $target.Substring([System.IO.Path]::GetFullPath($studyPath).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar).Length + 1) -replace '\\', '/'
    return [ordered]@{
        studyId      = $StudyId
        scopeHash    = $ScopeHash
        path         = $target
        relativePath = $relative
        bytes        = (Get-Item -LiteralPath $target).Length
    }
}

function Complete-Study {
    <#
    .SYNOPSIS
        Seals a study. One-way (D7).
    .DESCRIPTION
        A three-step commit, in this exact order, so a crash at any point
        leaves a detectably incomplete study rather than a lying one:

          1. render `report.html` into a temp file and rename it into place;
          2. hash every file except `manifest.json` and `SEALED` — neither
             exists yet — and write `manifest.json` atomically;
          3. create the `SEALED` marker, then append one record to the scope's
             `index.json`.

        The manifest is self-describing (NFR-11): schema versions, api
        versions, tool substitutions, scope descriptor, `faultPath` and
        `derivedFrom` all travel with the study, so a zipped study opens on
        another machine with no credentials and no network.
    .OUTPUTS
        The manifest payload hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StudyId,
        [string]$ScopeHash,
        [string]$ReportHtml,
        [ValidateSet('completed', 'blocked', 'abandoned', 'failed')]
        [string]$Outcome = 'completed',
        [System.Collections.IDictionary]$Scope,
        [string]$FaultPath,
        [System.Collections.IDictionary]$ApiVersions,
        [object[]]$ToolSubstitutions,
        [string]$DerivedFrom,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }
    if (-not $ScopeHash) { $ScopeHash = Find-StudyScopeHash -StudyId $StudyId -Root $Root }

    $studyPath = Resolve-StudyPath -ScopeHash $ScopeHash -StudyId $StudyId -Root $Root
    if (-not (Test-Path -LiteralPath $studyPath -PathType Container)) {
        throw (New-StudyErrorRecord -ErrorType 'StudyNotFound' -Message "no study '$StudyId' under '$Root'.")
    }
    Assert-StudyUnsealed -StudyPath $studyPath -StudyId $StudyId

    $planEnvelope = Read-StudyJson -Path (Join-Path $studyPath $script:StudyPlanName)
    $plan = if ($planEnvelope) { $planEnvelope['plan'] } else { $null }
    $createdAt = if ($planEnvelope -and $planEnvelope['generatedAt']) {
        ConvertTo-StudyTimestamp -Value $planEnvelope['generatedAt']
    } else {
        (Get-Item -LiteralPath $studyPath).CreationTimeUtc.ToString('o')
    }
    if (-not $Scope -and $planEnvelope) { $Scope = $planEnvelope['scope'] }
    if (-not $DerivedFrom -and $planEnvelope) { $DerivedFrom = [string]$planEnvelope['derivedFrom'] }
    if (-not $FaultPath -and $plan -and $plan['fault']) { $FaultPath = [string]$plan['fault']['faultPath'] }

    # Step 1 — the report is content, so it goes in before anything is hashed.
    if ($PSBoundParameters.ContainsKey('ReportHtml')) {
        Save-StudyArtifact -StudyId $StudyId -ScopeHash $ScopeHash -Root $Root `
            -Name $script:StudyReportName -Content $ReportHtml | Out-Null
    }

    # Step 2 — hash everything except the manifest (absent) and SEALED (absent).
    $files = @(
        foreach ($relative in (Get-StudyRelativeFile -StudyPath $studyPath -Exclude $script:StudyUnhashedNames)) {
            Get-StudyFileDigest -StudyPath $studyPath -RelativePath $relative
        }
    )

    $sealedAt = (Get-Date).ToUniversalTime().ToString('o')
    $manifest = [ordered]@{
        studyId           = $StudyId
        createdAt         = $createdAt
        sealedAt          = $sealedAt
        outcome           = $Outcome
        scope             = $Scope
        scopeHash         = $ScopeHash
        derivedFrom       = $DerivedFrom
        faultPath         = $FaultPath
        apiVersions       = if ($ApiVersions) { $ApiVersions } else { [ordered]@{} }
        toolSubstitutions = @($ToolSubstitutions)
        files             = $files
        schemaVersions    = [ordered]@{
            studyManifest = $script:StudySchemaVersion
            studyPlan     = 1
            runRecord     = 1
            findings      = 1
        }
    }

    $scopeId = if ($planEnvelope -and $planEnvelope['scopeId']) { [string]$planEnvelope['scopeId'] } else { $ScopeHash }
    $envelope = [ordered]@{
        artifactSchemaVersion = 1
        artifactType          = 'study-manifest'
        scopeId               = $scopeId
        runId                 = $StudyId
        generatedAt           = $sealedAt
        provenance            = (New-StudyProvenance)
        warnings              = @()
        manifest              = $manifest
    }

    # The manifest is written WITHOUT the embedded-token scrub: every value in
    # it is computed here, and a SHA-256 is itself 64 hex characters, which the
    # secret-value shapes would otherwise redact.
    $manifestPath = Join-Path $studyPath $script:StudyManifestName
    Invoke-WithEvidenceLock -LockPath "${manifestPath}.lock" -Action {
        Write-EvidenceFileAtomic -Path $manifestPath -Content ($envelope | ConvertTo-Json -Depth 32)
    }

    # Step 3 — the marker, then the index. The marker is the immutability
    # boundary, so it is created only once the manifest is durable.
    $markerPath = Join-Path $studyPath $script:StudySealMarker
    Write-EvidenceFileAtomic -Path $markerPath -Content (ConvertTo-StudyJson -Data ([ordered]@{
                studyId  = $StudyId
                sealedAt = $sealedAt
                outcome  = $Outcome
            }))

    Add-StudyIndexEntry -ScopeHash $ScopeHash -Root $Root -Entry ([ordered]@{
            studyId    = $StudyId
            scopeHash  = $ScopeHash
            createdAt  = $createdAt
            sealedAt   = $sealedAt
            outcome    = $Outcome
            vertical   = if ($plan) { $plan['vertical'] } else { $null }
            question   = if ($plan) { $plan['question'] } else { $null }
            faultPath  = $FaultPath
            reportPath = "$StudyId/$($script:StudyReportName)"
            fileCount  = $files.Count
        }) | Out-Null

    [Console]::Error.WriteLine("[Study] Sealed $StudyId ($Outcome, $($files.Count) files)")
    return $manifest
}

Set-Alias -Name Seal-Study -Value Complete-Study -Scope Global -Force -Description 'Readable alias; Complete-Study carries the approved verb.'

function Read-StudyJson {
    <# Parses a JSON file into a hashtable, or $null when absent or corrupt. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
    } catch {
        [Console]::Error.WriteLine("[Study] Ignoring unreadable JSON at $Path : $_")
        return $null
    }
}

function Find-StudyScopeHash {
    <#
    .SYNOPSIS
        Finds the scope a studyId lives under by scanning the root.
    .DESCRIPTION
        Callers that hold only a studyId — a cold conversation reading a study
        by id weeks later — must not have to know its scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StudyId,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }
    if (Test-Path -LiteralPath $Root -PathType Container) {
        foreach ($scope in (Get-ChildItem -LiteralPath $Root -Directory -Force)) {
            if (Test-Path -LiteralPath (Join-Path $scope.FullName $StudyId) -PathType Container) {
                return $scope.Name
            }
        }
    }
    throw (New-StudyErrorRecord -ErrorType 'StudyNotFound' -Message "no study '$StudyId' under '$Root'.")
}

function Get-Study {
    <#
    .SYNOPSIS
        Reads a study back from disk, offline.
    .DESCRIPTION
        The lifecycle state is the presence of files on disk; there is no
        status field to read and none to lie:

          SEALED    — `SEALED` marker + `manifest.json`
          EXECUTED  — `run-record.v1.json`, no marker
          ABANDONED — a plan older than $CHAOS_STUDY_ABANDON_HOURS with no run
                      record (reported, never deleted)
          PLANNED   — a plan, possibly with a partial evidence tree

        -Path reads a study directory directly, so a study unzipped anywhere —
        on another machine, under another root — is readable on its own terms
        (NFR-11). No Azure call and no credential is involved either way.
    .PARAMETER Verify
        Recompute every manifest hash and report mismatched, missing and
        unexpected files.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')][string]$StudyId,
        [Parameter(ParameterSetName = 'ById')][string]$ScopeHash,
        [Parameter(ParameterSetName = 'ById')][string]$Root,
        [Parameter(Mandatory, ParameterSetName = 'ByPath')][string]$Path,
        [switch]$Verify
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        $studyPath = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $studyPath -PathType Container)) {
            throw (New-StudyErrorRecord -ErrorType 'StudyNotFound' -Message "no study directory at '$Path'.")
        }
        $StudyId = Split-Path -Leaf $studyPath
        $ScopeHash = Split-Path -Leaf (Split-Path -Parent $studyPath)
    } else {
        if (-not $Root) { $Root = Get-StudyRoot }
        if (-not $ScopeHash) { $ScopeHash = Find-StudyScopeHash -StudyId $StudyId -Root $Root }
        $studyPath = Resolve-StudyPath -ScopeHash $ScopeHash -StudyId $StudyId -Root $Root
        if (-not (Test-Path -LiteralPath $studyPath -PathType Container)) {
            throw (New-StudyErrorRecord -ErrorType 'StudyNotFound' -Message "no study '$StudyId' under '$Root'.")
        }
    }

    $planEnvelope = Read-StudyJson -Path (Join-Path $studyPath $script:StudyPlanName)
    $runEnvelope = Read-StudyJson -Path (Join-Path $studyPath $script:StudyRunRecordName)
    $findingsEnvelope = Read-StudyJson -Path (Join-Path $studyPath $script:StudyFindingsName)
    $manifestEnvelope = Read-StudyJson -Path (Join-Path $studyPath $script:StudyManifestName)
    $manifest = if ($manifestEnvelope) { $manifestEnvelope['manifest'] } else { $null }
    $sealed = Test-StudySealed -StudyPath $studyPath

    $createdAt = if ($manifest -and $manifest['createdAt']) {
        ConvertTo-StudyTimestamp -Value $manifest['createdAt']
    } elseif ($planEnvelope -and $planEnvelope['generatedAt']) {
        ConvertTo-StudyTimestamp -Value $planEnvelope['generatedAt']
    } else {
        (Get-Item -LiteralPath $studyPath).CreationTimeUtc.ToString('o')
    }

    $state = if ($sealed -and $manifest) {
        'SEALED'
    } elseif ($runEnvelope) {
        'EXECUTED'
    } elseif ($planEnvelope) {
        $created = [datetime]::Parse($createdAt, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $age = ((Get-Date).ToUniversalTime() - $created).TotalHours
        if ($age -gt (Get-StudyAbandonHours)) { 'ABANDONED' } else { 'PLANNED' }
    } else {
        throw (New-StudyErrorRecord -ErrorType 'StudyNotFound' -Message "'$studyPath' holds no study plan.")
    }

    $result = [ordered]@{
        studyId    = $StudyId
        scopeHash  = $ScopeHash
        path       = $studyPath
        state      = $state
        sealed     = $sealed
        createdAt  = $createdAt
        sealedAt   = if ($manifest) { ConvertTo-StudyTimestamp -Value $manifest['sealedAt'] } else { $null }
        outcome    = if ($manifest) { $manifest['outcome'] } else { $null }
        plan       = if ($planEnvelope) { $planEnvelope['plan'] } else { $null }
        runRecord  = if ($runEnvelope) { $runEnvelope['runRecord'] } else { $null }
        findings   = if ($findingsEnvelope) { $findingsEnvelope['findings'] } else { $null }
        manifest   = $manifest
        reportPath = if (Test-Path -LiteralPath (Join-Path $studyPath $script:StudyReportName)) {
            (Join-Path $studyPath $script:StudyReportName)
        } else { $null }
        files      = (Get-StudyRelativeFile -StudyPath $studyPath)
    }

    if ($Verify) {
        $result['integrity'] = Test-StudyManifest -StudyPath $studyPath -Manifest $manifest
    }
    return $result
}

function Test-StudyManifest {
    <#
    .SYNOPSIS
        Recomputes every manifest hash and reports what no longer matches.
    .OUTPUTS
        {valid, reason, mismatched[], missing[], unexpected[]}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StudyPath,
        [AllowNull()][System.Collections.IDictionary]$Manifest
    )

    if (-not $Manifest -or -not $Manifest['files']) {
        return [ordered]@{
            valid = $false; reason = 'NoManifest'
            mismatched = @(); missing = @(); unexpected = @()
        }
    }

    $mismatched = @()
    $missing = @()
    $recorded = @()
    foreach ($entry in $Manifest['files']) {
        $relative = [string]$entry['path']
        $recorded += $relative
        $full = Join-Path $StudyPath ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $missing += $relative
            continue
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$entry['sha256']).ToLowerInvariant()) {
            $mismatched += $relative
        }
    }

    $onDisk = Get-StudyRelativeFile -StudyPath $StudyPath -Exclude $script:StudyUnhashedNames
    $unexpected = @($onDisk | Where-Object { $recorded -notcontains $_ })

    $valid = ($mismatched.Count -eq 0 -and $missing.Count -eq 0 -and $unexpected.Count -eq 0)
    return [ordered]@{
        valid      = $valid
        reason     = if ($valid) { $null } else { 'ManifestMismatch' }
        mismatched = @($mismatched)
        missing    = @($missing)
        unexpected = @($unexpected)
    }
}

function Get-StudyIndexPath {
    <# The index file for one scope. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScopeHash,
        [string]$Root
    )

    return (Join-Path (Resolve-StudyPath -ScopeHash $ScopeHash -Root $Root) $script:StudyIndexName)
}

function Build-StudyIndexEntry {
    <# One index record derived from a sealed study directory. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StudyPath)

    $manifestEnvelope = Read-StudyJson -Path (Join-Path $StudyPath $script:StudyManifestName)
    if (-not $manifestEnvelope -or -not $manifestEnvelope['manifest']) { return $null }
    $manifest = $manifestEnvelope['manifest']
    $planEnvelope = Read-StudyJson -Path (Join-Path $StudyPath $script:StudyPlanName)
    $plan = if ($planEnvelope) { $planEnvelope['plan'] } else { $null }

    return [ordered]@{
        studyId    = [string]$manifest['studyId']
        scopeHash  = [string]$manifest['scopeHash']
        createdAt  = ConvertTo-StudyTimestamp -Value $manifest['createdAt']
        sealedAt   = ConvertTo-StudyTimestamp -Value $manifest['sealedAt']
        outcome    = $manifest['outcome']
        vertical   = if ($plan) { $plan['vertical'] } else { $null }
        question   = if ($plan) { $plan['question'] } else { $null }
        faultPath  = $manifest['faultPath']
        reportPath = "$($manifest['studyId'])/$($script:StudyReportName)"
        fileCount  = @($manifest['files']).Count
    }
}

function Build-StudyIndex {
    <# Scans one scope's sealed studies. The scan, not the file, is the truth. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScopeHash,
        [string]$Root
    )

    $scopePath = Resolve-StudyPath -ScopeHash $ScopeHash -Root $Root
    if (-not (Test-Path -LiteralPath $scopePath -PathType Container)) { return @() }

    $records = foreach ($directory in (Get-ChildItem -LiteralPath $scopePath -Directory -Force | Sort-Object Name)) {
        if (-not (Test-StudySealed -StudyPath $directory.FullName)) { continue }
        $entry = Build-StudyIndexEntry -StudyPath $directory.FullName
        if ($entry) { $entry }
    }
    return @($records)
}

function Get-StudyIndex {
    <#
    .SYNOPSIS
        Enumerates sealed studies for a scope.
    .DESCRIPTION
        `index.json` is a rebuildable cache, not a source of truth (NFR-6). A
        missing or corrupt index costs a directory scan, never a study: the
        scan result is returned and the file is left alone unless -Rebuild is
        given, which reconstructs and persists it.
    .PARAMETER ScopeHash
        The scope to enumerate. All scopes when omitted.
    .PARAMETER Rebuild
        Reconstruct the index from the sealed directories and write it.
    #>
    [CmdletBinding()]
    param(
        [string]$ScopeHash,
        [switch]$Rebuild,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }

    if (-not $ScopeHash) {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
        $all = foreach ($scope in (Get-ChildItem -LiteralPath $Root -Directory -Force | Sort-Object Name)) {
            Get-StudyIndex -ScopeHash $scope.Name -Root $Root -Rebuild:$Rebuild
        }
        return @($all)
    }

    $indexPath = Get-StudyIndexPath -ScopeHash $ScopeHash -Root $Root

    if (-not $Rebuild) {
        $existing = Read-StudyJson -Path $indexPath
        if ($existing -and $existing['studies']) {
            return @($existing['studies'])
        }
        # Missing or corrupt: answer from the directories, and do not write.
        return (Build-StudyIndex -ScopeHash $ScopeHash -Root $Root)
    }

    $records = Build-StudyIndex -ScopeHash $ScopeHash -Root $Root
    Write-StudyIndex -IndexPath $indexPath -ScopeHash $ScopeHash -Records $records
    return @($records)
}

function Write-StudyIndex {
    <# Commits an index atomically under the shared [E2] lock. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IndexPath,
        [Parameter(Mandatory)][string]$ScopeHash,
        [AllowEmptyCollection()][object[]]$Records
    )

    $directory = Split-Path -Parent $IndexPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $document = [ordered]@{
        studyIndexSchemaVersion = $script:StudySchemaVersion
        scopeHash               = $ScopeHash
        updatedAt               = (Get-Date).ToUniversalTime().ToString('o')
        studies                 = @($Records)
    }
    Write-EvidenceFileAtomic -Path $IndexPath -Content (ConvertTo-StudyJson -Data $document)
}

function Add-StudyIndexEntry {
    <#
    .SYNOPSIS
        Appends (or replaces) one record in a scope's index.
    .DESCRIPTION
        Serialized on the shared `[E2]` lock and committed atomically, so two
        studies sealing concurrently cannot lose each other's record. A record
        for a studyId already present is replaced rather than duplicated —
        the index is keyed on studyId.
    .OUTPUTS
        The stored record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScopeHash,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry,
        [string]$Root
    )

    if (-not $Root) { $Root = Get-StudyRoot }
    $indexPath = Get-StudyIndexPath -ScopeHash $ScopeHash -Root $Root
    $directory = Split-Path -Parent $indexPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Invoke-WithEvidenceLock -LockPath "${indexPath}.lock" -Action {
        $existing = Read-StudyJson -Path $indexPath
        $records = if ($existing -and $existing['studies']) { @($existing['studies']) } else { @() }
        $records = @($records | Where-Object { [string]$_['studyId'] -ne [string]$Entry['studyId'] })
        $records += , $Entry
        Write-StudyIndex -IndexPath $indexPath -ScopeHash $ScopeHash -Records $records
    }

    return $Entry
}
