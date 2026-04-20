<#
.SYNOPSIS
    Step 2 of 3 — Promote the prepared server to an AD DS forest root domain controller.

.DESCRIPTION
    - Loads settings from config.psd1
    - Prompts for the DSRM password interactively (skipped with -DryRun)
    - Runs Install-ADDSForest with parameters from config
    - The server auto-reboots upon successful promotion

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
# Bootstrap helpers and config
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'Helpers.ps1')

$logDir     = New-LogDir -ScriptDir $PSScriptRoot
$transcript = Join-Path $logDir ("PromoteDC_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $transcript -Append

$cfgPath = Get-ConfigPath -ScriptDir $PSScriptRoot
Write-Step 'Loading configuration'
$cfg = Import-PowerShellDataFile -Path $cfgPath
Assert-Config -Cfg $cfg -Keys @(
    'DomainFQDN','NetBIOSName','ForestLevel','DomainLevel',
    'NTDSPath','LogPath','SysvolPath'
)
Write-OK "Config loaded from $cfgPath"

# ---------------------------------------------------------------------------
# Verify AD DS role is installed
# ---------------------------------------------------------------------------
Write-Step 'Verifying AD DS role is installed'
try {
    if (-not (Get-WindowsFeature -Name AD-Domain-Services).Installed) {
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
Write-Step "Checking whether this server is already domain-joined"
try {
    $null = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    Write-Warn 'This server is already a domain member — promotion may be unnecessary.'
    Write-Warn 'Verify the environment before continuing.'
} catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
    Write-OK 'Server is in a workgroup — promotion can proceed.'
} catch {
    Write-OK 'Server is not domain-joined — promotion can proceed.'
}

# ---------------------------------------------------------------------------
# Show promotion plan
# ---------------------------------------------------------------------------
Write-Step 'Promotion parameters'
Write-Host "  Domain FQDN      : $($cfg.DomainFQDN)"  -ForegroundColor Cyan
Write-Host "  NetBIOS Name     : $($cfg.NetBIOSName)"  -ForegroundColor Cyan
Write-Host "  Forest Level     : $($cfg.ForestLevel)"  -ForegroundColor Cyan
Write-Host "  Domain Level     : $($cfg.DomainLevel)"  -ForegroundColor Cyan
Write-Host "  NTDS Path        : $($cfg.NTDSPath)"     -ForegroundColor Cyan
Write-Host "  Log Path         : $($cfg.LogPath)"      -ForegroundColor Cyan
Write-Host "  SYSVOL Path      : $($cfg.SysvolPath)"   -ForegroundColor Cyan

if ($DryRun) {
    Write-Warn 'DRY RUN — Install-ADDSForest will NOT be called.'
    Stop-Transcript
    exit 0
}

# ---------------------------------------------------------------------------
# Prompt for DSRM password (after DryRun short-circuit so it is never prompted in dry runs)
# ---------------------------------------------------------------------------
Write-Step 'DSRM password'
Write-Host '  The Directory Services Restore Mode (DSRM) password is required.' -ForegroundColor Cyan
Write-Host '  Store it securely — you need it to recover AD DS.' -ForegroundColor Yellow

$dsrmPassword = $null
do {
    $ss1 = Read-Host -Prompt '  Enter DSRM password'   -AsSecureString
    $ss2 = Read-Host -Prompt '  Confirm DSRM password' -AsSecureString

    # Convert to plaintext in native memory, compare, then immediately zero the buffers.
    $ptr1 = [IntPtr]::Zero
    $ptr2 = [IntPtr]::Zero
    try {
        $ptr1   = [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($ss1)
        $ptr2   = [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($ss2)
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr1)
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr2)

        if ($plain1 -ne $plain2) {
            Write-Warn 'Passwords do not match — please try again.'
        } elseif ($plain1.Length -lt 8) {
            Write-Warn 'Password must be at least 8 characters — please try again.'
        } else {
            $dsrmPassword = $ss1
        }
    } finally {
        if ($ptr1 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr1) }
        if ($ptr2 -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr2) }
    }
} until ($null -ne $dsrmPassword)

Write-OK 'DSRM password accepted.'

# ---------------------------------------------------------------------------
# Final confirmation before promotion
# ---------------------------------------------------------------------------
Write-Step "Promoting to forest root DC for '$($cfg.DomainFQDN)'"
Write-Warn 'The server will REBOOT automatically when promotion completes.'
$confirm = Read-Host 'Type YES to proceed with promotion'
if ($confirm -ne 'YES') {
    Write-Warn 'Promotion cancelled by user.'
    Stop-Transcript
    exit 0
}

# ---------------------------------------------------------------------------
# Promote
# ---------------------------------------------------------------------------
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
    # Reached only if the reboot is somehow suppressed; normally the system reboots above.
    Write-OK 'Install-ADDSForest returned — reboot should be imminent.'
} catch {
    Write-Fail "Promotion failed: $_"
    Stop-Transcript
    throw
}

Stop-Transcript
