# Input Variables
$csvPath = "C:\Path\Devices.csv" # Replace with the path to your CSV file
$groupName = "Intune.Win.WKS.APPS.Citrix.Workspace.en-US.24.2.3000.3016.Required" # Replace with your group name

# Define log file path in the same directory as the script
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path $scriptPath
$logFile = Join-Path $scriptDir "Device_Addition_Log.log"

# Initialize log file
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Starting device addition process..." | Out-File -FilePath $logFile -Encoding UTF8

# Install the AzureAD module if not already installed
if (-not (Get-Module -ListAvailable -Name AzureAD)) {
    Install-Module -Name AzureAD -Force
}

# Connect to Azure AD
Connect-AzureAD

# Retrieve the group ID from the group name
Write-Host "Retrieving group ID for group name: $groupName"
$groupId = (Get-AzureADGroup -Filter "DisplayName eq '$groupName'").ObjectId
Write-Host "This is group ID for group name: $groupId"

Read-Host "Please press enter to continue" 

# Import device names from the CSV file
Write-Host "Importing device names from CSV file: $csvPath"
$deviceNames = Import-Csv -Path $csvPath | Select-Object -ExpandProperty DeviceName

# Retrieve and add device IDs
$totalDevices = $deviceNames.Count
$currentDevice = 0

foreach ($deviceName in $deviceNames) {
    $currentDevice++
    Write-Host "Retrieving device IDs for device name: $deviceName ($currentDevice of $totalDevices)"
    
    $devices = Get-AzureADDevice -SearchString $deviceName | Where-Object { $_.DisplayName -eq $deviceName }

    if ($devices) {
        foreach ($device in $devices) {
            try {
                Add-AzureADGroupMember -ObjectId $groupId -RefObjectId $device.ObjectId
                $status = "Success"
            } catch {
                $status = "Failed: $($_.Exception.Message)"
                Write-Warning "Failed to add device $deviceName with ID $($device.ObjectId): $_"
            }
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Group: $groupName | Device: $deviceName | Status: $status" | Out-File -FilePath $logFile -Append -Encoding UTF8
        }
    } else {
        $status = "Failed: Device not found in Azure AD"
        Write-Warning "Device $deviceName not found in Azure AD."
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Group: $groupName | Device: $deviceName | Status: $status" | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

Write-Host "`nScript execution completed. Total devices processed: $currentDevice"
Write-Host "Log file saved to: $logFile"
