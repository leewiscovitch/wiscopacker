# OpenSSH server: how Packer gets into the build VM, and how a clone is managed later.
# Run at the first logon (autounattend.xml), from the build CD; sshd_config lies beside this script.
# Log: C:\Windows\Temp\enable-communicator.log. Safe to run again.
#
# The shell sshd starts stays cmd.exe for the build: Packer wraps each script in a command line that only
# cmd passes on unchanged. sysprep.ps1 makes PowerShell the shell as its last setting.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:\Windows\Temp\enable-communicator.log" -Append | Out-Null

try {
  # 1. The network profile: "private", as a machine on a trusted network. A fresh Windows calls its network
  #    "public" (or is still working it out). The firewall rule below does not depend on it; this is for
  #    everything else that looks at the profile during the build. Not worth failing for.
  $deadline = (Get-Date).AddSeconds(90)
  do {
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    if ($profiles.Count -gt 0) { break }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)
  try {
    $profiles | Where-Object { $_.NetworkCategory -eq "Public" } | Set-NetConnectionProfile -NetworkCategory Private
    Write-Output "enable-communicator: network profile set to private"
  }
  catch {
    Write-Output "enable-communicator: could not set the network profile to private (going on): $_"
  }

  # 2. The OpenSSH server. Windows Server 2025 has it installed and switched off; elsewhere it is a
  #    capability that Windows downloads.
  $capability = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
  if (-not $capability) {
    throw "this Windows has no capability named OpenSSH.Server"
  }
  if ($capability.State -ne "Installed") {
    Write-Output "enable-communicator: installing $($capability.Name)"
    Add-WindowsCapability -Online -Name $capability.Name | Out-Null
  }

  # 3. The first start makes C:\ProgramData\ssh and the host keys. Then our configuration, and a restart.
  Set-Service -Name "sshd" -StartupType Automatic
  Start-Service -Name "sshd"
  $source = Join-Path $PSScriptRoot "sshd_config"
  if (-not (Test-Path $source)) {
    throw "sshd_config is not beside this script ($PSScriptRoot)"
  }
  Copy-Item -Path $source -Destination "C:\ProgramData\ssh\sshd_config" -Force

  # 4. The firewall: port 22 on every profile. Windows' own rule covers the private profile only, and a
  #    clone's network starts as "public".
  $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
  if ($rule) {
    $rule | Set-NetFirewallRule -Enabled True -Profile Any
  }
  else {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH SSH Server (sshd)" `
      -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -Enabled True | Out-Null
  }

  Restart-Service -Name "sshd"
  if ((Get-Service -Name "sshd").Status -ne "Running") {
    throw "the service sshd is not running after its restart (is sshd_config valid?)"
  }
  Write-Output "enable-communicator: done, sshd is running"
  exit 0
}
catch {
  Write-Output "enable-communicator: FAILED: $_"
  exit 1
}
finally {
  Stop-Transcript | Out-Null
}
