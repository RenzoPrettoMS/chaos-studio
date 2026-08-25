<#
.SYNOPSIS
    Pester 5 unit tests for the blast-radius helpers in scripts/Render.ps1 (E3-T1 / E3-T5).

.DESCRIPTION
    Field evidence F8: exclusions and the resulting affected-resource set were
    never shown before the configuration was created, and CS-7 records that
    exclusion-based leg starvation is undiscoverable. `Resolve-BlastRadius` is
    the pure resolver behind the card the setup skill renders *before* the
    first mutation; `Write-BlastRadiusCard` is its Markdown rendering.

    The precedence contract asserted here is the one written down in
    `references/chaos/blast-radius.md`:
      1. empty include  = every candidate is in scope;
      2. non-empty include filters the candidate set;
      3. exclude always wins over include;
      4. ARM ids compare case-insensitively;
      5. an empty resolved set is reported as starved, and starvation caused by
         an exclusion is called out separately.

    Lives under `skills/setup-scenario/tests/` so it is discovered by the
    existing CI Pester invocation (`Run.Path = './copilot-cli-plugin/skills'`)
    without changing or narrowing that path.
#>

BeforeAll {
    $script:PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $script:PluginRoot 'scripts' 'Render.ps1')

    $script:VmA  = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-a'
    $script:VmB  = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-b'
    $script:VmC  = '/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm-c'
    $script:All  = @($script:VmA, $script:VmB, $script:VmC)
}

Describe 'Resolve-BlastRadius — include/exclude precedence' {
    It 'includes every candidate when neither filter is supplied' {
        $br = Resolve-BlastRadius -Candidate $script:All
        $br.included      | Should -Be $script:All
        $br.excluded      | Should -BeNullOrEmpty
        $br.includedCount | Should -Be 3
        $br.isStarved     | Should -BeFalse
    }

    It 'narrows the candidate set to a non-empty include list' {
        $br = Resolve-BlastRadius -Candidate $script:All -Include @($script:VmA, $script:VmC)
        $br.included    | Should -Be @($script:VmA, $script:VmC)
        $br.notIncluded | Should -Be @($script:VmB)
        $br.excluded    | Should -BeNullOrEmpty
    }

    It 'removes excluded candidates when no include list is supplied' {
        $br = Resolve-BlastRadius -Candidate $script:All -Exclude @($script:VmB)
        $br.included | Should -Be @($script:VmA, $script:VmC)
        $br.excluded | Should -Be @($script:VmB)
    }

    It 'gives exclude precedence over include for a resource named in both' {
        $br = Resolve-BlastRadius -Candidate $script:All `
            -Include @($script:VmA, $script:VmB) -Exclude @($script:VmB)
        $br.included | Should -Be @($script:VmA)
        $br.excluded | Should -Be @($script:VmB)
        # vm-c never entered the include set, so it is *not* an exclusion.
        $br.notIncluded | Should -Be @($script:VmC)
    }

    It 'matches ARM ids case-insensitively' {
        $br = Resolve-BlastRadius -Candidate $script:All -Exclude @($script:VmB.ToUpper())
        $br.included | Should -Be @($script:VmA, $script:VmC)
        $br.excluded | Should -Be @($script:VmB)
    }

    It 'ignores a trailing slash and surrounding whitespace on a filter' {
        $br = Resolve-BlastRadius -Candidate $script:All -Exclude @("  $($script:VmA)/  ")
        $br.included | Should -Be @($script:VmB, $script:VmC)
        $br.excluded | Should -Be @($script:VmA)
    }

    It 'preserves candidate order and de-duplicates repeated candidates' {
        $br = Resolve-BlastRadius -Candidate @($script:VmC, $script:VmA, $script:VmC)
        $br.included       | Should -Be @($script:VmC, $script:VmA)
        $br.candidateCount | Should -Be 2
    }

    It 'reports filters that matched nothing instead of silently dropping them' {
        $br = Resolve-BlastRadius -Candidate @($script:VmA) `
            -Include @($script:VmA, '/subscriptions/s1/ghost-include') `
            -Exclude @('/subscriptions/s1/ghost-exclude')
        $br.unmatchedInclude | Should -Be @('/subscriptions/s1/ghost-include')
        $br.unmatchedExclude | Should -Be @('/subscriptions/s1/ghost-exclude')
        $br.included         | Should -Be @($script:VmA)
    }

    It 'flags starvation caused by an exclusion (CS-7)' {
        $br = Resolve-BlastRadius -Candidate @($script:VmA) -Exclude @($script:VmA)
        $br.included           | Should -BeNullOrEmpty
        $br.isStarved          | Should -BeTrue
        $br.starvedByExclusion | Should -BeTrue
    }

    It 'flags starvation caused by an include list that matches nothing' {
        $br = Resolve-BlastRadius -Candidate @($script:VmA) -Include @('/subscriptions/s1/ghost')
        $br.isStarved          | Should -BeTrue
        $br.starvedByExclusion | Should -BeFalse
    }

    It 'is not starved when there were no candidates to begin with' {
        # Nothing was discovered; that is an upstream scope problem, not an
        # exclusion problem, and must not be misreported as one.
        $br = Resolve-BlastRadius -Candidate @()
        $br.candidateCount     | Should -Be 0
        $br.isStarved          | Should -BeFalse
        $br.starvedByExclusion | Should -BeFalse
    }

    It 'drops null and empty candidate entries' {
        $br = Resolve-BlastRadius -Candidate @($script:VmA, $null, '', '   ')
        $br.included       | Should -Be @($script:VmA)
        $br.candidateCount | Should -Be 1
    }
}

Describe 'Write-BlastRadiusCard' {
    It 'renders the affected resources and the counts' {
        $br  = Resolve-BlastRadius -Candidate $script:All -Exclude @($script:VmB)
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"

        $out | Should -Match '## Blast Radius'
        $out | Should -Match ([regex]::Escape($script:VmA))
        $out | Should -Match ([regex]::Escape($script:VmC))
        $out | Should -Match 'Affected Resources'
    }

    It 'lists the exclusions so they are visible before any mutation (F8)' {
        $br  = Resolve-BlastRadius -Candidate $script:All -Exclude @($script:VmB)
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"

        $out | Should -Match 'Excluded'
        $out | Should -Match ([regex]::Escape($script:VmB))
    }

    It 'warns loudly and points at the contract when the set is starved' {
        $br  = Resolve-BlastRadius -Candidate @($script:VmA) -Exclude @($script:VmA)
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"

        $out | Should -Match '⚠️'
        $out | Should -Match 'references/chaos/blast-radius.md'
    }

    It 'names filters that matched nothing' {
        $br  = Resolve-BlastRadius -Candidate @($script:VmA) -Exclude @('/subscriptions/s1/ghost')
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"
        $out | Should -Match 'ghost'
    }

    It 'renders without throwing when nothing was discovered' {
        $br  = Resolve-BlastRadius -Candidate @()
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"
        $out | Should -Match '## Blast Radius'
    }

    It 'never shows a green status when nothing would be touched' {
        # candidateCount 0 is not starvation (blast-radius.md §4 row 3), but a
        # ✅ on "this will touch nothing" is the same silent no-op as CS-7.
        $br  = Resolve-BlastRadius -Candidate @()
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"
        $out | Should -Match 'Nothing discovered in scope'
        $out | Should -Not -Match '✅'
    }
}

Describe 'Write-BlastRadiusCard discloses that targeting is advisory' {
    # The service accepts no include/exclude on `scenario config create`, so an
    # exclusion is never enforced. A card that implies otherwise would tell a
    # user their primary is spared and then take it down — strictly worse than
    # rendering nothing, and the inverse of the F8 failure this exists to fix.
    It 'says so on a plain run with no targeting at all' {
        $br  = Resolve-BlastRadius -Candidate $script:All
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"

        $out | Should -Match 'advisory'
        $out | Should -Match 'not\s+transmitted to Azure Chaos Studio'
        $out | Should -Match 'not an\s+enforced filter'
    }

    It 'says so again on the row of every excluded resource' {
        $br  = Resolve-BlastRadius -Candidate $script:All -Exclude @($script:VmB)
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"

        ($out -split "`n" | Where-Object { $_ -match [regex]::Escape($script:VmB) -and $_ -match 'Excluded by resourceTargeting.exclude' }) |
            Should -Match 'not enforced by the service'
    }

    It 'frames the affected set as a prediction, never as what was applied' {
        $br  = Resolve-BlastRadius -Candidate $script:All -Exclude @($script:VmB)
        $out = (Write-BlastRadiusCard -BlastRadius $br) -join "`n"

        $out | Should -Match 'Predicted Affected Resources'
        $out | Should -Match 'preview of what the service is expected to target'
        # It must also say how to actually spare a resource.
        $out | Should -Match 'workspace scope|Chaos target'
    }
}

Describe 'The advisory disclosure is repeated everywhere targeting is documented' {
    BeforeAll {
        $script:Docs = @{
            'blast-radius.md'         = Join-Path $script:PluginRoot 'references' 'chaos' 'blast-radius.md'
            'setup-scenario/SKILL.md' = Join-Path $script:PluginRoot 'skills' 'setup-scenario' 'SKILL.md'
            'run-scenario/SKILL.md'   = Join-Path $script:PluginRoot 'skills' 'run-scenario' 'SKILL.md'
        }
    }

    It '<_> states that resourceTargeting is advisory and not enforced' -ForEach @(
        'blast-radius.md', 'setup-scenario/SKILL.md', 'run-scenario/SKILL.md'
    ) {
        $text = Get-Content -Raw -LiteralPath $script:Docs[$_]
        $text | Should -Match '(?i)advisory'
        $text | Should -Match '(?i)no include/exclude argument'
    }

    It 'blast-radius.md tells the reader how to enforce an exclusion for real' {
        $text = Get-Content -Raw -LiteralPath $script:Docs['blast-radius.md']
        # §2 disclosure and the §4 recipe table must both carry it.
        $text | Should -Match 'never transmitted to the service'
        $text | Should -Match 'These recipes shape the prediction, not the run'
        $text | Should -Match 'disable its Chaos target|disabling that instance''s Chaos target'
    }

    It 'run-scenario/SKILL.md does not claim the configuration was created against it' {
        $text = Get-Content -Raw -LiteralPath $script:Docs['run-scenario/SKILL.md']
        $text | Should -Not -Match 'blast radius the configuration was created against'
        $text | Should -Match 'can still be targeted by this run'
    }

    It 'Invoke-SetupScenario.ps1 passes no targeting to `scenario config create`' {
        # Pins the disclosure to the code: if targeting is ever transmitted, this
        # test must be revisited together with the "advisory" wording above.
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:PluginRoot 'skills' 'setup-scenario' 'scripts' 'Invoke-SetupScenario.ps1')
        $createBlock = [regex]::Match($src, "\`$createCfgArgs = @\((?<body>[\s\S]*?)\r?\n\s*\)").Groups['body'].Value
        $createBlock | Should -Not -BeNullOrEmpty
        $createBlock | Should -Not -Match 'ResourceTargeting|blastRadius|include|exclude'
    }
}

Describe 'setup-scenario renders the blast radius before it mutates anything' {
    BeforeAll {
        $script:SetupScript = Join-Path $script:PluginRoot 'skills' 'setup-scenario' 'scripts' 'Invoke-SetupScenario.ps1'
        $script:SetupSource = Get-Content $script:SetupScript -Raw
    }

    It 'resolves and renders the blast radius' {
        $script:SetupSource | Should -Match 'Resolve-BlastRadius'
        $script:SetupSource | Should -Match 'Write-BlastRadiusCard'
    }

    It 'renders it strictly before `scenario config create`' {
        $render = $script:SetupSource.IndexOf('Write-BlastRadiusCard')
        $create = $script:SetupSource.IndexOf("'scenario', 'config', 'create'")
        $render | Should -BeGreaterThan -1
        $create | Should -BeGreaterThan -1
        $render | Should -BeLessThan $create
    }

    It 'accepts caller-supplied include/exclude targeting' {
        $script:SetupSource | Should -Match '\$ResourceTargeting'
    }
}
