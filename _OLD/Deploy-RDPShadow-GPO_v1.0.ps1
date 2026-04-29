#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Script de deploiement GPO - Configuration RDP Shadow et WinRM.
.DESCRIPTION
    A executer au demarrage des postes via GPO Startup Script.
    Configure RDP, Shadow, RPC, WinRM et le pare-feu de facon idempotente.
.AUTHOR
    Julien CRINON - Grand Est
#>

[CmdletBinding()]
param (
    [ValidateSet(0, 1, 2, 3, 4)]
    [int]$ShadowMode = 2,
    [bool]$EnableLogging = $true,
    [string]$LogPath = "C:\Windows\Logs\RDP-Shadow-Deploy.log",
    [string]$AllowedRemoteAddresses = "Any",
    [switch]$EnableLocalAccountTokenFilterPolicy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $Message"

    if ($EnableLogging) {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    }

    Write-Host $line
}

function Ensure-RegistryDwordValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $current = $null
    try {
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    }
    catch {
        $current = $null
    }

    if ($null -eq $current) {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
        return "created"
    }

    if ([int]$current -ne $Value) {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value
        return "updated"
    }

    return "unchanged"
}

function Enable-FirewallGroupIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayGroup,
        [Parameter(Mandatory = $true)]
        [string]$RemoteAddress
    )

    $rules = Get-NetFirewallRule -DisplayGroup $DisplayGroup -ErrorAction SilentlyContinue
    if (-not $rules) {
        return $false
    }

    $rules | Enable-NetFirewallRule | Out-Null
    $rules | Set-NetFirewallRule -RemoteAddress $RemoteAddress | Out-Null
    return $true
}

Write-Log "=========================================="
Write-Log "Deploiement RDP Shadow et WinRM - $env:COMPUTERNAME"
Write-Log "=========================================="

try {
    # 1. Activer RDP
    Write-Log "[1/7] Activation RDP..."
    $rdpPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
    $rdpResult = Ensure-RegistryDwordValue -Path $rdpPath -Name "fDenyTSConnections" -Value 0
    Write-Log "fDenyTSConnections: $rdpResult"

    # 2. Configurer Shadow Sessions
    Write-Log "[2/7] Configuration Shadow (Mode $ShadowMode)..."
    $shadowPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    $shadowResult = Ensure-RegistryDwordValue -Path $shadowPath -Name "Shadow" -Value $ShadowMode
    Write-Log "Shadow: $shadowResult"

    # 3. Activer NLA
    Write-Log "[3/7] Activation NLA..."
    $nlaPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    $nlaResult = Ensure-RegistryDwordValue -Path $nlaPath -Name "UserAuthentication" -Value 1
    Write-Log "UserAuthentication: $nlaResult"

    # 4. Autoriser RPC distant pour RDP shadow
    Write-Log "[4/7] Autorisation RPC distant..."
    $rpcResult = Ensure-RegistryDwordValue -Path $rdpPath -Name "AllowRemoteRPC" -Value 1
    Write-Log "AllowRemoteRPC: $rpcResult"

    # 5. Optionnel: autoriser l'elevation distante pour comptes locaux
    Write-Log "[5/7] Parametre UAC distant (optionnel)..."
    if ($EnableLocalAccountTokenFilterPolicy) {
        $uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        $uacResult = Ensure-RegistryDwordValue -Path $uacPath -Name "LocalAccountTokenFilterPolicy" -Value 1
        Write-Log "LocalAccountTokenFilterPolicy: $uacResult"
    }
    else {
        Write-Log "Non modifie (switch -EnableLocalAccountTokenFilterPolicy non fourni)."
    }

    # 6. Activer PSRemoting (WinRM)
    Write-Log "[6/7] Activation WinRM (PSRemoting)..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM
    Write-Log "WinRM configure et demarre."

    # 7. Configurer le pare-feu
    Write-Log "[7/7] Configuration des regles de pare-feu (RemoteAddress=$AllowedRemoteAddresses)..."
    $fwGroups = @(
        "Bureau a distance", "Bureau a distance avec prise en charge de la redirection",
        "Remote Desktop", "Remote Desktop - Shadow (TCP-In)", "Remote Desktop - User Mode (TCP-In)",
        "Gestion a distance de Windows", "Windows Remote Management"
    )

    $updatedGroups = New-Object System.Collections.Generic.List[string]
    foreach ($group in $fwGroups) {
        if (Enable-FirewallGroupIfPresent -DisplayGroup $group -RemoteAddress $AllowedRemoteAddresses) {
            $updatedGroups.Add($group)
        }
    }

    if ($updatedGroups.Count -eq 0) {
        Write-Log "Aucun groupe pare-feu cible trouve (noms localises possibles differents)."
    }
    else {
        Write-Log ("Groupes pare-feu mis a jour: " + ($updatedGroups -join ", "))
    }

    Write-Log "[OK] Redemarrage TermService..."
    Restart-Service -Name TermService -Force

    Write-Log "CONFIGURATION TERMINEE AVEC SUCCES"
    exit 0
}
catch {
    Write-Log "ERREUR CRITIQUE: $($_.Exception.Message)"
    exit 1
}
