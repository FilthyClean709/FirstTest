<#
.SYNOPSIS
    Shared helper functions dot-sourced by all DC setup scripts.
.NOTES
    Author : <your name>
    Date   : 2026-04-20
#>

function Write-Step { param([string]$msg) Write-Host "`n[STEP] $msg" -ForegroundColor Cyan   }
function Write-OK   { param([string]$msg) Write-Host "  [OK] $msg"   -ForegroundColor Green  }
function Write-Warn { param([string]$msg) Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "  [ERR] $msg"  -ForegroundColor Red    }

function Assert-Config {
    param(
        [hashtable]$Cfg,
        [string[]]$Keys
    )
    foreach ($k in $Keys) {
        if (-not $Cfg.ContainsKey($k) -or $null -eq $Cfg[$k]) {
            throw "config.psd1 is missing required value: '$k'"
        }
        # Reject empty strings, but allow integers and arrays
        if ($Cfg[$k] -is [string] -and [string]::IsNullOrWhiteSpace($Cfg[$k])) {
            throw "config.psd1 has a blank value for: '$k'"
        }
    }
}

function Get-ConfigPath {
    param([string]$ScriptDir)
    $path = Join-Path $ScriptDir 'config.psd1'
    if (-not (Test-Path $path)) { throw "config.psd1 not found at: $path" }
    return $path
}

function New-LogDir {
    param([string]$ScriptDir)
    $dir = Join-Path $ScriptDir 'Logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return $dir
}
