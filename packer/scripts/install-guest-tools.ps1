# The VirtIO guest tools: every VirtIO driver and the QEMU guest agent, from the virtio-win CD.
# Run at the first logon (autounattend.xml), before Packer can connect: Packer asks the agent for the VM's
# address. Log: C:\Windows\Temp\install-guest-tools.log.
# Safe to run again: with the agent running it does nothing.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Start-Transcript -Path "C:\Windows\Temp\install-guest-tools.log" -Append | Out-Null

try {
  $agent = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
  if ($agent -and $agent.Status -eq "Running") {
    Write-Output "install-guest-tools: the QEMU guest agent is already running, nothing to do"
    exit 0
  }

  # The virtio-win CD is the one with the installer in its root; its letter is not fixed.
  $installer = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root "virtio-win-guest-tools.exe" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
  if (-not $installer) {
    throw "no drive has virtio-win-guest-tools.exe in its root: is the virtio-win ISO attached?"
  }

  Write-Output "install-guest-tools: running $installer"
  $setup = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
    "/install", "/quiet", "/norestart", "/log", "C:\Windows\Temp\virtio-win-guest-tools.log"
  )
  # 3010: installed, wants a restart (Packer restarts Windows as its first step)
  if ($setup.ExitCode -notin 0, 3010) {
    throw "virtio-win-guest-tools.exe ended with exit code $($setup.ExitCode), see C:\Windows\Temp\virtio-win-guest-tools.log"
  }

  # The agent's service is installed and started by the installer; give it a minute.
  $deadline = (Get-Date).AddSeconds(60)
  do {
    $agent = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if ($agent -and $agent.Status -eq "Running") { break }
    if ($agent -and $agent.Status -eq "Stopped") { Start-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)

  if (-not $agent -or $agent.Status -ne "Running") {
    throw "the guest tools are installed but the service QEMU-GA is not running"
  }
  Set-Service -Name "QEMU-GA" -StartupType Automatic
  Write-Output "install-guest-tools: done, the QEMU guest agent is running"
  exit 0
}
catch {
  Write-Output "install-guest-tools: FAILED: $_"
  exit 1
}
finally {
  Stop-Transcript | Out-Null
}
