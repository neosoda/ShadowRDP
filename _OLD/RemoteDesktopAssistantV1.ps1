<#
.SYNOPSIS
    Remote Desktop Assistant - DSI
.DESCRIPTION
    Script PowerShell avec interface WPF pour gerer les connexions RDP shadow et classiques.
    Optimise pour une execution depuis un poste du domaine.
#>

# ============================================================================
# AUTO-ELEVATION EN ADMINISTRATEUR
# ============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs
    exit
}

# ============================================================================
# IMPORTS
# ============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

function Test-HostReachable {
    param([string]$ComputerName)
    try {
        return (New-Object System.Net.NetworkInformation.Ping).Send($ComputerName, 1500).Status -eq 'Success'
    } catch { return $false }
}

function Resolve-ComputerNameToIP {
    param([string]$ComputerName)
    if ($ComputerName -match '^(\d{1,3}\.){3}\d{1,3}$') { return $ComputerName }
    try {
        $ipv4 = [System.Net.Dns]::GetHostEntry($ComputerName).AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($ipv4) { return $ipv4.IPAddressToString }
    } catch {}
    return $ComputerName
}

function Get-RemoteUserSessions {
    param([string]$ComputerName)
    
    $sessions = @()
    
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "qwinsta.exe"
    $psi.Arguments = "/server:$ComputerName"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null
    
    $output = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit(5000)
    
    if ($process.ExitCode -ne 0) {
        if ($err -match '(?i)erreur 5|access.*denied|acc.s.*refus.') {
            throw "Accès refusé (Erreur 5). Assurez-vous d'avoir les droits administrateur sur la machine cible."
        }
        throw "Erreur qwinsta : $err"
    }
    
    $lines = $output -split "`r?`n" | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
    foreach ($line in $lines) {
        if ($line -match '^\s*(\S+)\s+(\S+)?\s+(\d+)\s+(\S+)') {
            $sessionName = $matches[1].Trim()
            $username = if ($matches[2]) { $matches[2].Trim() } else { "" }
            if ($username -eq $sessionName) { $username = "" }
            
            $sessions += [PSCustomObject]@{
                SessionName = $sessionName
                Utilisateur = if ([string]::IsNullOrWhiteSpace($username)) { "-" } else { $username }
                ID          = [int]$matches[3].Trim()
                Etat        = $matches[4].Trim()
            }
        }
    }
    return $sessions
}

function Start-ShadowSession {
    param([string]$ComputerTarget, [int]$SessionID, [string]$Mode)
    $shadowArgs = switch ($Mode) {
        'View' { "/shadow:$SessionID /v:$ComputerTarget" }
        'Control' { "/shadow:$SessionID /v:$ComputerTarget /control" }
        'NoConsent' { "/shadow:$SessionID /v:$ComputerTarget /control /noConsentPrompt" }
    }
    Start-Process "mstsc.exe" -ArgumentList $shadowArgs
}

function Start-ClassicRDP {
    param([string]$ComputerTarget)
    # Lancement classique de mstsc sans parametres shadow
    Start-Process "mstsc.exe" -ArgumentList "/v:$ComputerTarget"
}

# ============================================================================
# INTERFACE GRAPHIQUE WPF
# ============================================================================

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Remote Desktop Assistant - DSI" Height="680" Width="900" 
        WindowStartupLocation="CenterScreen" Background="#FF1E1E1E">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <StackPanel Grid.Row="0" Margin="0,0,0,20">
            <Label Content="Assistant RDP Shadow &amp; Classique" Foreground="White" FontSize="22" FontWeight="Bold"/>
            <Label Content="Mode : Connecté au Domaine | Exécuté en tant qu'Administrateur" Foreground="#FF4EC9B0" FontSize="12"/>
        </StackPanel>
        
        <Border Grid.Row="1" Background="#FF252526" Padding="15" CornerRadius="5" Margin="0,0,0,15">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel Grid.Column="0" Margin="0,0,15,0">
                    <Label Content="Nom de l'ordinateur ou IP de la cible :" Foreground="#FFCCCCCC" FontSize="14"/>
                    <TextBox Name="txtComputerName" Background="#FF2D2D30" Foreground="White" FontSize="14" Padding="10" Margin="0,5,0,0" BorderBrush="#FF3F3F46"/>
                </StackPanel>
                
                <Button Name="btnConnect" Grid.Column="1" Content="Rechercher Sessions" 
                        Background="#FF0078D4" Foreground="White" FontSize="13" FontWeight="Bold" 
                        Padding="15,0" Margin="0,32,10,0" BorderThickness="0" Cursor="Hand"/>
                        
                <Button Name="btnClassicRDP" Grid.Column="2" Content="RDP Classique" 
                        Background="#FF4CAF50" Foreground="White" FontSize="13" FontWeight="Bold" 
                        Padding="15,0" Margin="0,32,0,0" BorderThickness="0" Cursor="Hand" ToolTip="Ouvrir une session Bureau à distance classique"/>
            </Grid>
        </Border>
        
        <Border Grid.Row="2" Background="#FF252526" Padding="15" CornerRadius="5" Margin="0,0,0,15">
            <DataGrid Name="dgSessions" AutoGenerateColumns="False" IsReadOnly="True" 
                      Background="#FF2D2D30" Foreground="White" HeadersVisibility="Column" 
                      RowBackground="#FF2D2D30" AlternatingRowBackground="#FF333337" 
                      BorderBrush="#FF3F3F46" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#FF3F3F46">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Session" Binding="{Binding SessionName}" Width="150"/>
                    <DataGridTextColumn Header="Utilisateur" Binding="{Binding Utilisateur}" Width="*"/>
                    <DataGridTextColumn Header="ID" Binding="{Binding ID}" Width="80"/>
                    <DataGridTextColumn Header="État" Binding="{Binding Etat}" Width="120"/>
                </DataGrid.Columns>
                <DataGrid.ColumnHeaderStyle>
                    <Style TargetType="DataGridColumnHeader">
                        <Setter Property="Background" Value="#FF0078D4"/>
                        <Setter Property="Foreground" Value="White"/>
                        <Setter Property="Padding" Value="10,8"/>
                        <Setter Property="FontWeight" Value="Bold"/>
                    </Style>
                </DataGrid.ColumnHeaderStyle>
            </DataGrid>
        </Border>
        
        <Border Grid.Row="3" Background="#FF252526" Padding="15" CornerRadius="5" Margin="0,0,0,15">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel Grid.Column="0">
                    <Label Content="Mode d'intervention Shadow :" Foreground="#FFCCCCCC" FontWeight="Bold" FontSize="14"/>
                    <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                        <RadioButton Name="rbView" Content="Visualisation" Foreground="White" FontSize="14" Margin="0,0,20,0" IsChecked="True"/>
                        <RadioButton Name="rbControl" Content="Contrôle (Demande accord)" Foreground="White" FontSize="14" Margin="0,0,20,0"/>
                        <RadioButton Name="rbNoConsent" Content="Forcer le contrôle" Foreground="#FFFF6B6B" FontSize="14"/>
                    </StackPanel>
                </StackPanel>
                
                <Button Name="btnLaunch" Grid.Column="1" Content="Lancer l'intervention Shadow" 
                        Background="#FF0078D4" Foreground="White" FontSize="14" FontWeight="Bold" 
                        Width="240" Height="50" BorderThickness="0" Cursor="Hand" IsEnabled="False"/>
            </Grid>
        </Border>
        
        <Border Grid.Row="4" Background="#FF007ACC" Padding="10" CornerRadius="3">
            <Label Name="lblStatus" Content="Prêt - Entrez une cible pour commencer" Foreground="White" FontWeight="Bold"/>
        </Border>
    </Grid>
</Window>
"@

# Chargement de la fenetre
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [Windows.Markup.XamlReader]::Load($reader)

# Liaisons des controles
$txtComputerName = $window.FindName("txtComputerName")
$btnConnect = $window.FindName("btnConnect")
$btnClassicRDP = $window.FindName("btnClassicRDP")
$dgSessions = $window.FindName("dgSessions")
$rbView = $window.FindName("rbView")
$rbControl = $window.FindName("rbControl")
$rbNoConsent = $window.FindName("rbNoConsent")
$btnLaunch = $window.FindName("btnLaunch")
$lblStatus = $window.FindName("lblStatus")

$Script:CurrentTarget = ""

# ============================================================================
# EVENEMENTS
# ============================================================================

$btnConnect.Add_Click({
    $lblStatus.Content = "Recherche en cours..."
    $lblStatus.Background = "#FFFF9800"
    $btnConnect.IsEnabled = $false
    $btnLaunch.IsEnabled = $false
    $dgSessions.ItemsSource = $null
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        $comp = $txtComputerName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($comp)) { throw "Veuillez entrer une cible." }
        
        $lblStatus.Content = "Ping vers $comp..."
        [System.Windows.Forms.Application]::DoEvents()
        if (-not (Test-HostReachable $comp)) { throw "Le poste $comp est injoignable au ping." }
        
        $lblStatus.Content = "Interrogation de qwinsta..."
        [System.Windows.Forms.Application]::DoEvents()
        $Script:CurrentTarget = Resolve-ComputerNameToIP $comp
        
        $sessions = Get-RemoteUserSessions -ComputerName $Script:CurrentTarget
        
        if ($sessions.Count -eq 0) {
            $lblStatus.Content = "Aucune session active. Utilisez 'RDP Classique'."
            $lblStatus.Background = "#FFFF6B6B"
            [System.Windows.MessageBox]::Show("Aucune session active n'a été trouvée sur le poste.`n`nVous pouvez utiliser le bouton 'RDP Classique' pour ouvrir une session standard sur ce poste.", "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } else {
            $dgSessions.ItemsSource = $sessions
            $lblStatus.Content = "$($sessions.Count) session(s) trouvée(s)."
            $lblStatus.Background = "#FF4CAF50"
        }
    } catch {
        $lblStatus.Content = "Erreur : $($_.Exception.Message)"
        $lblStatus.Background = "#FFFF6B6B"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    } finally {
        $btnConnect.IsEnabled = $true
    }
})

$btnClassicRDP.Add_Click({
    try {
        $comp = $txtComputerName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($comp)) { 
            [System.Windows.MessageBox]::Show("Veuillez entrer une cible avant de lancer RDP.", "Erreur", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return 
        }
        
        $lblStatus.Content = "Lancement RDP classique vers $comp..."
        [System.Windows.Forms.Application]::DoEvents()
        
        $Script:CurrentTarget = Resolve-ComputerNameToIP $comp
        Start-ClassicRDP -ComputerTarget $Script:CurrentTarget
        
        $lblStatus.Content = "Prêt"
        $lblStatus.Background = "#FF007ACC"
    } catch {
        [System.Windows.MessageBox]::Show("Erreur lors du lancement de mstsc : $($_.Exception.Message)", "Erreur", 'OK', 'Error')
    }
})

$txtComputerName.Add_KeyDown({
    if ($_.Key -eq 'Return') {
        $btnConnect.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
})

$dgSessions.Add_SelectionChanged({ 
    $btnLaunch.IsEnabled = ($dgSessions.SelectedItem -ne $null) 
})

$btnLaunch.Add_Click({
    $sel = $dgSessions.SelectedItem
    if ($sel -eq $null) { return }
    
    $mode = if ($rbView.IsChecked) { 'View' } elseif ($rbControl.IsChecked) { 'Control' } else { 'NoConsent' }
    
    if ($mode -eq 'NoConsent') {
        $confirm = [System.Windows.MessageBox]::Show("Prendre le contrôle forcé sans le consentement de l'utilisateur ?", "Avertissement", 'YesNo', 'Warning')
        if ($confirm -eq 'No') { return }
    }
    
    $lblStatus.Content = "Lancement Shadow sur $($sel.Utilisateur)..."
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        Start-ShadowSession -ComputerTarget $Script:CurrentTarget -SessionID $sel.ID -Mode $mode
        $lblStatus.Content = "Prêt"
        $lblStatus.Background = "#FF007ACC"
    } catch {
        [System.Windows.MessageBox]::Show("Erreur lors du lancement de mstsc : $($_.Exception.Message)", "Erreur", 'OK', 'Error')
    }
})

# ============================================================================
# LANCEMENT
# ============================================================================
$window.ShowDialog() | Out-Null