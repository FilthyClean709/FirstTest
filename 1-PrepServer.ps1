<#
.SYNOPSIS
    Step 1 of 3 — Prepare a fresh Windows Server 2025 install to become a domain controller.

.DESCRIPTION
    - Renames the computer
    - Sets timezone and High Performance power plan
    - Enables Remote Desktop + firewall rule
    - Renames the network adapter and applies a static IP / DNS
    - Installs the AD DS and DNS server roles with management tools
    - Prompts for reboot (or use -NoReboot to skip)

.PARAMETER NoReboot
    Suppress the reboot prompt at the end. You must reboot manually before running 2-PromoteDC.ps1.

.PARAMETER DryRun
    Print what would be done without making any changes.

.NOTES
    Author : <your name>
    Date   : 2026-04-20
    Run As : Administrator
    Prereq : Fresh Windows Server 2025 install; config.psd1 in the same folder.
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NoReboot,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$scriptDir  = $PSScriptRoot
$logDir     = Join-Path $scriptDir 'Logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$transcript = Join-Path $logDir ("PrepServer_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $transcript -Append

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step  { param($msg) Write-Host "`n[STEP] $msg" -ForegroundColor Cyan   }
function Write-OK    { param($msg) Write-Host "  [OK] $msg"   -ForegroundColor Green  }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "  [ERR] $msg"  -ForegroundColor Red    }

function Assert-Config {
    param([hashtable]$Cfg, [string[]]$Keys)
    foreach ($k in $Keys) {
        if (-not $Cfg.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($Cfg[$k])) {
            throw "config.psd1 is missing required value: '$k'"
        }
    }
}

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
Write-Step 'Loading configuration'
$cfgPath = Join-Path $scriptDir 'config.psd1'
if (-not (Test-Path $cfgPath)) { throw "config.psd1 not found at: $cfgPath" }

$cfg = Import-PowerShellDataFile -Path $cfgPath

$required = @('ComputerName','Timezone','AdapterName','IPAddress','PrefixLength',
              'DefaultGateway','PrimaryDNS','SecondaryDNS')
Assert-Config -Cfg $cfg -Keys $required

if ($DryRun) { Write-Warn 'DRY RUN — no changes will be made.' }
Write-OK "Config loaded from $cfgPath"

# ---------------------------------------------------------------------------
# 1. Rename computer
# ---------------------------------------------------------------------------
Write-Step "Rename computer to '$($cfg.ComputerName)'"
$currentName = $env:COMPUTERNAME
if ($currentName -eq $cfg.ComputerName) {
    Write-OK "Computer is already named '$($cfg.ComputerName)' — skipping."
} else {
    try {
        if (-not $DryRun) {
            Rename-Computer -NewName $cfg.ComputerName -Force
        }
        Write-OK "Renamed '$currentName' -> '$($cfg.ComputerName)' (takes effect after reboot)."
    } catch {
        Write-Fail "Failed to rename computer: $_"
        throw
    }
}

# ---------------------------------------------------------------------------
# 2. Timezone
# ---------------------------------------------------------------------------
Write-Step "Set timezone to '$($cfg.Timezone)'"
try {
    $current = (Get-TimeZone).Id
    if ($current -eq $cfg.Timezone) {
        Write-OK "Timezone already set to '$($cfg.Timezone)' — skipping."
    } else {
        if (-not $DryRun) { Set-TimeZone -Id $cfg.Timezone }
        Write-OK "Timezone set to '$($cfg.Timezone)'."
    }
} catch {
    Write-Fail "Failed to set timezone: $_"
    throw
}

# ---------------------------------------------------------------------------
# 3. High Performance power plan
# ---------------------------------------------------------------------------
Write-Step 'Set High Performance power plan'
try {
    $hp = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerPlan |
          Where-Object { $_.ElementName -eq 'High Performance' }
    if ($hp) {
        if ($hp.IsActive) {
            Write-OK 'High Performance plan already active — skipping.'
        } else {
            if (-not $DryRun) {
                $guid = ($hp.InstanceID -split '\\')[1] -replace '[{}]',''
                powercfg /setactive $guid | Out-Null
            }
            Write-OK 'High Performance power plan activated.'
        }
    } else {
        Write-Warn 'High Performance plan not found (may not be available in a VM).'
    }
} catch {
    Write-Warn "Could not set power plan (non-fatal): $_"
}

# ---------------------------------------------------------------------------
# 4. Enable Remote Desktop
# ---------------------------------------------------------------------------
Write-Step 'Enable Remote Desktop'
try {
    $rdpKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    $current = (Get-ItemProperty -Path $rdpKey -Name fDenyTSConnections).fDenyTSConnections
    if ($current -eq 0) {
        Write-OK 'Remote Desktop already enabled — skipping.'
    } else {
        if (-not $DryRun) {
            Set-ItemProperty -Path $rdpKey -Name fDenyTSConnections -Value 0
            Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        }
        Write-OK 'Remote Desktop enabled and firewall rule activated.'
    }
} catch {
    Write-Fail "Failed to enable Remote Desktop: $_"
    throw
}

# ---------------------------------------------------------------------------
# 5. Network adapter — rename + static IP
# ---------------------------------------------------------------------------
Write-Step "Configure network adapter '$($cfg.AdapterName)'"
try {
    # Locate the adapter — try by target name first, fall back to first physical adapter
    $adapter = Get-NetAdapter | Where-Object { $_.Name -eq $cfg.AdapterName } | Select-Object -First 1
    if (-not $adapter) {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } |
                   Select-Object -First 1
        if (-not $adapter) { $adapter = Get-NetAdapter | Select-Object -First 1 }
        if (-not $adapter) { throw 'No network adapter found.' }

        Write-Warn "Adapter '$($cfg.AdapterName)' not found — using '$($adapter.Name)'. Renaming it."
        if (-not $DryRun) { Rename-NetAdapter -Name $adapter.Name -NewName $cfg.AdapterName }
        Write-OK "Adapter renamed to '$($cfg.AdapterName)'."
        $adapter = Get-NetAdapter -Name $cfg.AdapterName
    } else {
        Write-OK "Adapter '$($cfg.AdapterName)' found."
    }

    # Remove existing IP configuration
    if (-not $DryRun) {
        $existingIP = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($existingIP) {
            if ($existingIP.IPAddress -eq $cfg.IPAddress -and $existingIP.PrefixLength -eq $cfg.PrefixLength) {
                Write-OK "Static IP $($cfg.IPAddress)/$($cfg.PrefixLength) already set — skipping IP config."
            } else {
                Remove-NetIPAddress    -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                Remove-NetRoute        -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                                 -IPAddress      $cfg.IPAddress `
                                 -PrefixLength   $cfg.PrefixLength `
                                 -DefaultGateway $cfg.DefaultGateway | Out-Null
                Write-OK "Static IP set: $($cfg.IPAddress)/$($cfg.PrefixLength) GW $($cfg.DefaultGateway)"
            }
        } else {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex `
                             -IPAddress      $cfg.IPAddress `
                             -PrefixLength   $cfg.PrefixLength `
                             -DefaultGateway $cfg.DefaultGateway | Out-Null
            Write-OK "Static IP set: $($cfg.IPAddress)/$($cfg.PrefixLength) GW $($cfg.DefaultGateway)"
        }

        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
            -ServerAddresses @($cfg.PrimaryDNS, $cfg.SecondaryDNS)
        Write-OK "DNS servers set: $($cfg.PrimaryDNS), $($cfg.SecondaryDNS)"
    } else {
        Write-OK "[DryRun] Would set IP $($cfg.IPAddress)/$($cfg.PrefixLength), GW $($cfg.DefaultGateway), DNS $($cfg.PrimaryDNS)/$($cfg.SecondaryDNS)"
    }
} catch {
    Write-Fail "Network configuration failed: $_"
    throw
}

# ---------------------------------------------------------------------------
# 6. Install AD DS + DNS roles
# ---------------------------------------------------------------------------
Write-Step 'Install AD DS and DNS Server roles'
try {
    $features  = @('AD-Domain-Services', 'DNS')
    $installed = Get-WindowsFeature -Name $features | Where-Object { $_.Installed }
    $missing   = $features | Where-Object { $_ -notin $installed.Name }

    if ($missing.Count -eq 0) {
        Write-OK 'AD DS and DNS roles already installed — skipping.'
    } else {
        Write-OK "Installing features: $($missing -join ', ')"
        if (-not $DryRun) {
            $result = Install-WindowsFeature -Name $features -IncludeManagementTools -IncludeAllSubFeature
            if ($result.Success) {
                Write-OK 'Roles installed successfully.'
                if ($result.RestartNeeded -eq 'Yes') {
                    Write-Warn 'Role installation flagged a restart — a reboot is required before promotion.'
                }
            } else {
                throw 'Install-WindowsFeature reported failure.'
            }
        } else {
            Write-OK "[DryRun] Would install: $($missing -join ', ')"
        }
    }
} catch {
    Write-Fail "Role installation failed: $_"
    throw
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host " Step 1 complete." -ForegroundColor Cyan
Write-Host " Next: reboot, then run  2-PromoteDC.ps1" -ForegroundColor Cyan
Write-Host "================================================`n" -ForegroundColor Cyan

Stop-Transcript

if (-not $NoReboot -and -not $DryRun) {
    $answer = Read-Host 'Reboot now? (Y/N)'
    if ($answer -match '^[Yy]') {
        Restart-Computer -Force
    } else {
        Write-Warn 'Reboot skipped. Remember to reboot before running 2-PromoteDC.ps1.'
    }
} elseif ($DryRun) {
    Write-Warn 'DryRun complete — no changes were made, no reboot initiated.'
} else {
    Write-Warn 'NoReboot specified — remember to reboot before running 2-PromoteDC.ps1.'
}
