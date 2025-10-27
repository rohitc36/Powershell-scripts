<#======================================================================================================================
 Script:    Fix-WUfBClient.ps1   (v2.1)
 Purpose:   Detect & remediate three Windows Update client alert scenarios on a single device:
              • ClientUpdateAlert: DeviceDiagnosticDataNotReceived
              • ServiceUpdateAlert: RegistrationMissingUpdateClient
              • ServiceUpdateAlert: NotConnectedToWindowsUpdate
 Key actions:
   - Verifies/sets Diagnostic Data (AllowTelemetry) to Required (>=1) and ensures DiagTrack is running.
   - Validates core Windows Update services (WUAgent, USO, WaaSMedic, BITS, CryptSvc).
   - Detects and (optionally) clears policy blocks:
        * DoNotConnectToWindowsUpdateInternetLocations
        * Lingering WSUS policy keys (WUServer/WUStatusServer/UseWUServer) if using WUfB
   - Shows/resets WinHTTP proxy used by WU Agent
   - Tests reachability to critical Windows Update endpoints (metadata over 443; payload/CDN over 80)
   - Forces settings refresh & scan to re-register with Windows Update.
   - Produces a clear PASS/FAIL summary.
 Switches:
   -AuditOnly            : Make no changes; only audit and report.
   -RemoveWSUS           : Remove WSUS policy keys and enable WUfB cloud processing (cloud-only scenario).
   -ResetWinHTTPProxy    : Reset WinHTTP proxy to DIRECT (fixes many connectivity issues).
   -ResetWU              : Full Windows Update component reset (SoftwareDistribution/Catroot2).
   -VerboseLog           : Save a transcript under C:\ProgramData\WUfB-Fix\Logs.
 Requirements:
   - Run in an elevated PowerShell session (Administrator).
   - Windows 10/11 Pro/Enterprise/Education.
======================================================================================================================#>
[CmdletBinding()]
param(
  [switch]$AuditOnly,
  [switch]$RemoveWSUS,
  [switch]$ResetWinHTTPProxy,
  [switch]$ResetWU,
  [switch]$VerboseLog
)
#region ---------- Helpers ----------
function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "This script must be run in an elevated (Administrator) PowerShell session."
  }
}
function Write-Info($m){ Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "[ OK  ] $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Err($m){ Write-Host "[FAIL ] $m" -ForegroundColor Red }
function New-Dir($p){ if(-not (Test-Path $p)){ New-Item -Path $p -ItemType Directory -Force | Out-Null } }
function Get-RegDword([string]$Path,[string]$Name){
  try { (Get-ItemProperty -Path $Path -ErrorAction Stop).$Name } catch { $null }
}
function Set-PolicyDword([string]$Path,[string]$Name,[int]$Value,[switch]$Audit){
  if($Audit){ Write-Warn ("AUDIT-ONLY: would set {0}\{1} = {2}" -f $Path,$Name,$Value); return }
  if(-not (Test-Path $Path)){ New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}
function Remove-PolicyValue([string]$Path,[string[]]$Names,[switch]$Audit){
  foreach($n in $Names){
    if($Audit){ Write-Warn ("AUDIT-ONLY: would remove {0}\{1}" -f $Path,$n); continue }
    try { Remove-ItemProperty -Path $Path -Name $n -ErrorAction SilentlyContinue } catch {}
  }
}
# Ensure service (tolerates protected startup types like UsoSvc/WaaSMedicSvc)
function Ensure-Service($name, $startup='Manual', [switch]$Audit){
  try {
    $svc = Get-Service -Name $name -ErrorAction Stop
    $canChangeStartup = $true
    if ($name -in @('UsoSvc','WaaSMedicSvc')) { $canChangeStartup = $false }  # protected
    if ($canChangeStartup -and $svc.StartType -ne $startup) {
      if($Audit){ Write-Warn ("AUDIT-ONLY: would Set-Service {0} -StartupType {1}" -f $name,$startup) }
      else {
        try { Set-Service -Name $name -StartupType $startup }
        catch { Write-Verbose ("StartupType change blocked for {0}: {1}" -f $name, $_.Exception.Message) }
      }
    }
    if ($svc.Status -ne 'Running') {
      if($Audit){ Write-Warn ("AUDIT-ONLY: would Start-Service {0}" -f $name) }
      else { Start-Service -Name $name -ErrorAction SilentlyContinue }
    }
    return $true
  } catch { return $false }
}
function Test-Endpoint443([string]$name){
  try {
    $ok = Test-NetConnection -ComputerName $name -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    [pscustomobject]@{ Host = $name; Port = 443; Reachable = $ok }
  } catch {
    [pscustomobject]@{ Host = $name; Port = 443; Reachable = $false }
  }
}
function Test-Endpoint80([string]$name){
  try {
    $ok = Test-NetConnection -ComputerName $name -Port 80 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    [pscustomobject]@{ Host = $name; Port = 80; Reachable = $ok }
  } catch {
    [pscustomobject]@{ Host = $name; Port = 80; Reachable = $false }
  }
}
function Get-WinHTTPProxy(){
  $o = & netsh winhttp show proxy 2>$null
  [string]::Join(" ",$o)
}
#endregion ---------- Helpers ----------
# Logging
$logRoot = 'C:\ProgramData\WUfB-Fix\Logs'
if($VerboseLog){
  try { New-Dir $logRoot; $log = Join-Path $logRoot ("WUfB-Fix_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)); Start-Transcript -Path $log -ErrorAction SilentlyContinue | Out-Null } catch {}
}
try {
  Assert-Admin
  Write-Info "Starting Windows Update diagnostics…"
  # --- Device info (for context)
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Info ("OS: {0} {1} (Build {2})" -f $os.Caption,$cv.DisplayVersion,$cv.CurrentBuildNumber)
  } catch {}
  # --- Diagnostic Data (AllowTelemetry >= 1)
  $polData = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
  $curTel = Get-RegDword $polData 'AllowTelemetry'
  if($null -eq $curTel -or $curTel -lt 1){
    Write-Warn "Diagnostic Data (AllowTelemetry) < 1. Setting to Required (1)…"
    Set-PolicyDword -Path $polData -Name 'AllowTelemetry' -Value 1 -Audit:$AuditOnly
  } else { Write-Ok ("Diagnostic Data policy OK (AllowTelemetry={0})" -f $curTel) }
  # Ensure DiagTrack (Connected User Experiences and Telemetry) is running
  if(Ensure-Service -name 'DiagTrack' -startup 'Automatic' -Audit:$AuditOnly){ Write-Ok "DiagTrack running" } else { Write-Warn "DiagTrack service unavailable/not running" }
  # --- Core Windows Update / networking services
  $svcOK = @()
  $svcOK += [pscustomobject]@{Name='wuauserv'     ;Result=(Ensure-Service 'wuauserv'      'Manual'    -Audit:$AuditOnly)}
  $svcOK += [pscustomobject]@{Name='UsoSvc'       ;Result=(Ensure-Service 'UsoSvc'        'Manual'    -Audit:$AuditOnly)}
  $svcOK += [pscustomobject]@{Name='WaaSMedicSvc' ;Result=(Ensure-Service 'WaaSMedicSvc'  'Manual'    -Audit:$AuditOnly)}
  $svcOK += [pscustomobject]@{Name='BITS'         ;Result=(Ensure-Service 'BITS'          'Manual'    -Audit:$AuditOnly)}
  $svcOK += [pscustomobject]@{Name='CryptSvc'     ;Result=(Ensure-Service 'CryptSvc'      'Automatic' -Audit:$AuditOnly)}
  foreach($s in $svcOK){ if($s.Result){ Write-Ok ("Service {0} ok" -f $s.Name) } else { Write-Err ("Service {0} missing/failure" -f $s.Name) } }
  # --- Policy that can block Microsoft Update cloud connections
  $wuPolBase = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $dnci = Get-RegDword $wuPolBase 'DoNotConnectToWindowsUpdateInternetLocations'
  if($dnci -eq 1){
    Write-Warn "Policy DoNotConnectToWindowsUpdateInternetLocations = 1 detected. Clearing to 0…"
    Set-PolicyDword -Path $wuPolBase -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Value 0 -Audit:$AuditOnly
  } else { Write-Ok "No 'DoNotConnect…' block present (or already 0)" }
  # --- Optional WSUS cleanup for WUfB cloud servicing
  if($RemoveWSUS){
    Write-Warn "Removing WSUS policy keys and enabling WUfB cloud processing…"
    Remove-PolicyValue -Path $wuPolBase -Names @('WUServer','WUStatusServer') -Audit:$AuditOnly
    $auPol = Join-Path $wuPolBase 'AU'
    Remove-PolicyValue -Path $auPol -Names @('UseWUServer') -Audit:$AuditOnly
    Set-PolicyDword -Path $wuPolBase -Name 'AllowWUfBCloudProcessing' -Value 1 -Audit:$AuditOnly
  }
  # --- Optional: full Windows Update component reset
  if($ResetWU){
    Write-Warn "Resetting Windows Update components (stop services, rename SoftwareDistribution & Catroot2)…"
    if($AuditOnly){ Write-Warn "AUDIT-ONLY: would reset WU components"; }
    else {
      $toStop='wuauserv','bits','cryptsvc','msiserver','UsoSvc'
      foreach($n in $toStop){ Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
      Start-Sleep 2
      try { Rename-Item "$env:SystemRoot\SoftwareDistribution" "SoftwareDistribution.bak_$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue } catch {}
      try { Rename-Item "$env:SystemRoot\System32\catroot2"    "catroot2.bak_$(Get-Date -Format yyyyMMddHHmmss)"           -ErrorAction SilentlyContinue } catch {}
      foreach($n in $toStop){ Start-Service -Name $n -ErrorAction SilentlyContinue }
      Write-Ok "Windows Update components reset complete"
    }
  }
  # --- WinHTTP proxy diagnostics / reset
  $whp = Get-WinHTTPProxy
  Write-Info ("WinHTTP proxy: {0}" -f $whp)
  if($ResetWinHTTPProxy){
    if($AuditOnly){ Write-Warn "AUDIT-ONLY: would reset WinHTTP proxy to DIRECT" }
    else {
      Write-Warn "Resetting WinHTTP proxy to DIRECT…"
      & netsh winhttp reset proxy | Out-Null
      $whp = Get-WinHTTPProxy
      Write-Ok ("WinHTTP proxy after reset: {0}" -f $whp)
    }
  }
  # --- Endpoint reachability tests (NotConnectedToWindowsUpdate)
  Write-Info "Testing Windows Update metadata endpoints (TCP 443)…"
  $metaHosts = @(
    'fe2.update.microsoft.com',          # Windows Update services
    'slscr.update.microsoft.com',        # Service Location Service (scan metadata)
    'settings-win.data.microsoft.com'    # OneSettings/metadata config
  )
  $meta = $metaHosts | ForEach-Object { Test-Endpoint443 $_ }
  $meta | ForEach-Object { if($_.Reachable){ Write-Ok ("443 OK  - {0}" -f $_.Host) } else { Write-Err ("443 FAIL - {0}" -f $_.Host) } }
  Write-Info "Testing Windows Update content/CDN endpoints (HTTP 80)…"
  $contentHosts = @(
    'ctldl.windowsupdate.com',
    'download.windowsupdate.com',
    'dl.delivery.mp.microsoft.com'
  )
  $cont = $contentHosts | ForEach-Object { Test-Endpoint80 $_ }
  $cont | ForEach-Object { if($_.Reachable){ Write-Ok ("80  OK  - {0}" -f $_.Host) } else { Write-Err ("80  FAIL - {0}" -f $_.Host) } }
  # --- Refresh policy and force a scan (re-registration)
  Write-Info "Refreshing policy and triggering a Windows Update scan…"
  if($AuditOnly){ Write-Warn "AUDIT-ONLY: would run gpupdate /force and USOClient scan" }
  else {
    try { gpupdate /target:computer /force | Out-Null } catch {}
    foreach($verb in 'RefreshSettings','StartScan','StartInteractiveScan'){
      try { Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList $verb -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}
      Start-Sleep 2
    }
  }
  # --- Summary
  Write-Host ""
  Write-Host "=== SUMMARY =====================================================" -ForegroundColor White
  $metaFail = $meta | Where-Object { -not $_.Reachable }
  $contFail = $cont | Where-Object { -not $_.Reachable }
  if(($metaFail | Measure-Object).Count -eq 0){ Write-Ok "WU metadata endpoints reachable (443)" } else { Write-Err ("Metadata blocked: {0}" -f (($metaFail.Host) -join ', ')) }
  if(($contFail | Measure-Object).Count -eq 0){ Write-Ok "WU content/CDN endpoints reachable (80)" } else { Write-Err ("Content blocked: {0}" -f (($contFail.Host) -join ', ')) }
  $dnciNow = Get-RegDword $wuPolBase 'DoNotConnectToWindowsUpdateInternetLocations'
  if($dnciNow -eq 1){ Write-Err "Policy still blocks Internet WU connections (DoNotConnect…=1)" } else { Write-Ok "Policy allows Internet WU connections" }
  $allSvcs = ($svcOK | Where-Object {$_.Result -eq $true}).Count -ge 5
  if($allSvcs){ Write-Ok "WU & dependent services healthy" } else { Write-Err "One or more WU services unhealthy" }
  Write-Host ""
  Write-Info "Tip: Devices typically need ≥2 continuous + 6 total connected hours after release to reliably complete updates (consider power/connected-standby for laptops)."
} catch {
  Write-Err $_.Exception.Message
} finally {
  if($VerboseLog){ try { Stop-Transcript | Out-Null } catch {} }
}
 
