# Ensure required modules are available
Import-Module GroupPolicy
Import-Module ActiveDirectory

# Optional: Install ImportExcel module if not already installed
# Install-Module -Name ImportExcel -Scope CurrentUser -Force

# Set target OU
$TargetOU = "OU=Sales,DC=example,DC=com"  # Replace with your actual OU DN

# Create a list to store GPO data
$GPOData = @()

# Function to get GPOs linked to an OU
function Get-GPOsForOU {
    param ($OU)

    $Links = Get-GPOLink -Target $OU
    foreach ($link in $Links) {
        $GPO = Get-GPO -Guid $link.GPOId
        $SecurityFiltering = (Get-GPPermission -Guid $GPO.Id -TargetType Group) | Select-Object -ExpandProperty Trustee.Name -Unique

        $GPOData += [PSCustomObject]@{
            DisplayName       = $GPO.DisplayName
            Enforced          = $link.Enforced
            GPOID             = $GPO.Id
            OU                = $OU
            SecurityFiltering = ($SecurityFiltering -join ", ")
        }
    }
}

# Get GPOs for the target OU
Get-GPOsForOU -OU $TargetOU

# Traverse parent OUs for inherited GPOs
$CurrentOU = $TargetOU
while ($CurrentOU -ne (Get-ADDomain).DistinguishedName) {
    try {
        $ParentOU = (Get-ADOrganizationalUnit -Identity $CurrentOU).DistinguishedName
        Get-GPOsForOU -OU $ParentOU
        $CurrentOU = $ParentOU
    } catch {
        break
    }
}

# Export to Excel
$ExcelPath = "C:\\OU_GPOs_Detailed.xlsx"
$GPOData | Export-Excel -Path $ExcelPath -AutoSize -WorksheetName "GPOs"

Write-Host "Excel file created at: $ExcelPath"
