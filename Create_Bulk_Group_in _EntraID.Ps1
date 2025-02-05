# Import the AzureAD module
Import-Module AzureAD

# Connect to Azure AD
Connect-AzureAD

# Read the CSV file
$groups = Import-Csv -Path "C:\Path\To\Your\groups.csv"

# Loop through each group and create it
foreach ($group in $groups) {
    New-AzureADGroup -DisplayName $group.GroupName -MailNickname $group.GroupName -MailEnabled $false -SecurityEnabled $true
    Write-Output "Created group: $($group.GroupName)"
}

# Disconnect from Azure AD
Disconnect-AzureAD
