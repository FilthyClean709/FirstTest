<#
.SYNOPSIS
    Step 3 of 3 — Post-promotion configuration for the new domain controller.

.DESCRIPTION
    - Verifies AD DS, DNS, and Netlogon services are running
    - Creates a DNS reverse lookup zone derived from the configured IP and prefix length
    - Configures DNS forwarders
    - Configures the PDC emulator as the authoritative NTP source via w32tm
    - Enables the AD Recycle Bin
    - Creates baseline OUs and security groups from config.psd1
    - Sets loopback (127.0.0.1) as primary DNS on the DC NIC
    - Writes a summary report to .\Logs\

.PARAMETER DryRun
    Show what would be done without making any changes.

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
# Bootstrap helpers and config
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'Helpers.ps1')

$logDir     = New-LogDir -ScriptDir $PSScriptRoot
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$transcript = Join-Path $logDir "PostConfig_$timestamp.log"
$report     = Join-Path $logDir "PostConfig_Summary_$timestamp.txt"
Start-Transcript -Path $transcript -Append

$summaryLines = [System.Collections.Generic.List[string]]::new()
function Add-Summary { param($line) $summaryLines.Add($line) }

# Override helpers to also append to summary list
function Write-OK   { param([string]$msg) Write-Host "  [OK] $msg"   -ForegroundColor Green  ; Add-Summary "  OK   : $msg" }
function Write-Warn { param([string]$msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow ; Add-Summary "  WARN : $msg" }
function Write-Fail { param([string]$msg) Write-Host "  [ERR] $msg"  -ForegroundColor Red    ; Add-Summary "  ERR  : $msg" }

$cfgPath = Get-ConfigPath -ScriptDir $PSScriptRoot
Write-Step 'Loading configuration'
$cfg = Import-PowerShellDataFile -Path $cfgPath
Assert-Config -Cfg $cfg -Keys @(
    'DomainFQDN','IPAddress','PrefixLength','AdapterName','SecondaryDNS',
    'DNSForwarders','BaselineOUs','BaselineGroups'
)
Write-OK "Config loaded from $cfgPath"

if ($DryRun) { Write-Warn 'DRY RUN — no changes will be made.' }

# ---------------------------------------------------------------------------
# 1. Verify core services
# ---------------------------------------------------------------------------
Write-Step 'Verifying AD DS, DNS, and Netlogon services'
$allOK = $true
foreach ($svc in @('ADWS', 'DNS', 'Netlogon', 'kdc', 'W32Time')) {
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
if (-not $allOK) { Write-Warn 'One or more services could not be verified. Continuing — investigate.' }

# Wait for AD DS to become available (up to 60 s after reboot)
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

# Cache domain info used by multiple steps below
$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName

# ---------------------------------------------------------------------------
# 2. DNS reverse lookup zone
# ---------------------------------------------------------------------------
Write-Step 'Creating DNS reverse lookup zone'
try {
    $ipOctets = $cfg.IPAddress -split '\.'

    # Number of octets to include in the reverse zone name is determined by the
    # prefix length. Floor gives the right boundary for standard classes;
    # e.g. /24 -> 3 octets, /16 -> 2 octets, /8 -> 1 octet.
    $octetCount  = [Math]::Max(1, [Math]::Floor([int]$cfg.PrefixLength / 8))
    $networkPart = $ipOctets[0..($octetCount - 1)]
    $reverseZone = (($octetCount - 1)..0 | ForEach-Object { $networkPart[$_] }) -join '.'
    $reverseZone += '.in-addr.arpa'

    $existing = Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue
    if ($existing) {
        Write-OK "Reverse zone '$reverseZone' already exists — skipping."
    } else {
        if (-not $DryRun) {
            Add-DnsServerPrimaryZone `
                -NetworkId      "$($ipOctets[0..($octetCount-1)] -join '.').0/$($cfg.PrefixLength)" `
                -ReplicationScope 'Forest' `
                -DynamicUpdate  'Secure'
        }
        Write-OK "Reverse zone '$reverseZone' created$(if ($DryRun) { ' [DryRun]' })."
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
    if ($DryRun) {
        Write-OK "[DryRun] Would set forwarders: $($desired -join ', ')"
    } else {
        $currentFwdr = Get-DnsServerForwarder
        $currentIPs  = if ($null -ne $currentFwdr.IPAddress) {
                           $currentFwdr.IPAddress.IPAddressToString
                       } else { @() }

        $diff = Compare-Object -ReferenceObject $desired -DifferenceObject $currentIPs
        if ($diff) {
            Set-DnsServerForwarder -IPAddress $desired
            Write-OK "DNS forwarders set to: $($desired -join ', ')"
        } else {
            Write-OK "DNS forwarders already correct: $($desired -join ', ') — skipping."
        }
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
        w32tm /config /manualpeerlist:"time.windows.com,0x8 pool.ntp.org,0x8" `
              /syncfromflags:manual /reliable:YES /update | Out-Null
        Restart-Service W32Time -Force
        w32tm /resync /force | Out-Null
    }
    Write-OK "NTP configured (time.windows.com, pool.ntp.org)$(if ($DryRun) { ' [DryRun]' })."
} catch {
    Write-Fail "Failed to configure NTP: $_"
}

# ---------------------------------------------------------------------------
# 5. AD Recycle Bin
# ---------------------------------------------------------------------------
Write-Step 'Enabling AD Recycle Bin'
try {
    $forestName = (Get-ADForest).Name
    $rb = Get-ADOptionalFeature -Filter { Name -eq 'Recycle Bin Feature' } -ErrorAction Stop

    if ($rb.EnabledScopes.Count -gt 0) {
        Write-OK 'AD Recycle Bin is already enabled — skipping.'
    } else {
        if (-not $DryRun) {
            Enable-ADOptionalFeature 'Recycle Bin Feature' `
                -Scope ForestOrConfigurationSet `
                -Target $forestName `
                -Confirm:$false
        }
        Write-OK "AD Recycle Bin enabled$(if ($DryRun) { ' [DryRun]' })."
    }
} catch {
    Write-Fail "Failed to enable AD Recycle Bin: $_"
}

# ---------------------------------------------------------------------------
# 6. Baseline OUs
# ---------------------------------------------------------------------------
Write-Step 'Creating baseline Organisational Units'
try {
    foreach ($ouName in $cfg.BaselineOUs) {
        $ouDN = "OU=$ouName,$domainDN"
        try {
            $null = Get-ADOrganizationalUnit -Identity $ouDN -ErrorAction Stop
            Write-OK "OU '$ouName' already exists — skipping."
        } catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            if (-not $DryRun) {
                New-ADOrganizationalUnit -Name $ouName -Path $domainDN `
                                         -ProtectedFromAccidentalDeletion $true
                Write-OK "OU '$ouName' created."
            } else {
                Write-OK "[DryRun] Would create OU '$ouName'."
            }
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
    $groupsOU = "OU=Groups,$domainDN"
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
                New-ADGroup -Name           $grp.Name `
                            -SamAccountName $grp.Name `
                            -GroupScope     'Global' `
                            -GroupCategory  'Security' `
                            -Description    $grp.Description `
                            -Path           $groupsOU
                Write-OK "Group '$($grp.Name)' created."
            } else {
                Write-OK "[DryRun] Would create group '$($grp.Name)'."
            }
        }
    }
} catch {
    Write-Fail "Failed creating security groups: $_"
}

# ---------------------------------------------------------------------------
# 8. Set loopback as primary DNS on the DC NIC
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
        Write-OK "DNS updated to: $($desired -join ', ')$(if ($DryRun) { ' [DryRun]' })."
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
