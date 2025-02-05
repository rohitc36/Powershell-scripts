# Import the AzureAD module
Import-Module AzureAD

# Connect to Azure AD
Connect-AzureAD

# Function to generate a random string of specified length
function Generate-RandomString {
    param ($length)

    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    $string = -join ((1..$length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $string
}

# Function to generate the mail nickname in the required format
function Generate-MailNickname {
    $part1 = Generate-RandomString -length 8
    $part2 = Get-Random -Minimum 0 -Maximum 10
    return "$part1-$part2"
}

# Read the CSV file
$groups = Import-Csv -Path "C:\Path\groups.csv"

# Loop through each group and create it
foreach ($group in $groups) {
    if (![string]::IsNullOrEmpty($group.GroupName)) {
        # Generate the MailNickname in the required format
        $mailNickname = Generate-MailNickname
        
        New-AzureADGroup -DisplayName $group.GroupName -MailNickname $mailNickname -MailEnabled $false -SecurityEnabled $true
        Write-Output "Created group: $($group.GroupName) with MailNickname: $mailNickname"
    } else {
        Write-Output "Skipped empty or null group name"
    }
}

# Disconnect from Azure AD
Disconnect-AzureAD

