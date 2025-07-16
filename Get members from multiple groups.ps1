Connect-AzureAD

# List of Azure AD Group IDs
$groupIds = @(
    "59fa1e54-17e0-48cf-87d7-8dfc431f5e7c",
 
"502f39fc-e8ca-4468-b92c-6a7acf7f354e",
 
"c7d19d2a-0d7d-4302-8d96-298b64f4533e",
 
"b8eb74c5-e5d3-4bd9-861f-da39a722f19b",
 
"aff5dfd1-d425-4c0e-8985-ea52d66a5552",
 
"0fb48cb2-fec3-474a-bcbb-f38455e7c45a",
 
"e6782f1b-57c8-4d8f-840a-cc2123e47ef4",
 
"d5e7249d-fb9e-4334-87ae-ed2e27b6fe0e",


"00845789-278b-48ab-bd8c-0f83de233c3c",
"0fb48cb2-fec3-474a-bcbb-f38455e7c45a",
 
"ed9f4053-84ac-46d0-9954-eaf0f889a3b8"
 
 
)

# Initialize an array to collect all members
$allMembers = @()

foreach ($groupId in $groupIds) {
    $group = Get-AzureADGroup -ObjectId $groupId
    $members = Get-AzureADGroupMember -ObjectId $groupId -All $true

    foreach ($member in $members) {
        $allMembers += [PSCustomObject]@{
            GroupName         = $group.DisplayName
            GroupId           = $group.ObjectId
            DisplayName       = $member.DisplayName
            UserPrincipalName = $member.UserPrincipalName
            ObjectId          = $member.ObjectId
        }
    }
}

# Export to CSV
$allMembers | Export-Csv -Path "C:\path\AzureADGroupMembers.csv" -NoTypeInformation

Write-Host "Export completed: AzureADGroupMembers.csv"
