# Windows Server 2025 — Lab Domain Controller Setup

A set of PowerShell scripts that take a fresh Server 2025 install from bare metal to a fully configured AD DS forest root domain controller.

---

## Prerequisites

| Requirement | Detail |
|---|---|
| OS | Windows Server 2025 (Desktop Experience or Core) |
| Privileges | All scripts must be run as **Administrator** |
| PowerShell | 5.1 or later (built into Server 2025) |
| Network | One connected NIC; internet access recommended for Windows Update before starting |
| Execution Policy | `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` |

---

## Files

| File | Purpose |
|---|---|
| `config.psd1` | All environment-specific settings — **edit this first** |
| `Helpers.ps1` | Shared functions dot-sourced by all scripts — do not run directly |
| `1-PrepServer.ps1` | Rename, network config, role installation |
| `2-PromoteDC.ps1` | AD DS forest promotion |
| `3-PostConfig.ps1` | DNS, NTP, Recycle Bin, OUs, groups |
| `Logs\` | Transcripts and summary reports (auto-created) |

---

## Run Order

```
1.  Edit config.psd1
2.  Run  1-PrepServer.ps1   →  reboot when prompted
3.  Run  2-PromoteDC.ps1    →  server auto-reboots after promotion
4.  Run  3-PostConfig.ps1
```

Copy the entire folder to the server (e.g. `C:\DCSetup\`) before starting.

```powershell
# From an elevated PowerShell prompt in C:\DCSetup\

.\1-PrepServer.ps1
# ... reboot ...

.\2-PromoteDC.ps1
# ... server reboots automatically ...

.\3-PostConfig.ps1
```

Each script creates a timestamped transcript under `.\Logs\`.  
`3-PostConfig.ps1` also writes a human-readable summary: `Logs\PostConfig_Summary_<timestamp>.txt`.

---

## Editing config.psd1

Open `config.psd1` in Notepad or VS Code and change every value marked below.

### Values you must change

| Setting | Default | Why you need to change it |
|---|---|---|
| `ComputerName` | `LAB-DC01` | Must be unique on your network |
| `IPAddress` | `192.168.10.10` | Must match your lab subnet |
| `PrefixLength` | `24` | Match your subnet mask |
| `DefaultGateway` | `192.168.10.1` | Your router/hypervisor gateway |
| `PrimaryDNS` | `192.168.10.1` | Pre-promotion upstream DNS (swap to `127.0.0.1` handled automatically by script 3) |
| `SecondaryDNS` | `8.8.8.8` | Leave as-is or use your preferred resolver |
| `DomainFQDN` | `lab.local` | Your domain name — avoid `.local` in production |
| `NetBIOSName` | `LAB` | 15 chars max, no spaces |

### Values you may leave as defaults

| Setting | Default | Notes |
|---|---|---|
| `Timezone` | `Eastern Standard Time` | Run `Get-TimeZone -ListAvailable` for valid IDs |
| `AdapterName` | `Ethernet` | Run `Get-NetAdapter` to verify the name on your NIC |
| `ForestLevel` / `DomainLevel` | `WinThreshold` | 2016/2019/2022-level; change to `Windows2025Forest` / `Windows2025Domain` for Server 2025 native features |
| `NTDSPath` / `LogPath` / `SysvolPath` | `C:\Windows\...` | Move to a dedicated volume on production |
| `DNSForwarders` | `8.8.8.8`, `8.8.4.4` | Replace with your ISP or preferred public DNS |
| `BaselineOUs` | See file | Add or remove OU names freely |
| `BaselineGroups` | See file | Add or remove group definitions freely |

---

## DryRun / Preview Mode

Scripts 1 and 3 support `-DryRun` to print planned actions without making changes:

```powershell
.\1-PrepServer.ps1 -DryRun
.\3-PostConfig.ps1 -DryRun
```

Script 1 also has `-NoReboot` to skip the reboot prompt:

```powershell
.\1-PrepServer.ps1 -NoReboot
```

---

## Recovery

### Script 1 fails
The script is idempotent for most steps. Correct the problem and re-run. If only the role install failed, run:
```powershell
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
```
Then reboot and proceed.

### Script 2 fails mid-promotion
Check `Logs\PromoteDC_*.log` and the Directory Service event log (`eventvwr.msc`).  
If the forest was not created, fix the error and re-run `2-PromoteDC.ps1`.  
If the forest *was* partially created, the safest recovery is to rebuild the VM and start over.

### Script 3 fails partway through
Script 3 is idempotent — it skips objects that already exist. Simply correct the error and re-run.

### Roll back a domain
There is no supported in-place rollback of an AD DS promotion. For lab use, snapshot your VM **before** running `2-PromoteDC.ps1` and revert if needed.

---

## Tips for Hyper-V / VMware lab use

- Take a VM snapshot after script 1 completes (pre-promotion) and another after script 3.
- The domain name `lab.local` is fine for an isolated lab. For a lab that interacts with the internet or Azure AD, use a subdomain of a real domain you own (e.g. `ad.yourdomain.com`).
- Assign at least 2 vCPUs and 2 GB RAM for the DC; 4 GB is comfortable.
