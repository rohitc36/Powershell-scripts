
<#
.SYNOPSIS
    Windows Update Reboot & Intune Grace Period Diagnostic Script
.DESCRIPTION
    Collects all diagnostic information needed to verify if a Windows Update
    pending reboot exists, whether the Intune-configured grace period has expired,
    and why the device has not yet restarted.
.NOTES
    Author  : Rohit Chaudhary
    Date    : 2026-06-16
    Version : 1.0
    Run as  : Administrator (elevated PowerShell)
#>

# ============================================================
# INITIALIZATION
# ============================================================
$ErrorActionPreference = "SilentlyContinue"
$separator = "=" * 80
$subSeparator = "-" * 60
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logDir = "C:\Temp"
$logFile = "$logDir\WU_RebootDiag_$timestamp.log"

# Ensure log directory exists
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

# Start transcript to capture all output to log file
Start-Transcript -Path $logFile -Force | Out-Null

# Admin check
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] This script must be run as Administrator. Exiting." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# Summary collection
$summaryFindings = @()

Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host "  WINDOWS UPDATE REBOOT & INTUNE GRACE PERIOD DIAGNOSTIC" -ForegroundColor White
Write-Host "  Run Date : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  Log File : $logFile" -ForegroundColor White
Write-Host $separator -ForegroundColor Magenta
Write-Host ""

# ============================================================
# SECTION 1: SYSTEM INFORMATION
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 1: SYSTEM INFORMATION" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$lastBoot = $os.LastBootUpTime
$uptime = (Get-Date) - $lastBoot

Write-Host "  Computer Name    : $($cs.Name)" -ForegroundColor Yellow
Write-Host "  Domain           : $($cs.Domain)" -ForegroundColor Yellow
Write-Host "  OS               : $($os.Caption)" -ForegroundColor Yellow
Write-Host "  OS Version       : $($os.Version)" -ForegroundColor Yellow
Write-Host "  OS Build         : $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion)" -ForegroundColor Yellow
Write-Host "  Last Boot Time   : $lastBoot" -ForegroundColor Yellow
Write-Host "  Uptime           : $($uptime.Days) days, $($uptime.Hours) hours, $($uptime.Minutes) minutes" -ForegroundColor Yellow
Write-Host ""

if ($uptime.Days -gt 7) {
    Write-Host "  [!] Device has NOT been rebooted for $($uptime.Days) days!" -ForegroundColor Red
    $summaryFindings += "ALERT: Device uptime is $($uptime.Days) days - reboot overdue"
} else {
    Write-Host "  [OK] Device was rebooted within the last 7 days." -ForegroundColor Green
}
Write-Host ""

# ============================================================
# SECTION 2: PENDING REBOOT CHECKS
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 2: PENDING REBOOT STATUS" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$rebootChecks = @{
    "WU RebootRequired"      = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    "CBS RebootPending"      = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    "CBS PackagesPending"    = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending"
}

$rebootPending = $false
foreach ($check in $rebootChecks.GetEnumerator()) {
    $exists = Test-Path $check.Value
    $status = if ($exists) { "TRUE  -> Reboot IS pending" } else { "FALSE -> No pending reboot from this source" }
    $color = if ($exists) { "Red" } else { "Green" }
    Write-Host "  $($check.Key.PadRight(25)) : $status" -ForegroundColor $color
    if ($exists) { $rebootPending = $true }
}

# Check PendingFileRenameOperations
$pendingFileOps = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
$pfroExists = $null -ne $pendingFileOps
$pfroColor = if ($pfroExists) { "Red" } else { "Green" }
$pfroStatus = if ($pfroExists) { "TRUE  -> File operations pending after reboot" } else { "FALSE -> No pending file operations" }
Write-Host "  PendingFileRenameOps    : $pfroStatus" -ForegroundColor $pfroColor
Write-Host ""

if ($rebootPending) {
    Write-Host "  [!] REBOOT IS PENDING on this device." -ForegroundColor Red
    $summaryFindings += "CONFIRMED: Device has a pending reboot (WU and/or CBS)"
} else {
    Write-Host "  [OK] No pending reboot detected." -ForegroundColor Green
    $summaryFindings += "INFO: No pending reboot detected from registry checks"
}
Write-Host ""

# ============================================================
# SECTION 3: WINDOWS UPDATE HISTORY (COM Object - Reliable)
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 3: WINDOWS UPDATE HISTORY (Last 15 Updates)" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

try {
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $HistoryCount = $Searcher.GetTotalHistoryCount()
    $History = $Searcher.QueryHistory(0, [Math]::Min($HistoryCount, 15))

    $updateHistory = $History | Where-Object { $_.Title } |
        Select-Object @{N='Date';E={$_.Date}},
                      @{N='Result';E={switch($_.ResultCode){1{'In Progress'};2{'Succeeded'};3{'Succeeded w/ Errors'};4{'Failed'};5{'Aborted'};default{'Unknown'}}}},
                      @{N='Title';E={$_.Title}}

    if ($updateHistory) {
        $updateHistory | Format-Table Date, Result, Title -AutoSize -Wrap
        $lastUpdate = ($updateHistory | Select-Object -First 1)
        $lastUpdateDate = $lastUpdate.Date
        Write-Host "  Last update installed on: $lastUpdateDate" -ForegroundColor Yellow
        $summaryFindings += "Last update date: $lastUpdateDate ($($lastUpdate.Title))"
    } else {
        Write-Host "  [!] No update history found via COM object." -ForegroundColor Red
    }
} catch {
    Write-Host "  [!] Failed to query update history: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ============================================================
# SECTION 4: GET-HOTFIX (Safe Version)
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 4: INSTALLED HOTFIXES (Last 5)" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

try {
    Get-HotFix | Where-Object { $_.InstalledOn } |
        Sort-Object InstalledOn -Descending |
        Select-Object -First 5 |
        Format-Table HotFixID, InstalledOn, Description -AutoSize
} catch {
    Write-Host "  [!] Error retrieving hotfix info: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ============================================================
# SECTION 5: INTUNE/MDM APPLIED WUfB POLICIES
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 5: INTUNE/MDM APPLIED WUfB POLICIES" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$mdmPolicyFound = $false
$configuredGracePeriod = $null
$configuredDeadlineQuality = $null
$configuredDeadlineFeature = $null
$configuredNoAutoReboot = $null

try {
    $mdmPaths = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\PolicyManager\providers" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*Update*" }

    foreach ($path in $mdmPaths) {
        $props = Get-ItemProperty -Path $path.PSPath -ErrorAction SilentlyContinue
        $relevantKeys = $props.PSObject.Properties | Where-Object {
            $_.Name -match "Deadline|GracePeriod|AutoReboot|ActiveHours|Restart|Engaged|DeferQuality|DeferFeature|BranchReadiness"
        }
        if ($relevantKeys) {
            $mdmPolicyFound = $true
            Write-Host ""
            Write-Host "  Registry Path: $($path.PSPath -replace 'Microsoft\.PowerShell\.Core\\Registry::','')" -ForegroundColor DarkCyan
            Write-Host "  $subSeparator" -ForegroundColor DarkGray
            foreach ($key in $relevantKeys) {
                Write-Host "    $($key.Name.PadRight(55)) = $($key.Value)" -ForegroundColor Yellow

                # Capture key values for summary
                if ($key.Name -match "ConfigureDeadlineGracePeriod$" -and $key.Name -notmatch "Feature") {
                    $configuredGracePeriod = $key.Value
                }
                if ($key.Name -match "ConfigureDeadlineForQualityUpdates") {
                    $configuredDeadlineQuality = $key.Value
                }
                if ($key.Name -match "ConfigureDeadlineForFeatureUpdates") {
                    $configuredDeadlineFeature = $key.Value
                }
                if ($key.Name -match "ConfigureDeadlineNoAutoReboot") {
                    $configuredNoAutoReboot = $key.Value
                }
            }
        }
    }
} catch {
    Write-Host "  [!] Error reading MDM policies: $($_.Exception.Message)" -ForegroundColor Red
}

# Also check PolicyManager current device Update
Write-Host ""
Write-Host "  $subSeparator" -ForegroundColor DarkGray
Write-Host "  Checking PolicyManager\current\device\Update..." -ForegroundColor DarkCyan
$currentUpdatePath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
if (Test-Path $currentUpdatePath) {
    $currentProps = Get-ItemProperty -Path $currentUpdatePath -ErrorAction SilentlyContinue
    $currentRelevant = $currentProps.PSObject.Properties | Where-Object {
        $_.Name -match "Deadline|GracePeriod|AutoReboot|ActiveHours|Restart|Engaged|DeferQuality|DeferFeature|BranchReadiness"
    }
    if ($currentRelevant) {
        $mdmPolicyFound = $true
        foreach ($key in $currentRelevant) {
            Write-Host "    $($key.Name.PadRight(55)) = $($key.Value)" -ForegroundColor Yellow
            # Capture if not already captured above
            if ($key.Name -match "ConfigureDeadlineGracePeriod$" -and $key.Name -notmatch "Feature" -and -not $configuredGracePeriod) {
                $configuredGracePeriod = $key.Value
            }
            if ($key.Name -match "ConfigureDeadlineForQualityUpdates" -and -not $configuredDeadlineQuality) {
                $configuredDeadlineQuality = $key.Value
            }
        }
    }
} else {
    Write-Host "    [!] Path not found: $currentUpdatePath" -ForegroundColor Red
}

if (-not $mdmPolicyFound) {
    Write-Host "  [!] No Intune/MDM WUfB policies found on this device." -ForegroundColor Red
    $summaryFindings += "WARNING: No Intune WUfB deadline/grace period policies detected"
} else {
    if ($configuredGracePeriod) { $summaryFindings += "Configured Grace Period: $configuredGracePeriod days" }
    if ($configuredDeadlineQuality) { $summaryFindings += "Configured Quality Update Deadline: $configuredDeadlineQuality days" }
    if ($configuredDeadlineFeature) { $summaryFindings += "Configured Feature Update Deadline: $configuredDeadlineFeature days" }
}
Write-Host ""

# ============================================================
# SECTION 6: WUfB STATE VARIABLES
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 6: WINDOWS UPDATE STATE VARIABLES" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$stateVarPaths = @(
    "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\StateVariables",
    "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings",
    "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\Settings"
)

foreach ($svPath in $stateVarPaths) {
    if (Test-Path $svPath) {
        Write-Host "  Path: $svPath" -ForegroundColor DarkCyan
        $svProps = Get-ItemProperty -Path $svPath -ErrorAction SilentlyContinue
        $svKeys = $svProps.PSObject.Properties | Where-Object {
            $_.Name -notmatch "^PS" -and $_.Name -ne "(default)"
        }
        foreach ($key in $svKeys) {
            Write-Host "    $($key.Name.PadRight(45)) = $($key.Value)" -ForegroundColor Yellow
        }
        Write-Host ""
    }
}
Write-Host ""

# ============================================================
# SECTION 7: ACTIVE HOURS CONFIGURATION
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 7: ACTIVE HOURS CONFIGURATION" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$uxSettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
if (Test-Path $uxSettingsPath) {
    $uxSettings = Get-ItemProperty -Path $uxSettingsPath -ErrorAction SilentlyContinue
    $ahStart = $uxSettings.ActiveHoursStart
    $ahEnd = $uxSettings.ActiveHoursEnd
    $smartAH = $uxSettings.SmartActiveHoursState
    $isActiveHoursManagedByUser = $uxSettings.IsActiveHoursEnabled

    Write-Host "  Active Hours Start         : $ahStart ($(if($ahStart -ne $null){"$($ahStart):00"}else{'Not Set'}))" -ForegroundColor Yellow
    Write-Host "  Active Hours End           : $ahEnd ($(if($ahEnd -ne $null){"$($ahEnd):00"}else{'Not Set'}))" -ForegroundColor Yellow
    Write-Host "  Smart Active Hours State   : $smartAH" -ForegroundColor Yellow
    Write-Host "  Active Hours Enabled       : $isActiveHoursManagedByUser" -ForegroundColor Yellow

    if ($ahStart -ne $null -and $ahEnd -ne $null) {
        $summaryFindings += "Active Hours: $($ahStart):00 to $($ahEnd):00"
    }
} else {
    Write-Host "  [!] UX Settings path not found." -ForegroundColor Red
}
Write-Host ""

# ============================================================
# SECTION 8: GPO-LEVEL WINDOWS UPDATE POLICIES (Conflict Check)
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 8: GPO-LEVEL WINDOWS UPDATE POLICIES (Conflict Check)" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$gpoWUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (Test-Path $gpoWUPath) {
    Write-Host "  [!] GPO-level Windows Update policies DETECTED - potential conflict with Intune!" -ForegroundColor Red
    $summaryFindings += "WARNING: GPO-level WU policies found - may conflict with Intune MDM!"

    Write-Host ""
    Write-Host "  Path: $gpoWUPath" -ForegroundColor DarkCyan
    $gpoProps = Get-ItemProperty -Path $gpoWUPath -ErrorAction SilentlyContinue
    $gpoKeys = $gpoProps.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" -and $_.Name -ne "(default)" }
    foreach ($key in $gpoKeys) {
        Write-Host "    $($key.Name.PadRight(45)) = $($key.Value)" -ForegroundColor Yellow
    }

    # Check AU sub-key
    $gpoAUPath = "$gpoWUPath\AU"
    if (Test-Path $gpoAUPath) {
        Write-Host ""
        Write-Host "  Path: $gpoAUPath" -ForegroundColor DarkCyan
        $gpoAUProps = Get-ItemProperty -Path $gpoAUPath -ErrorAction SilentlyContinue
        $gpoAUKeys = $gpoAUProps.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" -and $_.Name -ne "(default)" }
        foreach ($key in $gpoAUKeys) {
            Write-Host "    $($key.Name.PadRight(45)) = $($key.Value)" -ForegroundColor Yellow
        }
    }

    # Check for WSUS server settings
    if ($gpoProps.WUServer) {
        Write-Host ""
        Write-Host "  [!] WSUS Server configured via GPO: $($gpoProps.WUServer)" -ForegroundColor Red
        $summaryFindings += "WARNING: WSUS server configured via GPO ($($gpoProps.WUServer)) - may block WUfB!"
    }
} else {
    Write-Host "  [OK] No GPO-level Windows Update policies found. No conflicts." -ForegroundColor Green
    $summaryFindings += "OK: No GPO-level WU policy conflicts detected"
}
Write-Host ""

# ============================================================
# SECTION 9: INTUNE MDM ENROLLMENT & SYNC STATUS
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 9: INTUNE MDM ENROLLMENT & SYNC STATUS" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$enrollPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
if (Test-Path $enrollPath) {
    $enrollGuids = Get-ChildItem $enrollPath -ErrorAction SilentlyContinue |
        Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProviderID }

    foreach ($guid in $enrollGuids) {
        $enrollProps = Get-ItemProperty $guid.PSPath -ErrorAction SilentlyContinue
        Write-Host "  Enrollment GUID   : $($guid.PSChildName)" -ForegroundColor Yellow
        Write-Host "  Provider ID       : $($enrollProps.ProviderID)" -ForegroundColor Yellow
        Write-Host "  UPN               : $($enrollProps.UPN)" -ForegroundColor Yellow
        Write-Host "  AAD Tenant ID     : $($enrollProps.AADTenantID)" -ForegroundColor Yellow

        # Check last sync
        $statusPath = "$($guid.PSPath)\DMClient\MS DM Server"
        if (Test-Path $statusPath) {
            $dmProps = Get-ItemProperty $statusPath -ErrorAction SilentlyContinue
            if ($dmProps) {
                $lastSync = $dmProps.'LastSuccessfulSyncTime'
                Write-Host "  Last Sync Time    : $lastSync" -ForegroundColor Yellow
                if ($lastSync) {
                    $summaryFindings += "Last Intune sync: $lastSync"
                }
            }
        }
        Write-Host ""
    }
} else {
    Write-Host "  [!] No MDM enrollment found." -ForegroundColor Red
    $summaryFindings += "WARNING: No MDM enrollment detected on this device"
}
Write-Host ""

# ============================================================
# SECTION 10: WINDOWS UPDATE CLIENT EVENT LOG
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 10: WINDOWS UPDATE CLIENT EVENTS (Reboot/Deadline/Grace)" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

try {
    $wuEvents = Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match "restart|reboot|deadline|grace|pending|scheduled" } |
        Select-Object -First 15 TimeCreated, Id, @{N='Message';E={$_.Message.Substring(0, [Math]::Min($_.Message.Length, 200))}}

    if ($wuEvents) {
        foreach ($evt in $wuEvents) {
            Write-Host "  [$($evt.TimeCreated)] EventID: $($evt.Id)" -ForegroundColor DarkCyan
            Write-Host "    $($evt.Message)" -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host "  [INFO] No reboot/deadline/grace related events found in WU Client log." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  [!] Error reading WU Client event log: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ============================================================
# SECTION 11: UPDATE ORCHESTRATOR EVENTS
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 11: UPDATE ORCHESTRATOR EVENTS (Reboot/Restart Schedule)" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

$orchestratorLogs = @(
    "Microsoft-Windows-UpdateOrchestrator/Operational",
    "Microsoft-Windows-WindowsUpdateClient/Operational"
)

foreach ($logName in $orchestratorLogs) {
    try {
        $orchEvents = Get-WinEvent -LogName $logName -MaxEvents 100 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match "reboot|restart|schedule|orchestrat|engage|deadline" } |
            Select-Object -First 10 TimeCreated, Id, @{N='Message';E={$_.Message.Substring(0, [Math]::Min($_.Message.Length, 250))}}

        if ($orchEvents) {
            Write-Host "  Log: $logName" -ForegroundColor DarkCyan
            foreach ($evt in $orchEvents) {
                Write-Host "    [$($evt.TimeCreated)] EventID: $($evt.Id)" -ForegroundColor DarkGray
                Write-Host "      $($evt.Message)" -ForegroundColor Yellow
                Write-Host ""
            }
        }
    } catch {
        Write-Host "  [!] Could not read log: $logName" -ForegroundColor Red
    }
}
Write-Host ""

# ============================================================
# SECTION 12: GRACE PERIOD EXPIRY CALCULATION
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 12: GRACE PERIOD EXPIRY CALCULATION" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

if ($lastUpdateDate -and $configuredGracePeriod) {
    $gracePeriodDays = [int]$configuredGracePeriod
    $graceExpiryDate = ([DateTime]$lastUpdateDate).AddDays($gracePeriodDays)
    $now = Get-Date
    $graceExpired = $now -gt $graceExpiryDate

    Write-Host "  Last Update Installed      : $lastUpdateDate" -ForegroundColor Yellow
    Write-Host "  Configured Grace Period    : $gracePeriodDays days" -ForegroundColor Yellow
    Write-Host "  Grace Period Expires On    : $graceExpiryDate" -ForegroundColor Yellow
    Write-Host "  Current Time               : $now" -ForegroundColor Yellow

    if ($graceExpired) {
        $overdueDays = ($now - $graceExpiryDate).Days
        Write-Host ""
        Write-Host "  [!] GRACE PERIOD HAS EXPIRED! ($overdueDays days overdue)" -ForegroundColor Red
        Write-Host "  [!] Device SHOULD have force-rebooted but has NOT." -ForegroundColor Red
        $summaryFindings += "CRITICAL: Grace period expired $overdueDays days ago - device should have rebooted!"
    } else {
        $remainingDays = ($graceExpiryDate - $now).Days
        Write-Host ""
        Write-Host "  [OK] Grace period has NOT yet expired. $remainingDays days remaining." -ForegroundColor Green
        $summaryFindings += "INFO: Grace period still active - $remainingDays days remaining"
    }
} else {
    Write-Host "  [INFO] Cannot calculate grace period expiry." -ForegroundColor DarkGray
    if (-not $lastUpdateDate) {
        Write-Host "    - Could not determine last update install date." -ForegroundColor DarkGray
    }
    if (-not $configuredGracePeriod) {
        Write-Host "    - Grace period not configured or not detected in MDM policies." -ForegroundColor DarkGray
    }
    $summaryFindings += "INFO: Grace period calculation could not be completed (missing data)"
}
Write-Host ""

# ============================================================
# SECTION 13: SCHEDULED REBOOT TASK CHECK
# ============================================================
Write-Host $separator -ForegroundColor Cyan
Write-Host "  SECTION 13: WINDOWS UPDATE SCHEDULED TASKS" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan

try {
    $wuTasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\WindowsUpdate\*" -ErrorAction SilentlyContinue |
        Select-Object TaskName, State, @{N='NextRunTime';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue).NextRunTime}},
        @{N='LastRunTime';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue).LastRunTime}}

    $rebootTasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\UpdateOrchestrator\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -match "reboot|restart|schedule" } |
        Select-Object TaskName, State, @{N='NextRunTime';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue).NextRunTime}},
        @{N='LastRunTime';E={(Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue).LastRunTime}}

    if ($wuTasks) {
        Write-Host "  Windows Update Tasks:" -ForegroundColor DarkCyan
        $wuTasks | Format-Table TaskName, State, LastRunTime, NextRunTime -AutoSize
    }
    if ($rebootTasks) {
        Write-Host "  Update Orchestrator Reboot Tasks:" -ForegroundColor DarkCyan
        $rebootTasks | Format-Table TaskName, State, LastRunTime, NextRunTime -AutoSize
    }
} catch {
    Write-Host "  [!] Error reading scheduled tasks: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# ============================================================
# SUMMARY
# ============================================================
Write-Host $separator -ForegroundColor Magenta
Write-Host "  DIAGNOSTIC SUMMARY" -ForegroundColor White
Write-Host $separator -ForegroundColor Magenta
Write-Host ""

$index = 1
foreach ($finding in $summaryFindings) {
    $color = "White"
    if ($finding -match "^CRITICAL|^ALERT|^WARNING") { $color = "Red" }
    elseif ($finding -match "^OK") { $color = "Green" }
    elseif ($finding -match "^INFO|^CONFIRMED") { $color = "Yellow" }

    Write-Host "  $index. $finding" -ForegroundColor $color
    $index++
}

Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host "  RECOMMENDED NEXT STEPS:" -ForegroundColor White
Write-Host $separator -ForegroundColor Magenta
Write-Host ""
Write-Host "  1. If GPO conflicts found  -> Remove conflicting GPOs or clean registry keys" -ForegroundColor Cyan
Write-Host "  2. If grace period expired  -> Check Update Orchestrator logs for reboot blocks" -ForegroundColor Cyan
Write-Host "  3. If no MDM policies found -> Verify Update Ring assignment in Intune admin center" -ForegroundColor Cyan
Write-Host "  4. If Intune not syncing    -> Force sync: Settings > Accounts > Access work/school > Sync" -ForegroundColor Cyan
Write-Host "  5. Collect full WU logs     -> Run: Get-WindowsUpdateLog (saves to Desktop)" -ForegroundColor Cyan
Write-Host "  6. Collect MDM diagnostics  -> Run: mdmdiagnosticstool.exe -area DeviceEnrollment -cab C:\Temp\MDMDiag.cab" -ForegroundColor Cyan
Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host "  Full log saved to: $logFile" -ForegroundColor Green
Write-Host $separator -ForegroundColor Magenta
Write-Host ""

# Stop transcript
Stop-Transcript | Out-Null

Write-Host "  [DONE] Diagnostic complete. Share the log file for further analysis." -ForegroundColor Green
Write-Host ""


