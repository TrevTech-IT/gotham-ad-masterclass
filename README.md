# gotham-ad-masterclass
Free scripts and commands from the Gotham AD Masterclass on TrevTech-IT. Build Active Directory as Wayne Enterprises.

## What's in here

| File | What it does |
|---|---|
| `EP00-domain-controller-commands.md` | Every command from Episode 0 (network proof, promotion at the 2025 level, the DNS break and fix, dcdiag), in order, one section at a time. |
| `New-GothamUsers.ps1` | Builds the OU structure and all the accounts, with full detail (title, department, company, office, phone, employee ID, email, manager). Supports `-WhatIf`. |
| `New-GothamGroups.ps1` | Builds the security groups, nests them the AGDLP way, and adds everyone to their groups. Supports `-WhatIf`. Run it after the users script. |
| `Invoke-GothamLeaver.ps1` | Offboards a leaver: disable, strip groups, clear manager, stamp the reason, move to Former Employees. Refuses admin accounts. Supports `-WhatIf` and the pipeline. |
| `gotham-roster.csv` | 41 accounts: 26 staff, 5 former employees, 2 contractors, 2 service accounts, 6 admin accounts. |
| `gotham-groups.csv` | 23 groups: 9 role groups, 11 resource groups, 3 admin tier groups. |

## What it builds

```
<your domain>
├── Wayne Enterprises
│   ├── Executive          Bruce Wayne, Lucius Fox, Harvey Dent, ...
│   ├── R&D                Dick Grayson, Barbara Gordon, Tim Drake, ...
│   ├── Applied Sciences   Leslie Thompkins, Luke Fox, ...
│   ├── Security           Kate Kane, Renee Montoya, ...
│   ├── IT                 Jim Gordon (helpdesk lead), Harper Row, ...
│   └── Operations         Julia Pennyworth, ...
├── Former Employees       Nygma, Fries, Isley, Karlo, Sionis (all disabled)
├── Contractors            Oswald Cobblepot (expires in 90 days), the Joker (disabled)
├── Service Accounts       svc-alfred, svc-oracle
├── Groups
│   ├── Role Groups        GG-  (who you are)
│   └── Resource Groups    DL-  (what you can touch)
└── Admin                  only with -IncludeAdminTier
    ├── Tier 0             bwayne-adm, batsignal (break glass), GG-Tier0-Admins
    ├── Tier 1             lfox-adm, hrow-adm, GG-Tier1-ServerAdmins
    └── Tier 2             jgordon-adm, callen-adm, GG-Tier2-Helpdesk
```

Why former staff and contractors sit **outside** Wayne Enterprises: anything you aim at current staff (Group Policy, helpdesk delegation) is aimed at the Wayne Enterprises OU. Put leavers under it and they get those policies too. Put them next to it and they don't.

## Account types

The `AccountType` column decides how each account behaves:

| Type | Behaviour |
|---|---|
| `User` | Enabled, must change password at first logon, gets an email address |
| `Former` | Always created disabled, whatever the `Enabled` column says |
| `Contractor` | `Enabled` column decides. `ExpiresInDays` sets an expiry so it switches itself off |
| `Service` | Password never expires, account can't change it. No email |
| `Admin` | Tiered `-adm` account, marked "sensitive and cannot be delegated". No email. Only with `-IncludeAdminTier` |
| `BreakGlass` | Emergency account. Password never expires. Only with `-IncludeAdminTier` |

## Requirements

- A domain controller (built for Windows Server 2025, works on 2016+), or a machine with RSAT and the `ActiveDirectory` module
- Windows PowerShell 5.1 or PowerShell 7+
- Rights to create OUs, users and groups (Domain Admin in a lab)

## Quick start

```powershell
# 1. Dry run. See every OU and account it WOULD create. Touches nothing.
.\New-GothamUsers.ps1 -WhatIf

# 2. Build it. You'll be asked for a starting password.
.\New-GothamUsers.ps1

# 3. Groups and memberships.
.\New-GothamGroups.ps1

# Later in the series: add the admin tier on top of an existing build.
.\New-GothamUsers.ps1  -IncludeAdminTier
.\New-GothamGroups.ps1 -IncludeAdminTier
```

Both build scripts skip anything that already exists, so running them again is safe. Re-runs never change existing accounts, including their managers, so promotions and moves you've made since survive. The groups script never adds a **disabled** account to a group, so a leaver can't sneak back in through an out-of-date CSV.

```powershell
# Someone's left:
.\Invoke-GothamLeaver.ps1 -Identity tdrake -Reason "Resigned" -WhatIf
.\Invoke-GothamLeaver.ps1 -Identity tdrake -Reason "Resigned"
```

## Following the series

| Episode | Run |
|---|---|
| EP0: the domain controller | `EP00-domain-controller-commands.md`, section by section |
| EP1: the build | `New-GothamUsers.ps1`, then `Invoke-GothamLeaver.ps1` for the leaver |
| Groups & permissions | `New-GothamGroups.ps1` |
| Tiered admin | both scripts with `-IncludeAdminTier` |

## Using it in your own domain

No edits needed. The CSVs are written for `gotham.lab`, but both scripts swap the `DC=` part of every path for whatever domain you run them in.

Want your own cast? Keep the columns and swap the rows. Middle-earth, Springfield, the Nostromo. The scripts don't judge.

## Lab shortcuts to know about

- OUs are created with accidental-deletion protection **off**, because labs get rebuilt. Production wants it on.
- `svc-alfred` is a classic never-expires service account, so the series can talk about why that's a problem. In production, use a group Managed Service Account (gMSA).
- No passwords are stored anywhere. The users script prompts for a SecureString at runtime.

