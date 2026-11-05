<#
.SYNOPSIS
    Builds the Gotham AD Masterclass lab: the OU structure and every Gotham account,
    straight from gotham-roster.csv.

.DESCRIPTION
    Companion script for the TrevTech-IT "Gotham AD Masterclass" series.

    Reads the roster, creates any missing OUs (parents first), creates every account
    with proper detail - title, department, company, office, phone, employee ID,
    email - then links each person to their manager so the org chart actually works.

    How an account behaves comes from its AccountType column:

      User        Wayne Enterprises staff. Enabled, must change password at first logon.
      Former      Ex-staff. Always created DISABLED, parked outside Wayne Enterprises so
                  no policy or delegation aimed at current staff ever touches them.
      Contractor  Enabled column decides on/off. ExpiresInDays sets an expiry date, so
                  the account switches itself off when the contract ends.
      Service     Password never expires and the account can't change it. (Alfred.)
      Admin       Tiered -adm accounts. Only created with -IncludeAdminTier.
      BreakGlass  The emergency account. Only created with -IncludeAdminTier.

    Group memberships (the MemberOf column) are NOT handled here - that's
    New-GothamGroups.ps1, run after this one.

    Built for gotham.lab, but it runs in ANY domain: the DC= suffix on every OU path
    in the CSV is swapped for whatever domain you run it in. Swap the rows for your
    own cast and away you go.

.PARAMETER CsvPath
    Path to the roster. Defaults to gotham-roster.csv next to the script.

.PARAMETER DefaultPassword
    Starting password for every new account, as a SecureString. Leave it off and
    you'll be prompted - passwords don't belong in scripts, CSVs or shell history.
    (No prompt on a -WhatIf run, because nothing gets created.)

.PARAMETER IncludeAdminTier
    Also builds the Admin OUs and the tiered admin accounts (bwayne-adm and friends).
    Held back by default - that's a later episode, and it deserves its own.

.EXAMPLE
    .\New-GothamUsers.ps1 -WhatIf

    Dry run. Shows every OU and account it WOULD create. Touches nothing.
    Run this first. Every time.

.EXAMPLE
    .\New-GothamUsers.ps1

    The real thing: staff, former staff, contractors and service accounts.

.EXAMPLE
    .\New-GothamUsers.ps1 -IncludeAdminTier

    Adds the Admin tier on top. Safe to run over an existing build - anything
    that already exists is skipped, not touched (managers included).

.NOTES
    Author  : Trev - TrevTech-IT | trevtech.blog
    Repo    : TrevTech-IT/PowershellForActiveDirectory
    Built for: Windows Server 2025 (works on 2016+), Windows PowerShell 5.1 / PowerShell 7, ActiveDirectory module

    Lab shortcut to know about: OUs are created with accidental-deletion protection
    OFF, because labs get bulldozed and rebuilt. Production keeps it ON.

    I broke it. Fixed it.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'gotham-roster.csv'),

    [Parameter()]
    [securestring]$DefaultPassword,

    [Parameter()]
    [switch]$IncludeAdminTier
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredColumns = @(
    'FirstName', 'LastName', 'SamAccountName', 'AccountType', 'Enabled', 'Department',
    'Title', 'Company', 'Office', 'OfficePhone', 'EmployeeID', 'Manager', 'ExpiresInDays',
    'MemberOf', 'Description', 'OU'
)
$validTypes  = @('User', 'Former', 'Contractor', 'Service', 'Admin', 'BreakGlass')
$adminTypes  = @('Admin', 'BreakGlass')
$peopleTypes = @('User', 'Former', 'Contractor')   # real humans get email + city

# --- Check the roster before we touch anything ------------------------------------
# Much cheaper to fail here than halfway through hiring Gotham.
$roster = @(Import-Csv -Path $CsvPath)
if ($roster.Count -eq 0) {
    throw "The roster at '$CsvPath' is empty. Gotham can't run on zero staff."
}

$columns = $roster[0].PSObject.Properties.Name
$missing = @($requiredColumns | Where-Object { $_ -notin $columns })
if ($missing.Count -gt 0) {
    throw "Roster is missing column(s): $($missing -join ', ')"
}

$badTypes = @($roster | Where-Object { $_.AccountType.Trim() -notin $validTypes })
if ($badTypes.Count -gt 0) {
    throw "Unknown AccountType on: $(($badTypes | ForEach-Object SamAccountName) -join ', '). Valid: $($validTypes -join ', ')"
}

$dupes = @($roster | Group-Object -Property { $_.SamAccountName.Trim() } | Where-Object Count -gt 1)
if ($dupes.Count -gt 0) {
    throw "Duplicate SamAccountName(s) in the roster: $(($dupes | ForEach-Object Name) -join ', ')"
}

# --- Admin tier stays in the vault unless you ask for it ---------------------------
$toProcess = @($roster | Where-Object { $IncludeAdminTier -or $_.AccountType.Trim() -notin $adminTypes })
$heldBack  = $roster.Count - $toProcess.Count

# --- Password ------------------------------------------------------------------------
# No hardcoded passwords. Not in my scripts, not in yours.
if (-not $DefaultPassword -and -not $WhatIfPreference) {
    $DefaultPassword = Read-Host -AsSecureString -Prompt 'Starting password for all new Gotham accounts'
}

# --- Work out where we're standing -----------------------------------------------------
# The CSV says DC=gotham,DC=lab. Yours might not. Swap it on the fly so the same
# roster drops into trevtech.lab, corp.contoso.com, whatever you've got.
$domain    = Get-ADDomain
$domainDN  = $domain.DistinguishedName
$upnSuffix = $domain.DNSRoot
Write-Verbose "Target domain: $upnSuffix ($domainDN)"

foreach ($row in $toProcess) {
    $row.OU = $row.OU -replace 'DC=gotham,DC=lab$', $domainDN
}

# --- Build the OU structure ------------------------------------------------------------
# Collect every OU the roster mentions plus every parent above it, then create them
# shallowest-first so a parent always exists before its kids.
$allOus = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $toProcess) {
    $dn = $row.OU
    while ($dn -match '^OU=') {
        [void]$allOus.Add($dn)
        $dn = $dn -replace '^OU=[^,]+,', ''   # step up one level
    }
}

# Fewer commas = closer to the root = created first. (Safe because none of our OU
# names contain commas. If yours do, we need to talk about your naming standard.)
$orderedOus = @($allOus | Sort-Object -Property { ($_ -split ',').Count }, { $_ })

$ouCreated = 0
foreach ($ouDn in $orderedOus) {
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'") {
        Write-Verbose "OU already standing: $ouDn"
        continue
    }

    $ouName     = ($ouDn -split ',')[0] -replace '^OU='
    $parentPath = $ouDn -replace '^OU=[^,]+,', ''

    if ($PSCmdlet.ShouldProcess($ouDn, 'Create organizational unit')) {
        # Deletion protection OFF - it's a lab, and labs get bulldozed.
        New-ADOrganizationalUnit -Name $ouName -Path $parentPath -ProtectedFromAccidentalDeletion:$false
        Write-Host "  [OU]    Built: $ouName" -ForegroundColor Cyan
        $ouCreated++
    }
}

# --- Create the accounts -----------------------------------------------------------------
$created = 0
$skipped = 0
$newAccounts = [System.Collections.Generic.List[object]]::new()   # rows created (or would be) this run

foreach ($row in $toProcess) {
    $sam     = $row.SamAccountName.Trim()
    $first   = $row.FirstName.Trim()
    $last    = $row.LastName.Trim()
    $type    = $row.AccountType.Trim()
    $enabled = $row.Enabled.Trim() -match '^(true|yes|1)$'

    # Already on the payroll? Skip it, don't clobber it. Run this twice, nothing breaks.
    if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
        Write-Warning "$first $last ($sam) already exists - skipping."
        $skipped++
        continue
    }

    # Admin and service accounts get a suffix on the display name, so nobody mistakes
    # "Bruce Wayne (Admin)" for the Bruce who reads his email.
    $name = switch ($type) {
        'Service' { "$first $last (svc)" }
        'Admin'   { "$first $last (Admin)" }
        default   { "$first $last" }
    }

    $params = @{
        Name              = $name
        DisplayName       = $name
        GivenName         = $first
        Surname           = $last
        SamAccountName    = $sam
        UserPrincipalName = "$sam@$upnSuffix"
        Path              = $row.OU
        AccountPassword   = $DefaultPassword
        Enabled           = $enabled
    }

    # The detail. Only set what the CSV actually fills in - blank stays blank.
    foreach ($column in 'Department', 'Title', 'Company', 'Office', 'OfficePhone', 'EmployeeID', 'Description') {
        $value = $row.$column
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $params[$column] = $value.Trim()
        }
    }

    # Real people get an email address and a city. Admin and service accounts don't -
    # an admin account with a mailbox is an admin account that can get phished.
    if ($type -in $peopleTypes) {
        $localPart = '{0}.{1}' -f ($first -replace '[^A-Za-z0-9]', ''), ($last -replace '[^A-Za-z0-9]', '')
        $params['EmailAddress'] = '{0}@{1}' -f $localPart.ToLower(), $upnSuffix
        $params['City']         = 'Gotham City'
    }

    switch ($type) {
        'User'       { $params['ChangePasswordAtLogon'] = $true }
        'Contractor' { $params['ChangePasswordAtLogon'] = $enabled }
        'Former'     { $params['Enabled'] = $false }   # ex-staff are ALWAYS disabled, whatever the CSV says
        'Service'    { $params['PasswordNeverExpires'] = $true; $params['CannotChangePassword'] = $true }
        'Admin'      { $params['ChangePasswordAtLogon'] = $true; $params['AccountNotDelegated'] = $true }
        'BreakGlass' { $params['PasswordNeverExpires'] = $true; $params['AccountNotDelegated'] = $true }
    }

    # Contractors and interns: the account ends when the contract does. Nobody has to remember.
    $expiry = $null
    if ($row.ExpiresInDays.Trim() -match '^\d+$') {
        $expiry = (Get-Date).Date.AddDays([int]$row.ExpiresInDays.Trim())
        $params['AccountExpirationDate'] = $expiry
    }

    $newAccounts.Add($row)
    if ($PSCmdlet.ShouldProcess("$name ($sam) in $($row.OU)", 'Create AD user')) {
        New-ADUser @params

        $note = switch ($type) {
            'Service'    { ' - service account, never expires, never sleeps' }
            'Former'     { ' - former employee, disabled' }
            'Admin'      { ' - admin account, cannot be delegated' }
            'BreakGlass' { ' - break glass. Seal that password offline' }
            'Contractor' { if ($enabled) { ' - contractor' } else { ' - contractor, disabled' } }
            default      { '' }
        }
        if ($expiry) { $note += ", expires $($expiry.ToString('yyyy-MM-dd'))" }

        Write-Host "  [USER]  $name - $($row.Title)$note" -ForegroundColor Green
        $created++
    }
}

# --- Link new accounts to their manager ------------------------------------------------
# Second pass on purpose: a manager has to exist before anyone can report to them.
# This is what makes the Organization tab - and every org-chart tool - actually work.
# Only NEW accounts get linked. If someone's been promoted or moved since the CSV was
# written, a re-run won't quietly drag their manager back to the old one.
$linked = 0
foreach ($row in $newAccounts) {
    $managerSam = $row.Manager.Trim()
    if (-not $managerSam) { continue }
    $sam = $row.SamAccountName.Trim()

    if ($PSCmdlet.ShouldProcess($sam, "Set manager to $managerSam")) {
        $manager = Get-ADUser -Filter "SamAccountName -eq '$managerSam'"
        if (-not $manager) {
            Write-Warning "Manager '$managerSam' for $sam isn't in AD - skipping that link."
            continue
        }
        Set-ADUser -Identity $sam -Manager $manager
        $linked++
    }
}

# --- Roll credits -----------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 64)
Write-Host '  Gotham onboarding complete.'
Write-Host "  OUs built: $ouCreated | Accounts created: $created | Skipped: $skipped | Manager links: $linked"
if ($heldBack -gt 0) {
    Write-Host "  Admin tier: $heldBack account(s) held back. Add -IncludeAdminTier when you get there."
}
Write-Host '  Next up: .\New-GothamGroups.ps1 to hand out group memberships.'
Write-Host ('=' * 64)
