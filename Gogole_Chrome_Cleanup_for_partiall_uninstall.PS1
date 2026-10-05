<#
.SYNOPSIS
Removes orphaned Google Chrome MSI registrations.

.DESCRIPTION
Safely removes stale Google Chrome Windows Installer registrations
after Chrome has already been removed from the machine.

The script:
- Verifies chrome.exe is absent
- Backs up registry entries
- Removes Uninstall registry keys
- Removes Windows Installer product registrations
- Removes leftover Chrome folders
- Verifies cleanup

.NOTES
Author: Rohit Chaudhary
Use only when Chrome binaries are already removed.
#>

[CmdletBinding()]
param()

$BackupFolder = "C:\Temp\ChromeCleanupBackup"

Try {

    Write-Output "===== Chrome MSI Cleanup Started ====="

    # Create backup folder
    If (-not (Test-Path $BackupFolder)) {
        New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
    }

    # Verify Chrome binaries do NOT exist
    $ChromePaths = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )

    $ChromeInstalled = $ChromePaths | Where-Object {
        Test-Path $_
    }

    If ($ChromeInstalled) {
        Throw "Chrome executable still exists. Cleanup aborted."
    }

    Write-Output "Chrome files not detected."

    #
    # Backup and Remove Uninstall Keys
    #
    Write-Output "Searching uninstall registry keys..."

    $UninstallLocations = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($Location in $UninstallLocations) {

        Get-ChildItem $Location -ErrorAction SilentlyContinue | ForEach-Object {

            Try {
                $App = Get-ItemProperty $_.PSPath -ErrorAction Stop

                If ($App.DisplayName -eq "Google Chrome") {

                    $KeyName = $_.PSChildName

                    Write-Output "Found uninstall key: $KeyName"

                    reg export `
                        ($_.Name -replace 'HKEY_LOCAL_MACHINE','HKLM') `
                        "$BackupFolder\$($KeyName)_Uninstall.reg" `
                        /y | Out-Null

                    Remove-Item $_.PSPath -Recurse -Force

                    Write-Output "Removed uninstall key."
                }
            }
            Catch {
                Continue
            }
        }
    }

    #
    # Backup and Remove Installer Product Keys
    #
    Write-Output "Searching Windows Installer product registrations..."

    $InstallerProducts =
        "Registry::HKEY_CLASSES_ROOT\Installer\Products"

    Get-ChildItem $InstallerProducts -ErrorAction SilentlyContinue |
    ForEach-Object {

        Try {

            $Props = Get-ItemProperty $_.PSPath -ErrorAction Stop

            If ($Props.ProductName -eq "Google Chrome") {

                $InstallerKey = $_.PSChildName

                Write-Output "Found installer registration: $InstallerKey"

                reg export `
                    "HKCR\Installer\Products\$InstallerKey" `
                    "$BackupFolder\$InstallerKey.reg" `
                    /y | Out-Null

                Remove-Item `
                    $_.PSPath `
                    -Recurse `
                    -Force

                Write-Output "Removed installer registration."
            }
        }
        Catch {
            Continue
        }
    }

    #
    # Remove residual folders
    #
    Write-Output "Removing residual folders..."

    $Folders = @(
        "C:\Program Files\Google\Chrome",
        "C:\Program Files (x86)\Google\Chrome",
        "$env:ProgramData\Google\Chrome"
    )

    foreach ($Folder in $Folders) {

        If (Test-Path $Folder) {

            Remove-Item `
                $Folder `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue

            Write-Output "Removed $Folder"
        }
    }

    #
    # Verification
    #
    Write-Output ""
    Write-Output "===== Verification ====="

    $ChromeWmi = Get-WmiObject Win32_Product -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "*Chrome*"
        }

    $ChromePackage = Get-Package -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "*Chrome*"
        }

    If (($null -eq $ChromeWmi) -and ($null -eq $ChromePackage)) {

        Write-Output ""
        Write-Output "SUCCESS: Chrome orphaned MSI registrations removed."
    }
    Else {

        Write-Output ""
        Write-Warning "Chrome references still exist."

        If ($ChromeWmi) {
            Write-Output "WMI:"
            $ChromeWmi
        }

        If ($ChromePackage) {
            Write-Output "Package:"
            $ChromePackage
        }
    }

    Write-Output ""
    Write-Output "Registry backups stored in:"
    Write-Output $BackupFolder
}
Catch {

    Write-Error $_.Exception.Message
}
Finally {

    Write-Output ""
    Write-Output "===== Cleanup Complete ====="
}
