# The last cleaning before the capture: nothing half-installed, no crash dumps, no downloads, no logs of the
# build. Run by Packer right before sysprep.ps1. Safe to run again.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Invoke-QuietDelete {
  # Deletes what it can. A file that is in use (this script itself, a log being written) stays. A folder
  # that vanishes while it is being deleted (Windows clearing the same cache at the same time: seen on Server
  # Core) makes Remove-Item throw a terminating error, which -ErrorAction does not silence: caught here.
  param([string[]]$Path)
  foreach ($item in $Path) {
    try {
      Remove-Item -Path $item -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      Write-Output "cleanup: left alone, $item ($($_.Exception.Message))"
    }
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

  # 3. No recovery partition behind C:. Windows Setup makes one even when the answer file has none: WinRE's
  #    agent shrinks C: and puts WinRE in a new partition at the end of the disk (seen in the first clone,
  #    setup's log: ShrinkOsPartition). A clone with a bigger disk could then never grow C:. WinRE is moved back
  #    into C: (reagentc /disable copies it to C:\Windows\System32\Recovery), the partition removed, C: grown
  #    to the end, WinRE switched on again: with no recovery partition it stays on C:.
  $os = Get-Partition -DriveLetter C
  $behind = @(Get-Partition -DiskNumber $os.DiskNumber | Where-Object { $_.Offset -gt $os.Offset })
  $recovery_type = "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}"
  $other = @($behind | Where-Object { $_.GptType -ne $recovery_type })
  if ($other.Count -gt 0) {
    throw "a partition that is not a recovery partition sits behind C: (number $($other[0].PartitionNumber)): not touched"
  }
  if ($behind.Count -gt 0) {
    & reagentc.exe /disable | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reagentc /disable ended with exit code $LASTEXITCODE" }
    foreach ($partition in $behind) {
      Remove-Partition -DiskNumber $os.DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
    }
    $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
    if ($max -gt (Get-Partition -DriveLetter C).Size) { Resize-Partition -DriveLetter C -Size $max }
    & reagentc.exe /enable | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reagentc /enable ended with exit code $LASTEXITCODE" }
    Write-Output "cleanup: recovery partition behind C: removed, C: grown to the end, WinRE now on C:"
  }
  else {
    Write-Output "cleanup: nothing behind C:"
  }

  # 4. Crash dumps
  Invoke-QuietDelete -Path "C:\Windows\MEMORY.DMP", "C:\Windows\Minidump\*", "C:\Windows\LiveKernelReports\*.dmp", "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*", "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*"
  Get-ChildItem -Path "C:\Users" -Filter "*.dmp" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Output "cleanup: crash dumps removed"

  # 5. The update download cache (the updates are installed; the downloads are only space)
  Stop-Service -Name "wuauserv", "bits" -Force -ErrorAction SilentlyContinue
  Invoke-QuietDelete -Path "C:\Windows\SoftwareDistribution\Download\*"
  Write-Output "cleanup: update download cache removed"

  # 6. Temp folders, with the logs the build's own scripts wrote. Packer's own files (this script, its
  #    environment file) stay: Packer removes them itself after each script and fails if they are gone.
  #    sysprep.ps1 removes what is left at the very end.
  Get-ChildItem -Path "C:\Windows\Temp" -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "script-*.ps1" -and $_.Name -notlike "packer-*" } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Invoke-QuietDelete -Path "C:\Users\*\AppData\Local\Temp\*"
  Write-Output "cleanup: temp folders emptied"

  # 7. Windows' own copies of the answer file. Setup has already blanked the password in them; they are
  #    removed anyway.
  #    unattend-original.xml is not blanked: it holds the build password in plain text (seen in the first
  #    clone). Then no answer file left under setup's folders may hold a password value.
  Invoke-QuietDelete -Path "C:\Windows\Panther\unattend.xml", "C:\Windows\Panther\unattend-original.xml", "C:\Windows\Panther\Unattend\*", "C:\Windows\System32\Sysprep\unattend.xml"
  $ns = @{ u = "urn:schemas-microsoft-com:unattend" }
  $files = @(Get-ChildItem -Path "C:\Windows\Panther", "C:\Windows\System32\Sysprep" -Filter "*.xml" -Recurse -File -ErrorAction SilentlyContinue)
  foreach ($file in $files) {
    $values = @(Select-Xml -Path $file.FullName -Namespace $ns -XPath "//u:Password/u:Value | //u:AdministratorPassword/u:Value" -ErrorAction SilentlyContinue |
      Where-Object { $_.Node.InnerText -and $_.Node.InnerText -notlike "*SENSITIVE*DATA*DELETED*" })
    if ($values.Count -gt 0) { throw "$($file.FullName) still holds a password" }
  }
  Write-Output "cleanup: setup's answer file copies removed; none of $($files.Count) XML files left holds a password"

  # 8. PowerShell's command history of the build account
  Invoke-QuietDelete -Path "C:\Users\*\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"

  # 9. Event logs, last: a clone's logs start with the clone. Some logs cannot be cleared; that is fine.
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
