# cloudbase-init: what configures a clone on its first boot from the cloud-init drive (host name, user,
# password, SSH keys, a grown disk).
# Run by Packer after the last restart of the build. Needs from the environment: CLOUDBASE_INIT_VERSION,
# CLOUDBASE_INIT_URL, CLOUDBASE_INIT_SHA256, BUILD_CD_LABEL, CLONE_USERNAME.
# Safe to run again: an installed cloudbase-init of the pinned version is kept, the files are written again.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$home_dir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init"
$msi = "C:\Windows\Temp\cloudbase-init.msi"
$msi_log = "C:\Windows\Temp\cloudbase-init-msi.log"

try {
  foreach ($name in "CLOUDBASE_INIT_VERSION", "CLOUDBASE_INIT_URL", "CLOUDBASE_INIT_SHA256", "BUILD_CD_LABEL", "CLONE_USERNAME") {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "the environment variable $name is not set" }
  }

  # 1. Install, unless this version is already there.
  $uninstall_keys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
  $installed = Get-ItemProperty -Path $uninstall_keys -ErrorAction SilentlyContinue |
    Where-Object { $_.PSObject.Properties["DisplayName"] -and $_.DisplayName -like "Cloudbase-Init*" } |
    Select-Object -First 1
  if ($installed -and $installed.DisplayVersion -like "$($env:CLOUDBASE_INIT_VERSION)*") {
    Write-Output "install-cloudbase-init: version $($installed.DisplayVersion) is already installed"
  }
  else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $attempt = 0
    while ($true) {
      $attempt++
      try {
        Write-Output "install-cloudbase-init: downloading $($env:CLOUDBASE_INIT_URL)"
        (New-Object System.Net.WebClient).DownloadFile($env:CLOUDBASE_INIT_URL, $msi)
        break
      }
      catch {
        if ($attempt -ge 5) { throw "download failed $attempt times, the last error: $_" }
        Start-Sleep -Seconds 15
      }
    }

    # The pin: a file with another hash is never run.
    $hash = (Get-FileHash -Path $msi -Algorithm SHA256).Hash
    if ($hash -ne $env:CLOUDBASE_INIT_SHA256) {
      Remove-Item -Path $msi -Force
      throw "the downloaded MSI has sha256 $($hash.ToLower()), expected $($env:CLOUDBASE_INIT_SHA256)"
    }

    # Silent (/qn): the installer's last page, which offers to run sysprep and to start the service, is
    # never shown, so neither happens. The service runs as LocalSystem: otherwise the installer makes a
    # local account "cloudbase-init" with a password of its own, one more account in every clone.
    Write-Output "install-cloudbase-init: installing"
    $setup = Start-Process -FilePath "msiexec.exe" -Wait -PassThru -ArgumentList @(
      "/i", "`"$msi`"", "/qn", "/norestart", "/l*v", "`"$msi_log`"", "RUN_SERVICE_AS_LOCAL_SYSTEM=1"
    )
    if ($setup.ExitCode -notin 0, 3010) {
      throw "msiexec ended with exit code $($setup.ExitCode), see $msi_log"
    }
    Remove-Item -Path $msi -Force
  }

  # 2. The service must exist and not run now: its first run belongs to a clone. In the template it does not
  #    start with Windows: started by Windows, it would run while a clone is still in Windows setup, where a
  #    user's profile cannot be loaded yet ("The device is not ready"), so the user gets no profile and no SSH
  #    keys, and the service may restart Windows in the middle of setup (seen in the first clone). Windows runs
  #    SetupComplete.cmd once, as SYSTEM, when setup has finished and before the logon screen: that file makes
  #    the service start with Windows from then on and starts it.
  $service = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
  if (-not $service) { throw "the service cloudbase-init does not exist after the install" }
  if ($service.Status -ne "Stopped") { Stop-Service -Name "cloudbase-init" -Force }
  Set-Service -Name "cloudbase-init" -StartupType Manual

  $setup_scripts = "C:\Windows\Setup\Scripts"
  $setup_complete = "$setup_scripts\SetupComplete.cmd"
  if ((Test-Path $setup_complete) -and -not (Select-String -Path $setup_complete -Pattern "cloudbase-init" -Quiet)) {
    throw "$setup_complete already exists and was not written by this build: not overwritten"
  }
  New-Item -ItemType Directory -Path $setup_scripts -Force | Out-Null
  Set-Content -Path $setup_complete -Encoding ascii -Value @'
@echo off
rem Written by the template build (install-cloudbase-init.ps1). Windows runs this once, as SYSTEM, when setup
rem has finished: from now on cloudbase-init starts with Windows, and its first run starts now.
sc.exe config cloudbase-init start= auto
sc.exe start cloudbase-init
exit /b 0
'@
  Write-Output "install-cloudbase-init: service set to Manual; $setup_complete starts it once setup has finished"

  # 3. Both configuration files, rendered by Packer onto the build CD (found by its label).
  $letter = (Get-Volume -FileSystemLabel $env:BUILD_CD_LABEL -ErrorAction SilentlyContinue | Select-Object -First 1).DriveLetter
  if (-not $letter) { throw "no drive has the label $($env:BUILD_CD_LABEL): is the build CD attached?" }
  foreach ($file in "cloudbase-init.conf", "cloudbase-init-unattend.conf") {
    $source = "${letter}:\$file"
    if (-not (Test-Path $source)) { throw "$source is missing on the build CD" }
    Copy-Item -Path $source -Destination "$home_dir\conf\$file" -Force
    Write-Output "install-cloudbase-init: wrote conf\$file"
  }

  # 4. The answer file sysprep will be given comes with the installer; sysprep.ps1 depends on it.
  if (-not (Test-Path "$home_dir\conf\Unattend.xml")) { throw "$home_dir\conf\Unattend.xml is missing" }

  # 5. A script cloudbase-init runs once on a clone (LocalScriptsPlugin): the built-in Administrator is the
  #    build account, and no clone should have it switched on beside its own administrator. sysprep.ps1
  #    disables it before the capture; this holds even if Windows setup switches it back on in a clone.
  $local_script = "$home_dir\LocalScripts\disable-builtin-administrator.ps1"
  if ($env:CLONE_USERNAME -ne "Administrator") {
    New-Item -ItemType Directory -Path "$home_dir\LocalScripts" -Force | Out-Null
    Set-Content -Path $local_script -Encoding ascii -Value @'
# Written by the template build. The built-in Administrator (its SID ends in -500) stays disabled: this
# machine's administrator is the user cloudbase-init created.
Get-LocalUser | Where-Object { $_.SID.Value -like "S-1-5-21-*-500" -and $_.Enabled } | Disable-LocalUser
exit 0
'@
    Write-Output "install-cloudbase-init: wrote LocalScripts\disable-builtin-administrator.ps1"
  }
  elseif (Test-Path $local_script) {
    Remove-Item -Path $local_script -Force
  }

  Write-Output "install-cloudbase-init: done"
  exit 0
}
catch {
  Write-Output "install-cloudbase-init: FAILED: $_"
  exit 1
}
