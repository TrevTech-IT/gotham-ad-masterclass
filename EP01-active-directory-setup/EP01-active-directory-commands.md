# EP1: Every Command, In Order

**Gotham AD Masterclass · Episode 1: I Built Gotham City's Active Directory**

Every command from the video, in the order you see them. **Run them one section at a time, not as a script.** Section 7 deletes an account *on purpose*, and only works because section 1 turned on the Recycle Bin.

| Lab value | Used in this episode |
|---|---|
| Domain | `gotham.lab` · NetBIOS `GOTHAM` |
| Domain controller | `GOTHAM-DC01` (Windows Server 2025, from EP0) |
| Scripts | `New-GothamUsers.ps1` · `Invoke-GothamLeaver.ps1` · `gotham-roster.csv` (this folder) |

Different domain name in your lab? Swap `gotham.lab` and `GOTHAM`. The scripts read the domain automatically.

---

## 1. The org chart, and a safety net

Clicks, not commands:

- **Server Manager → Tools → Active Directory Users and Computers**
- Right-click `gotham.lab` → **New → Organizational Unit** → `Wayne Enterprises`
- Untick **Protect container from accidental deletion** *(lab only, because it gets rebuilt. Leave it ticked at work.)*

Turn on the AD Recycle Bin. **This is a one-way switch.** Once it's on, it can't be turned off.

```powershell
Enable-ADOptionalFeature -Identity "Recycle Bin Feature" -Scope ForestOrConfigurationSet -Target gotham.lab
```

## 2. Hire all of Gotham

Copy this folder to the DC (the video uses `C:\Setup Gotham\Scripts\`), then:

```powershell
cd "C:\Setup Gotham\Scripts"
.\New-GothamUsers.ps1 -WhatIf     # dry run: shows every change, touches nothing, no password prompt
.\New-GothamUsers.ps1             # the real run: asks for a starting password
```

Expected: `OUs built: 9 | Accounts created: 35 | Skipped: 0 | Manager links: 28` (9, because you built Wayne Enterprises by hand). Staff accounts must change the starting password at first logon.

## 3. Walk the building

Clicks:

- **ADUC:** a user → Properties → **Organization** tab (title, department, manager chain)
- **Server Manager → Tools → Active Directory Administrative Center** → expand **Windows PowerShell History** at the bottom. Every click shows the command it ran.

Who's a Domain Admin? (Should be the built-in Administrator only.)

```powershell
Get-ADGroupMember -Identity "Domain Admins"
```

## 4. Joiners, movers, leavers

**Joiner:** add a row to `gotham-roster.csv`, then re-run the same script. Existing accounts are skipped, not changed.

```powershell
.\New-GothamUsers.ps1
```

**Mover:**

```powershell
Set-ADUser -Identity dgrayson -Title "Lead Systems Engineer" -Manager lfox
```

**Leaver:** disables, removes groups, clears the manager, stamps the reason in the description, and moves the account to Former Employees. It refuses to touch admin accounts.

```powershell
.\Invoke-GothamLeaver.ps1 -Identity tdrake -Reason "Resigned" -WhatIf
.\Invoke-GothamLeaver.ps1 -Identity tdrake -Reason "Resigned"
```

## 5. Directory detective

Who reports to Lucius?

```powershell
Get-ADUser lfox -Properties directReports | Select-Object -ExpandProperty directReports
```

What expires in the next six months?

```powershell
Search-ADAccount -AccountExpiring -TimeSpan 180.00:00:00 -UsersOnly | Select-Object Name, AccountExpirationDate
```

What's disabled? (`krbtgt` is disabled by design. Leave it alone.)

```powershell
Search-ADAccount -AccountDisabled -UsersOnly | Select-Object Name, DistinguishedName
```

Who breaks the naming rule (first initial + surname)?

```powershell
Get-ADUser -Filter * | Where-Object {
  $_.GivenName -and $_.SamAccountName -notlike "svc-*" -and
  $_.SamAccountName -notlike "$($_.GivenName[0])$($_.Surname)*" }
```

## 6. Bad Friday: restore a deleted account

Deleted in ADUC by "accident". Find it, then bring it back with every attribute intact (same SID, groups, manager, title):

```powershell
Get-ADObject -Filter 'samAccountName -eq "dgrayson"' -IncludeDeletedObjects
Get-ADObject -Filter 'samAccountName -eq "dgrayson"' -IncludeDeletedObjects | Restore-ADObject
```

GUI alternative: **ADAC → gotham (local) → Deleted Objects** → right-click → **Restore**. Deleted objects are kept for 180 days by default.

## 7. Password rules

Check the defaults (lockout threshold 0 = never locks):

```powershell
Get-ADDefaultDomainPasswordPolicy
```

Set the domain rules (3 is for a quick demo; CIS says 5 or fewer, not 0):

```powershell
Set-ADDefaultDomainPasswordPolicy -Identity gotham.lab -LockoutThreshold 3 -LockoutDuration 00:15:00 -LockoutObservationWindow 00:15:00 -MinPasswordLength 14
Get-ADDefaultDomainPasswordPolicy
```

Fine-grained policy for service accounts. **It replaces the domain rules for those accounts, it doesn't add to them**, so spell out every setting you care about. It applies to users or global security groups, never OUs, and takes effect the next time the password is set.

```powershell
New-ADFineGrainedPasswordPolicy -Name "PSO-ServiceAccounts" -Precedence 10 -MinPasswordLength 25 -ComplexityEnabled $true -PasswordHistoryCount 24 -LockoutThreshold 3 -LockoutDuration 00:15:00 -LockoutObservationWindow 00:15:00
Add-ADFineGrainedPasswordPolicySubject -Identity "PSO-ServiceAccounts" -Subjects svc-alfred, svc-oracle

Get-ADUserResultantPasswordPolicy -Identity svc-alfred   # shows PSO-ServiceAccounts
Get-ADUserResultantPasswordPolicy -Identity bwayne       # returns nothing = domain rules apply
```

## 8. Keep the Joker out

From a command prompt, enter a wrong password three times, then the right one (refused, locked out):

```cmd
runas /user:GOTHAM\bwayne cmd
```

```powershell
Search-ADAccount -LockedOut | Select-Object Name, SamAccountName
Unlock-ADAccount -Identity bwayne
```


---

**Next:** EP2, Group Policy (coming soon) · Full series: https://www.youtube.com/watch?v=0T5iN290njQ&list=PLfmRIg23g1uw&pp=sAgC
