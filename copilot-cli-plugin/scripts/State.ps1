<#
.SYNOPSIS
    State file management and durable evidence mirroring for the startchaos plugin.

.DESCRIPTION
    Provides Read-State, Save-State, and Set-StateProperty functions that
    persist plugin progress to $env:STARTCHAOS_STATE_PATH as pretty-printed JSON.

    Every write stamps stateSchemaVersion and updatedAt. Writes are atomic
    (write to temp file then rename) to prevent corruption on crashes.

    Save-State additionally MIRRORS the state to the durable evidence store at
    $env:CHAOS_EVIDENCE_ROOT (per-user application-data directory by default).
    The mirror is additive: $env:STARTCHAOS_STATE_PATH remains the source of
    truth and is never relocated. The evidence root deliberately lives outside
    the repository and outside any session tmp/ directory so a repo or session
    wipe cannot destroy a run's evidence (field evidence F12).

.NOTES
    State schema version: 1 (unchanged — Import-State imports v1 and any
    earlier partial file forward without a version bump).
    Evidence envelope schema version: 1.
#>

# ── Constants ───────────────────────────────────────────
$script:StateSchemaVersion = 1
$script:DefaultStatePath = $null
$script:EvidenceSchemaVersion = 1
$script:EvidenceAppDir = 'chaos-studio'
$script:EvidenceKinds = @('artifacts', 'raw', 'rendered')
$script:EvidenceLockTimeoutSeconds = 10
$script:EvidenceLockStaleSeconds = 60
$script:EvidenceRedacted = '[REDACTED]'

# Key names whose value is always secret. Mirrors _DENY_KEY_EXACT /
# _DENY_KEY_HINTS in mcp/chaos_mcp/evidence.py — the two surfaces write into
# the same store, so they must redact the same things.
$script:EvidenceDenyKeyExact = @(
    'key', 'keys', 'secret', 'secrets', 'password', 'passwd', 'pwd', 'token',
    'credential', 'credentials', 'authorization', 'auth', 'sas', 'signature', 'sig'
)
$script:EvidenceDenyKeyHints = @(
    'secret', 'password', 'passwd', 'token', 'credential', 'apikey', 'api_key',
    'accountkey', 'account_key', 'primarykey', 'secondarykey', 'sharedaccesskey',
    'connectionstring', 'connection_string', 'privatekey', 'private_key',
    'clientsecret', 'client_secret', 'approvalkey', 'approval_key',
    'sessionkey', 'session_key', 'k_session', 'ksession', 'bearer',
    'sastoken', 'sas_token'
)

# Unanchored forms of the Test-EvidenceSecretValue shapes, for callers that must
# scrub a token EMBEDDED in a longer string (an error message, an `az` argv)
# rather than test a whole value. Exported through Get-EvidenceRedactionList so
# the study store reuses these shapes instead of forking them (D16).
# Each is bounded so a resource id, a GUID or an ISO timestamp cannot match.
$script:EvidenceSecretValuePatterns = @(
    '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}',
    '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*',
    '(?<![A-Za-z0-9])[A-Fa-f0-9]{32,}(?![A-Za-z0-9])',
    '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/=])'
)

function Get-EvidenceRedactionList {
    <#
    .SYNOPSIS
        Returns the redaction denylists and secret-value shapes (E4-T2).
    .DESCRIPTION
        The single source of the redaction vocabulary. `Study.ps1` reads it so
        the study store redacts exactly what the evidence store redacts; the
        two must never drift (D16). Copies are returned so a caller cannot
        mutate the lists in place.
    .OUTPUTS
        [ordered] hashtable with denyKeyExact, denyKeyHints, secretValuePatterns
        and redacted (the placeholder string).
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        denyKeyExact        = @($script:EvidenceDenyKeyExact)
        denyKeyHints        = @($script:EvidenceDenyKeyHints)
        secretValuePatterns = @($script:EvidenceSecretValuePatterns)
        redacted            = $script:EvidenceRedacted
    }
}

function Get-StatePath {
    <# Returns the resolved state file path. #>
    if ($env:STARTCHAOS_STATE_PATH) {
        return $env:STARTCHAOS_STATE_PATH
    }
    # Fallback: current directory
    return Join-Path $PWD 'startchaos-state.json'
}

function Get-EvidenceRoot {
    <#
    .SYNOPSIS
        Returns the durable evidence root directory (not created here).
    .DESCRIPTION
        $env:CHAOS_EVIDENCE_ROOT wins when set. Otherwise a per-user
        application-data directory is used (Q9): %LOCALAPPDATA% on Windows,
        ~/Library/Application Support on macOS, $XDG_DATA_HOME (or
        ~/.local/share) elsewhere. Never a repository or session tmp/ path.
    #>
    if ($env:CHAOS_EVIDENCE_ROOT) {
        return $env:CHAOS_EVIDENCE_ROOT
    }

    $isWin = $IsWindows -or ($env:OS -eq 'Windows_NT')
    if ($isWin) {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData/Local' }
    } elseif ($IsMacOS) {
        $base = Join-Path $HOME 'Library/Application Support'
    } else {
        $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
    }

    return (Join-Path (Join-Path $base $script:EvidenceAppDir) 'evidence')
}

function Test-EvidenceMirroringDisabled {
    <# Escape hatch for environments that must not create an on-disk store. #>
    return ($env:CHAOS_EVIDENCE_DISABLED -in @('1', 'true', 'True', 'yes'))
}

function Get-EvidenceScopeHash {
    <#
    .SYNOPSIS
        Deterministic per-scope directory name for the evidence store.
    .DESCRIPTION
        Derived from subscription + resource group + workspace name so that
        two runs against the same scope land under the same scopeHash, and a
        different scope never collides. Missing parts hash as 'unknown' rather
        than being dropped, so the hash stays stable as context fills in.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$State)

    $ctx = if ($State) { $State['context'] } else { $null }
    $ws = if ($State) { $State['workspace'] } else { $null }

    $subscription = 'unknown'
    $resourceGroup = 'unknown'
    $workspaceName = 'unknown'
    if ($ctx -is [System.Collections.IDictionary]) {
        if ($ctx['subscriptionId']) { $subscription = [string]$ctx['subscriptionId'] }
        if ($ctx['resourceGroup']) { $resourceGroup = [string]$ctx['resourceGroup'] }
    }
    if ($ws -is [System.Collections.IDictionary] -and $ws['name']) {
        $workspaceName = [string]$ws['name']
    }
    $material = (@($subscription, $resourceGroup, $workspaceName) -join '|').ToLowerInvariant()

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    } finally {
        $sha.Dispose()
    }
    return -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
}

function Initialize-EvidenceIdentity {
    <#
    .SYNOPSIS
        Ensures the state carries a stable evidence runId and scopeHash.
    .DESCRIPTION
        Mutates $State in place. runId is taken from the state (so a resumed
        run keeps mirroring into the same evidence directory), then from
        $env:CHAOS_RUN_ID, and is otherwise generated. scopeHash is always
        recomputed because context fills in as phases complete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$State
    )

    if (-not ($State['evidence'] -is [System.Collections.IDictionary])) {
        $State['evidence'] = [ordered]@{}
    }

    if (-not $State['evidence']['runId']) {
        $State['evidence']['runId'] = if ($env:CHAOS_RUN_ID) {
            $env:CHAOS_RUN_ID
        } else {
            'run-' + ([guid]::NewGuid().ToString('n').Substring(0, 12))
        }
    }
    $State['evidence']['scopeHash'] = Get-EvidenceScopeHash -State $State

    return $State
}

function New-EmptyState {
    <# Returns a new empty state object with the v1 schema. #>
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [ordered]@{
        stateSchemaVersion = $script:StateSchemaVersion
        createdAt          = $now
        updatedAt          = $now
        context            = [ordered]@{
            subscriptionId   = $null
            subscriptionName = $null
            resourceGroup    = $null
            location         = 'westus2'
            tenantId         = $null
            signedInUser     = $null
        }
        auth               = [ordered]@{
            status     = 'pending'
            method     = $null
            verifiedAt = $null
            lastError  = $null
        }
        workspace          = [ordered]@{
            status    = 'pending'
            name      = $null
            id        = $null
            identity  = [ordered]@{
                type                          = $null
                principalId                   = $null
                userAssignedIdentityResourceId = $null
            }
            scopes    = @()
            rbac      = @()
            lroUrl    = $null
            lastError = $null
        }
        setup              = [ordered]@{
            status                = 'pending'
            evaluation            = [ordered]@{
                status       = $null
                lastPolledAt = $null
            }
            recommendedScenarios  = @()
            selectedScenarioId    = $null
            configuration         = [ordered]@{
                name       = $null
                id         = $null
                parameters = @()
                validation = [ordered]@{
                    lastResult    = $null
                    permissionFix = [ordered]@{
                        state   = $null
                        summary = @{}
                    }
                }
            }
            lastError             = $null
        }
        run                = [ordered]@{
            status            = 'pending'
            scenarioRunId     = $null
            lastObservedState = $null
            actions           = @()
            errors            = @()
            lastError         = $null
        }
        evidence           = [ordered]@{
            runId     = $null
            scopeHash = $null
        }
    }
}

function Import-State {
    <#
    .SYNOPSIS
        Imports an existing (possibly partial or older) state object forward.
    .DESCRIPTION
        Backward-compatible importer (E2-T1). An existing v1
        `startchaos-state.json` imports unchanged: every key it already carries
        is preserved verbatim, including keys this version does not know about.
        Only *missing* sections and leaves are filled from New-EmptyState, so a
        file written before the `evidence` section existed still resumes.

        The state schema version is NOT bumped — v1 remains the wire format.
    .PARAMETER State
        The parsed state hashtable to import.
    .OUTPUTS
        The imported state hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Collections.IDictionary]$State
    )

    if ($null -eq $State) {
        return (Initialize-EvidenceIdentity -State (New-EmptyState))
    }

    $defaults = New-EmptyState
    Merge-StateDefault -Target $State -Defaults $defaults

    if (-not $State['stateSchemaVersion']) {
        $State['stateSchemaVersion'] = $script:StateSchemaVersion
    }

    return (Initialize-EvidenceIdentity -State $State)
}

function Merge-StateDefault {
    <#
    .SYNOPSIS
        Recursively adds missing default keys to $Target without overwriting.
    .DESCRIPTION
        Additive only: an existing key keeps its value even when that value is
        $null, because "$null recorded by a previous phase" and "never
        collected" are different facts and only the writer may change them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults
    )

    foreach ($key in @($Defaults.Keys)) {
        if (-not $Target.Contains($key)) {
            $Target[$key] = $Defaults[$key]
            continue
        }
        if ($Defaults[$key] -is [System.Collections.IDictionary] -and
            $Target[$key] -is [System.Collections.IDictionary]) {
            Merge-StateDefault -Target $Target[$key] -Defaults $Defaults[$key]
        }
    }
}

function Test-EvidenceSecretName {
    <# True when a key name always carries secret material. #>
    param([string]$Name)

    if (-not $Name) { return $false }
    $lowered = $Name.ToLowerInvariant()
    if ($script:EvidenceDenyKeyExact -contains $lowered) { return $true }
    foreach ($hint in $script:EvidenceDenyKeyHints) {
        if ($lowered.Contains($hint)) { return $true }
    }
    return $false
}

function Test-EvidenceSecretValue {
    <#
    .SYNOPSIS
        True when a string looks like key material regardless of its key name.
    .DESCRIPTION
        The base64 pattern deliberately excludes '-', '_' and '.', so ARM
        resource IDs, GUIDs and ISO timestamps can never match.
    #>
    param([object]$Value)

    if ($Value -isnot [string]) { return $false }
    $s = $Value.Trim()
    if (-not $s) { return $false }
    if ($s -match '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}') { return $true }
    if ($s -match '^eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.') { return $true }
    if ($s -match '^[A-Fa-f0-9]{32,}$') { return $true }
    if ($s -match '^[A-Za-z0-9+/]{40,}={0,2}$') { return $true }
    return $false
}

function Protect-EvidenceData {
    <#
    .SYNOPSIS
        Recursively redacts secret-bearing keys and secret-shaped values.
    .DESCRIPTION
        Applied before anything is written to the evidence store. The store is
        fronted by the model-callable evidence_get tool, so anything that lands
        there is reachable by the model.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowNull()][object]$Data)

    process {
        if ($null -eq $Data) { return $null }

        if ($Data -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($key in @($Data.Keys)) {
                if (Test-EvidenceSecretName -Name ([string]$key)) {
                    $out[[string]$key] = $script:EvidenceRedacted
                } else {
                    $out[[string]$key] = Protect-EvidenceData -Data $Data[$key]
                }
            }
            return $out
        }

        if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
            return @(foreach ($item in $Data) { , (Protect-EvidenceData -Data $item) })
        }

        if (Test-EvidenceSecretValue -Value $Data) { return $script:EvidenceRedacted }
        return $Data
    }
}

function Invoke-WithEvidenceLock {
    <#
    .SYNOPSIS
        Runs a script block while holding an exclusive on-disk lock (E4-T2).
    .DESCRIPTION
        The lock primitive behind every evidence write, exported so the study
        store serializes its writes with the same code rather than a fork
        (D16). A lock left behind by a process that died mid-write goes stale
        after $script:EvidenceLockStaleSeconds and is reclaimed. Only lock
        contention is retryable: a missing directory or an unwritable store is
        a real failure and surfaces immediately.
    .PARAMETER LockPath
        Path of the lock file to create.
    .PARAMETER Action
        The script block to run while the lock is held.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $deadline = (Get-Date).AddSeconds($script:EvidenceLockTimeoutSeconds)
    $lockStream = $null
    while ($null -eq $lockStream) {
        try {
            $lockStream = [System.IO.File]::Open(
                $LockPath, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            # Only lock contention is retryable. A missing directory or an
            # unwritable store is a real failure and must surface immediately
            # rather than spinning until the timeout.
            if (-not (Test-Path $LockPath)) { throw }
            # A lock left behind by a process that died mid-write.
            $stale = ((Get-Date) - (Get-Item $LockPath).LastWriteTime).TotalSeconds -gt $script:EvidenceLockStaleSeconds
            if ($stale) {
                Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
                continue
            }
            if ((Get-Date) -gt $deadline) {
                throw "Timed out acquiring the evidence lock at ${LockPath}."
            }
            Start-Sleep -Milliseconds 10
        }
    }

    try {
        & $Action
    } finally {
        $lockStream.Dispose()
        Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-EvidenceFileAtomic {
    <#
    .SYNOPSIS
        Writes text to a file via a temp file in the same directory + rename.
    .DESCRIPTION
        The atomicity primitive behind every evidence write, exported so the
        study store commits its artifacts the same way (D16). A reader never
        observes a partial file; a failed write leaves no scratch behind.
    .PARAMETER Path
        Destination file path.
    .PARAMETER Content
        The exact bytes (as UTF-8 text) to write. No trailing newline is added.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $tempPath = "${Path}.tmp.$([System.IO.Path]::GetRandomFileName())"
    try {
        $Content | Out-File -FilePath $tempPath -Encoding utf8 -NoNewline
        Move-Item -Path $tempPath -Destination $Path -Force
    } catch {
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Write-EvidenceArtifact {
    <#
    .SYNOPSIS
        Mirrors one phase output into the durable evidence store atomically.
    .DESCRIPTION
        Writes $CHAOS_EVIDENCE_ROOT/<scopeHash>/<runId>/<kind>/<name>. The
        payload is wrapped in an evidence envelope carrying a monotonic
        revision counter; the read-revision/write-revision pair is serialized
        by an exclusive lock file, and the file itself is replaced atomically,
        so a concurrent writer can never observe a partial artifact.

        Never relocates or replaces $STARTCHAOS_STATE_PATH — this is a mirror.
    .PARAMETER Name
        Artifact file name, e.g. 'state.json'.
    .PARAMETER Data
        The object to mirror. Redacted before it reaches disk.
    .PARAMETER Kind
        One of artifacts | raw | rendered.
    .OUTPUTS
        A hashtable describing the written item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][object]$Data,
        [ValidateSet('artifacts', 'raw', 'rendered')]
        [string]$Kind = 'artifacts',
        [string]$ScopeHash,
        [string]$RunId
    )

    if (-not $ScopeHash) { $ScopeHash = 'unknown' }
    if (-not $RunId) { $RunId = 'unknown' }

    $root = Get-EvidenceRoot
    $dir = Join-Path (Join-Path (Join-Path $root $ScopeHash) $RunId) $Kind
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $target = Join-Path $dir $Name
    $lockPath = "${target}.lock"

    $revision = 1
    $revision = Invoke-WithEvidenceLock -LockPath $lockPath -Action {
        $rev = 1
        if (Test-Path $target) {
            try {
                $existing = Get-Content -Path $target -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
                if ($existing -and $existing['revision']) {
                    $rev = [int]$existing['revision'] + 1
                }
            } catch {
                # A corrupt prior revision must not block the current write.
                [Console]::Error.WriteLine("[Evidence] Ignoring unreadable prior revision at $target : $_")
            }
        }

        $envelope = [ordered]@{
            evidenceSchemaVersion = $script:EvidenceSchemaVersion
            scopeHash             = $ScopeHash
            runId                 = $RunId
            kind                  = $Kind
            name                  = $Name
            revision              = $rev
            writtenAt             = (Get-Date).ToUniversalTime().ToString('o')
            redacted              = $true
            data                  = (Protect-EvidenceData -Data $Data)
        }

        Write-EvidenceFileAtomic -Path $target -Content ($envelope | ConvertTo-Json -Depth 32)
        $rev
    }

    [Console]::Error.WriteLine("[Evidence] Mirrored $Kind/$Name rev $revision to $target")
    return [ordered]@{
        root         = $root
        scopeHash    = $ScopeHash
        runId        = $RunId
        kind         = $Kind
        name         = $Name
        revision     = $revision
        path         = $target
        relativePath = "$ScopeHash/$RunId/$Kind/$Name"
    }
}

function Read-State {
    <#
    .SYNOPSIS
        Reads the current state file and returns it as a hashtable.
    .DESCRIPTION
        If the file does not exist, returns a new empty state. An existing file
        is passed through Import-State so a partial or pre-evidence file
        resumes without migration and without losing unknown keys.
    .OUTPUTS
        [ordered] hashtable representing the state.
    #>
    [CmdletBinding()]
    param()

    $path = Get-StatePath

    if (-not (Test-Path $path)) {
        [Console]::Error.WriteLine("[State] No state file at $path — returning empty state")
        return New-EmptyState
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding utf8
        $parsed = $raw | ConvertFrom-Json -AsHashtable
        [Console]::Error.WriteLine("[State] Loaded state from $path (schema v$($parsed.stateSchemaVersion))")
        return (Import-State -State $parsed)
    } catch {
        [Console]::Error.WriteLine("[State] ERROR reading $path : $_")
        throw "Failed to read state file at ${path}: $_"
    }
}

function Save-State {
    <#
    .SYNOPSIS
        Writes the state hashtable to disk atomically and mirrors it to evidence.
    .DESCRIPTION
        Stamps stateSchemaVersion and updatedAt on every write.
        Uses write-to-temp + rename for atomic persistence.

        After the state file is durable, the same content is mirrored to the
        durable evidence store (F12). The mirror is best-effort: an evidence
        failure warns but never fails the phase, because the state file — not
        the mirror — is the source of truth.
    .PARAMETER State
        The state hashtable to persist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $path = Get-StatePath

    # Stamp metadata on every write
    $State['stateSchemaVersion'] = $script:StateSchemaVersion
    $State['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')

    # Ensure createdAt is set
    if (-not $State['createdAt']) {
        $State['createdAt'] = $State['updatedAt']
    }

    Initialize-EvidenceIdentity -State $State | Out-Null

    $json = $State | ConvertTo-Json -Depth 32

    # Atomic write: temp file + rename
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tempPath = "${path}.tmp.$([System.IO.Path]::GetRandomFileName())"

    try {
        $json | Out-File -FilePath $tempPath -Encoding utf8 -NoNewline
        Move-Item -Path $tempPath -Destination $path -Force
        [Console]::Error.WriteLine("[State] Saved state to $path")
    } catch {
        # Clean up temp file on failure
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw "Failed to save state to ${path}: $_"
    }

    if (-not (Test-EvidenceMirroringDisabled)) {
        try {
            Write-EvidenceArtifact -Name 'state.json' -Data $State -Kind 'artifacts' `
                -ScopeHash $State['evidence']['scopeHash'] -RunId $State['evidence']['runId'] | Out-Null
        } catch {
            [Console]::Error.WriteLine("[Evidence] WARNING: state mirror failed: $_")
        }
    }
}

function Set-StateProperty {
    <#
    .SYNOPSIS
        Sets a single dot-delimited property on the state and saves.
    .DESCRIPTION
        Reads the current state, sets the property at the given path,
        and saves atomically. Supports nested dot notation
        (e.g. "auth.status", "workspace.identity.principalId").
    .PARAMETER PropertyPath
        Dot-delimited property path (e.g. "auth.status").
    .PARAMETER Value
        The value to set.
    .EXAMPLE
        Set-StateProperty -PropertyPath 'auth.status' -Value 'done'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PropertyPath,

        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value
    )

    $state = Read-State

    # Navigate to the parent, then set the leaf
    $parts = $PropertyPath.Split('.')
    $current = $state

    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $key = $parts[$i]
        # (Re)initialize the slot whenever it is missing, $null, or not a
        # dictionary — otherwise the next iteration would try to index into
        # $null (or a scalar) and throw "Cannot index into a null array."
        $needsInit = $false
        if (-not ($current -is [System.Collections.IDictionary])) {
            throw "Set-StateProperty: cannot navigate '$PropertyPath' — segment before '$key' is not a dictionary (type: $($current.GetType().FullName))."
        }
        if (-not $current.Contains($key)) {
            $needsInit = $true
        } elseif ($null -eq $current[$key] -or -not ($current[$key] -is [System.Collections.IDictionary])) {
            $needsInit = $true
        }
        if ($needsInit) {
            $current[$key] = [ordered]@{}
        }
        $current = $current[$key]
    }

    if (-not ($current -is [System.Collections.IDictionary])) {
        throw "Set-StateProperty: cannot set leaf '$PropertyPath' — parent is not a dictionary."
    }

    $leafKey = $parts[-1]
    $current[$leafKey] = $Value

    Save-State -State $state
    [Console]::Error.WriteLine("[State] Set $PropertyPath = $Value")
}

# When imported via Import-Module, all functions are exported by default.
# When dot-sourced, functions are available in the calling scope.
