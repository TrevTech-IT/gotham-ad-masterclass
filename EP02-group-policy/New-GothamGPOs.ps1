<#
.SYNOPSIS
    Builds the three Wayne Enterprises GPOs from Gotham AD Masterclass Episode 2 and links them
    to the Wayne Enterprises OU.

.DESCRIPTION
    Creates, configures and links:

      WE-C-USB-Block              Computer half only. All Removable Storage classes: Deny all access.
      WE-C-Workstation-Baseline   Computer half only. Logon banner (title + text), 15-minute machine
                                  inactivity lock, forced lock-screen image.
      WE-U-Desktop-Branding       User half only. Desktop wallpaper (Fill).

    Also creates OU=Workstations under Wayne Enterprises if it isn't there yet.

    It never touches the Default Domain Policy or the Default Domain Controllers Policy, and it
    never links anything to the domain root.

    Safe to re-run: a GPO that already exists is re-configured with the same values, not duplicated,
    and an existing link is left alone.

    The video builds these by clicking, so you can see where every setting lives. This script is
    the "do it again in ten seconds" version for your own lab.

.PARAMETER BrandingPath
    UNC folder holding wayne-desktop.jpg and wayne-lockscreen.jpg.
    Default: \\<your domain>\NETLOGON\Branding

.PARAMETER BannerTitle
    Logon banner title. Default: WAYNE ENTERPRISES

.PARAMETER BannerText
    Logon banner text.

.PARAMETER InactivitySeconds
    Machine inactivity limit in seconds. Default 900 (15 minutes).

.EXAMPLE
    .\New-GothamGPOs.ps1 -WhatIf
    Shows every GPO, setting and link it would create. Changes nothing.

.EXAMPLE
    .\New-GothamGPOs.ps1
    Builds and links the three GPOs.

.NOTES
    Gotham AD Masterclass · TrevTech-IT · https://www.youtube.com/watch?v=0T5iN290njQ&list=PLfmRIg23g1uw&pp=sAgC
    Requires the GroupPolicy and ActiveDirectory modules (on a DC, or RSAT).

    Built-by-script vs clicked: the banner and inactivity values are written as registry policy.
    They behave exactly the same, but GPMC's Settings report lists them under "Extra Registry
    Settings" rather than "Security Options".

    The lock-screen setting only takes effect on Windows Enterprise, Education and Server editions.
    The wallpaper policy expects a .jpg or .bmp.

    
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BrandingPath,
    [string]$BannerTitle = 'WAYNE ENTERPRISES',
    [string]$BannerText  = 'This system is the property of Wayne Enterprises. Authorized personnel only. All activity is monitored.',
    [ValidateRange(60, 599940)]
    [int]$InactivitySeconds = 900
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
Import-Module GroupPolicy

# --- Where are we? ----------------------------------------------------------------------------
$domain     = Get-ADDomain
$domainDN   = $domain.DistinguishedName
$dnsRoot    = $domain.DNSRoot
$companyOU  = "OU=Wayne Enterprises,$domainDN"
$workstOU   = "OU=Workstations,$companyOU"

if (-not $BrandingPath) { $BrandingPath = "\\$dnsRoot\NETLOGON\Branding" }
$wallpaper  = Join-Path $BrandingPath 'wayne-desktop.jpg'
$lockscreen = Join-Path $BrandingPath 'wayne-lockscreen.jpg'

Write-Host "Domain:   $dnsRoot" -ForegroundColor Cyan
Write-Host "Link to:  $companyOU" -ForegroundColor Cyan
Write-Host "Branding: $BrandingPath`n" -ForegroundColor Cyan

# --- Pre-flight -------------------------------------------------------------------------------
try { Get-ADOrganizationalUnit -Identity $companyOU | Out-Null }
catch { throw "Can't find '$companyOU'. Build the org chart first (New-GothamUsers.ps1, Episode 1)." }

foreach ($img in $wallpaper, $lockscreen) {
    if (-not (Test-Path $img)) {
        Write-Warning "Not found: $img. The GPO will still be built, but PCs will show the default image until the file is there."
    }
}

$created = 0; $linked = 0

# --- Helpers ----------------------------------------------------------------------------------
function Get-OrNewGpo {
    param([string]$Name, [string]$Comment)
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if ($gpo) {
        Write-Host "  exists  $Name" -ForegroundColor DarkGray
        return $gpo
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create GPO')) {
        $script:created++
        Write-Host "  create  $Name" -ForegroundColor Green
        return New-GPO -Name $Name -Comment $Comment
    }
    # -WhatIf: hand back a stand-in so the settings and link still get listed
    return [pscustomobject]@{ DisplayName = $Name; Id = $null; WhatIfOnly = $true }
}

function Set-Policy {
    param($Gpo, [string]$Key, [string]$ValueName, [ValidateSet('DWord','String')][string]$Type, $Value)
    $label = "$($Gpo.DisplayName): $Key\$ValueName = $Value"
    if ($PSCmdlet.ShouldProcess($label, 'Set policy value')) {
        Set-GPRegistryValue -Guid $Gpo.Id -Key $Key -ValueName $ValueName -Type $Type -Value $Value | Out-Null
        Write-Host "    set   $ValueName = $Value"
    }
}

function Set-HalfDisabled {
    param($Gpo, [ValidateSet('UserSettingsDisabled','ComputerSettingsDisabled')][string]$Status)
    if ($PSCmdlet.ShouldProcess($Gpo.DisplayName, "GPO Status: $Status")) {
        $Gpo.GpoStatus = $Status
        Write-Host "    status $Status"
    }
}

function Add-LinkOnce {
    param($Gpo, [string]$Target)
    $existing = (Get-GPInheritance -Target $Target).GpoLinks | Where-Object DisplayName -eq $Gpo.DisplayName
    if ($existing) {
        Write-Host "    linked already" -ForegroundColor DarkGray
        return
    }
    if ($PSCmdlet.ShouldProcess("$($Gpo.DisplayName) -> $Target", 'Link GPO')) {
        New-GPLink -Guid $Gpo.Id -Target $Target -LinkEnabled Yes | Out-Null
        $script:linked++
        Write-Host "    link  -> Wayne Enterprises" -ForegroundColor Green
    }
}

# --- Workstations OU --------------------------------------------------------------------------
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$workstOU'" -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($workstOU, 'Create OU')) {
        # Protection off to match the rest of the lab (it gets rebuilt). Leave it on at work.
        New-ADOrganizationalUnit -Name 'Workstations' -Path $companyOU -ProtectedFromAccidentalDeletion $false
        Write-Host "OU created: Workstations`n" -ForegroundColor Green
    }
}

# --- 1. WE-C-USB-Block ------------------------------------------------------------------------
Write-Host "WE-C-USB-Block"
$usb = Get-OrNewGpo -Name 'WE-C-USB-Block' -Comment 'All removable storage denied. Computer settings only. Gotham AD Masterclass EP2.'
if ($usb) {
    # Computer Configuration > Administrative Templates > System > Removable Storage Access >
    # All Removable Storage classes: Deny all access
    Set-Policy $usb 'HKLM\Software\Policies\Microsoft\Windows\RemovableStorageDevices' 'Deny_All' DWord 1
    Set-HalfDisabled $usb UserSettingsDisabled
    Add-LinkOnce $usb $companyOU
}

# --- 2. WE-C-Workstation-Baseline -------------------------------------------------------------
Write-Host "`nWE-C-Workstation-Baseline"
$base = Get-OrNewGpo -Name 'WE-C-Workstation-Baseline' -Comment 'Logon banner, 15-min inactivity lock, lock-screen image. Computer settings only. Gotham AD Masterclass EP2.'
if ($base) {
    # Security Options > Interactive logon: Message title / Message text for users attempting to log on
    Set-Policy $base 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticecaption' String $BannerTitle
    Set-Policy $base 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticetext'    String $BannerText
    # Security Options > Interactive logon: Machine inactivity limit
    Set-Policy $base 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs' DWord $InactivitySeconds
    # Administrative Templates > Control Panel > Personalization >
    # Force a specific default lock screen and logon image (Enterprise / Education / Server only)
    Set-Policy $base 'HKLM\Software\Policies\Microsoft\Windows\Personalization' 'LockScreenImage' String $lockscreen
    Set-HalfDisabled $base UserSettingsDisabled
    Add-LinkOnce $base $companyOU
}

# --- 3. WE-U-Desktop-Branding -----------------------------------------------------------------
Write-Host "`nWE-U-Desktop-Branding"
$brand = Get-OrNewGpo -Name 'WE-U-Desktop-Branding' -Comment 'Wayne Enterprises wallpaper. User settings only. Gotham AD Masterclass EP2.'
if ($brand) {
    # User Configuration > Administrative Templates > Desktop > Desktop > Desktop Wallpaper
    # WallpaperStyle 4 = Fill
    Set-Policy $brand 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'Wallpaper'      String $wallpaper
    Set-Policy $brand 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'WallpaperStyle' String '4'
    Set-HalfDisabled $brand ComputerSettingsDisabled
    Add-LinkOnce $brand $companyOU
}

# --- Credits ----------------------------------------------------------------------------------
Write-Host "`nGPOs created: $created | Links added: $linked" -ForegroundColor Cyan
Write-Host "Next: move your PCs into Workstations, and point new ones there with:" -ForegroundColor Cyan
Write-Host "  redircmp `"$workstOU`"" -ForegroundColor Cyan
Write-Host "Then back them up:  Backup-GPO -All -Path C:\GPOBackups" -ForegroundColor Cyan
