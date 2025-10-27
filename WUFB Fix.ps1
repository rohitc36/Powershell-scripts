<#
.SYNOPSIS
  Detects and remediates issues behind:
   - ClientUpdateAlert: DeviceDiagnosticDataNotReceived
   - ServiceUpdateAlert: RegistrationMissingUpdateClient

.DESCRIPTION
  - Ensures Diagnostic Data (telemetry) is enabled at Required level
  - Validates/starts core Windows Update & telemetry services
  - Checks WUfB Deployment Service (WUfB-DS) enrollment hints
  - Optionally removes legacy WSUS policy and resets WU components
  - Tests outbound connectivity to Microsoft telemetry & WU endpoints
  - Forces settings refresh, telemetry signal, and WU scan

.PARAMETER RemoveWSUS
  Removes WSUS policy (UseWUServer/WUServer/WUStatusServer) and enables native Windows Update (cloud).
  Use only if your update source should be Microsoft Update/WUfB.

.PARAMETER ResetWU
  Performs a full Windows Update component reset (stops services, renames SoftwareDistribution & Catroot2).

.PARAMETER VerboseLog
  Writes a detailed transcript to C:\ProgramData\WUfB-Fix\Logs\.

.OUTPUTS
  Summarized PASS/FAIL for:
   - Diagnostic Data level
   - Telemetry service state
   - WU core services
   - WUfB-DS enrollment signals present
   - Endpoint connectivity (443)
   - Last scan/install times
   - Final re-scan result

.NOTES
  Tested on Windows 10/11 Enterprise/Pro. Requires elevation.
#>

[CmdletBinding()]
param(
  [switch]$RemoveWSUS,
  [switch]$ResetWU,
  [switch]$VerboseLog
)

#region helpers
function Write-Info($msg){ Write-Host "[INFO ] $msg" -ForegroundColor Cyan }
function Write-Ok($msg){ Write-Host "[ OK  ] $msg" -ForegroundColor Green }
function Write-Warn($msg){ Write-Host "[WARN ] $msg" -ForegroundColor Yellow }
function Write-Err($msg){ Write-Host "[FAIL ] $msg" -ForegroundColor Red }
function New-Dir($path){ if(-not (Test-Path $path)){ New-Item -Path $path -ItemType Directory -Force | Out-Null } }
function Get-RegDword([string]$Path,[string]$Name){
  try{ (Get-ItemProperty -Path $Path -ErrorAction Stop).$Name } catch { $null }
}
function Set-RegDword([string]$Path,[string]$Name,[int]$Value){
  if(-not (Test-Path $Path)){ New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}
function Ensure-Service($name, $startup='Manual'){
  try{
    $svc = Get-Service -Name $name -ErrorAction Stop
    if($svc.StartType -ne $startup){ Set-Service -Name $name -StartupType $startup }
    if($svc.Status -ne 'Running'){ Start-Service -Name $name -ErrorAction SilentlyContinue }
    $true
  } catch { $false }
}
function Test-Endpoint443($host){
  try{
    $r = Test-NetConnection -ComputerName $host -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    [PSCustomObject]@{Host=$host; Port=443; Reachable=$r}
  } catch { [PSCustomObject]@{Host=$host; Port=443; Reachable=$false} }
}
#endregion

# Logging
$logRoot = 'C:\ProgramData\WUfB-Fix\Logs'
if($VerboseLog){ New-Dir $logRoot; $log = Join-Path $logRoot ("WUfB-Fix_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)); Start-Transcript -Path $log -ErrorAction SilentlyContinue | Out-Null }

try{
  Write-Info "Starting checks…"

  # ---- Basic device info
  $os = (Get-CimInstance Win32_OperatingSystem)
  $build = [int](GetntBuildNumber
  $releaseId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
  Write-Info "OS: $($os.Caption) $releaseId (Build $build)"

  # ---- AAD Join check (helps with WUfB-DS prerequisites)
  $aad = & dsregcmd.exe /status 2>$null
  $aadJoined = ($aad -match 'AzureAdJoined\s*:\s*YES') -or ($aad -match 'AzureAdJoined\s*:\s*Yes')
  if($aadJoined){ Write-Ok "Azure AD Joined: YES" } else { Write-Warn "Azure AD Joined: NO (WUfB-DS requires Entra join/hybrid for best results)" }

  # ---- Last WU scan/install times (for visibility)
  $wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results'
  $lastDetect = (Get-ItemProperty "$wuKey\Detect" -ErrorAction SilentlyContinue).LastSuccessTime
  $lastInstall = (Get-ItemProperty "$wuKey\Install" -ErrorAction SilentlyContinue).LastSuccessTime
  if($lastDetect){ Write-Info "Last Detect:  $lastDetect" } else { Write-Warn "Last Detect:  (none)" }
  if($lastInstall){ Write-Info "Last Install: $lastInstall" } else { Write-Warn "Last Install: (none)" }

  # ---- Ensure Diagnostic Data level (Required => AllowTelemetry >=1)
  $polData = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
  $curTelemetry = Get-RegDword $polData 'AllowTelemetry'
  if($null -eq $curTelemetry -or $curTelemetry -lt 1){
    Write-Warn "Diagnostic Data policy not set to Required. Setting AllowTelemetry=1…"
    Set-RegDword $polData 'AllowTelemetry' 1
  } else {
    Write-Ok "Diagnostic Data policy present (AllowTelemetry=$curTelemetry)"
  }
  # Mirror default path as well (helps when policies not applied yet)
  $defData = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'
  if( (Get-RegDword $defData 'AllowTelemetry') -lt 1 ){ Set-RegDword $defData 'AllowTelemetry' 1 }

  # ---- Start telemetry pipeline (DiagTrack)
  if(Ensure-Service -name 'DiagTrack' -startup 'Automatic'){ Write-Ok "DiagTrack running" } else { Write-Warn "DiagTrack service not found/running" }

  # ---- Make sure WU core services are healthy
  $svcOk = @()
  $svcOk += [pscustomobject]@{Name='wuauserv';Result=(Ensure-Service 'wuauserv' 'Manual')}
  $svcOk += [pscustomobject]@{Name='UsoSvc';Result=(Ensure-Service 'UsoSvc' 'Manual')}
  $svcOk += [pscustomobject]@{Name='WaaSMedicSvc';Result=(Ensure-Service 'WaaSMedicSvc' 'Manual')}
  $svcOk += [pscustomobject]@{Name='BITS';Result=(Ensure-Service 'BITS' 'Manual')}
  $svcOk += [pscustomobject]@{Name='CryptSvc';Result=(Ensure-Service 'CryptSvc' 'Automatic')}
  foreach($s in $svcOk){ if($s.Result){ Write-Ok "Service $($s.Name) ok" } else { Write-Err "Service $($s.Name) missing or failed to start" } }

  # ---- (Optional) Remove WSUS policy for WUfB cloud servicing
  if($RemoveWSUS){
    $wuPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $auPol = Join-Path $wuPol 'AU'
    if(Test-Path $wuPol){
      Write-Warn "Removing WSUS policy keys (UseWUServer/WUServer/WUStatusServer)…"
      Remove-ItemProperty -Path $auPol -Name 'UseWUServer' -ErrorAction SilentlyContinue
      Remove-ItemProperty -Path $wuPol -Name 'WUServer','WUStatusServer' -ErrorAction SilentlyContinue
    }
    # Ensure cloud processing flag (helps WUfB scenarios)
    Set-RegDword $wuPol 'AllowWUfBCloudProcessing' 1
    Write-Ok "Configured AllowWUfBCloudProcessing=1"
  }

  # ---- (Optional) Full Windows Update reset
  if($ResetWU){
    Write-Warn "Resetting Windows Update components (stopping services, renaming SoftwareDistribution & Catroot2)…"
    $toStop = 'wuauserv','bits','cryptsvc','msiserver','UsoSvc'
    foreach($n in $toStop){ Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Rename-Item -Path "$env:SystemRoot\SoftwareDistribution" -NewName "SoftwareDistribution.bak_$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue
    Rename-Item -Path "$env:SystemRoot\System32\catroot2" -NewName "catroot2.bak_$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue
    foreach($n in $toStop){ Start-Service -Name $n -ErrorAction SilentlyContinue }
    Write-Ok "Windows Update components reset complete"
  }

  # ---- WUfB-DS enrollment hints (read-only)
  $wufbKey = 'HKLM:\SOFTWARE\Microsoft\WufbDS'
  $wufbExists = Test-Path $wufbKey
  $wufbQual = if($wufbExists){ (Get-ItemProperty $wufbKey -ErrorAction SilentlyContinue).'enrollmenttype' } else { $null }
  if($wufbExists){
    Write-Info "WUfB-DS key present. enrollmenttype='$wufbQual'"
  } else {
    Write-Warn "WUfB-DS enrollment key not present yet (will try to refresh settings/scan to trigger)."
  }

  # ---- Network connectivity to telemetry & WU endpoints
  Write-Info "Testing outbound 443 connectivity to critical endpoints…"
  $hosts = @(
    # Diagnostic data / settings
    'us-v10c.events.data.microsoft.com',
    'settings-win.data.microsoft.com',
    'watsonc.events.data.microsoft.com',
    # Windows Update / Delivery
    'fe2.update.microsoft.com',
    'download.windowsupdate.com',
    'delivery.mp.microsoft.com'
  )
  $net = $hosts | ForEach-Object { Test-Endpoint443 $_ }
  $net | ForEach-Object { if($_.Reachable){ Write-Ok ("443 OK  - {0}" -f $_.Host) } else { Write-Err ("443 FAIL - {0}" -f $_.Host) } }

  # ---- Force policy refresh / WU re-registration
  Write-Info "Refreshing device policy & Windows Update settings…"
  try{ Invoke-Command { gpupdate /target:computer /force | Out-Null } } catch {}
  Start-Sleep 2
  # USOClient calls (best-effort; some verbs vary by build)
  foreach($verb in 'RefreshSettings','StartScan','StartInteractiveScan'){
    try{ Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList $verb -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 3
  }

  # ---- Light telemetry nudge (best-effort ETW flush)
  wevtutil.exe qe Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin /c:1 /rd:true /f:text 2>$null | Out-Null

  # ---- Re-check last detect time after scan
  Start-Sleep -Seconds 8
  $lastDetect2 = (Get-ItemProperty "$wuKey\Detect" -ErrorAction SilentlyContinue).LastSuccessTime
  if($lastDetect2 -and $lastDetect2 -ne $lastDetect){
    Write-Ok "WU scan refreshed: $lastDetect2"
  } else {
    Write-Warn "WU scan time did not update yet (backend may take time)."
  }

  # ---- Summary
  Write-Host ""
  Write-Host "=== SUMMARY ===" -ForegroundColor White
  $teleOk = (Get-RegDword $polData 'AllowTelemetry') -ge 1
  if($teleOk){ Write-Ok "Diagnostic Data (AllowTelemetry) = $(Get-RegDword $polData 'AllowTelemetry')" } else { Write-Err "Diagnostic Data not set to Required (>=1)" }
  if(($net | Where-Object {!$_.Reachable}).Count -eq 0){ Write-Ok "All tested endpoints reachable on 443" } else { Write-Warn "One or more telemetry/WU endpoints blocked" }
  $wuSvcHealthy = $svcOk.Where({$_.Result -eq $true}).Count -ge 5
  if($wuSvcHealthy){ Write-Ok "WU core services healthy" } else { Write-Err "One or more WU services failed" }
  if(Test-Path $wufbKey){ Write-Ok "WUfB-DS enrollment key present (enrollmenttype='$wufbQual')" } else { Write-Warn "WUfB-DS enrollment key still missing (allow 24–48h after first good telemetry)" }

} finally {
  if($VerboseLog){ Stop-Transcript | Out-Null }
}
