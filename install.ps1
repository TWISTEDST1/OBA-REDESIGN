<#
.SYNOPSIS
    Installs the OBS Redesign themes for the current Windows user.

.DESCRIPTION
    Copies Prism, Prism Light and Cyber Pink into %APPDATA%\obs-studio\themes.
    Restart OBS Studio afterwards and choose a theme in Settings > Appearance.
#>
$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'themes'
$target = Join-Path $env:APPDATA 'obs-studio\themes'

if (-not (Test-Path $source)) {
    throw "Theme folder not found: $source. Run this script from the repository root."
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

$themes = Get-ChildItem -Path $source -Filter '*.ovt'
foreach ($theme in $themes) {
    Copy-Item -Path $theme.FullName -Destination $target -Force
    Write-Host "  Installed $($theme.Name)"
}

Write-Host ''
Write-Host "Installed $($themes.Count) themes to $target"
if (Get-Process -Name obs64 -ErrorAction SilentlyContinue) {
    Write-Host 'OBS Studio is running. Restart it to load the new themes.'
}
Write-Host 'Then open Settings > Appearance and choose Prism, Prism Light or Cyber Pink.'
