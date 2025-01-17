# Install AzureAD module if not already installed
Install-Module -Name AzureAD -Force -AllowClobber

# Import the AzureAD module
Import-Module AzureAD

# Connect to Azure AD
Connect-AzureAD

# Define the path to the input file and output file
$inputFilePath = "C:\data\useremails.txt"
$outputFilePath = "C:\data\device_details.csv"

# Read the list of user emails
$userEmails = Get-Content -Path $inputFilePath

# Initialize an array to store device details
$deviceDetails = @()

# Loop through each email and get device details
foreach ($userEmail in $userEmails) {
    # Get the user object
    $user = Get-AzureADUser -Filter "UserPrincipalName eq '$userEmail'"
    
    if ($user) {
        # Get the device details for the user
        $devices = Get-AzureADUserRegisteredDevice -ObjectId $user.ObjectId
        
        # Add device details to the array
        foreach ($device in $devices) {
            $deviceDetails += [PSCustomObject]@{
                UserEmail       = $userEmail
                DisplayName     = $device.DisplayName
                DeviceId        = $device.DeviceId
                DeviceOSType    = $device.DeviceOSType
                DeviceOSVersion = $device.DeviceOSVersion
            }
        }
    } else {
        Write-Host "User not found: $userEmail"
    }
}

# Export the device details to a CSV file
$deviceDetails | Export-Csv -Path $outputFilePath -NoTypeInformation

Write-Host "Device details exported to $outputFilePath"
