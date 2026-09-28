# Example AdLifecycle configuration. The domain (corp.example), OUs and groups are fictional.
# Validate after editing:  Test-AdLifecycleConfig -Path .\lifecycle.config.psd1 -Strict
# This file is read with Import-PowerShellDataFile: data only, no code is executed.
@{
    # New accounts get <samAccountName>@<UpnSuffix>.
    UpnSuffix      = 'corp.example'

    # Leavers are moved here by Disable-AdLifecycleUser. Must differ from every site OU.
    DisabledOU     = 'OU=Disabled Users,OU=Corp,DC=corp,DC=example'

    # Length of generated initial passwords (12-128). Optional; default 16.
    PasswordLength = 16

    # Audit log (JSON Lines): one line per user changed by the joiner, mover or leaver. Optional;
    # -LogPath overrides it. The folder must exist.
    # LogPath      = 'C:\ops\logs\ad-lifecycle.jsonl'

    # Site name -> OU where new user accounts for that site are created.
    Sites          = @{
        'Buenos Aires' = 'OU=Users,OU=Buenos Aires,OU=Sites,OU=Corp,DC=corp,DC=example'
        'Cordoba'      = 'OU=Users,OU=Cordoba,OU=Sites,OU=Corp,DC=corp,DC=example'
        'Madrid'       = 'OU=Users,OU=Madrid,OU=Sites,OU=Corp,DC=corp,DC=example'
        'Remote'       = 'OU=Users,OU=Remote,OU=Sites,OU=Corp,DC=corp,DC=example'
    }

    # Groups every new user gets, whatever the department. Optional.
    # Not touched by Set-AdLifecycleUser (a department change keeps them).
    CommonGroups   = @(
        'GG-All-Staff'
        'GG-VPN-Users'
    )

    # Department -> groups (sAMAccountName of each group). Joiners get these; movers get the
    # difference between the old and the new list.
    Departments    = @{
        'Finance'     = @('GG-Finance', 'GG-Share-Finance-RW', 'GG-App-ERP', 'GG-Reporting-Read')
        'Sales'       = @('GG-Sales', 'GG-Share-Sales-RW', 'GG-App-CRM', 'GG-Reporting-Read')
        'Engineering' = @('GG-Engineering', 'GG-Share-Engineering-RW', 'GG-App-Git')
        'IT'          = @('GG-IT', 'GG-Share-IT-RW', 'GG-App-Monitoring-RO')
    }
}
