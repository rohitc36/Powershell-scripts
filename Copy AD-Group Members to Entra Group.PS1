# Input Variables
$targetGroupName = "Intune.Win.WKS.APPS.Nexaweb.Launcher.en-US.1.4.2.0008.Required"
$sourceGroupNames = @(
    "Nexaweb_Launcher_en-US_1.4.2.0008.Required.CETS",
    "Another_Source_Group_1",
    "Another_Source_Group_2"
)

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

# Retrieve the group ID for the target group
Write-Host "Retrieving group ID for target group name: $targetGroupName"
$targetGroupId = (Get-AzureADGroup -Filter "DisplayName eq '$targetGroupName'").ObjectId
Write-Host "Target group ID: $targetGroupId"

Read-Host "Please press enter to continue"

$totalDevices = 0
$currentDevice = 0

foreach ($sourceGroupName in $sourceGroupNames) {
    Write-Host "`nProcessing source group: $sourceGroupName"
    
    $members = Get-ADGroupMember -Identity $sourceGroupName -Recursive | Where-Object { $_.ObjectClass -eq "computer" }
    $totalDevices += $members.Count

    foreach ($member in $members) {
        $currentDevice++
        $deviceName = $member.Name
        Write-Host "Retrieving device IDs for device name: $deviceName ($currentDevice of $totalDevices)"
        
        $devices = Get-AzureADDevice -SearchString $deviceName | Where-Object { $_.DisplayName -eq $deviceName }

        if ($devices) {
            foreach ($device in $devices) {
                try {
                    Add-AzureADGroupMember -ObjectId $targetGroupId -RefObjectId $device.ObjectId
                    $status = "Success"
                } catch {
                    $status = "Failed: $($_.Exception.Message)"
                    Write-Warning "Failed to add device $deviceName with ID $($device.ObjectId): $_"
                }
                "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Group: $sourceGroupName | Device: $deviceName | Status: $status" | Out-File -FilePath $logFile -Append -Encoding UTF8
            }
        } else {
            $status = "Failed: Device not found in Azure AD"
            Write-Warning "Device $deviceName not found in Azure AD."
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Group: $sourceGroupName | Device: $deviceName | Status: $status" | Out-File -FilePath $logFile -Append -Encoding UTF8
        }
    }
}

Write-Host "`nScript execution completed. Total devices processed: $currentDevice"
Write-Host "Log file saved to: $logFile"
