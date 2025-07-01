# Run as Administrator

# Step 1: Suspend BitLocker
Suspend-BitLocker -MountPoint "C:" -RebootCount 1
Write-Host "BitLocker suspended on C:"

# Step 2: Check WinRE status
$reStatus = reagentc /info
if ($reStatus -match "Windows RE status: Disabled") {
    Write-Host "WinRE is disabled. Attempting to enable..."

    # Step 3: Set WinRE image path (adjust if needed)
    $winrePath = "C:\Windows\System32\Recovery\Winre.wim"
    if (Test-Path $winrePath) {
        reagentc /setreimage /path C:\Windows\System32\Recovery /target C:\Windows
        Write-Host "WinRE image path set."
    } else {
        Write-Host "WinRE image not found at expected location. Please provide the correct path."
        exit
    }

    # Step 4: Enable WinRE
    reagentc /enable
    Write-Host "WinRE enabled successfully."
} else {
    Write-Host "WinRE is already enabled."
}

# Step 5: Resume BitLocker
Resume-BitLocker -MountPoint "C:"
Write-Host "BitLocker protection resumed."
