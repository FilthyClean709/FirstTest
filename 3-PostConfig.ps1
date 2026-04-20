<#
.SYNOPSIS
    Step 3 of 3 — Post-promotion configuration for the new domain controller.

.DESCRIPTION
    - Verifies AD DS, DNS, and Netlogon services are running
    - Creates a DNS reverse lookup zone
    - Configures DNS forwarders
    - Configures the PDC emulator as the authoritative NTP source
    - Enables the AD Recycle Bin
    - Creates baseline OUs and security groups from config.psd1
    - Writes a summary report to .\Logs\

.PARAMETER DryRun
    Show what would be done without making changes.

.NOTES
    Author : <your name>
    Date   : 2026-04-20
    Run As : Administrator (Domain Admin)
    Prereq : 2-PromoteDC.ps1 completed and server rebooted; AD DS fully initialised.
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
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
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$transcript = Join-Path $logDir "PostConfig_$timestamp.log"
$report     = Join-Path $logDir "PostConfig_Summary_$timestamp.txt"
Start-Transcript -Path $transcript -Append

$summaryLines = [System.Collections.Generic.List[string]]::new()
function Add-Summary { param($line) $summaryLines.Add($line) }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step  { param($msg) Write-Host "`n[STEP] $msg" -ForegroundColor Cyan   }
function Write-OK    { param($msg) Write-Host "  [OK] $msg"   -ForegroundColor Green  ; Add-Summary "  OK   : $msg" }
function Write-Warn  { param($msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow ; Add-Summary "  WARN : $msg" }
function Write-Fail  { param($msg) Write-Host "  [ERR] $msg"  -ForegroundColor Red    ; Add-Summary "  ERR  : $msg" }

function Assert-Config {
    param([hashtable]$Cfg, [string[]]$Keys)
    foreach ($k in $Keys) {
        if (-not $Cfg.ContainsKey($k) -or ($null -eq $Cfg[$k])) {
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
Assert-Config -Cfg $cfg -Keys @('DomainFQDN','IPAddress','DNSForwarders','BaselineOUs','BaselineGroups')
Write-OK "Config loaded from $cfgPath"

if ($DryRun) { Write-Warn 'DRY RUN — no changes will be made.' }

# ---------------------------------------------------------------------------
# 1. Verify core services
# ---------------------------------------------------------------------------
Write-Step 'Verifying AD DS, DNS, and Netlogon services'
$requiredServices = @('ADWS', 'DNS', 'Netlogon', 'kdc', 'W32Time')
$allOK = $true
foreach ($svc in $requiredServices) {
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.Status -eq 'Running') {
            Write-OK "Service '$svc' is Running."
        } else {
            Write-Warn "Service '$svc' is '$($s.Status)' — attempting to start."
            if (-not $DryRun) { Start-Service -Name $svc }
        }
    } catch {
        Write-Fail "Service '$svc' not found: $_"
        $allOK = $false
    }
}
if (-not $allOK) {
    Write-Warn 'One or more services could not be verified. Continuing, but investigate.'
}

# Give AD DS a moment to fully initialise if this is right after reboot
$adReady = $false
$retries = 0
while (-not $adReady -and $retries -lt 6) {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        $adReady = $true
    } catch {
        $retries++
        Write-Warn "AD DS not ready yet (attempt $retries/6) — waiting 10 seconds..."
        Start-Sleep -Seconds 10
    }
}
if (-not $adReady) { throw 'AD DS did not become available after 60 seconds. Check event logs.' }
Write-OK 'AD DS is responding.'

# ---------------------------------------------------------------------------
# 2. DNS reverse lookup zone
# ---------------------------------------------------------------------------
Write-Step 'Creating DNS reverse lookup zone'
try {
    # Derive the reverse zone name from the IP (assumes /24; adapt for other masks)
    $ipOctets   = $cfg.IPAddress -split '\.'
    $reverseZone = "$($ipOctets[2]).$($ipOctets[1]).$($ipOctets[0]).in-addr.arpa"

    $existing = Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue
    if ($existing) {
        Write-OK "Reverse zone '$reverseZone' already exists — skipping."
    } else {
        if (-not $DryRun) {
            Add-DnsServerPrimaryZone -NetworkId "$($ipOctets[0]).$($ipOctets[1]).$($ipOctets[2]).0/$($cfg.PrefixLength)" `
                                     -ReplicationScope 'Forest' -DynamicUpdate 'Secure'
        }
        Write-OK "Reverse zone '$reverseZone' created."
    }
} catch {
    Write-Fail "Failed to create reverse lookup zone: $_"
}

# ---------------------------------------------------------------------------
# 3. DNS forwarders
# ---------------------------------------------------------------------------
Write-Step 'Configuring DNS forwarders'
try {
    $desired = $cfg.DNSForwarders
    if (-not $DryRun) {
        # Remove existing forwarders then add desired set
        $current = (Get-DnsServerForwarder).IPAddress.IPAddressToString
        $diff = Compare-Object -ReferenceObject $desired -DifferenceObject ($current ?? @())
        if ($diff) {
            Set-DnsServerForwarder -IPAddress $desired
            Write-OK "DNS forwarders set to: $($desired -join ', ')"
        } else {
            Write-OK "DNS forwarders already set to: $($desired -join ', ') — skipping."
        }
    } else {
        Write-OK "[DryRun] Would set forwarders: $($desired -join ', ')"
    }
} catch {
    Write-Fail "Failed to configure DNS forwarders: $_"
}

# ---------------------------------------------------------------------------
# 4. Authoritative NTP (PDC emulator)
# ---------------------------------------------------------------------------
Write-Step 'Configuring PDC emulator as authoritative NTP source'
try {
    if (-not $DryRun) {
        # Point at upstream NTP servers and mark this DC as reliable
        w32tm /config /manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8" /syncfromflags:manual /reliable:YES /update | Out-Null
        Restart-Service W32Time -Force
        w32tm /resync /force | Out-Null
    }
    Write-OK 'PDC emulator NTP configured (time.windows.com, pool.ntp.org) and W32Time restarted.'
} catch {
    Write-Fail "Failed to configure NTP: $_"
}

# ---------------------------------------------------------------------------
# 5. AD Recycle Bin
# ---------------------------------------------------------------------------
Write-Step 'Enabling AD Recycle Bin'
try {
    $forest = (Get-ADForest).Name
    $rb = Get-ADOptionalFeature -Filter { Name -eq 'Recycle Bin Feature' } -ErrorAction Stop

    if ($rb.EnabledScopes.Count -gt 0) {
        Write-OK 'AD Recycle Bin is already enabled — skipping.'
    } else {
        if (-not $DryRun) {
            Enable-ADOptionalFeature 'Recycle Bin Feature' `
                -Scope ForestOrConfigurationSet `
                -Target $forest `
                -Confirm:$false
        }
        Write-OK 'AD Recycle Bin enabled.'
    }
} catch {
    Write-Fail "Failed to enable AD Recycle Bin: $_"
}

# ---------------------------------------------------------------------------
# 6. Baseline OUs
# ---------------------------------------------------------------------------
Write-Step 'Creating baseline Organisational Units'
try {
    $domain    = Get-ADDomain
    $domainDN  = $domain.DistinguishedName

    foreach ($ouName in $cfg.BaselineOUs) {
        $ouDN = "OU=$ouName,$domainDN"
        try {
            $null = Get-ADOrganizationalUnit -Identity $ouDN -ErrorAction Stop
            Write-OK "OU '$ouName' already exists — skipping."
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            if (-not $DryRun) {
                New-ADOrganizationalUnit -Name $ouName -Path $domainDN -ProtectedFromAccidentalDeletion $true
            }
            Write-OK "OU '$ouName' created."
        }
    }
} catch {
    Write-Fail "Failed creating OUs: $_"
}

# ---------------------------------------------------------------------------
# 7. Baseline Security Groups
# ---------------------------------------------------------------------------
Write-Step 'Creating baseline security groups'
try {
    $domain    = Get-ADDomain
    $domainDN  = $domain.DistinguishedName
    $groupsOU  = "OU=Groups,$domainDN"

    # Verify Groups OU exists (created in step above)
    try {
        $null = Get-ADOrganizationalUnit -Identity $groupsOU -ErrorAction Stop
    } catch {
        Write-Warn "OU=Groups not found — creating groups in domain root instead."
        $groupsOU = $domainDN
    }

    foreach ($grp in $cfg.BaselineGroups) {
        try {
            $null = Get-ADGroup -Identity $grp.Name -ErrorAction Stop
            Write-OK "Group '$($grp.Name)' already exists — skipping."
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            if (-not $DryRun) {
                New-ADGroup -Name          $grp.Name `
                            -SamAccountName $grp.Name `
                            -GroupScope    'Global' `
                            -GroupCategory 'Security' `
                            -Description   $grp.Description `
                            -Path          $groupsOU
            }
            Write-OK "Group '$($grp.Name)' created."
        }
    }
} catch {
    Write-Fail "Failed creating security groups: $_"
}

# ---------------------------------------------------------------------------
# 8. Post-promotion DNS fix — set loopback as primary DNS
# ---------------------------------------------------------------------------
Write-Step 'Setting primary DNS to 127.0.0.1 on the DC NIC'
try {
    $adapter = Get-NetAdapter -Name $cfg.AdapterName -ErrorAction Stop
    $current = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses
    $desired = @('127.0.0.1', $cfg.SecondaryDNS)

    if (($current -join ',') -eq ($desired -join ',')) {
        Write-OK 'DNS client already set to 127.0.0.1 — skipping.'
    } else {
        if (-not $DryRun) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $desired
        }
        Write-OK "DNS updated to: $($desired -join ', ')"
    }
} catch {
    Write-Warn "Could not update DNS client addresses (non-fatal): $_"
}

# ---------------------------------------------------------------------------
# Summary report
# ---------------------------------------------------------------------------
$reportContent = @"
PostConfig Summary Report
Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Domain    : $($cfg.DomainFQDN)
DC Name   : $env:COMPUTERNAME
DryRun    : $DryRun

Results:
$($summaryLines -join "`n")
"@

$reportContent | Out-File -FilePath $report -Encoding UTF8
Write-Host "`n================================================" -ForegroundColor Green
Write-Host " Post-configuration complete!" -ForegroundColor Green
Write-Host " Summary report: $report"      -ForegroundColor Green
Write-Host "================================================`n" -ForegroundColor Green

Stop-Transcript
