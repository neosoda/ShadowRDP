#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Script de deploiement GPO - Configuration RDP Shadow & WinRM
.DESCRIPTION
    A executer au demarrage des postes via GPO Startup Script.
    Configure RDP, Shadow, RPC, WinRM et ouvre le pare-feu pour TOUS les sous-reseaux.
.AUTHOR
    Julien CRINON - Grand Est
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

# Mode Shadow a configurer
# 2 = Controle total SANS consentement (Permet tous les modes dans l'Assistant)
param (
    [int]$ShadowMode = 2,
    [switch]$EnableLogging = $true,
    [string]$LogPath = "C:\Windows\Logs\RDP-Shadow-Deploy.log"
)

function Write-Log {
    param([string]$Message)
    if ($EnableLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp - $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
    Write-Host $Message
}

# ============================================================================
# DEBUT DU SCRIPT
# ============================================================================

Write-Log "=========================================="
Write-Log "Deploiement RDP Shadow & WinRM - $env:COMPUTERNAME"
Write-Log "=========================================="

try {
    # 1. Activer RDP
    Write-Log "[1/6] Activation RDP..."
    $rdpPath = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    $rdpValue = (Get-ItemProperty -Path $rdpPath).fDenyTSConnections
    if ($rdpValue -ne 0) {
        Set-ItemProperty -Path $rdpPath -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
        Write-Log "RDP activé avec succès."
    }
    else {
        Write-Log "RDP déjà activé."
    }

    # 2. Configurer Shadow Sessions
    Write-Log "[2/6] Configuration Shadow (Mode $ShadowMode)..."
    $regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    $shadowValue = (Get-ItemProperty -Path $regPath).Shadow
    if ($shadowValue -ne $ShadowMode) {
        Set-ItemProperty -Path $regPath -Name "Shadow" -Value $ShadowMode -Type DWord -ErrorAction Stop
        Write-Log "Shadow configuré avec succès."
    }
    else {
        Write-Log "Shadow déjà configuré en mode $shadowValue."
    }

    # 3. Activer NLA
    Write-Log "[3/6] Activation NLA..."
    $nlaPath = 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    $nlaValue = (Get-ItemProperty -Path $nlaPath).UserAuthentication
    if ($nlaValue -ne 1) {
        Set-ItemProperty -Path $nlaPath -Name "UserAuthentication" -Value 1 -ErrorAction Stop
        Write-Log "NLA activé avec succès."
    }
    else {
        Write-Log "NLA déjà activé."
    }

    # 4. Autoriser RPC et UAC Distant (Securite de secours)
    Write-Log "[4/6] Autorisation RPC et UAC distant..."
    $rpcPath = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
    $rpcValue = (Get-ItemProperty -Path $rpcPath).AllowRemoteRPC
    if ($rpcValue -ne 1) {
        Set-ItemProperty -Path $rpcPath -Name "AllowRemoteRPC" -Value 1 -ErrorAction SilentlyContinue
        Write-Log "RPC autorisé avec succès."
    }
    else {
        Write-Log "RPC déjà autorisé."
    }

    $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $uacValue = (Get-ItemProperty -Path $uacPath).LocalAccountTokenFilterPolicy
    if ($uacValue -ne 1) {
        Set-ItemProperty -Path $uacPath -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Write-Log "UAC distant autorisé avec succès."
    }
    else {
        Write-Log "UAC distant déjà autorisé."
    }

    # 5. Activer PSRemoting (WinRM)
    Write-Log "[5/6] Activation WinRM (PSRemoting)..."
    $psremotingEnabled = Get-PSSessionConfiguration -Name Microsoft.PowerShell | Select-Object -ExpandProperty State
    if ($psremotingEnabled -ne 'Running') {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
        Write-Log "WinRM activé avec succès."
    }
    else {
        Write-Log "WinRM déjà activé."
    }

    # 6. Configurer le pare-feu (AVEC CORRECTION INTER-VLAN)
    Write-Log "[6/6] Configuration des regles de Pare-feu (Bypass LocalSubnet)..."
    
    # Liste des groupes de pare-feu en francais et anglais (pour compatibilite)
    $fwGroups = @(
        "Bureau a distance", "Bureau à distance", "Remote Desktop",
        "Gestion a distance de Windows", "Gestion à distance de Windows", "Windows Remote Management"
    )
    
    foreach ($group in $fwGroups) {
        try { 
            # 1. On active la regle
            Enable-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue 
            
            # 2. LA CORRECTION : On force l'ecoute sur toutes les IPs (et non plus juste le sous-reseau local)
            Set-NetFirewallRule -DisplayGroup $group -RemoteAddress Any -ErrorAction SilentlyContinue
            
            Write-Log "  --> Regles modifiees pour le groupe: $group"
        }
        catch {}
    }

    # 7. Redemarrage du service
    Write-Log "[OK] Redemarrage TermService..."
    Restart-Service TermService -Force -ErrorAction SilentlyContinue

    Write-Log "CONFIGURATION TERMINEE AVEC SUCCES"
    exit 0

}
catch {
    Write-Log "ERREUR CRITIQUE: $($_.Exception.Message)"
    exit 1
}