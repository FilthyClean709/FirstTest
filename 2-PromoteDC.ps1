<#
.SYNOPSIS
    Step 2 of 3 — Promote the prepared server to an AD DS forest root domain controller.

.DESCRIPTION
    - Loads settings from config.psd1
    - Prompts for the DSRM (Directory Services Restore Mode) password interactively
    - Runs Install-ADDSForest
    - The server will reboot automatically upon successful promotion

.PARAMETER DryRun
    Validate configuration and display planned parameters without performing the promotion.

.NOTES
    Author : <your name>
    Date   : 2026-04-20
    Run As : Administrator
    Prereq : 1-PrepServer.ps1 completed and server rebooted; AD DS role installed.
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
$transcript = Join-Path $logDir ("PromoteDC_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
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

$required = @('DomainFQDN','NetBIOSName','ForestLevel','DomainLevel',
              'NTDSPath','LogPath','SysvolPath')
Assert-Config -Cfg $cfg -Keys $required

Write-OK "Config loaded from $cfgPath"

# ---------------------------------------------------------------------------
# Verify AD DS role is installed
# ---------------------------------------------------------------------------
Write-Step 'Verifying AD DS role is installed'
try {
    $feature = Get-WindowsFeature -Name AD-Domain-Services
    if (-not $feature.Installed) {
        throw 'AD-Domain-Services role is not installed. Run 1-PrepServer.ps1 first and reboot.'
    }
    Write-OK 'AD DS role is installed.'
} catch {
    Write-Fail $_
    Stop-Transcript
    exit 1
}

# ---------------------------------------------------------------------------
# Check if domain already exists
# ---------------------------------------------------------------------------
Write-Step "Checking whether domain '$($cfg.DomainFQDN)' already exists"
try {
    $null = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    Write-Warn "This server appears to already be a domain member. Promotion may be unnecessary."
    Write-Warn "If this is unexpected, verify the environment before continuing."
} catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
    Write-OK "Server is in a workgroup — promotion can proceed."
} catch {
    Write-OK "Server is not yet domain-joined — promotion can proceed."
}

# ---------------------------------------------------------------------------
# Prompt for DSRM password
# ---------------------------------------------------------------------------
Write-Step 'DSRM password'
Write-Host '  The Directory Services Restore Mode (DSRM) password is required.' -ForegroundColor Cyan
Write-Host '  It must be stored securely — you will need it to recover AD DS.' -ForegroundColor Yellow

$dsrmPassword = $null
$confirm      = $null
do {
    $dsrmPassword = Read-Host -Prompt '  Enter DSRM password'    -AsSecureString
    $confirm      = Read-Host -Prompt '  Confirm DSRM password'  -AsSecureString

    $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dsrmPassword))
    $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirm))

    if ($plain1 -ne $plain2) {
        Write-Warn 'Passwords do not match — please try again.'
        $dsrmPassword = $null
    } elseif ($plain1.Length -lt 8) {
        Write-Warn 'Password must be at least 8 characters — please try again.'
        $dsrmPassword = $null
    }

    [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode(
        [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($dsrmPassword ?? (ConvertTo-SecureString ' ' -AsPlainText -Force)))
} until ($dsrmPassword)

Write-OK 'DSRM password accepted.'

# ---------------------------------------------------------------------------
# Show promotion plan
# ---------------------------------------------------------------------------
Write-Step 'Promotion parameters'
Write-Host "  Domain FQDN      : $($cfg.DomainFQDN)"     -ForegroundColor Cyan
Write-Host "  NetBIOS Name     : $($cfg.NetBIOSName)"     -ForegroundColor Cyan
Write-Host "  Forest Level     : $($cfg.ForestLevel)"     -ForegroundColor Cyan
Write-Host "  Domain Level     : $($cfg.DomainLevel)"     -ForegroundColor Cyan
Write-Host "  NTDS Path        : $($cfg.NTDSPath)"        -ForegroundColor Cyan
Write-Host "  Log Path         : $($cfg.LogPath)"         -ForegroundColor Cyan
Write-Host "  SYSVOL Path      : $($cfg.SysvolPath)"      -ForegroundColor Cyan

if ($DryRun) {
    Write-Warn 'DRY RUN — Install-ADDSForest will NOT be called.'
    Stop-Transcript
    exit 0
}

# ---------------------------------------------------------------------------
# Promote
# ---------------------------------------------------------------------------
Write-Step "Promoting to forest root DC for '$($cfg.DomainFQDN)'"
Write-Warn 'The server will REBOOT automatically when promotion completes.'
$confirm2 = Read-Host 'Type YES to proceed with promotion'
if ($confirm2 -ne 'YES') {
    Write-Warn 'Promotion cancelled by user.'
    Stop-Transcript
    exit 0
}

try {
    $promoteParams = @{
        DomainName                    = $cfg.DomainFQDN
        DomainNetbiosName             = $cfg.NetBIOSName
        ForestMode                    = $cfg.ForestLevel
        DomainMode                    = $cfg.DomainLevel
        DatabasePath                  = $cfg.NTDSPath
        LogPath                       = $cfg.LogPath
        SysvolPath                    = $cfg.SysvolPath
        SafeModeAdministratorPassword = $dsrmPassword
        InstallDns                    = $true
        NoRebootOnCompletion          = $false
        Force                         = $true
    }

    Install-ADDSForest @promoteParams
    # Execution continues only if NoRebootOnCompletion were $true; in practice
    # the server reboots here, so the lines below are a safety net.
    Write-OK 'Install-ADDSForest returned — reboot should be imminent.'
} catch {
    Write-Fail "Promotion failed: $_"
    Stop-Transcript
    throw
}

Stop-Transcript
