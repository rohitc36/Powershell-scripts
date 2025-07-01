# Run this script as Administrator

# Step 1: Decrypt the system drive
Write-Host "Starting BitLocker decryption on C:..."
Disable-BitLocker -MountPoint "C:"
Do {
    $status = Get-BitLockerVolume -MountPoint "C:"
    Start-Sleep -Seconds 10
    Write-Host "Decryption Progress: $($status.EncryptionPercentage)%"
} while ($status.EncryptionPercentage -gt 0)
Write-Host "Decryption complete."

# Step 2: Check and enable WinRE
$reStatus = reagentc /info
if ($reStatus -match "Windows RE status: Disabled") {
    Write-Host "WinRE is disabled. Attempting to enable..."

    $winrePath = "C:\Windows\System32\Recovery\Winre.wim"
    if (Test-Path $winrePath) {
        reagentc /setreimage /path C:\Windows\System32\Recovery /target C:\Windows
        reagentc /enable
        Write-Host "WinRE enabled successfully."
    } else {
        Write-Host "WinRE image not found at expected location. Please provide the correct path."
        exit
    }
} else {
    Write-Host "WinRE is already enabled."
}

# Step 3: Re-encrypt the system drive
Write-Host "Starting BitLocker encryption on C:..."
Enable-BitLocker -MountPoint "C:" -EncryptionMethod XtsAes256 -UsedSpaceOnly -TpmProtector
Write-Host "BitLocker encryption initiated. Monitor progress using 'Get-BitLockerVolume'."
