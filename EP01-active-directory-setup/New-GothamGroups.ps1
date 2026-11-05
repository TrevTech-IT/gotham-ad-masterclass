<#
.SYNOPSIS
    Builds the Gotham security groups, nests them the AGDLP way, and puts every
    Gotham account into the groups the roster says they belong in.

.DESCRIPTION
    Companion script for the TrevTech-IT "Gotham AD Masterclass" series.
    Run it AFTER New-GothamUsers.ps1.

    AGDLP in one breath: Accounts go into Global groups (who you are), Global groups
    go into Domain Local groups (what you can touch), and permissions only ever go on
    the Domain Local groups. So when Dick Grayson moves out of R&D, you change ONE
    group membership - you don't go hunting through share permissions.

    Three passes:
      1. Create the group OUs and the groups from gotham-groups.csv
      2. Nest groups into groups (the NestInto column)
      3. Add accounts to groups (the MemberOf column in gotham-roster.csv)

    Anything that already exists is left alone, so it's safe to run again.

.PARAMETER GroupsCsvPath
    Defaults to gotham-groups.csv next to the script.

.PARAMETER RosterCsvPath
    Defaults to gotham-roster.csv next to the script.

.PARAMETER IncludeAdminTier
    Also creates the Tier 0/1/2 admin groups and fills them. Match whatever you did
    with New-GothamUsers.ps1.

.EXAMPLE
    .\New-GothamGroups.ps1 -WhatIf

    Dry run. Every group, nesting and membership it WOULD create. Touches nothing.

.EXAMPLE
    .\New-GothamGroups.ps1 -IncludeAdminTier

    Everything, admin tier included.

.NOTES
    Author  : Trev - TrevTech-IT | trevtech.blog
    Built for: Windows Server 2025 (works on 2016+), Windows PowerShell 5.1 / PowerShell 7, ActiveDirectory module

    I broke it. Fixed it.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$GroupsCsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'gotham-groups.csv'),

    [Parameter()]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$RosterCsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'gotham-roster.csv'),

    [Parameter()]
    [switch]$IncludeAdminTier
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$adminTypes = @('Admin', 'BreakGlass')

function Split-List {
    # "GG-RD;GG-Managers" -> 'GG-RD','GG-Managers'. Blank -> nothing.
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Add-GothamMembership {
    # Adds one member to one group, politely: skips it if it's already there, and warns
    # instead of crashing if either side doesn't exist yet.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$GroupName,
        [Parameter(Mandatory)] [string]$MemberName,
        [Parameter(Mandatory)] [ValidateSet('User', 'Group')] [string]$MemberKind
    )

    $group = Get-ADGroup -Filter "Name -eq '$GroupName'"
    $member = if ($MemberKind -eq 'User') {
        Get-ADUser -Filter "SamAccountName -eq '$MemberName'" -Properties MemberOf, Enabled
    }
    else {
        Get-ADGroup -Filter "Name -eq '$MemberName'" -Properties MemberOf
    }

    # Never hand a group to a disabled account. If someone's left since the roster was
    # written, the CSV is out of date - AD wins, and they stay out.
    if ($MemberKind -eq 'User' -and $member -and -not $member.Enabled) {
        Write-Warning "$MemberName is disabled - not adding them to $GroupName. (Update the roster if they've left.)"
        return 'Disabled'
    }

    if ($group -and $member) {
        if ($member.MemberOf -contains $group.DistinguishedName) {
            Write-Verbose "$MemberName is already in $GroupName"
            return 'Existing'
        }
    }
    elseif (-not $WhatIfPreference) {
        $gap = if (-not $group) { "group '$GroupName'" } else { "$($MemberKind.ToLower()) '$MemberName'" }
        Write-Warning "Can't put $MemberName in $GroupName - $gap doesn't exist. (Run New-GothamUsers.ps1 first, with the same -IncludeAdminTier choice.)"
        return 'Missing'
    }

    if ($PSCmdlet.ShouldProcess($GroupName, "Add $($MemberKind.ToLower()) $MemberName")) {
        Add-ADGroupMember -Identity $group -Members $member
        Write-Host "  [MEMBER] $MemberName -> $GroupName" -ForegroundColor Green
        return 'Added'
    }
    return 'WhatIf'
}

# --- Load and check both CSVs --------------------------------------------------------------
$groups = @(Import-Csv -Path $GroupsCsvPath)
$roster = @(Import-Csv -Path $RosterCsvPath)

foreach ($check in @(
        @{ Rows = $groups; Name = 'groups CSV'; Columns = 'Name', 'Scope', 'Tier', 'OU', 'Description', 'NestInto' },
        @{ Rows = $roster; Name = 'roster CSV'; Columns = 'SamAccountName', 'AccountType', 'MemberOf' })) {
    if ($check.Rows.Count -eq 0) { throw "The $($check.Name) is empty." }
    $present = $check.Rows[0].PSObject.Properties.Name
    $missing = @($check.Columns | Where-Object { $_ -notin $present })
    if ($missing.Count -gt 0) { throw "The $($check.Name) is missing column(s): $($missing -join ', ')" }
}

$badScope = @($groups | Where-Object { $_.Scope.Trim() -notin 'Global', 'DomainLocal', 'Universal' })
if ($badScope.Count -gt 0) {
    throw "Invalid Scope on: $(($badScope | ForEach-Object Name) -join ', '). Use Global, DomainLocal or Universal."
}

# Admin groups (anything with a Tier) wait for -IncludeAdminTier.
$groups = @($groups | Where-Object { $IncludeAdminTier -or [string]::IsNullOrWhiteSpace($_.Tier) })
$roster = @($roster | Where-Object { $IncludeAdminTier -or $_.AccountType.Trim() -notin $adminTypes })

# --- Same trick as the users script: remap DC=gotham,DC=lab onto your domain -------------
$domainDN = (Get-ADDomain).DistinguishedName
foreach ($g in $groups) {
    $g.OU = $g.OU -replace 'DC=gotham,DC=lab$', $domainDN
}

# --- Pass 1a: group OUs, parents first -------------------------------------------------------
$allOus = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($g in $groups) {
    $dn = $g.OU
    while ($dn -match '^OU=') {
        [void]$allOus.Add($dn)
        $dn = $dn -replace '^OU=[^,]+,', ''
    }
}

$ouCreated = 0
foreach ($ouDn in @($allOus | Sort-Object -Property { ($_ -split ',').Count }, { $_ })) {
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'") { continue }

    $ouName     = ($ouDn -split ',')[0] -replace '^OU='
    $parentPath = $ouDn -replace '^OU=[^,]+,', ''
    if ($PSCmdlet.ShouldProcess($ouDn, 'Create organizational unit')) {
        New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ProtectedFromAccidentalDeletion:$false
        Write-Host "  [OU]     Built: $ouName" -ForegroundColor Cyan
        $ouCreated++
    }
}

# --- Pass 1b: the groups themselves ------------------------------------------------------------
$groupsCreated = 0
foreach ($g in $groups) {
    $name = $g.Name.Trim()
    if (Get-ADGroup -Filter "Name -eq '$name'") {
        Write-Verbose "Group already exists: $name"
        continue
    }

    if ($PSCmdlet.ShouldProcess("$name in $($g.OU)", "Create $($g.Scope.Trim()) security group")) {
        New-ADGroup -Name $name -SamAccountName $name -GroupScope $g.Scope.Trim() `
            -GroupCategory Security -Path $g.OU -Description $g.Description
        Write-Host "  [GROUP]  $name ($($g.Scope.Trim()))" -ForegroundColor Cyan
        $groupsCreated++
    }
}

# --- Pass 2: nest groups into groups (the G -> DL bit of AGDLP) -----------------------------------
$stats = @{ Added = 0; Existing = 0; Missing = 0; WhatIf = 0; Disabled = 0 }
foreach ($g in $groups) {
    foreach ($parent in (Split-List $g.NestInto)) {
        $result = Add-GothamMembership -GroupName $parent -MemberName $g.Name.Trim() -MemberKind Group
        $stats[$result]++
    }
}
$nested = $stats.Added

# --- Pass 3: people into their role groups (the A -> G bit) -----------------------------------------
foreach ($row in $roster) {
    foreach ($groupName in (Split-List $row.MemberOf)) {
        $result = Add-GothamMembership -GroupName $groupName -MemberName $row.SamAccountName.Trim() -MemberKind User
        $stats[$result]++
    }
}

# --- Roll credits ----------------------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 64)
Write-Host '  Gotham groups complete.'
Write-Host "  OUs built: $ouCreated | Groups created: $groupsCreated | Nestings: $nested | Memberships: $($stats.Added - $nested)"
if ($stats.Existing -gt 0) { Write-Host "  Already in place (left alone): $($stats.Existing)" }
if ($stats.Disabled -gt 0) { Write-Host "  Skipped disabled accounts: $($stats.Disabled)" }
if ($stats.Missing -gt 0)  { Write-Host "  Couldn't add: $($stats.Missing) - see the warnings above." -ForegroundColor Yellow }
Write-Host '  Permissions go on the DL- groups. Never on people.'
Write-Host ('=' * 64)
