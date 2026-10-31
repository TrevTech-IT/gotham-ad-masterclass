# EP0: Every Command, In Order

**Gotham AD Masterclass Episode 0: I Built Gotham City's Domain Controller (Windows Server 2025)**

Video: [EP0 LINK] Write-up: https://trevtech.blog/gotham-domain-controller-server-2025

Every command from the video, in the order you see them. **Run them one section at a time, not as a script.** Step 6 breaks DNS *on purpose*.

| Lab value | Used in this episode |
|---|---|
| Network | UniFi VLAN 20  `192.168.20.0/24`  gateway `192.168.20.1`  UniFi DHCP off |
| Server | `GOTHAM-DC01`  `192.168.20.10`  Windows Server 2025 |
| Domain | `gotham.lab` NetBIOS `GOTHAM`  Win2025 functional level |

Different network or names in your lab? Swap the values. Everything else is the same.

---

## 1. Name and fixed IP

```powershell
# Rename BEFORE it becomes a domain controller. Reboots.
Rename-Computer -NewName GOTHAM-DC01 -Restart
```

```powershell
# Find your network adapter's name (it's usually "Ethernet", but check)
Get-NetAdapter

$nic = 'Ethernet'   # change if Get-NetAdapter showed something else

# Fixed IP on the Gotham network
New-NetIPAddress -InterfaceAlias $nic -IPAddress 192.168.20.10 -PrefixLength 24 -DefaultGateway 192.168.20.1

# DNS points at the router FOR NOW. The promotion changes it. Remember this.
Set-DnsClientServerAddress -InterfaceAlias $nic -ServerAddresses 192.168.20.1
```

## 2. Prove the network works

```powershell
# The internet: should say TcpTestSucceeded : True (Windows Update needs this)
Test-NetConnection www.microsoft.com -Port 443

# Something on your HOME network: should time out (the Gotham zone is blocking it)
Test-Connection 192.168.x.x -Count 2   # put your own desktop's IP here
```

## 3. Promote to a domain controller

```powershell
# 1. The Active Directory role, with the management tools
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools

# 2. A brand-new forest: gotham.lab, at the 2025 functional level, with DNS on the same server.
#    It asks for a Safe Mode (DSRM) password. Write it down somewhere that isn't this server.
#    Reboots on its own.
Install-ADDSForest -DomainName "gotham.lab" -DomainNetbiosName "GOTHAM" `
    -ForestMode Win2025 -DomainMode Win2025 -InstallDns
```

After the reboot, log on as `GOTHAM\Administrator`:

```powershell
# The domain exists, at the 2025 level
Get-ADDomain | Select-Object DNSRoot, DomainMode, PDCEmulator
(Get-ADForest).ForestMode

# The firewall check: NetworkCategory should be DomainAuthenticated, NOT Public
Get-NetConnectionProfile

# The DNS zones (the video shows these in DNS Manager): gotham.lab and _msdcs.gotham.lab
Get-DnsServerZone
```

## 4. Break it on purpose
**Lab only.** This is the classic home lab mistake, done deliberately so you recognise it.

```powershell
# Point the DC's DNS back at the router...
Set-DnsClientServerAddress -InterfaceAlias $nic -ServerAddresses 192.168.20.1
Clear-DnsClientCache

# ...and ask the question every machine in the domain asks: where's the domain controller?
Resolve-DnsName -Type SRV _ldap._tcp.dc._msdcs.gotham.lab   # fails. The router's never heard of gotham.lab

# The DNS health check
dcdiag /test:dns
```

## 5. Fix it

```powershell
# Domain controllers point at domain controllers for DNS: itself first, loopback second
Set-DnsClientServerAddress -InterfaceAlias $nic -ServerAddresses 192.168.20.10,127.0.0.1
Clear-DnsClientCache

Resolve-DnsName -Type SRV _ldap._tcp.dc._msdcs.gotham.lab   # GOTHAM-DC01 comes back
```

**Rule:** DCs point at DCs. Clients point at DCs. Never at the router.

## 6. The inspection

```powershell
# The full health check. Watch the connectivity, replication and DNS results.
# A fresh DC may show a warning or two from its first boot's event logs. Read them, don't panic.
dcdiag
```

**Then take a snapshot** (Proxmox: `gotham-ep00-end`). Episode 1 starts from here.

---

## Next: Episode 1

Thirty-five people move in. The org chart, the whole roster and the joiner/mover/leaver scripts are in this folder:

- `New-GothamUsers.ps1` + `gotham-roster.csv`
- `New-GothamGroups.ps1` + `gotham-groups.csv`
- `Invoke-GothamLeaver.ps1`

See `README.md`.
