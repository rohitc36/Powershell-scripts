#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Audits and repairs the Windows Recovery Environment on Windows 11.

.DESCRIPTION
The script validates:

- WinRE status and registered location.
- Windows recovery partition availability.
- Winre.wim availability.
- GPT/UEFI disk layout.
- BitLocker protection status.

In Repair mode, the script can:

- Enable WinRE when it is disabled.
- Re-register WinRE on an existing recovery partition.
- Create a new recovery partition when none exists.
- Copy Winre.wim to the recovery partition.
- Configure the correct GPT recovery partition type and attributes.
- Validate that WinRE maps to the correct partition.

The script does not decrypt the operating system drive, remove BitLocker
protectors, or change the BitLocker encryption method.

.PARAMETER Mode
Audit performs read-only validation.

Repair attempts to repair WinRE.

.PARAMETER RecoveryPartitionSizeMB
Specifies the size of a newly created recovery partition.

The default is 1024 MB.

.PARAMETER LogPath
Specifies the log file path.

.EXAMPLE
.\Repair-WindowsRecoveryEnvironment.ps1 -Mode Audit -Verbose

.EXAMPLE
.\Repair-WindowsRecoveryEnvironment.ps1 -Mode Repair -Confirm:$false -Verbose

.EXAMPLE
.\Repair-WindowsRecoveryEnvironment.ps1 `
    -Mode Repair `
    -RecoveryPartitionSizeMB 1500 `
    -Confirm:$false `
    -Verbose
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param
(
    [Parameter()]
    [ValidateSet('Audit', 'Repair')]
    [string]$Mode = 'Audit',

    [Parameter()]
    [ValidateRange(750, 4096)]
    [int]$RecoveryPartitionSizeMB = 1024,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\Windows\Temp\WinRE-Repair.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RecoveryGptType = '{DE94BBA4-06D1-4D40-A16A-BFD50179D6AC}'
$RecoveryGptAttributes = '0x8000000000000001'

$MountedPartitionInformation = $null
$BitLockerWasSuspended = $false

function Write-WinReLog
{
    <#
    .SYNOPSIS
    Writes a timestamped entry to the WinRE repair log.

    .PARAMETER Level
    Specifies the log severity.

    .PARAMETER Message
    Specifies the log message.

    .EXAMPLE
    Write-WinReLog -Level INFO -Message 'Starting WinRE audit.'
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogEntry = '{0} [{1}] {2}' -f $Timestamp, $Level, $Message

    Add-Content -LiteralPath $LogPath -Value $LogEntry -Encoding UTF8
    Write-Verbose $LogEntry
}

function Invoke-ReAgentC
{
    <#
    .SYNOPSIS
    Executes ReAgentC and returns structured output.

    .PARAMETER Arguments
    Specifies the arguments passed to ReAgentC.

    .PARAMETER IgnoreExitCode
    Prevents a nonzero exit code from immediately throwing an exception.

    .EXAMPLE
    Invoke-ReAgentC -Arguments @('/info')
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [switch]$IgnoreExitCode
    )

    $ReAgentCPath = Join-Path $env:SystemRoot 'System32\reagentc.exe'

    $CommandOutput = & $ReAgentCPath @Arguments 2>&1
    $CommandExitCode = $LASTEXITCODE
    $OutputText = $CommandOutput -join "`r`n"

    Write-WinReLog -Level INFO -Message (
        'REAgentC {0}: {1}' -f ($Arguments -join ' '), $OutputText
    )

    if (($CommandExitCode -ne 0) -and (-not $IgnoreExitCode))
    {
        throw (
            'REAgentC failed with exit code {0}. Output: {1}' -f `
                $CommandExitCode,
                $OutputText
        )
    }

    [PSCustomObject]@{
        ExitCode = $CommandExitCode
        Output   = $CommandOutput
        Text     = $OutputText
    }
}

function Get-WinReConfiguration
{
    <#
    .SYNOPSIS
    Gets and parses the current WinRE configuration.

    .EXAMPLE
    Get-WinReConfiguration
    #>

    [CmdletBinding()]
    param()

    $Result = Invoke-ReAgentC -Arguments @('/info') -IgnoreExitCode

    $Status = 'Unknown'
    $Location = $null
    $Version = $null

    if ($Result.Text -match '(?im)Windows RE status:\s+Enabled')
    {
        $Status = 'Enabled'
    }
    elseif ($Result.Text -match '(?im)Windows RE status:\s+Disabled')
    {
        $Status = 'Disabled'
    }

    if ($Result.Text -match '(?im)Windows RE location:\s+(.+)$')
    {
        $Location = $Matches[1].Trim()
    }

    if ($Result.Text -match '(?im)Windows RE Version:\s+(.+)$')
    {
        $Version = $Matches[1].Trim()
    }

    $RegisteredDiskNumber = $null
    $RegisteredPartitionNumber = $null

    if ($Location -match '(?i)harddisk(\d+)\\partition(\d+)')
    {
        $RegisteredDiskNumber = [int]$Matches[1]
        $RegisteredPartitionNumber = [int]$Matches[2]
    }

    [PSCustomObject]@{
        Status                    = $Status
        Location                  = $Location
        Version                   = $Version
        RegisteredDiskNumber      = $RegisteredDiskNumber
        RegisteredPartitionNumber = $RegisteredPartitionNumber
        ExitCode                  = $Result.ExitCode
        RawText                   = $Result.Text
    }
}

function Get-AvailableDriveLetter
{
    <#
    .SYNOPSIS
    Returns an available temporary drive letter.

    .EXAMPLE
    Get-AvailableDriveLetter
    #>

    [CmdletBinding()]
    param()

    $UsedDriveLetters = @(
        Get-Volume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Select-Object -ExpandProperty DriveLetter
    )

    foreach ($CandidateLetter in @('R', 'W', 'T', 'S', 'Q', 'P'))
    {
        if ($CandidateLetter -notin $UsedDriveLetters)
        {
            return $CandidateLetter
        }
    }

    throw 'No temporary drive letter is available.'
}

function Mount-WinRePartition
{
    <#
    .SYNOPSIS
    Assigns a temporary drive letter to a recovery partition.

    .PARAMETER DiskNumber
    Specifies the disk number.

    .PARAMETER PartitionNumber
    Specifies the partition number.

    .EXAMPLE
    Mount-WinRePartition -DiskNumber 0 -PartitionNumber 4
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [int]$DiskNumber,

        [Parameter(Mandatory)]
        [int]$PartitionNumber
    )

    $Partition = Get-Partition `
        -DiskNumber $DiskNumber `
        -PartitionNumber $PartitionNumber

    if ($Partition.DriveLetter)
    {
        return [PSCustomObject]@{
            DiskNumber      = $DiskNumber
            PartitionNumber = $PartitionNumber
            DriveLetter     = [string]$Partition.DriveLetter
            AccessPathAdded = $false
        }
    }

    $TemporaryDriveLetter = Get-AvailableDriveLetter

    Add-PartitionAccessPath `
        -DiskNumber $DiskNumber `
        -PartitionNumber $PartitionNumber `
        -AccessPath ('{0}:\' -f $TemporaryDriveLetter) `
        -ErrorAction Stop

    Write-WinReLog -Level INFO -Message (
        'Assigned temporary drive letter {0}: to disk {1}, partition {2}.' -f `
            $TemporaryDriveLetter,
            $DiskNumber,
            $PartitionNumber
    )

    [PSCustomObject]@{
        DiskNumber      = $DiskNumber
        PartitionNumber = $PartitionNumber
        DriveLetter     = $TemporaryDriveLetter
        AccessPathAdded = $true
    }
}

function Dismount-WinRePartition
{
    <#
    .SYNOPSIS
    Removes a temporary recovery partition drive letter.

    .PARAMETER MountInformation
    Specifies the object returned by Mount-WinRePartition.

    .EXAMPLE
    Dismount-WinRePartition -MountInformation $MountInformation
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [PSCustomObject]$MountInformation
    )

    if (-not $MountInformation.AccessPathAdded)
    {
        return
    }

    Remove-PartitionAccessPath `
        -DiskNumber $MountInformation.DiskNumber `
        -PartitionNumber $MountInformation.PartitionNumber `
        -AccessPath ('{0}:\' -f $MountInformation.DriveLetter) `
        -ErrorAction Stop

    Write-WinReLog -Level INFO -Message (
        'Removed temporary drive letter {0}: from disk {1}, partition {2}.' -f `
            $MountInformation.DriveLetter,
            $MountInformation.DiskNumber,
            $MountInformation.PartitionNumber
    )
}

function Set-WinRePartitionAttributes
{
    <#
    .SYNOPSIS
    Configures the GPT recovery partition type and attributes.

    .PARAMETER DiskNumber
    Specifies the disk number.

    .PARAMETER PartitionNumber
    Specifies the partition number.

    .EXAMPLE
    Set-WinRePartitionAttributes -DiskNumber 0 -PartitionNumber 4
    #>

    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [int]$DiskNumber,

        [Parameter(Mandatory)]
        [int]$PartitionNumber
    )

    $RandomNumber = Get-Random -Minimum 100000 -Maximum 999999
    $DiskPartFile = Join-Path `
        $env:TEMP `
        ('WinRE-DiskPart-{0}.txt' -f $RandomNumber)

    $DiskPartCommands = @"
select disk $DiskNumber
select partition $PartitionNumber
set id=$RecoveryGptType override
gpt attributes=$RecoveryGptAttributes
exit
"@

    try
    {
        Set-Content `
            -LiteralPath $DiskPartFile `
            -Value $DiskPartCommands `
            -Encoding ASCII `
            -Force

        $DiskPartOutput = & "$env:SystemRoot\System32\diskpart.exe" `
            /s $DiskPartFile 2>&1

        $DiskPartExitCode = $LASTEXITCODE
        $DiskPartText = $DiskPartOutput -join "`r`n"

        Write-WinReLog -Level INFO -Message (
            'DiskPart output: {0}' -f $DiskPartText
        )

        if ($DiskPartExitCode -ne 0)
        {
            throw (
                'DiskPart exited with code {0}. Output: {1}' -f `
                    $DiskPartExitCode,
                    $DiskPartText
            )
        }

        if ($DiskPartText -match '(?i)DiskPart has encountered an error')
        {
            throw "DiskPart reported an error: $DiskPartText"
        }
    }
    finally
    {
        Remove-Item `
            -LiteralPath $DiskPartFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Find-WinReImage
{
    <#
    .SYNOPSIS
    Finds a usable Winre.wim file.

    .PARAMETER RecoveryDriveLetter
    Specifies the mounted recovery partition drive letter.

    .EXAMPLE
    Find-WinReImage -RecoveryDriveLetter R
    #>

    [CmdletBinding()]
    param
    (
        [Parameter()]
        [AllowNull()]
        [string]$RecoveryDriveLetter
    )

    $CandidatePaths = @(
        (Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim')
    )

    if ($RecoveryDriveLetter)
    {
        $CandidatePaths += (
            '{0}:\Recovery\WindowsRE\Winre.wim' -f `
                $RecoveryDriveLetter
        )
    }

    foreach ($CandidatePath in $CandidatePaths)
    {
        if (Test-Path -LiteralPath $CandidatePath -PathType Leaf)
        {
            $ImageFile = Get-Item -LiteralPath $CandidatePath

            if ($ImageFile.Length -gt 0)
            {
                return $CandidatePath
            }
        }
    }

    return $null
}

try
{
    $LogDirectory = Split-Path -Path $LogPath -Parent

    if (-not (Test-Path -LiteralPath $LogDirectory))
    {
        New-Item `
            -Path $LogDirectory `
            -ItemType Directory `
            -Force |
                Out-Null
    }

    Write-WinReLog -Level INFO -Message (
        'Starting WinRE operation in {0} mode.' -f $Mode
    )

    $OperatingSystemDriveLetter = $env:SystemDrive.TrimEnd(':')

    $OperatingSystemPartition = Get-Partition `
        -DriveLetter $OperatingSystemDriveLetter

    $OperatingSystemDisk = Get-Disk `
        -Number $OperatingSystemPartition.DiskNumber

    if ($OperatingSystemDisk.PartitionStyle -ne 'GPT')
    {
        throw (
            'This script supports only Windows 11 UEFI/GPT devices. ' +
            'Detected partition style: {0}.' -f `
                $OperatingSystemDisk.PartitionStyle
        )
    }

    $WinReConfiguration = Get-WinReConfiguration

    $AllDiskPartitions = @(
        Get-Partition -DiskNumber $OperatingSystemDisk.Number |
            Sort-Object Offset
    )

    $RecoveryPartitions = @(
        $AllDiskPartitions |
            Where-Object {
                $_.GptType -eq $RecoveryGptType -or
                $_.Type -eq 'Recovery'
            }
    )

    $RegisteredRecoveryPartition = $null

    if ($null -ne $WinReConfiguration.RegisteredPartitionNumber)
    {
        $RegisteredRecoveryPartition = $RecoveryPartitions |
            Where-Object {
                $_.PartitionNumber -eq `
                    $WinReConfiguration.RegisteredPartitionNumber
            } |
            Select-Object -First 1
    }

    $BitLockerVolume = Get-BitLockerVolume `
        -MountPoint ('{0}:' -f $OperatingSystemDriveLetter)

    $RecoveryPartitionSummary = @(
        foreach ($RecoveryPartition in $RecoveryPartitions)
        {
            [PSCustomObject]@{
                DiskNumber      = $RecoveryPartition.DiskNumber
                PartitionNumber = $RecoveryPartition.PartitionNumber
                SizeMB          = $RecoveryPartition.Size / 1MB
                
                GptType         = $RecoveryPartition.GptType
                DriveLetter     = $RecoveryPartition.DriveLetter
            }
        }
    )

    $IsHealthy = (
        $WinReConfiguration.Status -eq 'Enabled' -and
        $WinReConfiguration.Location -and
        $null -ne $RegisteredRecoveryPartition
    )

    $AuditResult = [PSCustomObject]@{
        ComputerName                  = $env:COMPUTERNAME
        Mode                          = $Mode
        OperatingSystemDisk           = $OperatingSystemDisk.Number
        PartitionStyle                = $OperatingSystemDisk.PartitionStyle
        OperatingSystemPartition      = $OperatingSystemPartition.PartitionNumber
        BitLockerProtectionStatus     = [string]$BitLockerVolume.ProtectionStatus
        BitLockerEncryptionPercentage = $BitLockerVolume.EncryptionPercentage
        BitLockerEncryptionMethod     = [string]$BitLockerVolume.EncryptionMethod
        WinReStatus                   = $WinReConfiguration.Status
        WinReVersion                  = $WinReConfiguration.Version
        WinReLocation                 = $WinReConfiguration.Location
        RegisteredRecoveryPartition   = $WinReConfiguration.RegisteredPartitionNumber
        RecoveryPartitionCount        = $RecoveryPartitions.Count
        RecoveryPartitions            = $RecoveryPartitionSummary
        IsHealthy                     = $IsHealthy
        ActionRequired                = -not $IsHealthy
        Result                        = $null
        LogPath                       = $LogPath
    }

    if ($IsHealthy)
    {
        Write-WinReLog -Level SUCCESS -Message (
            'WinRE is enabled and mapped to recovery partition {0}.' -f `
                $WinReConfiguration.RegisteredPartitionNumber
        )

        $AuditResult.Result = 'Healthy: no repair required'
        $AuditResult
        return
    }

    Write-WinReLog -Level WARNING -Message (
        'WinRE requires attention. Status: {0}; Location: {1}; ' +
        'Recovery partition count: {2}.' -f `
            $WinReConfiguration.Status,
            $WinReConfiguration.Location,
            $RecoveryPartitions.Count
    )

    if ($Mode -eq 'Audit')
    {
        $AuditResult.Result = 'Repair required: rerun with -Mode Repair'
        $AuditResult
        return
    }

    if (
        -not $PSCmdlet.ShouldProcess(
            (
                'Computer {0}, disk {1}' -f `
                    $env:COMPUTERNAME,
                    $OperatingSystemDisk.Number
            ),
            'Repair Windows Recovery Environment'
        )
    )
    {
        return
    }

    if ($RecoveryPartitions.Count -gt 1)
    {
        throw (
            'Multiple recovery partitions were detected. Automatic repair ' +
            'has stopped to avoid modifying the wrong partition. Review ' +
            'the disk layout manually.'
        )
    }

    if ($BitLockerVolume.ProtectionStatus -eq 'On')
    {
        Write-WinReLog -Level INFO -Message (
            'Suspending BitLocker protection for one restart. The drive ' +
            'will remain encrypted and existing protectors are preserved.'
        )

        Suspend-BitLocker `
            -MountPoint ('{0}:' -f $OperatingSystemDriveLetter) `
            -RebootCount 1 `
            -ErrorAction Stop |
                Out-Null

        $BitLockerWasSuspended = $true
    }

    Invoke-ReAgentC `
        -Arguments @('/disable') `
        -IgnoreExitCode |
            Out-Null

    $TargetRecoveryPartition = $null
    $WinReImageSource = $null

    if ($RecoveryPartitions.Count -eq 1)
    {
        $TargetRecoveryPartition = $RecoveryPartitions[0]

        Write-WinReLog -Level INFO -Message (
            'Using existing recovery partition {0}, size {1} MB.' -f `
                $TargetRecoveryPartition.PartitionNumber,
                $TargetRecoveryPartition.Size / 1MB
        )

        Set-WinRePartitionAttributes `
            -DiskNumber $TargetRecoveryPartition.DiskNumber `
            -PartitionNumber $TargetRecoveryPartition.PartitionNumber

        $MountedPartitionInformation = Mount-WinRePartition `
            -DiskNumber $TargetRecoveryPartition.DiskNumber `
            -PartitionNumber $TargetRecoveryPartition.PartitionNumber

        $WinReImageSource = Find-WinReImage `
            -RecoveryDriveLetter `
                $MountedPartitionInformation.DriveLetter

        if (-not $WinReImageSource)
        {
            throw (
                'Winre.wim was not found in C:\Windows\System32\Recovery ' +
                'or on the existing recovery partition. Restore Winre.wim ' +
                'from matching Windows 11 installation media or reimage ' +
                'the device.'
            )
        }
    }
    else
    {
        Write-WinReLog -Level WARNING -Message (
            'No recovery partition was detected. Preparing to create one.'
        )

        $WinReImageSource = Find-WinReImage

        if (-not $WinReImageSource)
        {
            throw (
                'No recovery partition exists and Winre.wim was not found ' +
                'at C:\Windows\System32\Recovery\Winre.wim. No partition ' +
                'changes have been performed.'
            )
        }

        $PartitionsAfterOperatingSystem = @(
            $AllDiskPartitions |
                Where-Object {
                    $_.Offset -gt $OperatingSystemPartition.Offset -and
                    $_.PartitionNumber -ne `
                        $OperatingSystemPartition.PartitionNumber
                }
        )

        if ($PartitionsAfterOperatingSystem.Count -gt 0)
        {
            throw (
                'No recovery partition exists, but another partition is ' +
                'located after the Windows partition. Automatic repair ' +
                'cannot safely rearrange that layout. Manual disk-layout ' +
                'remediation or reimaging is required.'
            )
        }

        $SupportedSize = Get-PartitionSupportedSize `
            -DiskNumber $OperatingSystemDisk.Number `
            -PartitionNumber $OperatingSystemPartition.PartitionNumber

        $RequestedShrinkBytes = $RecoveryPartitionSizeMB * 1MB
        

        $NewOperatingSystemSize = $OperatingSystemPartition.Size -
            $RequestedShrinkBytes
        

        if ($NewOperatingSystemSize -lt $SupportedSize.SizeMin)
        {
            $MinimumSizeGB = (
                '{0:N2}' -f ($SupportedSize.SizeMin / 1GB)
            )

            throw (
                'The OS partition cannot be safely shrunk by {0} MB. ' +
                'The supported minimum OS partition size is {1} GB.' -f `
                    $RecoveryPartitionSizeMB,
                    $MinimumSizeGB
            )
        }

        Write-WinReLog -Level INFO -Message (
            'Shrinking the Windows partition by {0} MB.' -f `
                $RecoveryPartitionSizeMB
        )

        Resize-Partition `
            -DiskNumber $OperatingSystemDisk.Number `
            -PartitionNumber $OperatingSystemPartition.PartitionNumber `
            -Size $NewOperatingSystemSize `
            -ErrorAction Stop

        Write-WinReLog -Level INFO -Message (
            'Creating a {0} MB Windows recovery partition.' -f `
                $RecoveryPartitionSizeMB
        )

        $TargetRecoveryPartition = New-Partition `
            -DiskNumber $OperatingSystemDisk.Number `
            -Size $RequestedShrinkBytes `
            -GptType $RecoveryGptType `
            -ErrorAction Stop

        Format-Volume `
            -Partition $TargetRecoveryPartition `
            -FileSystem NTFS `
            -NewFileSystemLabel 'Windows RE tools' `
            -Confirm:$false `
            -Force `
            -ErrorAction Stop |
                Out-Null

        Set-WinRePartitionAttributes `
            -DiskNumber $OperatingSystemDisk.Number `
            -PartitionNumber $TargetRecoveryPartition.PartitionNumber

        $TargetRecoveryPartition = Get-Partition `
            -DiskNumber $OperatingSystemDisk.Number `
            -PartitionNumber $TargetRecoveryPartition.PartitionNumber

        Write-WinReLog -Level SUCCESS -Message (
            'Created recovery partition {0}, size {1} MB.' -f `
                $TargetRecoveryPartition.PartitionNumber,
                $TargetRecoveryPartition.Size / 1MB
        )

        $MountedPartitionInformation = Mount-WinRePartition `
            -DiskNumber $TargetRecoveryPartition.DiskNumber `
            -PartitionNumber $TargetRecoveryPartition.PartitionNumber
    }

    $RecoveryDriveLetter = $MountedPartitionInformation.DriveLetter

    $RecoveryFolder = '{0}:\Recovery\WindowsRE' -f `
        $RecoveryDriveLetter

    if (-not (Test-Path -LiteralPath $RecoveryFolder))
    {
        New-Item `
            -Path $RecoveryFolder `
            -ItemType Directory `
            -Force `
            -ErrorAction Stop |
                Out-Null
    }

    $DestinationWinReImage = Join-Path `
        -Path $RecoveryFolder `
        -ChildPath 'Winre.wim'

    if ($WinReImageSource -ne $DestinationWinReImage)
    {
        Write-WinReLog -Level INFO -Message (
            'Copying Winre.wim from {0} to {1}.' -f `
                $WinReImageSource,
                $DestinationWinReImage
        )

        Copy-Item `
            -LiteralPath $WinReImageSource `
            -Destination $DestinationWinReImage `
            -Force `
            -ErrorAction Stop
    }
    else
    {
        Write-WinReLog -Level INFO -Message (
            'Winre.wim already exists in the target recovery folder.'
        )
    }

    if (-not (Test-Path -LiteralPath $DestinationWinReImage -PathType Leaf))
    {
        throw (
            'Winre.wim validation failed. Expected file: {0}' -f `
                $DestinationWinReImage
        )
    }

    $WinReImageFile = Get-Item -LiteralPath $DestinationWinReImage

    if ($WinReImageFile.Length -le 0)
    {
        throw 'The target Winre.wim file has a size of zero bytes.'
    }

    Write-WinReLog -Level INFO -Message (
        'Registering WinRE using {0}.' -f $RecoveryFolder
    )

    Invoke-ReAgentC -Arguments @(
        '/setreimage',
        '/path',
        $RecoveryFolder,
        '/target',
        ('{0}:\Windows' -f $OperatingSystemDriveLetter)
    ) | Out-Null

    Invoke-ReAgentC -Arguments @('/enable') | Out-Null

    $FinalConfiguration = Get-WinReConfiguration

    if (
        $FinalConfiguration.Status -ne 'Enabled' -or
        -not $FinalConfiguration.Location
    )
    {
        throw (
            'WinRE validation failed after repair. ReAgentC did not ' +
            'report an enabled recovery environment with a valid location.'
        )
    }

    if (
        $FinalConfiguration.RegisteredPartitionNumber -ne
        $TargetRecoveryPartition.PartitionNumber
    )
    {
        throw (
            'WinRE was enabled but mapped to the wrong partition. ' +
            'Expected partition {0}; actual partition {1}.' -f `
                $TargetRecoveryPartition.PartitionNumber,
                $FinalConfiguration.RegisteredPartitionNumber
        )
    }

    Write-WinReLog -Level SUCCESS -Message (
        'WinRE repair completed successfully. Location: {0}.' -f `
            $FinalConfiguration.Location
    )

    [PSCustomObject]@{
        ComputerName            = $env:COMPUTERNAME
        Mode                    = $Mode
        Result                  = 'WinRE repair completed successfully'
        WinReStatus             = $FinalConfiguration.Status
        WinReVersion            = $FinalConfiguration.Version
        WinReLocation           = $FinalConfiguration.Location
        RecoveryDiskNumber      = $TargetRecoveryPartition.DiskNumber
        RecoveryPartitionNumber = $TargetRecoveryPartition.PartitionNumber
        RecoveryPartitionSizeMB = $TargetRecoveryPartition.Size / 1MB
        
        BitLockerWasSuspended   = $BitLockerWasSuspended
        BitLockerAction         = if ($BitLockerWasSuspended)
        {
            'Protection suspended for one restart; volume remains encrypted'
        }
        else
        {
            'No BitLocker change required'
        }
        RestartRecommended      = $true
        LogPath                 = $LogPath
    }
}
catch
{
    $FailureMessage = $_.Exception.Message

    try
    {
        Write-WinReLog -Level ERROR -Message $FailureMessage
    }
    catch
    {
        Write-Error $FailureMessage
    }

    throw
}
finally
{
    if ($null -ne $MountedPartitionInformation)
    {
        try
        {
            Dismount-WinRePartition `
                -MountInformation $MountedPartitionInformation
        }
        catch
        {
            $DismountFailure = $_.Exception.Message

            try
            {
                Write-WinReLog -Level WARNING -Message (
                    'Could not remove temporary drive letter {0}: {1}' -f `
                        $MountedPartitionInformation.DriveLetter,
                        $DismountFailure
                )
            }
            catch
            {
                Write-Warning (
                    'Could not remove the temporary recovery partition ' +
                    'drive letter.'
                )
            }
        }
    }

    try
    {
        Write-WinReLog -Level INFO -Message 'WinRE operation finished.'
    }
    catch
    {
        Write-Verbose 'Unable to write the final log entry.'
    }
}
