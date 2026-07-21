$RegPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
$ValueName = "RestartNotificationsAllowed2"

# Create path if missing
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
}

# Enable "Notify me when a restart is required to finish updating"
New-ItemProperty `
    -Path $RegPath `
    -Name $ValueName `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null

Write-Host "Restart notification toggle enabled."
