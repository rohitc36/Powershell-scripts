# Input Variables
$targetGroupName = "Intune.Win.WKS.APPS.Nexaweb.Launcher.en-US.1.4.2.0008.Required" # Target Azure AD group
$sourceGroupNames = @(
    "Nexaweb_Launcher_en-US_1.4.2.0008.Required.CETS",
    "Another_Source_Group_1",
    "Another_Source_Group_2"
) # List of source AD groups

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
                Write-Host "Adding device ID $($device.ObjectId) to group $targetGroupName"
                try {
                    Add-AzureADGroupMember -ObjectId $targetGroupId -RefObjectId $device.ObjectId
                } catch {
                    Write-Warning "Failed to add device $deviceName with ID $($device.ObjectId): $_"
                }
            }
        } else {
            Write-Warning "Device $deviceName not found in Azure AD."
        }
    }
}

Write-Host "`nScript execution completed. Total devices processed: $currentDevice"
