<#
.SYNOPSIS
    RBAC helpers for the startchaos plugin.

.DESCRIPTION
    Provides functions to check, grant, and build remediation for Azure RBAC
    role assignments required by Chaos Studio workspaces.

    Functions:
      Test-CallerCanAssignRoles       — checks if current user can create role assignments
      Grant-Reader                    — grants the Reader role on a scope
      Build-RoleAssignmentRemediation — builds CLI commands for manual RBAC fixes
      Build-TargetedGrantProposal     — exact per-resource grants for validation blockers

.NOTES
    Reader role definition ID: acdd72a7-3385-48ef-bd42-f606fba81ae7
#>

# ── Constants ───────────────────────────────────────────
$script:ReaderRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

function Test-CallerCanAssignRoles {
    <#
    .SYNOPSIS
        Checks whether the current Azure CLI caller has permission to create
        role assignments on a given scope.
    .PARAMETER Scope
        The ARM scope to test (e.g. a subscription or resource group ID).
    .OUTPUTS
        [bool] $true if the caller can assign roles, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    [Console]::Error.WriteLine("[Rbac] Testing roleAssignment write on $Scope")

    try {
        # Check if caller has Microsoft.Authorization/roleAssignments/write
        $checkUri = "${Scope}/providers/Microsoft.Authorization/permissions"
        $response = Invoke-AzRest -Method GET -Uri $checkUri -ApiVersion '2022-04-01'

        if ($response.body -and $response.body.value) {
            foreach ($perm in $response.body.value) {
                $actions = @($perm.actions)
                foreach ($action in $actions) {
                    if ($action -eq '*' -or
                        $action -eq 'Microsoft.Authorization/*' -or
                        $action -eq 'Microsoft.Authorization/roleAssignments/*' -or
                        $action -eq 'Microsoft.Authorization/roleAssignments/write') {

                        # Check notActions don't exclude it
                        $notActions = @($perm.notActions)
                        $excluded = $false
                        foreach ($notAction in $notActions) {
                            if ($notAction -eq 'Microsoft.Authorization/roleAssignments/write' -or
                                $notAction -eq 'Microsoft.Authorization/roleAssignments/*' -or
                                $notAction -eq 'Microsoft.Authorization/*') {
                                $excluded = $true
                                break
                            }
                        }
                        if (-not $excluded) {
                            [Console]::Error.WriteLine("[Rbac] Caller CAN assign roles on $Scope")
                            return $true
                        }
                    }
                }
            }
        }

        [Console]::Error.WriteLine("[Rbac] Caller CANNOT assign roles on $Scope")
        return $false
    } catch {
        [Console]::Error.WriteLine("[Rbac] Permission check failed: $_ — assuming denied")
        return $false
    }
}

function Grant-Reader {
    <#
    .SYNOPSIS
        Grants the Reader role to a principal on a given scope.
    .PARAMETER Scope
        ARM scope for the role assignment.
    .PARAMETER PrincipalId
        Object ID of the managed identity or user.
    .PARAMETER PrincipalType
        Type of principal: ServicePrincipal (default) or User.
    .OUTPUTS
        [string] One of: 'granted', 'already-exists', 'denied'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$PrincipalId,

        [Parameter()]
        [ValidateSet('ServicePrincipal', 'User')]
        [string]$PrincipalType = 'ServicePrincipal'
    )

    $roleDefId = $script:ReaderRoleDefinitionId
    $assignmentId = [System.Guid]::NewGuid().ToString()
    $assignmentUri = "${Scope}/providers/Microsoft.Authorization/roleAssignments/${assignmentId}"

    [Console]::Error.WriteLine("[Rbac] Granting Reader ($roleDefId) to $PrincipalId on $Scope")

    $body = @{
        properties = @{
            roleDefinitionId = "${Scope}/providers/Microsoft.Authorization/roleDefinitions/${roleDefId}"
            principalId      = $PrincipalId
            principalType    = $PrincipalType
        }
    }

    try {
        $response = Invoke-AzRest -Method PUT -Uri $assignmentUri -Body $body -ApiVersion '2022-04-01'

        if ($response.body -and $response.body.id) {
            [Console]::Error.WriteLine("[Rbac] Reader role GRANTED — assignment: $($response.body.id)")
            return 'granted'
        }

        return 'granted'
    } catch {
        $errorMsg = $_.Exception.Message

        # Conflict = already exists
        if ($errorMsg -match '409' -or $errorMsg -match 'RoleAssignmentExists' -or $errorMsg -match 'Conflict') {
            [Console]::Error.WriteLine("[Rbac] Reader role ALREADY EXISTS on $Scope for $PrincipalId")
            return 'already-exists'
        }

        # Forbidden = caller cannot assign
        if ($errorMsg -match '403' -or $errorMsg -match 'Forbidden' -or $errorMsg -match 'AuthorizationFailed') {
            [Console]::Error.WriteLine("[Rbac] Reader role DENIED — insufficient permissions")
            return 'denied'
        }

        # Unknown error — treat as denied
        [Console]::Error.WriteLine("[Rbac] Reader role assignment failed: $errorMsg")
        return 'denied'
    }
}

function Build-RoleAssignmentRemediation {
    <#
    .SYNOPSIS
        Builds Azure CLI commands that a privileged user can run to fix
        missing role assignments.
    .PARAMETER Scope
        ARM scope for the role assignment.
    .PARAMETER PrincipalId
        Object ID of the managed identity.
    .PARAMETER RoleName
        Role name to assign. Default: Reader.
    .OUTPUTS
        [PSCustomObject] with properties:
          .command     — the az CLI command string
          .description — human-readable explanation
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$PrincipalId,

        [Parameter()]
        [string]$RoleName = 'Reader'
    )

    $command = "az role assignment create --assignee-object-id `"$PrincipalId`" --assignee-principal-type ServicePrincipal --role `"$RoleName`" --scope `"$Scope`""

    [PSCustomObject]@{
        command     = $command
        description = "Grant '$RoleName' to principal $PrincipalId on scope $Scope"
    }
}

function Build-TargetedGrantProposal {
    <#
    .SYNOPSIS
        Builds the exact, minimum-scope role grants that would clear a set of
        normalized validation blockers (E3-T2).
    .DESCRIPTION
        Pure function — no ARM calls. The proposal is always offered *before*
        `fixResourcePermissions`, which is a broad-breadth mutation: it grants
        whatever the service decides is required across every target resource
        in one call. Each proposed grant here is scoped to the single resource
        that reported the blocker.

        Blockers that no role assignment can fix (category != 'permission') and
        blockers with no resource id (the scope would be a guess) are skipped.
        Duplicate (resource, role) pairs collapse.
    .PARAMETER Blockers
        Normalized blockers from `ConvertTo-ValidationBlocker` (Validate-AndFix.ps1).
    .PARAMETER PrincipalId
        Object ID of the workspace identity. When unknown, a visible
        placeholder is emitted so the command is never silently unassignable.
    .PARAMETER DefaultRoleName
        Role to propose when the service did not name one. Default: Reader.
    .OUTPUTS
        [PSCustomObject[]] each with resourceId, roleName, blockerCode,
        command and description.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Blockers = @(),

        [Parameter()]
        [string]$PrincipalId,

        [Parameter()]
        [string]$DefaultRoleName = 'Reader'
    )

    $principal = if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        '<workspace-identity-principal-id>'
    } else {
        $PrincipalId
    }

    $proposal = @()
    $seen = @{}

    foreach ($blocker in $Blockers) {
        if (-not $blocker) { continue }
        if ($blocker.category -ne 'permission') { continue }
        if ([string]::IsNullOrWhiteSpace($blocker.resourceId)) { continue }

        $roleName = if ([string]::IsNullOrWhiteSpace($blocker.roleName)) { $DefaultRoleName } else { $blocker.roleName }
        $key = "$($blocker.resourceId)|$roleName".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $remediation = Build-RoleAssignmentRemediation -Scope $blocker.resourceId `
            -PrincipalId $principal -RoleName $roleName

        $proposal += [PSCustomObject]@{
            resourceId  = $blocker.resourceId
            roleName    = $roleName
            blockerCode = $blocker.code
            command     = $remediation.command
            description = $remediation.description
        }
    }

    return $proposal
}

# When imported via Import-Module, all functions are exported by default.
# When dot-sourced, functions are available in the calling scope.
