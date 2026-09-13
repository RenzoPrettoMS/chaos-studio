# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param(
    [Parameter(Mandatory)][string]$EntryPoint,
    [switch]$ReplayRunHash
)
$ErrorActionPreference = 'Stop'
if (Get-Command az -CommandType Application -ErrorAction SilentlyContinue) { throw 'Real Azure CLI must be OFF PATH.' }

function Read-TestAst {
    param([string]$Path)
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    return $ast
}

function Test-OptionalCall {
    param($Call, [string]$Name)
    for ($parent = $Call.Parent; $null -ne $parent; $parent = $parent.Parent) {
        if ($parent -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
        foreach ($clause in $parent.Clauses) {
            if ($Call.Extent.StartOffset -lt $clause.Item2.Extent.StartOffset -or
                $Call.Extent.EndOffset -gt $clause.Item2.Extent.EndOffset) { continue }
            $condition = $clause.Item1
            # Only positive Get-Command checks (alone or ANDed) make an import optional.
            $unsafeOperators = @($condition.FindAll({ param($node)
                ($node -is [System.Management.Automation.Language.UnaryExpressionAst]) -or
                ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and $node.Operator -ne 'And')
            }, $true))
            if ($unsafeOperators.Count -gt 0) { continue }
            foreach ($probe in $condition.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ($probe.GetCommandName() -eq 'Get-Command' -and $probe.CommandElements.Count -gt 1 -and
                    $probe.CommandElements[1].Extent.Text -eq $Name) { return $true }
            }
        }
    }
    return $false
}

$entryAst = Read-TestAst $EntryPoint
$skills = Split-Path (Split-Path (Split-Path $EntryPoint -Parent) -Parent) -Parent
$catalog = @{}
foreach ($file in Get-ChildItem "$skills/chaos-study*/scripts/lib/*.ps1") {
    $ast = Read-TestAst $file.FullName
    foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $catalog[$definition.Name] = $definition
    }
}
foreach ($definition in $entryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $catalog[$definition.Name] = $definition
}

# Execute only imports, path setup, and function declarations, never the phase.
$neededVariables = @{}
foreach ($import in $entryAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.PipelineAst] }) {
    foreach ($command in $import.PipelineElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandAst] -and
        $_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
    }) {
        foreach ($variable in $command.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $neededVariables[$variable.VariablePath.UserPath] = $true
        }
    }
}
do {
    $previousCount = $neededVariables.Count
    foreach ($assignment in $entryAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] }) {
        if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            -not $neededVariables.ContainsKey($assignment.Left.VariablePath.UserPath)) { continue }
        foreach ($variable in $assignment.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $neededVariables[$variable.VariablePath.UserPath] = $true
        }
    }
} while ($neededVariables.Count -ne $previousCount)
$entryRootLiteral = "'" + ((Split-Path $EntryPoint -Parent) -replace "'", "''") + "'"
foreach ($statement in $entryAst.EndBlock.Statements) {
    $statementText = $statement.Extent.Text.Replace('$PSScriptRoot', $entryRootLiteral)
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        if ($statement.Left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            -not $neededVariables.ContainsKey($statement.Left.VariablePath.UserPath)) { continue }
        $commands = @($statement.Right.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        if ($commands.Count -gt 0 -and @($commands | Where-Object { $_.GetCommandName() -notin @('Join-Path', 'Split-Path') }).Count -eq 0) {
            . ([scriptblock]::Create($statementText))
        }
    }
    elseif ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
    elseif ($statement -is [System.Management.Automation.Language.PipelineAst]) {
        $imports = @($statement.PipelineElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandAst] -and
            $_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
        })
        if ($imports.Count -gt 0) { . ([scriptblock]::Create($statementText)) }
    }
}

if ($ReplayRunHash) {
    $validation = [pscustomobject]@{
        status = 'Succeeded'
        legs = @([pscustomobject]@{ legSelector = 'zone-1'; action = 'shutdown'; executable = $true })
    }
    $expected = Get-ChaosDigest -InputObject ([ordered]@{
        total = 1; executable = 1; skipped = @(); undetermined = @()
    })
    $script:ReplayCalls = @()
    function New-ChaosStudyConfiguration {
        $script:ReplayCalls += 'create'
    }
    function Resolve-ChaosConfigurationValidation {
        $script:ReplayCalls += 'validate'
        return [pscustomobject]@{
            validation = $validation; status = 'Succeeded'; approvalRequired = $false
            permissionFix = $null; approvalPhrase = $null; grantSet = $null
        }
    }
    $plan = [pscustomobject]@{
        declaredVsEffective = [pscustomobject]@{ effectivePlanHash = $expected; preflight = $null }
    }
    $resolved = Resolve-ChaosRunConfiguration -Plan $plan -ConfigurationName 'offline-f24' -Adapter $null -StudyPath $null -PermissionApproval $null
    if (($script:ReplayCalls -join ',') -ne 'create,validate' -or $resolved.reused -or $resolved.status -ne 'Succeeded') {
        throw 'The re-created configuration did not complete the validation/equality path.'
    }
    $hash = Get-ChaosRunEffectivePlanHash -Validation $resolved.validation
    if ($hash -ne $expected) { throw "Unexpected effective-plan hash: $hash (expected $expected)." }
    "Run effective-plan hash resolved: $hash"
    exit 0
}

# Follow statically named calls from the entry point into library functions.
# This catches a missing transitive dependency even when the phase invokes only
# its wrapper (as with Resolve-ChaosRunConfiguration -> effective-plan hashing).
$queue = [System.Collections.Generic.Queue[object]]::new()
$queue.Enqueue($entryAst)
$visited = @{}
$missing = [System.Collections.Generic.List[string]]::new()
while ($queue.Count -gt 0) {
    $ast = $queue.Dequeue()
    foreach ($call in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $call.GetCommandName()
        if (-not $name -or $name -notmatch '(^|-)Chaos' -or -not $catalog.ContainsKey($name)) { continue }
        if (Test-OptionalCall -Call $call -Name $name) { continue }
        if ($visited.ContainsKey($name)) { continue }
        $visited[$name] = $true
        $definition = $catalog[$name]
        $owner = $definition.Parent
        while ($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $owner = $owner.Parent
        }
        if ($null -ne $owner -and $call.Extent.File -eq $definition.Extent.File -and
            $call.Extent.StartOffset -ge $owner.Body.Extent.StartOffset -and
            $call.Extent.EndOffset -le $owner.Body.Extent.EndOffset) {
            $queue.Enqueue($definition.Body)
            continue
        }
        $resolved = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $resolved) {
            $missing.Add("$name (called at $($call.Extent.File):$($call.Extent.StartLineNumber); defined in $($definition.Extent.File))")
        }
        elseif ($definition.Extent.File -ne $EntryPoint -and
            [IO.Path]::GetFullPath($resolved.ScriptBlock.File) -ne [IO.Path]::GetFullPath($definition.Extent.File)) {
            $missing.Add("$name resolved to '$($resolved.ScriptBlock.File)' instead of '$($definition.Extent.File)'")
        }
        $queue.Enqueue($definition.Body)
    }
}
if ($missing.Count -gt 0) { throw ("Unloaded shared functions:`n" + ($missing -join "`n")) }
"Shared import closure satisfied: $($visited.Count) function(s), $(Split-Path $EntryPoint -Leaf)."
