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

    Behavior (always-on validation + always-on remediation when applicable):
      1. `az chaos scenario config validate` (CLI polls the LRO to completion).
      2. Read the validation status (from the validate result, falling back to
         `az chaos scenario config show-validation`) -> $valStatus.
      3. If $valStatus is NOT 'Succeeded' (i.e. Failed/RequiresAttention/etc.) OR
         validationErrors are present, `az chaos scenario config fix-permissions`
         (actual fix, not --what-if), then re-validate.
      4. Returns the final validation status string via state.

    State persistence:
      - Always writes the final validation status to
        "$StateBasePath.validation.lastResult".
      - When fix runs, also writes:
          $StateBasePath.validation.permissionFix.state
          $StateBasePath.validation.permissionFix.summary
          $StateBasePath.validation.permissionFix.whatIfMode

    Required dot-sourced dependencies (caller must load before invoking):
      State.ps1, Render.ps1, Invoke-AzChaos.ps1

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

.OUTPUTS
    None. Callers should read the final status from state at
    "$StateBasePath.validation.lastResult" after this function returns.
#>
function Invoke-ValidateAndFix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$ScenarioName,
        [Parameter(Mandatory)][string]$ConfigName,
        [Parameter(Mandatory)][string]$StateBasePath
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

    # ── Step 3: Attempt fix-permissions ─────────────────────
    Write-Card -Title 'Validation Needs Attention — Auto-Fixing Permissions' -Status '⚠️' `
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

    # ── Step 4: Re-validate after fix ───────────────────────
    Write-Card -Title 'Re-validating Configuration' -Status '🔄'

    $reValResult = & $runValidate
    $valStatus = $reValResult.properties.status
    Set-StateProperty -PropertyPath "$StateBasePath.validation.lastResult" -Value $valStatus

    # ── Step 5: Wait for RBAC propagation ───────────────────
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
