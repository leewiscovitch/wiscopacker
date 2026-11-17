# The settings AWS gives its official Windows images, one block per row of the table in README.md.
# Run by Packer. Needs from the environment: TIME_ZONE. Safe to run again: every block sets a value.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-RegistryValue {
  param([string]$Path, [string]$Name, [string]$Type, $Value)
  if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Invoke-Native {
  # Runs a program and stops the script if it fails (PowerShell 5 does not do that by itself).
  param([string]$File, [string[]]$Arguments)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$File $($Arguments -join ' ') ended with exit code $LASTEXITCODE" }
}

try {
  # --- Time zone (UTC unless the build says otherwise) ---
  $time_zone = if ($env:TIME_ZONE) { $env:TIME_ZONE } else { "UTC" }
  Set-TimeZone -Id $time_zone
  Write-Output "tune: time zone $time_zone"

  # --- RealTimeIsUniversal: Windows reads and writes the hardware clock as UTC, not as local time.
  #     The VM must then hand out UTC as well (Proxmox: localtime=0, set after the build).
  Write-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" -Name "RealTimeIsUniversal" -Type DWord -Value 1
  Write-Output "tune: hardware clock is UTC (RealTimeIsUniversal)"

  # --- Secure time seeding off: it guesses the time from TLS handshakes and has set servers' clocks
  #     months off. Time comes from the time service alone.
  Write-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config" -Name "UtilizeSslTimeData" -Type DWord -Value 0
  Write-Output "tune: secure time seeding off"

  # --- Power plan "high performance" (a VM has nothing to save by slowing down) ---
  Invoke-Native -File "powercfg.exe" -Arguments "/setactive", "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
  Write-Output "tune: power plan high performance"

  # --- Hibernation off, which also removes hiberfil.sys (as large as the memory). A VM's firmware may not
  #     offer hibernation at all: then there is nothing to switch off and powercfg says so.
  & cmd.exe /c "powercfg.exe /hibernate off > nul 2>&1"
  if (Test-Path "C:\hiberfil.sys") { throw "hibernation is still on: C:\hiberfil.sys exists" }
  Write-Output "tune: hibernation off"

  # --- Display never switched off (the console stays readable) ---
  Invoke-Native -File "powercfg.exe" -Arguments "/change", "monitor-timeout-ac", "0"
  Invoke-Native -File "powercfg.exe" -Arguments "/change", "monitor-timeout-dc", "0"
  Write-Output "tune: display never off"

  # --- Visual effects "best performance" and no password when the screen saver ends. Both are per user,
  #     so they go into the default profile: every user made later (a clone's administrator) starts with
  #     them.
  $hive = "HKU\wiscopacker-default"
  Invoke-Native -File "reg.exe" -Arguments "load", $hive, "C:\Users\Default\NTUSER.DAT"
  try {
    Invoke-Native -File "reg.exe" -Arguments "add", "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects", "/v", "VisualFXSetting", "/t", "REG_DWORD", "/d", "2", "/f"
    Invoke-Native -File "reg.exe" -Arguments "add", "$hive\Control Panel\Desktop", "/v", "ScreenSaverIsSecure", "/t", "REG_SZ", "/d", "0", "/f"
  }
  finally {
    [GC]::Collect()
    Invoke-Native -File "reg.exe" -Arguments "unload", $hive
  }
  Write-Output "tune: default profile: visual effects best performance, screen saver without password"

  # --- Telemetry service ("Connected User Experiences and Telemetry") off ---
  $telemetry = Get-Service -Name "DiagTrack" -ErrorAction SilentlyContinue
  if ($telemetry) {
    Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "DiagTrack" -StartupType Disabled
    Write-Output "tune: telemetry service disabled"
  }
  else {
    Write-Output "tune: no telemetry service (DiagTrack) on this Windows"
  }

  # --- Execution policy RemoteSigned: local scripts run, downloaded ones need a signature ---
  #     Packer runs this script with the policy "Bypass" for its own process; Set-ExecutionPolicy reports
  #     that as an error although the machine's value is written, so the value is read back instead.
  try { Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force }
  catch { Write-Output "tune: Set-ExecutionPolicy reported (expected under Packer): $($_.Exception.Message.Split([char]10)[0])" }
  if ((Get-ExecutionPolicy -Scope LocalMachine) -ne "RemoteSigned") { throw "the machine's execution policy is not RemoteSigned" }
  Write-Output "tune: execution policy RemoteSigned"

  # --- Page file: system-managed is Windows' default. Checked, not set. ---
  $computer = Get-CimInstance -ClassName Win32_ComputerSystem
  if (-not $computer.AutomaticManagedPagefile) { throw "the page file is not system-managed" }
  Write-Output "tune: page file is system-managed (checked)"

  Write-Output "tune: done"
  exit 0
}
catch {
  Write-Output "tune: FAILED: $_"
  exit 1
}
