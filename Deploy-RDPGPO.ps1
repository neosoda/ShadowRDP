#Requires -Version 5.1
<#
.SYNOPSIS
    Configure RDP Shadow pour RemoteDesktopAssistant en contexte machine.

.DESCRIPTION
    Version production orientee GPO Startup / tache planifiee machine.
    Le script converge rapidement, reste idempotent, ne depend pas du
    repertoire courant, evite les attentes reseau longues et journalise dans
    C:\Windows\Logs avec rotation simple.

    Les parametres par defaut privilegient le chemin critique du demarrage:
    pas d'attente reseau, pas de redemarrage TermService, pas de scan.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateSet(0, 1, 2, 3, 4)]
    [int]$ShadowMode = 2,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AllowedRemoteAddresses = 'LocalSubnet',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = "$env:WINDIR\Logs\RDP-Shadow-Deploy.log",

    [Parameter()]
    [ValidateRange(0, 10MB)]
    [int]$MaxLogBytes = 1MB,

    [Parameter()]
    [ValidateRange(0, 120)]
    [int]$NetworkWaitTimeoutSeconds = 0,

    [Parameter()]
    [ValidateRange(1, 15)]
    [int]$NetworkRetryIntervalSeconds = 3,

    [Parameter()]
    [Alias('SkipIfAppliedWithinDays')]
    [ValidateRange(0, 365)]
    [int]$MaxAgeDays = 7,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int]$ServiceTimeoutSeconds = 12,

    [Parameter()]
    [switch]$RestartTermService,

    [Parameter()]
    [switch]$EnableLocalAccountTokenFilterPolicy,

    [Parameter()]
    [switch]$EnableWinRM,

    [Parameter()]
    [switch]$Uninstall,

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptVersion = '4.0.1'
$script:StateRegPath = 'HKLM:\SOFTWARE\GrandEst\CMIL\RDPShadowDeploy'
$script:EventSource = 'Deploy-RDPGPO'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:StartTime = Get-Date

function Write-DeployLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Level, $Message

    switch ($Level) {
        'WARN' { Write-Warning $Message }
        'ERROR' { Write-Warning "ERROR: $Message" }
        default { Write-Verbose $Message }
    }

    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }

        if ($MaxLogBytes -gt 0 -and (Test-Path -LiteralPath $LogPath)) {
            $item = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($null -ne $item -and $item.Length -gt $MaxLogBytes) {
                $archive = "$LogPath.1"
                if (Test-Path -LiteralPath $archive) {
                    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $LogPath -Destination $archive -Force -ErrorAction SilentlyContinue
            }
        }

        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $script:Utf8NoBom)
    }
    catch {
        Write-Warning "Journalisation fichier impossible: $($_.Exception.Message)"
    }
}

function Test-IsElevatedOrSystem {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity) {
        return $false
    }

    if ($identity.User.Value -eq 'S-1-5-18') {
        return $true
    }

    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Is64BitPowerShell {
    [CmdletBinding()]
    param()

    return [Environment]::Is64BitProcess
}

function Test-AllowedRemoteAddresses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -eq 'Any') {
        Write-DeployLog 'AllowedRemoteAddresses=Any ouvre largement les regles pare-feu.' 'WARN'
        return
    }

    $keywords = @('LocalSubnet', 'DNS', 'DHCP', 'WINS', 'DefaultGateway', 'Internet', 'Intranet')
    $parts = @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) {
        throw "AllowedRemoteAddresses est vide."
    }

    foreach ($part in $parts) {
        if ($part -in $keywords) {
            continue
        }

        $candidate = $part
        if ($part.Contains('/')) {
            $split = @($part.Split('/'))
            if ($split.Count -ne 2) {
                throw "CIDR invalide: '$part'"
            }

            $prefix = 0
            if (-not [int]::TryParse($split[1], [ref]$prefix)) {
                throw "Prefixe CIDR invalide: '$part'"
            }

            $candidate = $split[0]
            if ($candidate.Contains(':')) {
                if ($prefix -lt 0 -or $prefix -gt 128) {
                    throw "Prefixe IPv6 invalide: '$part'"
                }
            }
            elseif ($prefix -lt 0 -or $prefix -gt 32) {
                throw "Prefixe IPv4 invalide: '$part'"
            }
        }

        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$ip)) {
            throw "Adresse distante non reconnue: '$part'"
        }
    }
}

function Wait-DomainNetwork {
    [CmdletBinding()]
    param()

    if ($NetworkWaitTimeoutSeconds -le 0) {
        Write-DeployLog 'Attente reseau ignoree: NetworkWaitTimeoutSeconds=0.'
        return $true
    }

    $deadline = (Get-Date).AddSeconds($NetworkWaitTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $profile = Get-NetConnectionProfile -ErrorAction Stop |
                Where-Object { $_.NetworkCategory -eq 'DomainAuthenticated' } |
                Select-Object -First 1

            if ($null -ne $profile) {
                Write-DeployLog 'Profil reseau DomainAuthenticated detecte.'
                return $true
            }
        }
        catch {
            Write-DeployLog "Lecture profil reseau impossible: $($_.Exception.Message)" 'WARN'
            return $false
        }

        Start-Sleep -Seconds $NetworkRetryIntervalSeconds
    }

    Write-DeployLog "Aucun profil DomainAuthenticated apres ${NetworkWaitTimeoutSeconds}s. Poursuite sans blocage." 'WARN'
    return $false
}

function Get-DeploymentState {
    [CmdletBinding()]
    param()

    try {
        if (Test-Path -LiteralPath $script:StateRegPath) {
            return Get-ItemProperty -Path $script:StateRegPath -ErrorAction Stop
        }
    }
    catch {
        Write-DeployLog "Etat deploiement illisible: $($_.Exception.Message)" 'WARN'
    }

    return $null
}

function Test-AlreadyApplied {
    [CmdletBinding()]
    param()

    if ($Force -or $Uninstall -or $MaxAgeDays -le 0) {
        return $false
    }

    $state = Get-DeploymentState
    if ($null -eq $state) {
        return $false
    }

    try {
        if ($state.Version -ne $script:ScriptVersion) {
            return $false
        }
        if ($state.ShadowMode -ne $ShadowMode) {
            return $false
        }
        if ($state.AllowedRemoteAddresses -ne $AllowedRemoteAddresses) {
            return $false
        }
        if ([int]$state.EnableWinRM -ne [int]$EnableWinRM.IsPresent) {
            return $false
        }

        $lastSuccess = [DateTime]::Parse($state.LastSuccess)
        if (((Get-Date) - $lastSuccess).TotalDays -lt $MaxAgeDays) {
            Write-DeployLog "Meme version deja appliquee recemment: $($state.LastSuccess)."
            return $true
        }
    }
    catch {
        return $false
    }

    return $false
}

function Set-DeploymentState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Uninstalled')]
        [string]$Status
    )

    if (-not (Test-Path -LiteralPath $script:StateRegPath)) {
        if ($PSCmdlet.ShouldProcess($script:StateRegPath, 'Create state key')) {
            New-Item -Path $script:StateRegPath -Force | Out-Null
        }
    }

    if ($PSCmdlet.ShouldProcess($script:StateRegPath, "Set deployment state $Status")) {
        Set-ItemProperty -Path $script:StateRegPath -Name 'Version' -Value $script:ScriptVersion -Type String
        Set-ItemProperty -Path $script:StateRegPath -Name 'LastRun' -Value (Get-Date -Format 's') -Type String
        Set-ItemProperty -Path $script:StateRegPath -Name 'LastStatus' -Value $Status -Type String
        Set-ItemProperty -Path $script:StateRegPath -Name 'ShadowMode' -Value $ShadowMode -Type DWord
        Set-ItemProperty -Path $script:StateRegPath -Name 'AllowedRemoteAddresses' -Value $AllowedRemoteAddresses -Type String
        Set-ItemProperty -Path $script:StateRegPath -Name 'EnableWinRM' -Value ([int]$EnableWinRM.IsPresent) -Type DWord

        if ($Status -eq 'Success') {
            Set-ItemProperty -Path $script:StateRegPath -Name 'LastSuccess' -Value (Get-Date -Format 's') -Type String
        }
    }
}

function Set-DwordValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create registry key')) {
            New-Item -Path $Path -Force | Out-Null
        }
    }

    $current = $null
    try {
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        $current = $null
    }

    if ($null -eq $current) {
        if ($PSCmdlet.ShouldProcess("$Path\$Name", "Create DWORD $Value")) {
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        }
        return 'created'
    }

    if ([int]$current -ne $Value) {
        if ($PSCmdlet.ShouldProcess("$Path\$Name", "Update DWORD $current -> $Value")) {
            Set-ItemProperty -Path $Path -Name $Name -Value $Value
        }
        return "updated ($current -> $Value)"
    }

    return 'unchanged'
}

function Remove-RegistryValueSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return 'missing'
    }

    $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $prop) {
        return 'missing'
    }

    if ($PSCmdlet.ShouldProcess("$Path\$Name", 'Remove registry value')) {
        Remove-ItemProperty -Path $Path -Name $Name -Force
    }

    return 'removed'
}

function Set-ServiceSafe {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$StartupType,

        [Parameter()]
        [switch]$Start,

        [Parameter()]
        [switch]$Stop
    )

    $service = Get-Service -Name $Name -ErrorAction Stop
    $wmi = Get-WmiObject -Class Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
    $targetStartMode = @{ Automatic = 'Auto'; Manual = 'Manual'; Disabled = 'Disabled' }[$StartupType]

    if ($wmi.StartMode -ne $targetStartMode) {
        if ($PSCmdlet.ShouldProcess($Name, "Set StartupType=$StartupType")) {
            Set-Service -Name $Name -StartupType $StartupType
            Write-DeployLog "Service $Name StartupType: $($wmi.StartMode) -> $StartupType."
        }
    }

    if ($Start -and $service.Status -ne 'Running') {
        if ($PSCmdlet.ShouldProcess($Name, 'Start service')) {
            Start-Service -Name $Name
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds($ServiceTimeoutSeconds))
            Write-DeployLog "Service $Name demarre."
        }
    }

    if ($Stop -and $service.Status -eq 'Running') {
        if ($PSCmdlet.ShouldProcess($Name, 'Stop service')) {
            Stop-Service -Name $Name -Force
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceTimeoutSeconds))
            Write-DeployLog "Service $Name arrete."
        }
    }
}

function Get-FirewallRulesByNamePattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$NamePatterns
    )

    $rulesByName = @{}

    foreach ($pattern in $NamePatterns) {
        try {
            $found = @(Get-NetFirewallRule -Name $pattern -ErrorAction SilentlyContinue)
            foreach ($rule in $found) {
                if (-not $rulesByName.ContainsKey($rule.Name)) {
                    $rulesByName[$rule.Name] = $rule
                }
            }
        }
        catch {
            Write-DeployLog "Recherche regle pare-feu '$pattern' impossible: $($_.Exception.Message)" 'WARN'
        }
    }

    return @($rulesByName.Values)
}

function Set-FirewallRules {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$NamePatterns,

        [Parameter(Mandatory = $true)]
        [string]$RemoteAddress,

        [Parameter()]
        [switch]$Disable
    )

    $updated = 0
    $unchanged = 0
    $disabled = 0
    $rules = @(Get-FirewallRulesByNamePattern -NamePatterns $NamePatterns)

    foreach ($rule in $rules) {
        if ($Disable) {
            if ($rule.Enabled -ne 'False') {
                if ($PSCmdlet.ShouldProcess($rule.Name, 'Disable firewall rule')) {
                    Disable-NetFirewallRule -Name $rule.Name | Out-Null
                }
                $disabled++
            }
            else {
                $unchanged++
            }
            continue
        }

        $changed = $false
        if ($rule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess($rule.Name, 'Enable firewall rule')) {
                Enable-NetFirewallRule -Name $rule.Name | Out-Null
            }
            $changed = $true
        }

        $filter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
        $current = @($filter.RemoteAddress | Sort-Object)
        $target = @($RemoteAddress.Split(',') | ForEach-Object { $_.Trim() } | Sort-Object)
        if (($current -join '|') -ne ($target -join '|')) {
            if ($PSCmdlet.ShouldProcess($rule.Name, "Set RemoteAddress=$RemoteAddress")) {
                Set-NetFirewallRule -Name $rule.Name -RemoteAddress $RemoteAddress | Out-Null
            }
            $changed = $true
        }

        if ($changed) {
            $updated++
        }
        else {
            $unchanged++
        }
    }

    return [pscustomobject]@{
        Matched = $rules.Count
        Updated = $updated
        Unchanged = $unchanged
        Disabled = $disabled
    }
}

function Invoke-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-DeployLog "[$Name] Debut."
    try {
        & $Action
        Write-DeployLog "[$Name] OK."
    }
    catch {
        Write-DeployLog "[$Name] ECHEC: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

function Invoke-Install {
    [CmdletBinding()]
    param()

    Test-AllowedRemoteAddresses -Value $AllowedRemoteAddresses

    if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        throw 'Module NetSecurity indisponible: pare-feu non configurable.'
    }

    if (Test-AlreadyApplied) {
        Write-DeployLog 'Sortie anticipee: configuration deja appliquee.'
        return
    }

    Wait-DomainNetwork | Out-Null

    $rdpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $nlaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    $shadowPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    Invoke-Step 'Registry RDP' {
        Write-DeployLog ('fDenyTSConnections: ' + (Set-DwordValue -Path $rdpPath -Name 'fDenyTSConnections' -Value 0))
        Write-DeployLog ('AllowRemoteRPC: ' + (Set-DwordValue -Path $rdpPath -Name 'AllowRemoteRPC' -Value 1))
        Write-DeployLog ('UserAuthentication: ' + (Set-DwordValue -Path $nlaPath -Name 'UserAuthentication' -Value 1))
        Write-DeployLog ('Shadow: ' + (Set-DwordValue -Path $shadowPolicyPath -Name 'Shadow' -Value $ShadowMode))
    }

    Invoke-Step 'Optional UAC Policy' {
        if ($EnableLocalAccountTokenFilterPolicy) {
            Write-DeployLog ('LocalAccountTokenFilterPolicy: ' + (Set-DwordValue -Path $uacPath -Name 'LocalAccountTokenFilterPolicy' -Value 1))
        }
        else {
            Write-DeployLog 'LocalAccountTokenFilterPolicy ignore.'
        }
    }

    Invoke-Step 'Services' {
        Set-ServiceSafe -Name 'TermService' -StartupType 'Manual'
        Set-ServiceSafe -Name 'RemoteRegistry' -StartupType 'Manual' -Start
        if ($EnableWinRM) {
            Set-ServiceSafe -Name 'WinRM' -StartupType 'Automatic' -Start
        }
        else {
            Write-DeployLog 'WinRM ignore: EnableWinRM=false.'
        }
    }

    Invoke-Step 'Firewall' {
        $patterns = @(
            'RemoteDesktop-*',
            'RemoteSvc*',
            'RemoteEventLog*',
            'WMI-*',
            'FPS-SMB-In*',
            'FPS-ICMP4-ERQ-In*'
        )

        if ($EnableWinRM) {
            $patterns += 'WINRM-*'
        }

        $fw = Set-FirewallRules -NamePatterns $patterns -RemoteAddress $AllowedRemoteAddresses
        Write-DeployLog ("Firewall: matched={0}, updated={1}, unchanged={2}." -f $fw.Matched, $fw.Updated, $fw.Unchanged)

        if ($fw.Matched -eq 0) {
            throw 'Aucune regle pare-feu attendue trouvee.'
        }
    }

    Invoke-Step 'Optional TermService Restart' {
        if (-not $RestartTermService) {
            Write-DeployLog 'Redemarrage TermService ignore.'
            return
        }

        $sessions = & quser.exe 2>$null
        if ($LASTEXITCODE -eq 0 -and ($sessions | Measure-Object).Count -gt 1) {
            Write-DeployLog 'Sessions interactives detectees: TermService ne sera pas redemarre.' 'WARN'
            return
        }

        if ($PSCmdlet.ShouldProcess('TermService', 'Restart service')) {
            Restart-Service -Name 'TermService' -Force -ErrorAction Stop
            (Get-Service -Name 'TermService').WaitForStatus('Running', [TimeSpan]::FromSeconds($ServiceTimeoutSeconds))
            Write-DeployLog 'TermService redemarre.'
        }
    }

    Invoke-Step 'State' {
        Set-DeploymentState -Status 'Success'
    }
}

function Invoke-Uninstall {
    [CmdletBinding()]
    param()

    $state = Get-DeploymentState
    $scriptEnabledWinRM = $false
    if ($null -ne $state) {
        try {
            $scriptEnabledWinRM = ([int]$state.EnableWinRM -eq 1)
        }
        catch {
            $scriptEnabledWinRM = $false
        }
    }

    $rdpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $shadowPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    Invoke-Step 'Uninstall Registry' {
        Write-DeployLog ('fDenyTSConnections: ' + (Set-DwordValue -Path $rdpPath -Name 'fDenyTSConnections' -Value 1))
        Write-DeployLog ('Shadow: ' + (Set-DwordValue -Path $shadowPolicyPath -Name 'Shadow' -Value 0))
        Write-DeployLog ('AllowRemoteRPC: ' + (Remove-RegistryValueSafe -Path $rdpPath -Name 'AllowRemoteRPC'))
        Write-DeployLog ('LocalAccountTokenFilterPolicy: ' + (Remove-RegistryValueSafe -Path $uacPath -Name 'LocalAccountTokenFilterPolicy'))
    }

    Invoke-Step 'Uninstall Services' {
        Set-ServiceSafe -Name 'RemoteRegistry' -StartupType 'Disabled' -Stop
        if ($scriptEnabledWinRM) {
            Set-ServiceSafe -Name 'WinRM' -StartupType 'Manual'
        }
        else {
            Write-DeployLog 'WinRM non modifie: non active par le dernier deploiement connu.'
        }
    }

    Invoke-Step 'Uninstall Firewall' {
        $patterns = @('RemoteDesktop-*', 'RemoteSvc*', 'RemoteEventLog*', 'WMI-*', 'FPS-SMB-In*', 'FPS-ICMP4-ERQ-In*')
        if ($scriptEnabledWinRM) {
            $patterns += 'WINRM-*'
        }
        $fw = Set-FirewallRules -NamePatterns $patterns -RemoteAddress 'Any' -Disable
        Write-DeployLog ("Firewall disabled={0}, unchanged={1}." -f $fw.Disabled, $fw.Unchanged)
    }

    Invoke-Step 'Uninstall State' {
        Set-DeploymentState -Status 'Uninstalled'
    }
}

$exitCode = 0

try {
    if (-not (Test-Is64BitPowerShell)) {
        Write-DeployLog 'PowerShell 32 bits detecte sur OS 64 bits: utiliser System32 ou Sysnative dans le wrapper.' 'WARN'
    }

    if (-not (Test-IsElevatedOrSystem)) {
        Write-DeployLog 'Execution refusee: droits administrateur ou SYSTEM requis.' 'ERROR'
        exit 2
    }

    Write-DeployLog '======================================================'
    Write-DeployLog "Deploy-RDPGPO v$script:ScriptVersion - $env:COMPUTERNAME"
    Write-DeployLog "Mode=$(@('Install','Uninstall')[[int]$Uninstall.IsPresent]); PS=$($PSVersionTable.PSVersion); 64bit=$([Environment]::Is64BitProcess)"
    Write-DeployLog "PSScriptRoot=$PSScriptRoot"
    Write-DeployLog '======================================================'

    if ($Uninstall) {
        Invoke-Uninstall
    }
    else {
        Invoke-Install
    }

    $duration = [int]((Get-Date) - $script:StartTime).TotalSeconds
    Write-DeployLog "Operation terminee avec succes en ${duration}s."
}
catch {
    $exitCode = 1
    Write-DeployLog "Erreur critique: $($_.Exception.Message)" 'ERROR'
    Write-DeployLog "StackTrace: $($_.ScriptStackTrace)" 'ERROR'

    try {
        Set-DeploymentState -Status 'Failed'
    }
    catch {
        Write-DeployLog "Impossible d'ecrire l'etat d'echec: $($_.Exception.Message)" 'WARN'
    }
}

exit $exitCode
