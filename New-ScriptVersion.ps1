[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile,

    [string]$DestinationDirectory = ".",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-VersionedCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [string]$BaseNameNoExt,
        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $escapedBase = [Regex]::Escape($BaseNameNoExt)
    $escapedExt = [Regex]::Escape($Extension)
    $pattern = "^{0}V(?<major>\d+)\.(?<minor>\d+){1}$" -f $escapedBase, $escapedExt

    Get-ChildItem -Path $Directory -File |
        Where-Object { $_.Name -match $pattern } |
        ForEach-Object {
            [PSCustomObject]@{
                FileInfo = $_
                Major = [int]$matches.major
                Minor = [int]$matches.minor
            }
        }
}

function Get-NextVersionPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [string]$BaseNameNoExt,
        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $versions = Get-VersionedCandidates -Directory $Directory -BaseNameNoExt $BaseNameNoExt -Extension $Extension

    if (-not $versions) {
        return Join-Path -Path $Directory -ChildPath ("{0}V1.0{1}" -f $BaseNameNoExt, $Extension)
    }

    $latest = $versions | Sort-Object -Property Major, Minor | Select-Object -Last 1
    $nextMajor = $latest.Major
    $nextMinor = $latest.Minor + 1
    return Join-Path -Path $Directory -ChildPath ("{0}V{1}.{2}{3}" -f $BaseNameNoExt, $nextMajor, $nextMinor, $Extension)
}

$sourcePath = (Resolve-Path -LiteralPath $SourceFile).Path
$destinationPath = (Resolve-Path -LiteralPath $DestinationDirectory).Path

$sourceItem = Get-Item -LiteralPath $sourcePath
$baseNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($sourceItem.Name)
$extension = $sourceItem.Extension

# Si la source est deja versionnee, on retire le suffixe Vx.y pour le calcul de la prochaine version.
if ($baseNameNoExt -match "^(?<base>.*)V\d+\.\d+$") {
    $baseNameNoExt = $matches.base
}

$latestVersionFile = Get-VersionedCandidates -Directory $destinationPath -BaseNameNoExt $baseNameNoExt -Extension $extension |
    Sort-Object -Property Major, Minor |
    Select-Object -Last 1

if ($latestVersionFile -and -not $Force) {
    $srcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
    $latestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $latestVersionFile.FileInfo.FullName).Hash
    if ($srcHash -eq $latestHash) {
        Write-Host "Aucune nouvelle version creee: contenu identique a $($latestVersionFile.FileInfo.Name)"
        exit 0
    }
}

$nextPath = Get-NextVersionPath -Directory $destinationPath -BaseNameNoExt $baseNameNoExt -Extension $extension
Copy-Item -LiteralPath $sourcePath -Destination $nextPath -Force
Write-Host "Nouvelle version creee: $nextPath"
