# The last cleaning before the capture: nothing half-installed, no crash dumps, no downloads, no logs of the
# build. Run by Packer right before sysprep.ps1. Safe to run again.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-QuietDelete {
  # Deletes what it can. A file that is in use (this script itself, a log being written) stays.
  param([string[]]$Path)
  foreach ($item in $Path) {
    Remove-Item -Path $item -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Test-RebootPending {
  # The two places where Windows notes "an installation finishes at the next restart". sysprep refuses to
  # run while the first is set.
  (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
  (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
}

try {
  # 1. Wait until nothing is installing any more (updates finishing after the restart, the .NET
  #    optimiser's installers): up to 20 minutes, done when two checks in a row find nothing.
  $deadline = (Get-Date).AddMinutes(20)
  $quiet = 0
  while ($quiet -lt 2) {
    $busy = @(Get-Process -Name "TiWorker", "TrustedInstaller", "msiexec" -ErrorAction SilentlyContinue)
    if ($busy.Count -eq 0) { $quiet++ } else { $quiet = 0 }
    if ((Get-Date) -gt $deadline) {
      throw "still installing after 20 minutes: $(($busy | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', ')"
    }
    if ($quiet -lt 2) { Start-Sleep -Seconds 15 }
  }
  Write-Output "cleanup: nothing is installing"

  # 2. No restart may be pending: the build restarted Windows just before this. If one is, the image would
  #    carry a half-finished installation into every clone.
  if (Test-RebootPending) {
    throw "Windows still wants a restart to finish an installation (after the build's restart): look at the Windows Update history"
  }
  $renames = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue)
  if ($renames) {
    # Often a leftover temp file to delete at the next boot: harmless, and it happens then in the clone.
    Write-Output "cleanup: note: $(@($renames.PendingFileRenameOperations).Count) pending file rename entries (not an error)"
  }
  Write-Output "cleanup: no restart pending"

  # 3. Crash dumps
  Invoke-QuietDelete -Path "C:\Windows\MEMORY.DMP", "C:\Windows\Minidump\*", "C:\Windows\LiveKernelReports\*.dmp", "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*", "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*"
  Get-ChildItem -Path "C:\Users" -Filter "*.dmp" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Output "cleanup: crash dumps removed"

  # 4. The update download cache (the updates are installed; the downloads are only space)
  Stop-Service -Name "wuauserv", "bits" -Force -ErrorAction SilentlyContinue
  Invoke-QuietDelete -Path "C:\Windows\SoftwareDistribution\Download\*"
  Write-Output "cleanup: update download cache removed"

  # 5. Temp folders, with the logs the build's own scripts wrote. Packer's own files (this script, its
  #    environment file) stay: Packer removes them itself after each script and fails if they are gone.
  #    sysprep.ps1 removes what is left at the very end.
  Get-ChildItem -Path "C:\Windows\Temp" -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "script-*.ps1" -and $_.Name -notlike "packer-*" } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-QuietDelete -Path "C:\Users\*\AppData\Local\Temp\*"
  Write-Output "cleanup: temp folders emptied"

  # 6. Windows' own copies of the answer file. Setup has already blanked the password in them; they are
  #    removed anyway.
  Invoke-QuietDelete -Path "C:\Windows\Panther\unattend.xml", "C:\Windows\Panther\Unattend\*", "C:\Windows\System32\Sysprep\unattend.xml"
  Write-Output "cleanup: setup's answer file copies removed"

  # 7. PowerShell's command history of the build account
  Invoke-QuietDelete -Path "C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"

  # 8. Event logs, last: a clone's logs start with the clone. Some logs cannot be cleared; that is fine.
  $cleared = 0
  foreach ($log in (& wevtutil.exe el)) {
    & cmd.exe /c "wevtutil.exe cl `"$log`" > nul 2>&1"
    if ($LASTEXITCODE -eq 0) { $cleared++ }
  }
  Write-Output "cleanup: $cleared event logs cleared"

  Write-Output "cleanup: done"
  exit 0
}
catch {
  Write-Output "cleanup: FAILED: $_"
  exit 1
}
