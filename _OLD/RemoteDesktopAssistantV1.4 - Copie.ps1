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
$splash.Size = New-Object System.Drawing.Size(520, 120)
$splash.StartPosition = "CenterScreen"
$splash.FormBorderStyle = "None"
$splash.BackColor = [System.Drawing.Color]::FromArgb(255, 10, 18, 32)
$splash.TopMost = $true

$splashLabel = New-Object System.Windows.Forms.Label
$splashLabel.Text = "Remote Desktop Assistant`r`nInitialisation de la console RDP..."
$splashLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 226, 242, 255)
$splashLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
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

function Convert-IPToUInt32 {
    param([string]$IPAddress)
    $ipObj = [System.Net.IPAddress]::Parse($IPAddress)
    $bytes = $ipObj.GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIP {
    param([uint32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-NetworkScanTargets {
    param([string]$Cidr)

    if ([string]::IsNullOrWhiteSpace($Cidr)) {
        throw "Veuillez entrer un reseau au format x.x.x.x/x (ex: 192.168.1.0/24)."
    }

    $normalizedInput = $Cidr.Trim()
    if ($normalizedInput -match '^(\d{1,3}\.){3}\d{1,3}$') {
        $normalizedInput = "$normalizedInput/24"
    }
    elseif ($normalizedInput -match '^(\d{1,3}\.){2}\d{1,3}\.?$') {
        $normalizedInput = ($normalizedInput.TrimEnd('.') + ".0/24")
    }

    if ($normalizedInput -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
        throw "Format invalide. Exemples acceptes: 192.168.1.0/24, 192.168.1.0 ou 192.168.1"
    }

    $parts = $normalizedInput.Split('/')
    $ipPart = $parts[0]
    $prefix = [int]$parts[1]

    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "Prefixe CIDR invalide (0-32)."
    }

    $octets = $ipPart.Split('.')
    foreach ($octet in $octets) {
        if ([int]$octet -lt 0 -or [int]$octet -gt 255) {
            throw "L'adresse IP contient un octet hors plage (0-255)."
        }
    }

    $ipValue = Convert-IPToUInt32 -IPAddress $ipPart
    $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }
    $network = $ipValue -band $mask
    $broadcast = $network -bor ([uint32]::MaxValue -bxor $mask)

    if ($prefix -ge 31) {
        return @(Convert-UInt32ToIP -Value $network)
    }

    $targets = New-Object System.Collections.Generic.List[string]
    for ($value = ($network + 1); $value -lt $broadcast; $value++) {
        $targets.Add((Convert-UInt32ToIP -Value $value))
    }
    return $targets
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

function Get-ExceptionText {
    param([object]$ErrorObject)

    if ($null -eq $ErrorObject) { return "Erreur inconnue (objet nul)." }

    if ($ErrorObject -is [System.Exception]) {
        if (-not [string]::IsNullOrWhiteSpace($ErrorObject.Message)) { return $ErrorObject.Message }
        return $ErrorObject.ToString()
    }

    if ($ErrorObject.PSObject.Properties.Name -contains "Exception" -and $null -ne $ErrorObject.Exception) {
        if (-not [string]::IsNullOrWhiteSpace($ErrorObject.Exception.Message)) { return $ErrorObject.Exception.Message }
        return $ErrorObject.Exception.ToString()
    }

    return $ErrorObject.ToString()
}

function Write-ScanLog {
    param([string]$Text)
    try {
        $logPath = Join-Path $env:TEMP "RemoteDesktopAssistant-scan.log"
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
        Add-Content -Path $logPath -Value $line -Encoding UTF8
    }
    catch {}
}

# ============================================================================
# INTERFACE GRAPHIQUE WPF
# ============================================================================

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Remote Desktop Assistant - DSI" Height="760" Width="1080" MinHeight="700" MinWidth="960"
        WindowStartupLocation="CenterScreen" Background="#0B1120" FontFamily="Segoe UI Variable Display, Segoe UI"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <SolidColorBrush x:Key="Surface" Color="#101827"/>
        <SolidColorBrush x:Key="SurfaceSoft" Color="#162235"/>
        <SolidColorBrush x:Key="SurfaceRaised" Color="#1C2B41"/>
        <SolidColorBrush x:Key="Stroke" Color="#2D405C"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#F7FAFC"/>
        <SolidColorBrush x:Key="TextMuted" Color="#A9B8CC"/>
        <SolidColorBrush x:Key="Accent" Color="#38BDF8"/>
        <SolidColorBrush x:Key="AccentStrong" Color="#0284C7"/>
        <SolidColorBrush x:Key="Success" Color="#22C55E"/>
        <SolidColorBrush x:Key="Danger" Color="#FB7185"/>
        <SolidColorBrush x:Key="Warning" Color="#F59E0B"/>

        <LinearGradientBrush x:Key="PageBackground" StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#08111F" Offset="0"/>
            <GradientStop Color="#10233A" Offset="0.48"/>
            <GradientStop Color="#071827" Offset="1"/>
        </LinearGradientBrush>

        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource Surface}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="18"/>
            <Setter Property="Padding" Value="18"/>
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect BlurRadius="22" ShadowDepth="8" Opacity="0.22" Color="#000000"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#0D1726"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="Padding" Value="14,10"/>
            <Setter Property="MinHeight" Value="44"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="12">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{StaticResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Border" Property="Opacity" Value="0.55"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="{StaticResource AccentStrong}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="18,0"/>
            <Setter Property="MinHeight" Value="44"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="13">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonChrome" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonChrome" Property="RenderTransformOrigin" Value="0.5,0.5"/>
                                <Setter TargetName="ButtonChrome" Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.98" ScaleY="0.98"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonChrome" Property="Background" Value="#334155"/>
                                <Setter Property="Foreground" Value="#94A3B8"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" BasedOn="{StaticResource ModernButton}"/>

        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Margin" Value="0,0,18,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="TabControl">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>

        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="20,11"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="TabChrome" Background="#132035" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="{TemplateBinding Padding}">
                            <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="TabChrome" Property="Background" Value="{StaticResource AccentStrong}"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="TabChrome" Property="BorderBrush" Value="{StaticResource Accent}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="GridLinesVisibility" Value="None"/>
            <Setter Property="RowBackground" Value="#0F1A2B"/>
            <Setter Property="AlternatingRowBackground" Value="#132035"/>
            <Setter Property="HorizontalGridLinesBrush" Value="Transparent"/>
            <Setter Property="VerticalGridLinesBrush" Value="Transparent"/>
        </Style>

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#20344F"/>
            <Setter Property="Foreground" Value="#DCEBFF"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
        </Style>

        <Style TargetType="DataGridCell">
            <Setter Property="Padding" Value="12,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="DataGridRow">
            <Setter Property="MinHeight" Value="38"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1E3A5F"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#075985"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="ProgressBar">
            <Setter Property="Height" Value="14"/>
            <Setter Property="Foreground" Value="{StaticResource Accent}"/>
            <Setter Property="Background" Value="#0D1726"/>
            <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
        </Style>
    </Window.Resources>

    <Grid Background="{StaticResource PageBackground}">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Margin="24,22,24,16" CornerRadius="24" Padding="24" BorderBrush="#28415F" BorderThickness="1">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#11314E" Offset="0"/>
                        <GradientStop Color="#0E2238" Offset="0.56"/>
                        <GradientStop Color="#123C4D" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel>
                        <TextBlock Text="Remote Desktop Assistant" Foreground="White" FontSize="30" FontWeight="Bold"/>
                        <TextBlock Text="Shadow RDP, connexion classique et scan réseau depuis une console unique." Foreground="#C7D7EA" FontSize="14" Margin="0,7,0,0"/>
                    </StackPanel>

                    <Border Grid.Column="1" Background="#183B56" BorderBrush="#3ABFF8" BorderThickness="1" CornerRadius="20" Padding="14,8" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                            <Ellipse Width="8" Height="8" Fill="{StaticResource Success}" Margin="0,0,8,0"/>
                            <TextBlock Text="Domaine + Admin" Foreground="#DDF7FF" FontWeight="SemiBold" FontSize="13"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </Border>

            <TabControl Grid.Row="1" Margin="24,0,24,0">
                <TabItem Header="Assistant RDP">
                    <Grid Margin="0,18,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Style="{StaticResource Card}" Margin="0,0,0,16">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,18,0">
                                    <Label Content="Cible" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="14"/>
                                    <TextBlock Text="Nom de l'ordinateur ou adresse IP" Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,8"/>
                                    <TextBox Name="txtComputerName"/>
                                </StackPanel>

                                <Button Name="btnConnect" Grid.Column="1" Content="Rechercher sessions" Background="{StaticResource AccentStrong}" Margin="0,31,10,0"/>
                                <Button Name="btnClassicRDP" Grid.Column="2" Content="RDP classique" Background="{StaticResource Success}" Margin="0,31,0,0" ToolTip="Ouvrir une session Bureau à distance classique"/>
                            </Grid>
                        </Border>

                        <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,0,16">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                                    <TextBlock Text="Sessions détectées" Foreground="{StaticResource TextPrimary}" FontSize="17" FontWeight="SemiBold"/>
                                    <Border Background="#123954" CornerRadius="20" Padding="9,3" Margin="10,0,0,0">
                                        <TextBlock Text="qwinsta" Foreground="#B9E7FF" FontSize="11" FontWeight="SemiBold"/>
                                    </Border>
                                </StackPanel>
                                <DataGrid Name="dgSessions" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Session" Binding="{Binding SessionName}" Width="160"/>
                                        <DataGridTextColumn Header="Utilisateur" Binding="{Binding Utilisateur}" Width="*"/>
                                        <DataGridTextColumn Header="ID" Binding="{Binding ID}" Width="90"/>
                                        <DataGridTextColumn Header="État" Binding="{Binding Etat}" Width="130"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </Grid>
                        </Border>

                        <Border Grid.Row="2" Style="{StaticResource Card}">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0">
                                    <Label Content="Mode d'intervention Shadow" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="14"/>
                                    <TextBlock Text="Choisissez le niveau d'assistance avant de lancer la prise en main." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,12"/>
                                    <WrapPanel>
                                        <RadioButton Name="rbView" Content="Visualisation" IsChecked="True"/>
                                        <RadioButton Name="rbControl" Content="Contrôle avec accord"/>
                                        <RadioButton Name="rbNoConsent" Content="Forcer le contrôle" Foreground="{StaticResource Danger}"/>
                                    </WrapPanel>
                                </StackPanel>

                                <Button Name="btnLaunch" Grid.Column="1" Content="Lancer l'intervention" Background="{StaticResource AccentStrong}" Width="230" Height="52" Margin="22,0,0,0" IsEnabled="False"/>
                            </Grid>
                        </Border>
                    </Grid>
                </TabItem>

                <TabItem Header="Scan réseau">
                    <Grid Margin="0,18,0,0">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Row="0" Style="{StaticResource Card}" Margin="0,0,0,16">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,18,0">
                                    <Label Content="Plage réseau" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="14"/>
                                    <TextBlock Text="Format CIDR attendu, par exemple 192.168.1.0/24" Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,8"/>
                                    <TextBox Name="txtSubnetBase" Text="192.168.1.0/24"/>
                                </StackPanel>

                                <Button Name="btnScanNetwork" Grid.Column="1" Content="Scanner" Background="{StaticResource AccentStrong}" Margin="0,31,10,0"/>
                                <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,31,0,0">
                                    <Button Name="btnCancelScanNetwork" Content="Annuler" Background="{StaticResource Danger}" Margin="0,0,10,0" IsEnabled="False"/>
                                    <Button Name="btnUseSelectedHost" Content="Utiliser la sélection" Background="{StaticResource Success}"/>
                                </StackPanel>
                            </Grid>
                        </Border>

                        <Border Grid.Row="1" Style="{StaticResource Card}">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="*"/>
                                </Grid.RowDefinitions>
                                <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                                    <TextBlock Text="Hôtes en ligne" Foreground="{StaticResource TextPrimary}" FontSize="17" FontWeight="SemiBold"/>
                                    <Border Background="#173D2A" CornerRadius="20" Padding="9,3" Margin="10,0,0,0">
                                        <TextBlock Text="ping + DNS" Foreground="#BBF7D0" FontSize="11" FontWeight="SemiBold"/>
                                    </Border>
                                </StackPanel>
                                <DataGrid Name="dgNetworkScan" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="IP" Binding="{Binding IPAddress}" Width="190"/>
                                        <DataGridTextColumn Header="Nom d'hôte" Binding="{Binding HostName}" Width="*"/>
                                        <DataGridTextColumn Header="Statut" Binding="{Binding Status}" Width="130"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </Grid>
                        </Border>

                        <Border Grid.Row="2" Style="{StaticResource Card}" Padding="16" Margin="0,16,0,0">
                            <StackPanel>
                                <DockPanel Margin="0,0,0,8">
                                    <Label Name="lblNetworkScanProgress" Content="Progression : 0/254" Foreground="{StaticResource TextMuted}" FontSize="12" DockPanel.Dock="Left"/>
                                    <TextBlock Text="Scan réseau" Foreground="{StaticResource TextMuted}" FontSize="12" HorizontalAlignment="Right"/>
                                </DockPanel>
                                <ProgressBar Name="pbNetworkScan" Minimum="0" Maximum="254" Value="0"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                </TabItem>
            </TabControl>

            <Border Name="brdStatus" Grid.Row="2" Margin="24,16,24,22" Background="#0D2740" BorderBrush="#256B91" BorderThickness="1" CornerRadius="16" Padding="14,12">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Ellipse Width="9" Height="9" Fill="{StaticResource Accent}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                    <Label Name="lblStatus" Grid.Column="1" Content="Prêt - Entrez une cible pour commencer" Foreground="White" FontWeight="SemiBold"/>
                </Grid>
            </Border>
        </Grid>
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
$btnCancelScanNetwork = $window.FindName("btnCancelScanNetwork")
$btnUseSelectedHost = $window.FindName("btnUseSelectedHost")
$dgNetworkScan = $window.FindName("dgNetworkScan")
$pbNetworkScan = $window.FindName("pbNetworkScan")
$lblNetworkScanProgress = $window.FindName("lblNetworkScanProgress")
$lblStatus = $window.FindName("lblStatus")
$brdStatus = $window.FindName("brdStatus")

$Script:CurrentTarget = ""
$Script:NetworkScanInProgress = $false
$Script:NetworkScanCancelled = $false
$Script:NetworkScanTargets = @()
$Script:NetworkScanIndex = 0
$Script:NetworkScanResults = New-Object System.Collections.Generic.List[object]
$Script:NetworkScanTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:NetworkScanTimer.Interval = [TimeSpan]::FromMilliseconds(50)

$Script:NetworkScanTimer.Add_Tick({
        if (-not $Script:NetworkScanInProgress) {
            $Script:NetworkScanTimer.Stop()
            return
        }

        try {
            $total = $Script:NetworkScanTargets.Count
            if ($Script:NetworkScanCancelled) {
                $Script:NetworkScanTimer.Stop()
                $Script:NetworkScanInProgress = $false
                $btnScanNetwork.IsEnabled = $true
                $btnCancelScanNetwork.IsEnabled = $false
                $txtSubnetBase.IsEnabled = $true
                $lblStatus.Content = "Scan annule par l'utilisateur."
                $brdStatus.Background = "#FF007ACC"
                return
            }

            if ($Script:NetworkScanIndex -ge $total) {
                $Script:NetworkScanTimer.Stop()
                $Script:NetworkScanInProgress = $false
                $btnScanNetwork.IsEnabled = $true
                $btnCancelScanNetwork.IsEnabled = $false
                $txtSubnetBase.IsEnabled = $true

                $orderedResults = $Script:NetworkScanResults | Sort-Object IPAddress
                $dgNetworkScan.ItemsSource = $orderedResults
                $lblStatus.Content = "Scan terminé : $($Script:NetworkScanResults.Count) hôte(s) en ligne."
                $brdStatus.Background = "#FF4CAF50"
                $lblNetworkScanProgress.Content = "Progression : $total/$total"
                $pbNetworkScan.Value = $total
                return
            }

            $ip = $Script:NetworkScanTargets[$Script:NetworkScanIndex]
            $isOnline = $false
            try {
                $isOnline = (New-Object System.Net.NetworkInformation.Ping).Send($ip, 800).Status -eq "Success"
            }
            catch {
                $isOnline = $false
            }

            if ($isOnline) {
                $hostName = "-"
                try {
                    $hostName = [System.Net.Dns]::GetHostEntry($ip).HostName
                }
                catch {
                    $hostName = "-"
                }

                $Script:NetworkScanResults.Add([PSCustomObject]@{
                        IPAddress = $ip
                        HostName  = $hostName
                        Status    = "En ligne"
                    })
            }

            $Script:NetworkScanIndex++
            $pbNetworkScan.Value = $Script:NetworkScanIndex
            $lblNetworkScanProgress.Content = "Progression : $($Script:NetworkScanIndex)/$total"
            $lblStatus.Content = "Scan reseau : $($Script:NetworkScanIndex)/$total"
            $brdStatus.Background = "#FFFF9800"
        }
        catch {
            $detail = Get-ExceptionText -ErrorObject $_
            Write-ScanLog -Text ("Erreur timer scan: " + $detail)
            $Script:NetworkScanTimer.Stop()
            $Script:NetworkScanInProgress = $false
            $btnScanNetwork.IsEnabled = $true
            $btnCancelScanNetwork.IsEnabled = $false
            $txtSubnetBase.IsEnabled = $true
            $lblStatus.Content = "Erreur scan : $detail"
            $brdStatus.Background = "#FFFF6B6B"
            [System.Windows.MessageBox]::Show([string]$detail, "Erreur Scan Réseau", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    })

# ============================================================================
# EVENEMENTS
# ============================================================================

$btnConnect.Add_Click({
        $lblStatus.Content = "Recherche en cours..."
        $brdStatus.Background = "#FFFF9800"
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
                $brdStatus.Background = "#FFFF6B6B"
                [System.Windows.MessageBox]::Show([string]"Aucune session active n'a été trouvée sur le poste.`n`nVous pouvez utiliser le bouton 'RDP Classique' pour ouvrir une session standard sur ce poste.", "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
            else {
                $dgSessions.ItemsSource = $sessions
                $lblStatus.Content = "$($sessions.Count) session(s) trouvée(s)."
                $brdStatus.Background = "#FF4CAF50"
            }
        }
        catch {
            $lblStatus.Content = "Erreur : $($_.Exception.Message)"
            $brdStatus.Background = "#FFFF6B6B"
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
            $brdStatus.Background = "#FF007ACC"
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
            $brdStatus.Background = "#FF007ACC"
        }
        catch {
            [System.Windows.MessageBox]::Show([string]"Erreur lors du lancement de mstsc : $($_.Exception.Message)", "Erreur", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    })

$btnScanNetwork.Add_Click({
        if ($Script:NetworkScanInProgress) {
            [System.Windows.MessageBox]::Show([string]"Un scan est déjà en cours.", "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            return
        }

        try {
            $cidr = $txtSubnetBase.Text.Trim()
            $targets = Get-NetworkScanTargets -Cidr $cidr
            if ($targets.Count -eq 0) {
                throw "Aucune IP exploitable dans ce reseau."
            }

            $btnScanNetwork.IsEnabled = $false
            $btnCancelScanNetwork.IsEnabled = $true
            $txtSubnetBase.IsEnabled = $false
            $dgNetworkScan.ItemsSource = $null
            $pbNetworkScan.Maximum = $targets.Count
            $pbNetworkScan.Value = 0
            $lblNetworkScanProgress.Content = "Progression : 0/$($targets.Count)"
            $lblStatus.Content = "Scan reseau en cours sur $cidr..."
            $brdStatus.Background = "#FFFF9800"
            $Script:NetworkScanTargets = $targets
            $Script:NetworkScanIndex = 0
            $Script:NetworkScanResults = New-Object System.Collections.Generic.List[object]
            $Script:NetworkScanCancelled = $false
            $Script:NetworkScanInProgress = $true
            $Script:NetworkScanTimer.Start()
        }
        catch {
            $detail = Get-ExceptionText -ErrorObject $_
            Write-ScanLog -Text ("Erreur clic scan: " + $detail)
            $lblStatus.Content = "Erreur scan : $detail"
            $brdStatus.Background = "#FFFF6B6B"
            [System.Windows.MessageBox]::Show([string]$detail, "Erreur Scan Réseau", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    })

$btnCancelScanNetwork.Add_Click({
        if ($Script:NetworkScanInProgress) {
            $Script:NetworkScanCancelled = $true
            $btnCancelScanNetwork.IsEnabled = $false
            $lblStatus.Content = "Annulation du scan en cours..."
            $brdStatus.Background = "#FFFF9800"
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
        $brdStatus.Background = "#FF007ACC"
    })

# ============================================================================
# LANCEMENT
# ============================================================================

# On ferme l'ecran de chargement juste avant d'afficher la vraie fenetre
$splash.Close()
$window.ShowDialog() | Out-Null


