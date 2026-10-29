#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$uiFile = Join-Path $root 'RemoteDesktopAssistantV1.4.ps1'
$gpoFile = Join-Path $root 'Deploy-RDPGPO.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "PASS: $Message"
}
foreach ($file in @($uiFile, $gpoFile)) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "$file : $($errors | ForEach-Object { $_.Message + ' @ ' + $_.Extent.StartLineNumber } | Out-String)"
    }
    Assert-True ($null -ne $ast) ("PowerShell syntax: " + (Split-Path $file -Leaf))
}
$uiText = Get-Content -LiteralPath $uiFile -Raw -Encoding UTF8
$xamlMatch = [regex]::Match($uiText, '(?s)\$xaml = @"\r?\n(?<xaml>.*?)\r?\n"@')
Assert-True $xamlMatch.Success 'WPF XAML found'
[xml]$xaml = $xamlMatch.Groups['xaml'].Value
Assert-True ($xaml.DocumentElement.LocalName -eq 'Window') 'WPF XAML is well-formed'
foreach ($name in @('txtComputerName', 'btnConnect', 'btnClassicRDP', 'btnDiagnose', 'btnFavorite', 'cbFavorites', 'dgSessions', 'dgNetworkScan')) {
    Assert-True ($uiText.Contains('Name="' + $name + '"')) "WPF control $name"
}
$tokens = $null
$errors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiFile, [ref]$tokens, [ref]$errors)
foreach ($name in @('Convert-IPToUInt32', 'Convert-UInt32ToIP', 'Get-NetworkScanTargets', 'Assert-ComputerTarget')) {
    $node = $uiAst.Find({ param($x)
        $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $name
    }, $true)
    Assert-True ($null -ne $node) "Function $name exists"
    Invoke-Expression $node.Extent.Text
}
Assert-True (@(Get-NetworkScanTargets -Cidr '192.168.10.0/24').Count -eq 254) '/24 yields 254 usable hosts'
Assert-True (@(Get-NetworkScanTargets -Cidr '192.168.10.0/22').Count -eq 1022) '/22 is allowed'
Assert-True (@(Get-NetworkScanTargets -Cidr '192.168.10.0/31').Count -eq 2) '/31 yields two point-to-point hosts'
Assert-True (@(Get-NetworkScanTargets -Cidr '192.168.10.15/32').Count -eq 1) '/32 yields one host'
foreach ($cidr in @('0.0.0.0/0', '192.168.1.0/21', '300.1.1.1/24', 'not-a-network')) {
    $rejected = $false
    try { $null = Get-NetworkScanTargets -Cidr $cidr } catch { $rejected = $true }
    Assert-True $rejected "CIDR invalid/oversized rejected: $cidr"
}
foreach ($target in @('PC-001', 'pc.example.local', '192.168.1.15')) {
    Assert-ComputerTarget -ComputerName $target
}
foreach ($target in @('', '/shadow:4', 'server /admin', 'foo"bar')) {
    $rejected = $false
    try { Assert-ComputerTarget -ComputerName $target } catch { $rejected = $true }
    Assert-True $rejected "unsafe target rejected: $target"
}

$gpoText = Get-Content -LiteralPath $gpoFile -Raw -Encoding UTF8
Assert-True ($gpoText.Contains('Save-DeploymentBackup')) 'GPO snapshots original configuration'
Assert-True ($gpoText.Contains('Restore-DeploymentBackup')) 'GPO restores original configuration'
Assert-True (-not $gpoText.Contains("Set-FirewallRules -NamePatterns $patterns -RemoteAddress 'Any' -Disable")) 'Uninstall does not blindly disable system firewall groups'
Write-Host 'All static and CIDR smoke checks passed.'
