@{
    # =========================================================================
    # config.psd1 — Lab Domain Controller Environment Settings
    # Edit the values in this file before running any scripts.
    # =========================================================================

    # -------------------------------------------------------------------------
    # Computer Identity
    # -------------------------------------------------------------------------
    ComputerName        = 'LAB-DC01'
    Timezone            = 'Eastern Standard Time'   # Get-TimeZone -ListAvailable

    # -------------------------------------------------------------------------
    # Network
    # -------------------------------------------------------------------------
    AdapterName         = 'Ethernet'                # Get-NetAdapter to verify name
    IPAddress           = '192.168.10.10'
    PrefixLength        = 24                        # 24 = 255.255.255.0
    DefaultGateway      = '192.168.10.1'

    # DNS before promotion: point at an upstream resolver so Windows Update works.
    # After promotion (3-PostConfig.ps1) the primary is automatically 127.0.0.1.
    PrimaryDNS          = '192.168.10.1'            # Will become 127.0.0.1 post-promotion
    SecondaryDNS        = '8.8.8.8'

    # DNS forwarders written by 3-PostConfig.ps1
    DNSForwarders       = @('8.8.8.8', '8.8.4.4')

    # -------------------------------------------------------------------------
    # Active Directory
    # -------------------------------------------------------------------------
    DomainFQDN          = 'lab.local'
    NetBIOSName         = 'LAB'

    # Forest / Domain functional levels
    # Accepted values: Win2008, Win2008R2, Win2012, Win2012R2, WinThreshold (2016), Win2025
    ForestLevel         = 'WinThreshold'
    DomainLevel         = 'WinThreshold'

    # -------------------------------------------------------------------------
    # AD DS Directory Paths  (leave as defaults unless you have a reason to change)
    # -------------------------------------------------------------------------
    NTDSPath            = 'C:\Windows\NTDS'
    LogPath             = 'C:\Windows\NTDS'
    SysvolPath          = 'C:\Windows\SYSVOL'

    # -------------------------------------------------------------------------
    # Baseline Organisational Units
    # Created under the domain root, e.g. OU=Servers,DC=lab,DC=local
    # -------------------------------------------------------------------------
    BaselineOUs         = @(
        'Servers',
        'Workstations',
        'Users',
        'Groups',
        'ServiceAccounts',
        'AdminAccounts'
    )

    # -------------------------------------------------------------------------
    # Baseline Security Groups  (created in OU=Groups)
    # -------------------------------------------------------------------------
    BaselineGroups      = @(
        @{ Name = 'GG-IT-Admins';        Description = 'IT administrators'                 }
        @{ Name = 'GG-IT-HelpDesk';      Description = 'Help desk staff'                   }
        @{ Name = 'GG-Server-Admins';    Description = 'Server local admin delegation'      }
        @{ Name = 'GG-Workstation-Admins'; Description = 'Workstation local admin delegation' }
        @{ Name = 'GG-VPN-Users';        Description = 'Users permitted VPN access'         }
        @{ Name = 'GG-RDP-Users';        Description = 'Users permitted RDP access'         }
    )
}
