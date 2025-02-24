# Input Variables
$csvPath = "C:\Path\Devices.csv" # Replace with the path to your CSV file
$groupId = "8df9ea54-7e7a-4d6b-8b7e-70f4fe495f64" # Replace with your group ID

# Install the AzureAD module if not already installed
if (-not (Get-Module -ListAvailable -Name AzureAD)) {
    Install-Module -Name AzureAD -Force
}

# Connect to Azure AD
Connect-AzureAD

# Import device names from the CSV file
Write-Host "Importing device names from CSV file: $csvPath"
$deviceNames = Import-Csv -Path $csvPath | Select-Object -ExpandProperty DeviceName

# Retrieve the device IDs for the specified device names with progress count
$totalDevices = $deviceNames.Count
$currentDevice = 0
$deviceIds = foreach ($deviceName in $deviceNames) {
    $currentDevice++
    Write-Host "Retrieving device ID for device name: $deviceName ($currentDevice of $totalDevices)"
    Get-AzureADDevice -SearchString $deviceName | Select-Object -ExpandProperty ObjectId
}

# Using the specified group ID
Write-Host "Using group ID: $groupId"

# Remove each device from the specified group with progress count
$currentDevice = 0
foreach ($deviceId in $deviceIds) {
    $currentDevice++
    Write-Host "Removing device ID $deviceId from group $groupId ($currentDevice of $totalDevices)"
    Remove-AzureADGroupMember -ObjectId $groupId -MemberId $deviceId
}

Write-Host "Script execution completed. Total devices processed: $totalDevices"