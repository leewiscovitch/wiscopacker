# The capture: make this Windows a neutral image (sysprep /generalize), ready to start setup again in every
# clone, with cloudbase-init doing the answers there.
# The last script Packer runs. Needs from the environment: CLONE_USERNAME. After it Packer does not connect
# again: it shuts the VM down through the Proxmox API and makes it a template.
#
# Not safe to run twice on purpose: a generalized Windows is finished. A second run says so and ends well.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$home_dir = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init"
$unattend = "$home_dir\conf\Unattend.xml"
$sysprep_dir = "C:\Windows\System32\Sysprep"
$state_key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State"

function Test-Generalized {
  # Windows Setup's own state (Microsoft: "Windows Setup States"): IMAGE_STATE_COMPLETE on an installed
  # Windows, IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE once sysprep /generalize /oobe has run. Not
  # SYSTEM\Setup\Status\SysprepStatus\GeneralizationState: that is 7 on a fresh install as well.
  $state = Get-ItemProperty -Path $state_key -Name "ImageState" -ErrorAction SilentlyContinue
  ($null -ne $state) -and ($state.ImageState -eq "IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE")
}

try {
  if (-not $env:CLONE_USERNAME) { throw "the environment variable CLONE_USERNAME is not set" }

  if (Test-Generalized) {
    Write-Output "sysprep: this Windows is already generalized, nothing to do"
    exit 0
  }

  # 1. What a clone's first boot depends on must be in place before the image is sealed.
  if (-not (Test-Path $unattend)) { throw "$unattend is missing: was install-cloudbase-init.ps1 run?" }
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='cloudbase-init'"
  if (-not $service) { throw "the service cloudbase-init does not exist" }
  # Manual until Windows setup has finished in a clone; SetupComplete.cmd then starts it (install-cloudbase-init.ps1)
  if ($service.StartMode -ne "Manual") { throw "the service cloudbase-init must be Manual in the template (start mode $($service.StartMode))" }
  $setup_complete = "C:\Windows\Setup\Scripts\SetupComplete.cmd"
  if (-not (Test-Path $setup_complete) -or -not (Select-String -Path $setup_complete -Pattern "sc.exe start cloudbase-init" -SimpleMatch -Quiet)) {
    throw "$setup_complete does not start cloudbase-init: was install-cloudbase-init.ps1 run?"
  }
  if ($service.State -ne "Stopped") { throw "the service cloudbase-init is running in the build VM: it must run first in a clone" }

  # 2. PersistAllDeviceInstalls: sysprep normally forgets every installed device, and a clone would have
  #    to find the VirtIO disk and network card again. With it the drivers stay bound. The file that comes
  #    with cloudbase-init has the setting; it is added here if a later version drops it.
  [xml]$xml = Get-Content -Path $unattend -Raw
  $ns = "urn:schemas-microsoft-com:unattend"
  $manager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $manager.AddNamespace("u", $ns)
  $persist = $xml.SelectSingleNode("/u:unattend/u:settings[@pass='generalize']/u:component[@name='Microsoft-Windows-PnpSysprep']/u:PersistAllDeviceInstalls", $manager)
  if ($persist -and $persist.InnerText.Trim() -eq "true") {
    Write-Output "sysprep: Unattend.xml has PersistAllDeviceInstalls"
  }
  else {
    $settings = $xml.SelectSingleNode("/u:unattend/u:settings[@pass='generalize']", $manager)
    if (-not $settings) {
      $settings = $xml.CreateElement("settings", $ns)
      $settings.SetAttribute("pass", "generalize")
      $xml.DocumentElement.AppendChild($settings) | Out-Null
    }
    $component = $settings.SelectSingleNode("u:component[@name='Microsoft-Windows-PnpSysprep']", $manager)
    if (-not $component) {
      $component = $xml.CreateElement("component", $ns)
      $component.SetAttribute("name", "Microsoft-Windows-PnpSysprep")
      $component.SetAttribute("processorArchitecture", "amd64")
      $component.SetAttribute("publicKeyToken", "31bf3856ad364e35")
      $component.SetAttribute("language", "neutral")
      $component.SetAttribute("versionScope", "nonSxS")
      $settings.AppendChild($component) | Out-Null
    }
    if (-not $persist) {
      $persist = $xml.CreateElement("PersistAllDeviceInstalls", $ns)
      $component.AppendChild($persist) | Out-Null
    }
    $persist.InnerText = "true"
    $xml.Save($unattend)
    Write-Output "sysprep: added PersistAllDeviceInstalls to Unattend.xml"
  }

  # 3. PowerShell as the shell sshd starts, from here on (the session running this script keeps cmd.exe).
  #    It was cmd.exe for the build because of how Packer runs scripts; a clone is managed in PowerShell.
  if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) { New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null }
  New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -PropertyType String -Force `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
  Write-Output "sysprep: sshd's shell is PowerShell from the next connection on"

  # 4. The build account (the built-in Administrator, SID ending in -500) is disabled: its password was
  #    this build's, and no clone should have an account it did not ask for. Not when the clones' own user
  #    is that very account. Disabling does not end the session this script runs in.
  if ($env:CLONE_USERNAME -ne "Administrator") {
    Get-LocalUser | Where-Object { $_.SID.Value -like "S-1-5-21-*-500" } | Disable-LocalUser
    Write-Output "sysprep: the built-in Administrator is disabled"
  }

  # 5. sysprep. /generalize: remove what is unique to this installation. /oobe: the next boot runs setup's
  #    last part again. /quit: do not shut down, come back here, so that a failure is seen and reported
  #    (Packer shuts the VM down afterwards). /unattend: the answers for that next boot, which hand over
  #    to cloudbase-init. The answer file by its bare name, from its own folder (as cloudbase-init's docs run
  #    it): its full path has spaces, and sysprep stopped with "Unable to parse command-line arguments" on
  #    /unattend:"C:\Program Files\...\Unattend.xml" as Start-Process passed it. Sysprep keeps its own copy
  #    (Windows\Panther), so the folder does not matter after this.
  Remove-Item -Path "$sysprep_dir\Sysprep_succeeded.tag" -Force -ErrorAction SilentlyContinue
  Write-Output "sysprep: running sysprep /generalize /oobe /quit (a few minutes)"
  $run = Start-Process -FilePath "$sysprep_dir\sysprep.exe" -Wait -PassThru -WorkingDirectory (Split-Path $unattend) `
    -ArgumentList "/generalize /oobe /quit /quiet /unattend:$(Split-Path $unattend -Leaf)"

  if (-not ((Test-Path "$sysprep_dir\Sysprep_succeeded.tag") -and (Test-Generalized))) {
    Write-Output "sysprep: sysprep.exe ended with exit code $($run.ExitCode) and did not generalize. The end of its error log:"
    foreach ($log in "$sysprep_dir\Panther\setuperr.log", "$sysprep_dir\Panther\setupact.log") {
      if ((Test-Path $log) -and (Get-Item $log).Length -gt 0) {
        Get-Content -Path $log -Tail 30
        break
      }
    }
    throw "sysprep did not generalize this Windows (logs: $sysprep_dir\Panther)"
  }
  Write-Output "sysprep: generalized"

  # 6. sshd's host keys: each clone makes its own at its first start, instead of all sharing the template's.
  Remove-Item -Path "C:\ProgramData\ssh\ssh_host_*" -Force -ErrorAction SilentlyContinue
  Write-Output "sysprep: sshd host keys removed"

  # 7. What Packer left in the temp folder (this script, its environment file): Packer is told not to come
  #    back for them.
  Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

  Write-Output "sysprep: done"
  exit 0
}
catch {
  Write-Output "sysprep: FAILED: $_"
  exit 1
}
