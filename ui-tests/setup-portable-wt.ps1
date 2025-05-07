# Configures a portable Windows Terminal for the UI tests.
#
# Downloads WT if needed, then creates .portable marker and settings.json
# with exportBuffer bound to Ctrl+Shift+F12. The export file lands in the
# script's own directory (ui-tests/) so it gets uploaded as build artifact.
#
# The portable WT uses its own settings directory (next to the executable)
# so it never touches the user's installed Windows Terminal configuration.

param(
    [string]$WtVersion = $env:WT_VERSION,
    [string]$DestDir = $env:TEMP
)

if (-not $WtVersion) { $WtVersion = '1.22.11141.0' }

$wtDir = "$DestDir\terminal-$WtVersion"
$wtExe = "$wtDir\wt.exe"

# Download if the directory doesn't contain wt.exe yet
if (-not (Test-Path $wtExe)) {
    $wtZip = "$DestDir\wt.zip"
    if (-not (Test-Path $wtZip)) {
        $url = "https://github.com/microsoft/terminal/releases/download/v$WtVersion/Microsoft.WindowsTerminal_${WtVersion}_x64.zip"
        Write-Host "Downloading Windows Terminal $WtVersion ..."
        curl.exe -fLo $wtZip $url
        if ($LASTEXITCODE -ne 0) { throw "Download failed" }
    }
    Write-Host "Extracting ..."
    & "$env:WINDIR\system32\tar.exe" -C $DestDir -xf $wtZip
    if ($LASTEXITCODE -ne 0) { throw "Extract failed" }
}

# Create .portable marker so WT reads settings from settings\ next to wt.exe
$portableMarker = "$wtDir\.portable"
if (-not (Test-Path $portableMarker)) {
    Set-Content -Path $portableMarker -Value ""
}

# Write settings.json with exportBuffer action
$settingsDir = "$wtDir\settings"
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

$bufferExportPath = ($PSScriptRoot + '\wt-buffer-export.txt') -replace '\\', '/'

$settings = @"
{
  "`$schema": "https://aka.ms/terminal-profiles-schema",
  "actions": [
    {
      "command": {
        "action": "exportBuffer",
        "path": "$bufferExportPath"
      },
      "id": "User.TestExportBuffer"
    },
    {
      "command": { "action": "copy", "singleLine": false },
      "id": "User.copy"
    },
    { "command": "paste", "id": "User.paste" }
  ],
  "copyFormatting": "none",
  "copyOnSelect": false,
  "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
  "keybindings": [
    { "id": "User.TestExportBuffer", "keys": "ctrl+shift+f12" },
    { "id": null, "keys": "ctrl+v" },
    { "id": null, "keys": "ctrl+c" }
  ],
  "profiles": {
    "defaults": {},
    "list": [
      {
        "commandline": "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
        "hidden": false,
        "name": "Windows PowerShell"
      }
    ]
  },
  "schemes": [],
  "themes": []
}
"@

Set-Content -Path "$settingsDir\settings.json" -Value $settings

# Add WT to PATH if running in GitHub Actions
if ($env:GITHUB_PATH) {
    $wtDir | Out-File -Append -FilePath $env:GITHUB_PATH
}

Write-Host "Portable WT ready at: $wtDir"
Write-Host "  exportBuffer path: $bufferExportPath"
Write-Host "  exportBuffer key:  Ctrl+Shift+F12"
