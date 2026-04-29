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
# IMPORTS & ECRAN DE CHARGEMENT (SPLASH SCREEN)
# ============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Creation d'une petite fenetre instantanee pour faire patienter l'utilisateur
$splash = New-Object System.Windows.Forms.Form
$splash.Size = New-Object System.Drawing.Size(400, 80)
$splash.StartPosition = "CenterScreen"
$splash.FormBorderStyle = "None"
$splash.BackColor = [System.Drawing.Color]::FromArgb(255, 0, 120, 212) # Bleu DSI
$splash.TopMost = $true

$splashLabel = New-Object System.Windows.Forms.Label
$splashLabel.Text = "Lancement de l'Assistant RDP, veuillez patienter..."
$splashLabel.ForeColor = [System.Drawing.Color]::White
$splashLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$splashLabel.Dock = "Fill"
$splashLabel.TextAlign = "MiddleCenter"

$splash.Controls.Add($splashLabel)
$splash.Show()
$splash.Refresh() # Force l'affichage immediat

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

function Test-HostReachable {
    param([string]$ComputerName)
    try {
        return (New-Object System.Net.NetworkInformation.Ping).Send($ComputerName, 1500).Status -eq 'Success'
    }
    catch { return $false }
}

function Resolve-ComputerNameToIP {
    param([string]$ComputerName)
    if ($ComputerName -match '^(\d{1,3}\.){3}\d{1,3}$') { return $ComputerName }
    try {
        $ipv4 = [System.Net.Dns]::GetHostEntry($ComputerName).AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($ipv4) { return $ipv4.IPAddressToString }
    }
    catch {}
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
    
    $lines = $output -split "`r?`n" | Where-Object { $_ -match '\S' }
    if ($lines.Count -lt 2) { return @() }
    
    # Parsing robuste basé sur la position des colonnes
    $header = $lines[0]
    $idxUser = $header.IndexOf("USERNAME")
    if ($idxUser -lt 0) { $idxUser = $header.IndexOf("UTILISATEUR") }
    $idxId = $header.IndexOf("ID")
    $idxState = $header.IndexOf("STATE")
    if ($idxState -lt 0) { $idxState = $header.IndexOf("ÉTAT") }
    if ($idxState -lt 0) { $idxState = $header.IndexOf("ETAT") }
    
    if ($idxUser -lt 0 -or $idxId -lt 0 -or $idxState -lt 0) { throw "Format de réponse qwinsta non reconnu." }
    
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        $sessionName = $line.Substring(0, [math]::Min($idxUser, $line.Length)).Trim()
        
        $username = ""
        if ($line.Length -gt $idxUser) {
            $username = $line.Substring($idxUser, [math]::Min($idxId - $idxUser, $line.Length - $idxUser)).Trim()
        }
        
        $idStr = ""
        if ($line.Length -gt $idxId) {
            $idStr = $line.Substring($idxId, [math]::Min($idxState - $idxId, $line.Length - $idxId)).Trim()
        }
        
        $state = ""
        if ($line.Length -gt $idxState) {
            $state = $line.Substring($idxState).Trim() -split '\s+' | Select-Object -First 1
        }
        
        if ($idStr -match '^\d+$') {
            $sessions += [PSCustomObject]@{
                SessionName = if ($sessionName) { $sessionName } else { "-" }
                Utilisateur = if ([string]::IsNullOrWhiteSpace($username)) { "-" } else { $username }
                ID          = [int]$idStr
                Etat        = $state
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
    Start-Process "mstsc.exe" -ArgumentList "/v:$ComputerTarget"
}

function Get-NetworkScanTargets {
    param([string]$SubnetBase)

    if ([string]::IsNullOrWhiteSpace($SubnetBase)) {
        throw "Veuillez entrer un sous-réseau au format x.x.x (ex: 192.168.1)."
    }

    if ($SubnetBase -notmatch '^(\d{1,3}\.){2}\d{1,3}$') {
        throw "Format de sous-réseau invalide. Exemple attendu: 192.168.1"
    }

    $octets = $SubnetBase.Split('.')
    foreach ($octet in $octets) {
        if ([int]$octet -lt 0 -or [int]$octet -gt 255) {
            throw "Le sous-réseau contient un octet hors plage (0-255)."
        }
    }

    return (1..254 | ForEach-Object { "$SubnetBase.$_" })
}

function Resolve-HostNameFromIP {
    param([string]$IPAddress)
    try {
        return [System.Net.Dns]::GetHostEntry($IPAddress).HostName
    }
    catch {
        return "-"
    }
}

# ============================================================================
# INTERFACE GRAPHIQUE WPF
# ============================================================================

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Remote Desktop Assistant - DSI" Height="700" Width="980"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E1E">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,15">
            <Label Content="Assistant RDP Shadow, Classique et Scan Réseau" Foreground="White" FontSize="22" FontWeight="Bold"/>
            <Label Content="Mode : Connecté au Domaine | Exécuté en tant qu'Administrateur" Foreground="#FF4EC9B0" FontSize="12"/>
        </StackPanel>

        <TabControl Grid.Row="1" Background="#FF252526" BorderBrush="#FF3F3F46" Foreground="White">
            <TabItem Header="Assistant RDP" Background="#FF252526">
                <Grid Margin="15">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Background="#FF252526" Padding="15" CornerRadius="5" Margin="0,0,0,15">
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

                    <Border Grid.Row="1" Background="#FF252526" Padding="15" CornerRadius="5" Margin="0,0,0,15">
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

                    <Border Grid.Row="2" Background="#FF252526" Padding="15" CornerRadius="5">
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
                </Grid>
            </TabItem>

            <TabItem Header="Scan réseau" Background="#FF252526">
                <Grid Margin="15">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <Border Grid.Row="0" Background="#FF252526" Padding="15" CornerRadius="5" Margin="0,0,0,15">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0" Margin="0,0,15,0">
                                <Label Content="Sous-réseau (format x.x.x) :" Foreground="#FFCCCCCC" FontSize="14"/>
                                <TextBox Name="txtSubnetBase" Background="#FF2D2D30" Foreground="White" FontSize="14" Padding="10" Margin="0,5,0,0" BorderBrush="#FF3F3F46" Text="192.168.1"/>
                            </StackPanel>

                            <Button Name="btnScanNetwork" Grid.Column="1" Content="Scanner"
                                    Background="#FF0078D4" Foreground="White" FontSize="13" FontWeight="Bold"
                                    Padding="18,0" Margin="0,32,10,0" BorderThickness="0" Cursor="Hand"/>

                            <Button Name="btnUseSelectedHost" Grid.Column="2" Content="Utiliser la sélection"
                                    Background="#FF4CAF50" Foreground="White" FontSize="13" FontWeight="Bold"
                                    Padding="18,0" Margin="0,32,0,0" BorderThickness="0" Cursor="Hand"/>
                        </Grid>
                    </Border>

                    <Border Grid.Row="1" Background="#FF252526" Padding="15" CornerRadius="5">
                        <DataGrid Name="dgNetworkScan" AutoGenerateColumns="False" IsReadOnly="True"
                                  Background="#FF2D2D30" Foreground="White" HeadersVisibility="Column"
                                  RowBackground="#FF2D2D30" AlternatingRowBackground="#FF333337"
                                  BorderBrush="#FF3F3F46" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#FF3F3F46">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="IP" Binding="{Binding IPAddress}" Width="190"/>
                                <DataGridTextColumn Header="Nom d'hôte" Binding="{Binding HostName}" Width="*"/>
                                <DataGridTextColumn Header="Statut" Binding="{Binding Status}" Width="120"/>
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
                </Grid>
            </TabItem>
        </TabControl>

        <Border Grid.Row="2" Background="#FF007ACC" Padding="10" CornerRadius="3" Margin="0,15,0,0">
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
$txtSubnetBase = $window.FindName("txtSubnetBase")
$btnScanNetwork = $window.FindName("btnScanNetwork")
$btnUseSelectedHost = $window.FindName("btnUseSelectedHost")
$dgNetworkScan = $window.FindName("dgNetworkScan")
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
                [System.Windows.MessageBox]::Show([string]"Aucune session active n'a été trouvée sur le poste.`n`nVous pouvez utiliser le bouton 'RDP Classique' pour ouvrir une session standard sur ce poste.", "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
            else {
                $dgSessions.ItemsSource = $sessions
                $lblStatus.Content = "$($sessions.Count) session(s) trouvée(s)."
                $lblStatus.Background = "#FF4CAF50"
            }
        }
        catch {
            $lblStatus.Content = "Erreur : $($_.Exception.Message)"
            $lblStatus.Background = "#FFFF6B6B"
            [System.Windows.MessageBox]::Show([string]$_.Exception.Message, "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
        finally {
            $btnConnect.IsEnabled = $true
        }
    })

$btnClassicRDP.Add_Click({
        try {
            $comp = $txtComputerName.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($comp)) { 
                [System.Windows.MessageBox]::Show([string]"Veuillez entrer une cible avant de lancer RDP.", "Erreur", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return 
            }
        
            $lblStatus.Content = "Lancement RDP classique vers $comp..."
            [System.Windows.Forms.Application]::DoEvents()
        
            $Script:CurrentTarget = Resolve-ComputerNameToIP $comp
            Start-ClassicRDP -ComputerTarget $Script:CurrentTarget
        
            $lblStatus.Content = "Prêt"
            $lblStatus.Background = "#FF007ACC"
        }
        catch {
            [System.Windows.MessageBox]::Show([string]"Erreur lors du lancement de mstsc : $($_.Exception.Message)", "Erreur", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
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
            $confirm = [System.Windows.MessageBox]::Show([string]"Prendre le contrôle forcé sans le consentement de l'utilisateur ?", "Avertissement", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($confirm -eq 'No') { return }
        }
    
        $lblStatus.Content = "Lancement Shadow sur $($sel.Utilisateur)..."
        [System.Windows.Forms.Application]::DoEvents()
    
        try {
            Start-ShadowSession -ComputerTarget $Script:CurrentTarget -SessionID $sel.ID -Mode $mode
            $lblStatus.Content = "Prêt"
            $lblStatus.Background = "#FF007ACC"
        }
        catch {
            [System.Windows.MessageBox]::Show([string]"Erreur lors du lancement de mstsc : $($_.Exception.Message)", "Erreur", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    })

$btnScanNetwork.Add_Click({
        $btnScanNetwork.IsEnabled = $false
        $dgNetworkScan.ItemsSource = $null

        try {
            $subnetBase = $txtSubnetBase.Text.Trim()
            $targets = Get-NetworkScanTargets -SubnetBase $subnetBase
            $results = New-Object System.Collections.Generic.List[object]

            $lblStatus.Content = "Scan réseau en cours sur $subnetBase.0/24..."
            $lblStatus.Background = "#FFFF9800"
            [System.Windows.Forms.Application]::DoEvents()

            $total = $targets.Count
            for ($i = 0; $i -lt $total; $i++) {
                $ip = $targets[$i]
                if (($i % 20) -eq 0) {
                    $lblStatus.Content = "Scan réseau : $($i + 1)/$total"
                    [System.Windows.Forms.Application]::DoEvents()
                }

                $online = Test-HostReachable -ComputerName $ip
                if ($online) {
                    $hostname = Resolve-HostNameFromIP -IPAddress $ip
                    $results.Add([PSCustomObject]@{
                        IPAddress = $ip
                        HostName  = $hostname
                        Status    = "En ligne"
                    })
                }
            }

            $orderedResults = $results | Sort-Object IPAddress
            $dgNetworkScan.ItemsSource = $orderedResults
            $lblStatus.Content = "Scan terminé : $($results.Count) hôte(s) en ligne."
            $lblStatus.Background = "#FF4CAF50"
        }
        catch {
            $lblStatus.Content = "Erreur scan : $($_.Exception.Message)"
            $lblStatus.Background = "#FFFF6B6B"
            [System.Windows.MessageBox]::Show([string]$_.Exception.Message, "Erreur Scan Réseau", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
        finally {
            $btnScanNetwork.IsEnabled = $true
        }
    })

$btnUseSelectedHost.Add_Click({
        $selectedHost = $dgNetworkScan.SelectedItem
        if ($null -eq $selectedHost) {
            [System.Windows.MessageBox]::Show([string]"Sélectionnez un hôte dans les résultats du scan.", "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }

        $txtComputerName.Text = $selectedHost.IPAddress
        $lblStatus.Content = "Cible RDP mise à jour avec $($selectedHost.IPAddress)."
        $lblStatus.Background = "#FF007ACC"
    })

# ============================================================================
# LANCEMENT
# ============================================================================

# On ferme l'ecran de chargement juste avant d'afficher la vraie fenetre
$splash.Close()
$window.ShowDialog() | Out-Null
