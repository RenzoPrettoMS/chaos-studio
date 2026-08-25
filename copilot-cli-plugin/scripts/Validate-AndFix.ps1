# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    Shared helper: validate a ScenarioConfiguration and auto-fix resource permissions.
.DESCRIPTION
    Drives the validate -> fix-permissions -> re-validate loop against a
    Microsoft.Chaos ScenarioConfiguration using the `az chaos` CLI extension.
    Used by both the setup-scenario skill (creation-time validation) and the
    run-scenario skill (pre-execute gate).

    Behavior (always-on validation + consent-gated broad remediation):
      1. `az chaos scenario config validate` (CLI polls the LRO to completion).
      2. Read the validation status (from the validate result, falling back to
         `az chaos scenario config show-validation`) -> $valStatus.
      3. If $valStatus is NOT 'Succeeded' (i.e. Failed/RequiresAttention/etc.) OR
         validationErrors are present:
           a. normalize the blockers into one shape (`ConvertTo-ValidationBlocker`);
           b. render the exact, per-resource `az role assignment create` grants
              that would clear them (`Build-TargetedGrantProposal`) — always
              offered FIRST, because they are minimum-scope;
           c. only then, and only with explicit consent, run the broad
              `az chaos scenario config fix-permissions` (actual fix, not
              --what-if) and re-validate.
      4. Returns the final validation status string via state.

    Consent (E3-T3): `fixResourcePermissions` grants whatever the service
    decides is required across every target resource in a single call. Without
    consent this function persists the prompt, renders it, and throws
    `broadPermissionFixConsentRequired: ...` so the caller can pause for the
    user. Consent is given by `-ConsentToBroadPermissionFix` or by
    `$env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = '1'`.

    State persistence:
      - Always writes the final validation status to
        "$StateBasePath.validation.lastResult".
      - When validation reports blockers, also writes:
          $StateBasePath.validation.blockers
          $StateBasePath.validation.targetedGrants
          $StateBasePath.validation.permissionFix.consent        ('required'|'granted')
          $StateBasePath.validation.permissionFix.consentPrompt
      - When fix runs, also writes:
          $StateBasePath.validation.permissionFix.state
          $StateBasePath.validation.permissionFix.summary
          $StateBasePath.validation.permissionFix.whatIfMode

    Required dot-sourced dependencies (caller must load before invoking):
      State.ps1, Render.ps1, Invoke-AzChaos.ps1, Rbac.ps1

.PARAMETER ResourceGroup
    Resource group containing the workspace.
.PARAMETER WorkspaceName
    Chaos Studio workspace name.
.PARAMETER ScenarioName
    Parent scenario name (e.g. 'ZoneDown-1.0').
.PARAMETER ConfigName
    Scenario configuration name.
.PARAMETER StateBasePath
    Dotted state path under which to persist validation/permissionFix results
    (e.g. 'setup.configuration').
.PARAMETER PrincipalId
    Object ID of the workspace identity, used to build the targeted grant
    commands. Optional — a placeholder is emitted when it is unknown.
.PARAMETER ConsentToBroadPermissionFix
    Explicit consent to run the broad `fixResourcePermissions` mutation.

.OUTPUTS
    None. Callers should read the final status from state at
    "$StateBasePath.validation.lastResult" after this function returns.
#>

#: Codes/messages that a role assignment could plausibly fix.
$script:PermissionBlockerPattern = '(?i)(permission|authoriz|forbidden|denied|rbac|roleassignment|role assignment)'

#: Codes/messages that describe the target resource itself, not access to it.
$script:ResourceBlockerPattern = '(?i)(resource|target|notfound|not found|unsupported|agent|extension|sku|zone|capacity|state)'

function Test-StructuredValidationError {
    <#
    .SYNOPSIS
        True only for error entries that carry named fields.
    .DESCRIPTION
        Mirrors the `isinstance(item, dict)` guard in
        `normalize_validation_blockers` (mcp/chaos_mcp/server.py). A bare string
        or number in `errors[]` has no code, message or resource id; emitting a
        `code='Unknown'` blocker for it would produce a different blocker count
        on the two planes for the same payload. Both planes skip it.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Entry)

    if ($null -eq $Entry) { return $false }
    if ($Entry -is [System.Collections.IDictionary]) { return $true }
    return ($Entry -is [PSCustomObject])
}

function ConvertTo-ValidationBlocker {
    <#
    .SYNOPSIS
        Normalizes the errors on a `validations/latest` payload into one shape.
    .DESCRIPTION
        Pure function — no ARM calls, no state writes. The service reports
        blockers from several places and with several field spellings:

          properties.errors[]              / properties.validationErrors[]
          properties.resources[].errors[]  / .validationErrors[]
          errorCode|code, errorMessage|message, resourceId|targetResourceId|target|id

        Every blocker is emitted as
        `{ code, category, resourceId, roleName, principalId, message }` where
        category is one of 'permission', 'resource' or 'other'. Identical
        blockers reported from two places collapse to one.
    .PARAMETER ValidationResult
        The object returned by `validate` / `show-validation`.
    .OUTPUTS
        [PSCustomObject[]]
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$ValidationResult
    )

    if (-not $ValidationResult -or -not $ValidationResult.properties) { return @() }
    $props = $ValidationResult.properties

    $raw = @()
    foreach ($field in @('errors', 'validationErrors')) {
        foreach ($item in @($props.$field)) {
            if (Test-StructuredValidationError -Entry $item) {
                $raw += [PSCustomObject]@{ error = $item; parentResourceId = $null }
            }
        }
    }
    foreach ($resource in @($props.resources)) {
        if (-not $resource) { continue }
        $parentId = $resource.resourceId
        if (-not $parentId) { $parentId = $resource.id }
        foreach ($field in @('errors', 'validationErrors')) {
            foreach ($item in @($resource.$field)) {
                if (Test-StructuredValidationError -Entry $item) {
                    $raw += [PSCustomObject]@{ error = $item; parentResourceId = $parentId }
                }
            }
        }
    }

    $blockers = @()
    $seen = @{}

    foreach ($entry in $raw) {
        $e = $entry.error

        $code = $e.errorCode
        if (-not $code) { $code = $e.code }
        if (-not $code) { $code = 'Unknown' }

        $message = $e.errorMessage
        if (-not $message) { $message = $e.message }
        if (-not $message) { $message = '' }

        $resourceId = $e.resourceId
        if (-not $resourceId) { $resourceId = $e.targetResourceId }
        if (-not $resourceId) { $resourceId = $e.target }
        if (-not $resourceId) { $resourceId = $e.id }
        if (-not $resourceId) { $resourceId = $entry.parentResourceId }

        $roleName = $e.roleName
        if (-not $roleName) { $roleName = $e.requiredRole }
        if (-not $roleName) { $roleName = $e.roleDefinitionName }

        $probe = "$code $message"
        $category = if ($probe -match $script:PermissionBlockerPattern) {
            'permission'
        } elseif ($probe -match $script:ResourceBlockerPattern) {
            'resource'
        } else {
            'other'
        }

        # Deliberately message-free: the same code on the same resource for the
        # same role is one actionable blocker however many times (and with
        # whatever wording) the service reported it. Two different messages
        # under one code on one resource intentionally collapse.
        $key = "$code|$resourceId|$roleName".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $blockers += [PSCustomObject]@{
            code        = "$code"
            category    = $category
            resourceId  = if ($resourceId) { "$resourceId" } else { $null }
            roleName    = if ($roleName) { "$roleName" } else { $null }
            principalId = if ($e.principalId) { "$($e.principalId)" } else { $null }
            message     = "$message"
        }
    }

    return $blockers
}

function Test-BroadPermissionFixConsent {
    <#
    .SYNOPSIS
        Returns $true only when consent to the broad permission fix is explicit.
    .DESCRIPTION
        Any value other than the exact string '1' in
        `STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX` is NOT consent — a broad
        mutation must never turn on because an env var happened to be set.
    #>
    [CmdletBinding()]
    param([Parameter()][switch]$Consented)

    if ($Consented) { return $true }
    return ($env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX -eq '1')
}

function Invoke-ValidateAndFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][string]$ConfigName,
        [Parameter(Mandatory)][string]$StateBasePath,
        [Parameter()][string]$PrincipalId,
        [Parameter()][switch]$ConsentToBroadPermissionFix
    )

    $idArgs = @(
        '--resource-group', $ResourceGroup
        '--workspace-name', $WorkspaceName
        '--scenario-name', $ScenarioName
        '--name', $ConfigName
    )

    # Local helper: run `validate` (LRO awaited by the CLI) and return the
    # validation result. Falls back to `show-validation` if the validate command
    # does not echo the result body.
    $runValidate = {
        $r = Invoke-AzChaos -ChaosArgs (@('scenario', 'config', 'validate') + $idArgs)
        if (-not $r -or -not $r.properties -or -not $r.properties.status) {
            $r = Invoke-AzChaos -ChaosArgs (@('scenario', 'config', 'show-validation') + $idArgs) -AllowFailure
        }
        return $r
    }

    # ── Step 1: Initial validate ────────────────────────────
    Write-Card -Title 'Validating Configuration' -Status '🔄' `
        -Body 'Verifying that the workspace identity has sufficient permissions on all target resources...'

    $valResult = & $runValidate
    $valStatus = $valResult.properties.status
    Set-StateProperty -PropertyPath "$StateBasePath.validation.lastResult" -Value $valStatus

    # ── Step 2: Decide whether a fix is needed ──────────────
    # ALWAYS attempt a fix when validation did not return Succeeded, OR when the
    # service reported any validationErrors.
    $hasErrors  = [bool]$valResult.properties.validationErrors
    $needsFix   = ($valStatus -ne 'Succeeded') -or $hasErrors

    if (-not $needsFix) {
        Write-Card -Title 'Validation Complete' -Status "✅ $valStatus"
        return
    }

    # ── Step 3: Normalize blockers and offer targeted grants FIRST ──
    # `validations/latest` reports blockers from several places with several
    # field spellings; normalize once so everything downstream reads one shape.
    $blockers = @(ConvertTo-ValidationBlocker -ValidationResult $valResult)
    Set-StateProperty -PropertyPath "$StateBasePath.validation.blockers" -Value $blockers

    if ($blockers.Count -gt 0) {
        Write-Table -Data @($blockers | ForEach-Object {
            [ordered]@{
                'Code'     = $_.code
                'Category' = $_.category
                'Resource' = $_.resourceId
                'Role'     = $_.roleName
                'Message'  = $_.message
            }
        }) -Title "Validation Blockers ($($blockers.Count))"
    }

    $targetedGrants = @(Build-TargetedGrantProposal -Blockers $blockers -PrincipalId $PrincipalId)
    Set-StateProperty -PropertyPath "$StateBasePath.validation.targetedGrants" -Value $targetedGrants

    if ($targetedGrants.Count -gt 0) {
        Write-Card -Title 'Targeted Grants (minimum scope — try these first)' -Status 'ℹ️' -Body @"
Validation status: ``$valStatus``. These are the exact, per-resource role
assignments that would clear the permission blockers above. Each one is scoped
to a single resource — nothing wider:

$(($targetedGrants | ForEach-Object { "- ``$($_.command)``" }) -join "`n")
"@
    } else {
        Write-Card -Title 'No Targeted Grants Available' -Status 'ℹ️' -Body @"
Validation status: ``$valStatus``. None of the reported blockers can be cleared
by a per-resource role assignment (they are not permission blockers, or the
service did not name the resource).
"@
    }

    # ── Step 4: Consent gate on the broad fix (E3-T3) ───────
    $consentPrompt = @"
``fixResourcePermissions`` is a **broad** mutation. It asks Chaos Studio to grant
whatever roles it decides are required to the workspace identity, on every target resource
in this configuration's scope, in a single call. It is not limited to the
$($blockers.Count) blocker(s) listed above, and the plugin cannot enumerate the
grants in advance.

Prefer the targeted grants above. To proceed with the broad fix anyway, re-run
with ``-ConsentToBroadPermissionFix`` or set
``STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX=1``.
"@
    Set-StateProperty -PropertyPath "$StateBasePath.validation.permissionFix.consentPrompt" -Value $consentPrompt

    if (-not (Test-BroadPermissionFixConsent -Consented:$ConsentToBroadPermissionFix)) {
        Set-StateProperty -PropertyPath "$StateBasePath.validation.permissionFix.consent" -Value 'required'
        Write-Card -Title 'Consent Required — Broad Permission Fix' -Status '⏸️' -Body $consentPrompt
        throw "broadPermissionFixConsentRequired: validation is '$valStatus' and the broad fixResourcePermissions mutation needs explicit consent."
    }

    Set-StateProperty -PropertyPath "$StateBasePath.validation.permissionFix.consent" -Value 'granted'

    # ── Step 5: Attempt fix-permissions ─────────────────────
    Write-Card -Title 'Consent Given — Running Broad Permission Fix' -Status '⚠️' `
        -Body "Validation status: ``$valStatus``. Running ``az chaos scenario config fix-permissions``..."

    $fixResult = $null
    try {
        $fixResult = Invoke-AzChaos -ChaosArgs (@('scenario', 'config', 'fix-permissions') + $idArgs)
    } catch {
        $fixErr = $_.Exception.Message
        if ($fixErr -match '(?i)(403|Forbidden|AuthorizationFailed|Authorization_RequestDenied)') {
            Write-Error-Card -Title 'Permission Fix Failed — 403 Forbidden' `
                -ErrorMessage @"
The workspace identity does not have permission to create role assignments on the target scope.
The ``fix-permissions`` operation needs ``Microsoft.Authorization/roleAssignments/write`` on the workspace scope.

To resolve this, contact your security administrator and ask them to either:
  1. Grant you (or the workspace identity) the **User Access Administrator** or **Owner** role on the scope so that ``fix-permissions`` can auto-assign the required roles.
  2. Run the ``fix-permissions`` command themselves with elevated privileges:
     az chaos scenario config fix-permissions --resource-group $ResourceGroup --workspace-name $WorkspaceName --scenario-name $ScenarioName --name $ConfigName

Original error: $fixErr
"@
            throw "fixResourcePermissions 403: $fixErr"
        }
        throw
    }

    # Fall back to `show-permission-fix` when the fix command doesn't echo a body.
    if (-not $fixResult -or -not $fixResult.properties -or -not $fixResult.properties.state) {
        $fixResult = Invoke-AzChaos -ChaosArgs (@('scenario', 'config', 'show-permission-fix') + $idArgs) -AllowFailure
    }

    if (-not $fixResult -or -not $fixResult.properties) {
        # No result body available — proceed but warn; re-validation below is the real gate.
        Write-Card -Title 'Note' -Status 'ℹ️' `
            -Body '``fix-permissions`` completed but returned no result body. Relying on re-validation to confirm the outcome.'
        $fixResult = [PSCustomObject]@{ properties = [PSCustomObject]@{ state = 'Unknown'; summary = [PSCustomObject]@{ totalRequired = 0; succeeded = 0; failed = 0; skipped = 0 }; whatIfMode = $false } }
    }

    $fixState      = $fixResult.properties.state
    $fixSummary    = $fixResult.properties.summary
    $fixWhatIfMode = $fixResult.properties.whatIfMode

    Set-StateProperty -PropertyPath "$StateBasePath.validation.permissionFix.state"      -Value $fixState
    Set-StateProperty -PropertyPath "$StateBasePath.validation.permissionFix.summary"    -Value $fixSummary
    Set-StateProperty -PropertyPath "$StateBasePath.validation.permissionFix.whatIfMode" -Value $fixWhatIfMode

    if ($fixWhatIfMode -eq $true) {
        Write-Card -Title 'WARNING — fix-permissions ran in WHAT-IF mode' -Status '⚠️' -Body @"
The service returned ``whatIfMode: true``, meaning **no role assignments were actually created**.
This is unexpected because ``fix-permissions`` was invoked WITHOUT ``--what-if``.
Subsequent execution will likely fail with RBAC errors.
"@
    }

    if ($fixSummary.failed -gt 0) {
        Write-Error-Card -Title 'Some Permission Fixes Failed' `
            -ErrorMessage @"
$($fixSummary.failed) of $($fixSummary.totalRequired) required role assignments could not be created.
This typically means the workspace identity lacks ``Microsoft.Authorization/roleAssignments/write`` on one or more target resources.

To resolve this, contact your security administrator and ask them to either:
  1. Grant the workspace identity the required roles manually.
  2. Run the ``fix-permissions`` command with elevated privileges:
     az chaos scenario config fix-permissions --resource-group $ResourceGroup --workspace-name $WorkspaceName --scenario-name $ScenarioName --name $ConfigName
"@
    }

    Write-Card -Title 'Permission Fix Result' -Status $fixState -Properties ([ordered]@{
        'Total Required' = $fixSummary.totalRequired
        'Succeeded'      = $fixSummary.succeeded
        'Failed'         = $fixSummary.failed
        'Skipped'        = $fixSummary.skipped
    })

    # ── Step 6: Re-validate after fix ───────────────────────
    Write-Card -Title 'Re-validating Configuration' -Status '🔄'

    $reValResult = & $runValidate
    $valStatus = $reValResult.properties.status
    Set-StateProperty -PropertyPath "$StateBasePath.validation.lastResult" -Value $valStatus

    # ── Step 7: Wait for RBAC propagation ───────────────────
    # New role assignments take 30s-5min to propagate in ARM. If validation is
    # still not 'Succeeded' immediately after the fix, retry on an interval —
    # but ONLY when the failure looks like it could be a transient permission
    # propagation issue (i.e. the validation reports permission-related errors).
    # For non-permission failures, retrying wastes time, so we fall through to
    # the strict gate.
    if ($valStatus -ne 'Succeeded') {
        $isPermissionRelated = $true
        $reValErrors = $reValResult.properties.errors
        if ($reValErrors -and $reValErrors.Count -gt 0) {
            $nonPermCodes = @($reValErrors | Where-Object { $_.errorCode -notmatch '(?i)(Permission|Authoriz|Forbidden|RBAC|RoleAssignment)' })
            if ($nonPermCodes.Count -eq $reValErrors.Count) {
                $isPermissionRelated = $false
            }
        }

        if (-not $isPermissionRelated) {
            Write-Card -Title 'Skipping Propagation Wait' -Status 'ℹ️' -Body @"
Validation status is ``$valStatus`` but the errors do not look RBAC-related:
$(($reValErrors | ForEach-Object { "- **$($_.errorCode)**: $($_.errorMessage)" }) -join "`n")

Retrying validation will not help. The strict pre-execute gate will block execution below.
"@
        } else {
            $maxWaitSeconds      = 300   # 5 minutes total — typical RBAC propagation
            $intervalSeconds     = 20
            $maxAttempts         = [Math]::Ceiling($maxWaitSeconds / $intervalSeconds)
            $deadline            = (Get-Date).AddSeconds($maxWaitSeconds)

            Write-Card -Title 'Waiting for RBAC Propagation' -Status '⏳' -Body @"
Validation is still ``$valStatus`` immediately after the permission fix.
Azure role assignments can take up to **5 minutes** to propagate.
Re-validating every $intervalSeconds seconds (up to $maxAttempts attempts) until ``Succeeded`` or timeout...
"@

            $attempt = 0
            while ((Get-Date) -lt $deadline -and $valStatus -ne 'Succeeded') {
                $attempt++
                Start-Sleep -Seconds $intervalSeconds

                try {
                    $polResult = & $runValidate
                    $valStatus = $polResult.properties.status
                    Set-StateProperty -PropertyPath "$StateBasePath.validation.lastResult" -Value $valStatus

                    $elapsedSec = [int]((Get-Date) - $deadline.AddSeconds(-$maxWaitSeconds)).TotalSeconds
                    Write-Card -Title "Propagation Check $attempt/$maxAttempts" -Status "$(if ($valStatus -eq 'Succeeded') {'✅'} else {'⏳'}) $valStatus" `
                        -Body "Elapsed: ${elapsedSec}s of ${maxWaitSeconds}s budget."

                    if ($valStatus -eq 'Succeeded') { break }
                } catch {
                    # Transient errors during propagation are expected; keep polling.
                    Write-Card -Title "Propagation Check $attempt/$maxAttempts" -Status '⚠️ transient' `
                        -Body "Validation call failed: $($_.Exception.Message). Will retry."
                }
            }
        }
    }

    Write-Card -Title 'Validation Complete (post-fix)' -Status "$(if ($valStatus -eq 'Succeeded') {'✅'} else {'⚠️'}) $valStatus"
}
