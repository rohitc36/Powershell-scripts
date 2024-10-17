This Script is to create a extention attribute

# Import the Active Directory module
Import-Module ActiveDirectory

# Connect to Azure AD
Connect-AzureAD

# Define the time filter for the last 10 minutes
$timeFilter = (Get-Date).AddMinutes(-10)

# Get the devices modified in the last 10 minutes from Active Directory
$devices = Get-ADComputer -Filter {whenChanged -ge $timeFilter}

foreach ($device in $devices) {
    $distinguishedName = $device.DistinguishedName

    # Get the Azure AD device object
    $azureADDevice = Get-AzureADDevice -SearchString $device.Name

    if ($azureADDevice) {
        # Define the custom attribute
        $customAttribute = "extensionAttribute1"  # Replace with your custom attribute name

        # Update the custom attribute with the distinguished name
        Set-AzureADDeviceExtension -ObjectId $azureADDevice.ObjectId -ExtensionName $customAttribute -ExtensionValue $distinguishedName

        Write-Output "Custom attribute for device $($device.Name) updated successfully."
    } else {
        Write-Output "Device $($device.Name) not found in Azure AD."
    }
}

