<#
.SYNOPSIS
    Offboards a leaver properly: disable, strip groups, clear manager, stamp the
    reason, and move them to Former Employees. Disabled, not deleted.

.DESCRIPTION
    Companion script for the TrevTech-IT "Gotham AD Masterclass" series.

    What it does to each account, in order:
      1. Disables it
      2. Removes it from every group it's a direct member of (Domain Users stays -
         that's the primary group, and Windows won't let you remove it anyway)
      3. Clears the manager, so the leaver drops off the org chart
      4. Stamps the Description: date, reason, old title/department, groups removed
      5. Moves it to the Former Employees OU, outside every policy and delegation
         aimed at current staff

    Why not delete? Because the day after someone leaves, somebody always asks what
    they had access to. A disabled account still answers that question. A deleted
    one doesn't.

    Safety rails:
      - Refuses to touch anyone in Domain Admins, Enterprise Admins, Schema Admins or
        Administrators (directly or through nested groups). Offboarding an admin is a
        deliberate job, not a script run.
      - Skips anyone who's already disabled and sitting in Former Employees.
      - Full -WhatIf support.

.PARAMETER Identity
    SamAccountName of the leaver. Accepts pipeline input, so you can offboard a list.

.PARAMETER Reason
    Why they left. Goes into the Description, so the next person to look knows.

.PARAMETER TargetOU
    Where leavers go. Defaults to OU=Former Employees at the root of your domain.

.EXAMPLE
    .\Invoke-GothamLeaver.ps1 -Identity tdrake -Reason 'Resigned' -WhatIf

    Dry run. Shows everything it would do to Tim Drake's account.

.EXAMPLE
    .\Invoke-GothamLeaver.ps1 -Identity tdrake -Reason 'Resigned'

.EXAMPLE
    'jtodd','sbrown' | .\Invoke-GothamLeaver.ps1 -Reason 'Contract ended'

.NOTES
    Author  : Trev - TrevTech-IT | trevtech.blog
    Built for: Windows Server 2025 (works on 2016+), Windows PowerShell 5.1 / PowerShell 7, ActiveDirectory module

    Production extras worth adding for real offboarding: reset the password to
    something random, revoke sessions and tokens in Entra ID if you're hybrid, and
    hand their files and mailbox to their manager. This script covers the AD side.

    I broke it. Fixed it.
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('SamAccountName')]
    [string[]]$Identity,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reason,

    [Parameter()]
    [string]$TargetOU
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $domainDN = (Get-ADDomain).DistinguishedName
    if (-not $TargetOU) { $TargetOU = "OU=Former Employees,$domainDN" }

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$TargetOU'")) {
        throw "Target OU '$TargetOU' doesn't exist. Build it first (New-GothamUsers.ps1 does)."
    }

    # Everyone in these groups - directly or nested - is off limits.
    $protectedDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($groupName in 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators') {
        $group = Get-ADGroup -Filter "Name -eq '$groupName'"
        if ($group) {
            foreach ($m in @(Get-ADGroupMember -Identity $group -Recursive)) {
                [void]$protectedDNs.Add($m.DistinguishedName)
            }
        }
    }

    $done = 0
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
}

process {
    foreach ($sam in $Identity) {
        $user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties MemberOf, Title, Department, Enabled, Description
        if (-not $user) {
            Write-Warning "No account called '$sam' - skipping."
            continue
        }

        if ($protectedDNs.Contains($user.DistinguishedName)) {
            Write-Warning "$sam holds admin rights (directly or through a nested group). Not touching it - offboard admins by hand, on purpose."
            continue
        }

        $alreadyGone = (-not $user.Enabled) -and ($user.DistinguishedName -like "*,$TargetOU")
        if ($alreadyGone) {
            Write-Warning "$sam is already disabled and in Former Employees - nothing to do."
            continue
        }

        Write-Host "  Offboarding $($user.Name) ($sam)" -ForegroundColor Cyan

        # 1. Disable
        if ($PSCmdlet.ShouldProcess($sam, 'Disable account')) {
            Disable-ADAccount -Identity $user
            Write-Host '    Disabled'
        }

        # 2. Strip groups. Record the names first - they go in the description.
        $groupNames = @()
        foreach ($groupDN in @($user.MemberOf)) {
            $group = Get-ADGroup -Identity $groupDN
            $groupNames += $group.Name
            if ($PSCmdlet.ShouldProcess($sam, "Remove from $($group.Name)")) {
                Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false
                Write-Host "    Removed from $($group.Name)"
            }
        }

        # 3 + 4. Clear the manager and stamp the reason, in one write.
        $was = @($user.Title, $user.Department) | Where-Object { $_ }
        $note = "Left $stamp - $Reason."
        if ($was) { $note += " Was: $($was -join ', ')." }
        if ($groupNames) { $note += " Groups removed: $($groupNames -join ', ')." }

        if ($PSCmdlet.ShouldProcess($sam, "Clear manager, set description '$note'")) {
            Set-ADUser -Identity $user -Clear manager -Description $note
            Write-Host "    Description: $note"
        }

        # 5. Move last - the DN changes once it moves.
        if ($PSCmdlet.ShouldProcess($sam, "Move to $TargetOU")) {
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $TargetOU
            Write-Host '    Moved to Former Employees'
            $done++
        }
    }
}

end {
    Write-Host ''
    Write-Host "  Leavers processed: $done. Disabled, not deleted."
}
