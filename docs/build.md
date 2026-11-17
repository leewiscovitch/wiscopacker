# The build, step by step

What `packer build` does to make a Windows Server 2025 template, why each step is there, what to check, and what
goes wrong. Status: a build without Windows Update runs through untouched (2026-11-17, about 17 minutes, three
tries: the two sysprep fixes below); the build with updates and the first clone are still to come. What those
must prove is marked "to prove".

## What you need

- A Proxmox VE node (written against 9.2), with a storage for ISOs and one for disks
- An API token for Packer. Its role needs what creating a VM, uploading and downloading ISOs, changing the VM's
  options and deleting the uploaded ISO take; the plugin's docs name no privileges
- A bridge for the build VM with **DHCP and the internet** (Windows Update, the cloudbase-init download), which the
  machine running Packer can reach on port 22. Packer's HTTP server is not used, so the VM need not reach Packer
- Where Packer runs: Packer 1.16, `xorriso` (makes the small CD), `curl` (the last step)

## Run it

```bash
cp packer/example.pkrvars.hcl my.pkrvars.hcl       # put in your values; the file is ignored by git
export PKR_VAR_proxmox_token_secret="..."          # the token's secret
export PKR_VAR_build_password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
packer init packer/
packer build -only "*.server-2025" -var-file my.pkrvars.hcl packer/
```

The build password is new for every build and written down nowhere. If it happens to lack an upper-case letter, a
lower-case letter or a digit, Packer says so before it starts: run the `export` again.

`-var skip_windows_update=true` leaves Windows Update out: a build in well under an hour instead of one to three,
for testing everything else. Not for a template you use.

The id (`vm_id`) must be free. The build never replaces a VM or a template: remove the old one first.

### Server Core (no desktop)

The same ISO and the same source (`server-2025`) build Server Core: give the Core edition's name as
`image_name`, and its own `vm_id` and `template_name`. In the Server 2025 evaluation ISO the four images are
(display names, as Setup lists them): `Windows Server 2025 Standard Evaluation` (Core), the same with
`(Desktop Experience)`, and the two Datacenter ones likewise. List them yourself with
`wiminfo sources/install.wim` (or `dism /Get-WimInfo /WimFile:...`) on the mounted ISO.

```bash
packer build -only "*.server-2025" -var-file my.pkrvars.hcl \
  -var vm_id=9001 -var template_name=windows-server-2025-core \
  -var 'image_name=Windows Server 2025 Standard Evaluation' packer/
```

What differs on Core: no Explorer, so the VM's console shows a command window (or SConfig), not a desktop; the
scripts are the same. One fault Core showed and the desktop never did: `cleanup.ps1`'s delete of the update
download cache met a folder Windows removed at the same moment and failed the build; the delete now leaves such a
folder alone (step 8). And a clone of the first Core template could not be reached by SSH: Windows Update had
put sshd's firewall rule back to the private profile only (step 8, `sysprep.ps1` now sets it again; a rebuilt
template's fresh clone answered SSH with no hand fix). A Core
clone shows one device in error, the ICH9 HD Audio controller every q35 VM has: Core has no audio driver.
Harmless.

## Versions

Read on 2026-11-17, each at the pinned version:

| What | Version | Read |
|---|---|---|
| Packer | 1.16.2 | |
| `hashicorp/proxmox` (`proxmox-iso`) | 1.2.4 | its docs and source at tag `v1.2.4` |
| `rgl/windows-update` | 0.18.5 | readme and source at `v0.18.5` |
| cloudbase-init | 1.1.9 | docs and source at tag `1.1.9`; the installer's source (`cloudbase-init-installer`, 2026-10-09) |
| `virtio-win` | 0.1.302 | the ISO itself (folders, the guest tools installer) |
| Proxmox VE | 9.2 (`qemu-server` 9.2.15) | "Cloud-Init on Windows" in the admin guide; `PVE/QemuServer/Cloudinit.pm` |
| A working template of the same kind | | `rgl/windows-vagrant` (`windows-2025-uefi`), 2026-11 |

Microsoft's unattend reference was not read page by page: the answer file uses only settings that
`rgl/windows-vagrant`'s working Server 2025 file or cloudbase-init's own `Unattend.xml` also use.

To bump a version: change the pin (`packer/plugins.pkr.hcl`, the `locals` of `packer/windows-server-2025.pkr.hcl`,
your var file), read that version's docs for the arguments used here, run a build.

## The steps

### 1. Packer makes the VM

| Setting | Why |
|---|---|
| `os = "win11"` | Proxmox's type for Windows 11, Server 2022 and 2025. It also makes the cloud-init drive a "configdrive2" with the password in plain text, the form cloudbase-init reads. The plugin's docs list no `win11`; it passes the value through |
| `q35`, OVMF, EFI disk `4m` with pre-enrolled keys | UEFI with Secure Boot, as Windows 11 demands and Server 2025 expects |
| TPM 2.0 | the same; the state is a small disk beside the others and is cloned with them |
| VirtIO SCSI single, one disk with `io_thread`, `discard`, `ssd` | the fast path; `discard` gives freed space back to the storage |
| VirtIO network card | the same |
| CPU `x86-64-v2-AES` (variable `cpu_type`) | Proxmox's default for new VMs: SSE4.2, POPCNT, AES, enough for Server 2025; runs and live-migrates on nearly any x86-64 node, Intel or AMD. `host` gives every feature of the node's CPU (AVX2, nested virtualization), but a running VM then migrates only between nodes with the same CPU. The image itself is generalized: a clone boots on any CPU, the type is only in the VM's config |
| guest agent on | Packer asks the agent for the VM's address; Proxmox uses it for a clean shutdown |
| a cloud-init drive | added by Packer when the VM becomes a template; empty until a clone's settings fill it |

**Three CDs, all SATA.** A `q35` machine has two IDE slots, and Windows Setup reads SATA without a driver:

- `sata0`: the Windows ISO. The node downloads it itself (`iso_download_pve`) and checks the checksum
- `sata1`: `virtio-win`, the same way
- `sata2`: a small CD Packer makes with `xorriso`, labelled `WPBUILD`: the answer file with this build's password
  filled in, the two scripts that run before Packer can connect, `sshd_config`, the two cloudbase-init config
  files. Packer uploads it and deletes it after the build

All three are taken out of the template at the end.

**The clock.** The plugin cannot set a VM's `localtime` option, and Proxmox gives a Windows guest local time in
its hardware clock by default. The template reads that clock as UTC (step 6), so the last step of the build sets
`localtime=0` on the template over the API. During the build the two disagree: after the settings are made the
clock is off by the node's UTC offset until Windows syncs its time. Harmless there; in a clone it would be wrong
at every boot.

Check: the VM appears on the node with the id you gave, named like the template.

### 2. The one keystroke

The boot order is the (empty) disk, then the Windows CD. The firmware falls through to the CD, which asks "Press
any key to boot from CD or DVD" for five seconds. Packer sends the up-arrow key once a second for 15 seconds,
starting 2 seconds after the start: the prompt takes any key, and the arrow does nothing anywhere else. After the
first reboot the disk boots, the prompt times out unseen, and no key is sent again.

Goes wrong: the prompt is missed (a slow node) and the VM sits in the firmware's shell or boot menu. Raise
`boot_wait` or lengthen `boot_command`.

### 3. Windows Setup, unattended (`autounattend.xml`)

Setup looks for a file of that name in the root of every drive and finds it on the small CD.

- **windowsPE** (Setup itself): language; the VirtIO **SCSI and network drivers** from the `virtio-win` CD, folder
  `2k25`, listed for the letters `D:`, `E:` and `F:` because the CDs' letters are not fixed; a GPT disk (EFI
  260 MB, MSR 16 MB, Windows to the end); the edition by its **name** in `install.wim`; no product key
- **No recovery partition.** Setup would put it behind `C:`, and a clone with a bigger disk could then not grow
  `C:` into the new space. **Setup makes one anyway:** WinRE's agent shrinks `C:` by about 0.9 GB and puts WinRE
  in a new partition at the end (setup's log: `ShrinkOsPartition`; the first clone had `C:` stuck at 62.9 GB on an
  80 GB disk). `cleanup.ps1` removes it (step 8)
- **specialize**: the time zone; no computer name, so Windows picks a random one (a clone gets its own in step 9)
- **oobeSystem**: every welcome page skipped; the built-in `Administrator` gets the build password; one automatic
  logon; two commands at that logon (step 4)

Goes wrong: "no drives found" or a question about where to install means the storage driver was not loaded (the
`virtio-win` CD missing, or a version without `2k25`). A question about the edition means `image_name` does not
match a name in `install.wim` exactly (`wiminfo sources/install.wim`, or `dism /Get-WimInfo`).

### 4. First logon: the guest tools, then OpenSSH

Both scripts run from the small CD, found by its label, and each writes a log to `C:\Windows\Temp` (read it at the
console if Packer never gets in).

- `install-guest-tools.ps1`: `virtio-win-guest-tools.exe`, silent: every VirtIO driver and the **QEMU guest
  agent**. First, because Packer learns the VM's address from the agent
- `enable-communicator.ps1`: sets the network profile to private (if it can), switches on the **OpenSSH server**
  (part of Server 2025; a downloaded capability elsewhere), installs `sshd_config`, opens port 22 on every
  firewall profile (Windows' own rule covers "private" only, and a clone's network starts as "public")

**`sshd_config`** differs from Windows' in one thing: the `Match Group administrators` block is gone. With it,
sshd reads an administrator's keys only from `C:\ProgramData\ssh\administrators_authorized_keys`; cloudbase-init
writes a clone's keys into the user's own `.ssh\authorized_keys`, and that user is an administrator.

**sshd's shell stays `cmd.exe` during the build.** Packer runs a script as
`powershell -executionpolicy bypass "& { ...; exit $LastExitCode }"`. Under a PowerShell login shell the `$...`
inside the double quotes would be expanded before the script runs, and its exit code lost. The last script makes
PowerShell the shell for everything after the build.

Goes wrong: Packer shows "Waiting for SSH to become available" until `ssh_timeout` (4 hours). Open the VM's
console: is Windows at the desktop? Then read `C:\Windows\Temp\install-guest-tools.log` and
`enable-communicator.log`. No address at all on the VM's summary page: the agent is not running, or the bridge has
no DHCP.

### 5. Packer connects; restart; Windows Update

Packer logs in over SSH as `Administrator` with the build password, restarts Windows once (the guest tools'
drivers), then runs Windows Update until nothing is left. The plugin restarts Windows as often as needed.
"Recommended" updates, without KB5007651 ("Update for Windows Security platform"), which installs only for a user
at the desktop and would otherwise be offered for ever.

Goes wrong: hours pass. That is normal for a first build from an old ISO; the log names each update.

### 6. `tune.ps1`: what AWS does to its images

One block per row of the table in `README.md`: the time zone; the hardware clock as UTC (`RealTimeIsUniversal`);
secure time seeding off; power plan high performance; hibernation off; display never off; visual effects "best
performance" and no screen-saver password, both in the **default profile** (they are per-user settings, and the
clone's administrator does not exist yet); the telemetry service disabled; execution policy `RemoteSigned`; the
page file checked to be system-managed. Then a restart, so that whatever the updates left for "the next restart"
is done before the image is cleaned.

### 7. `install-cloudbase-init.ps1`

After the last restart, so that its service never starts in the build VM.

- The MSI is downloaded by the guest and **run only if its sha256 matches** the pin
- Silent, so the installer's last page (which offers to run sysprep and to start the service) never appears
- `RUN_SERVICE_AS_LOCAL_SYSTEM=1`: otherwise the installer makes a local account `cloudbase-init` with a password
  of its own, one more account in every clone
- Both config files come from the small CD (below)
- **The service is `Manual` in the template, and `C:\Windows\Setup\Scripts\SetupComplete.cmd` starts it.** Windows
  runs that file once, as SYSTEM, when setup has finished in a clone and before the logon screen: it sets the
  service to start with Windows and starts it. Left `Automatic`, the service starts while the clone is still in
  Windows setup and runs as soon as specialize ends, during the welcome phase: there a user's profile can't be
  loaded yet ("Cannot load user profile: 'The device is not ready.'"), so the user is made without a profile and
  the SSH keys never get written; the service may also restart Windows in the middle of setup. Seen in the first
  clone; a `SetupComplete.cmd` that is already there and not this build's is never overwritten
- A script in cloudbase-init's `LocalScripts`, run once in each clone, disables the built-in `Administrator`
  there: the build disables it before the capture, and this holds if Windows setup switches it back on. Left out
  when `clone_username` is `Administrator`

### 8. `cleanup.ps1`, then `sysprep.ps1`

`cleanup.ps1` waits until nothing is installing, **stops the build if Windows still wants a restart** (sysprep
would refuse, or the half-finished installation would be in every clone), then:

- **the recovery partition behind `C:`** (step 3): WinRE moved back into `C:` (`reagentc /disable`), the
  partition removed, `C:` grown to the end of the disk, WinRE on again (`reagentc /enable`: with no recovery
  partition it stays on `C:`). Any other partition behind `C:` stops the build untouched
- crash dumps, the update download cache, temp folders (best effort: what is in use, or vanishes while it is
  deleted, is left alone with a line `cleanup: left alone, <path> (...)`; first seen on Core)
- **setup's copies of the answer file**, `C:\Windows\Panther\unattend-original.xml` among them: setup leaves
  the build password in it **in plain text** (the others it blanks). Then every XML file under
  `C:\Windows\Panther` and `C:\Windows\System32\Sysprep` is read, and the build stops if one still holds a
  password value. (Found in the first clone: the account is disabled and the password random per build, but no
  secret belongs in the image)
- the event logs, last

`sysprep.ps1`:

1. checks that cloudbase-init's `Unattend.xml` and its service are in place, the service is `Manual`, has not run,
   and `SetupComplete.cmd` starts it
2. makes sure that file has `PersistAllDeviceInstalls` (it does as shipped): sysprep then keeps the VirtIO drivers
   bound instead of forgetting every device
3. makes PowerShell sshd's shell, and sets the firewall rule for port 22 to every profile **again**, and checks
   it: a cumulative update that services the OpenSSH server puts Windows' own rule back (private only). The
   build never notices (its network is private); a clone's network starts public, and SSH times out
4. disables the build account (the built-in `Administrator`)
5. runs `sysprep /generalize /oobe /quit /unattend:<that file>` and checks that Windows is generalized; if not,
   it prints the end of sysprep's error log and the build fails
6. removes sshd's host keys, so every clone makes its own, and what Packer left in the temp folder

**`/quit`, not `/shutdown`:** with `/shutdown` the VM would switch off under the running script and a failed
sysprep would look like a lost connection. With `/quit` the script sees the result; Packer then shuts the VM down
through the API. Packer is told not to connect again after this script (`skip_clean`): the account it used is
disabled.

Goes wrong: sysprep fails. The cause is in `C:\Windows\System32\Sysprep\Panther\setuperr.log` (the build prints its
end). On Server it is nearly always a pending restart or an update still installing.

### 9. Template, and what a clone does with it

Packer shuts the VM down, makes it a template, removes the three CDs, adds the empty cloud-init drive, and the
last step sets `localtime=0`.

A clone's first boot (proved 2026-11-17, the second clone; the first showed the race fixed in step 7):

1. Windows finishes setup with cloudbase-init's `Unattend.xml`. In its specialize pass cloudbase-init runs once
   with `cloudbase-init-unattend.conf`: it sets the **host name** from the cloud-init drive and grows `C:` (a
   clone with a disk 16 GB bigger: "Extending volume ... with 17179..." bytes). Windows restarts
2. Setup finishes; `SetupComplete.cmd` starts the service, which runs with `cloudbase-init.conf`: creates the user `clone_username` as an administrator, sets its
   **password** from the drive, writes its **SSH keys**, disables the built-in `Administrator`
3. `ssh <clone_username>@<address>` works, by key and by password, into PowerShell: about two minutes from the
   clone's start, with no console input. The service's run needs no restart of its own (the name is already set)

## cloudbase-init: the two config files

`packer/files/cloudbase-init.conf.pkrtpl` (the service, every boot) and `cloudbase-init-unattend.conf.pkrtpl`
(once, during setup). What Proxmox's drive holds for a Windows guest (`Cloudinit.pm`), and what reads it:

| On the drive | Where | Read by |
|---|---|---|
| password (`cipassword`) | `meta_data.json`: `admin_pass`; also in the user data | `SetUserPasswordPlugin`, with `inject_user_password = true` |
| SSH keys (`sshkeys`) | `meta_data.json`: `public_keys` | `SetUserSSHPublicKeysPlugin` |
| host name (the VM's name) | **user data only** (`hostname:` in a cloud-config) | `UserDataPlugin`; `SetHostNamePlugin` finds nothing in Proxmox's metadata |
| user name (`ciuser`) | user data, as `user:`, which cloudbase-init does not read | nothing: **the user's name is `clone_username`, fixed in the template** |
| network (`ipconfig0`) | `content/0000` | nothing: no network plugin is listed, a clone uses DHCP |

- `metadata_services` is the config drive alone; otherwise cloudbase-init first waits minutes for HTTP services
  that are not there
- `first_logon_behaviour = no`: no forced password change at the first logon
- **`debug = false`.** At debug level cloudbase-init logs the user data it read, and Proxmox's user data holds the
  clone's password in plain text. (The drive itself stays attached to the clone and holds it too: that is how
  Proxmox does cloud-init)
- `UserDataPlugin` is in the first run so that the name is set before the first full boot, and in the normal run
  in case that did not happen. Proved: in a clone the first run sets the name during setup, and the service's run
  finds it set and restarts nothing

## What to check after a build

- The log ends with the template's id and `template <id>: localtime=0`
- `qm config <id>` on the node: `template: 1`, `ostype: win11`, `localtime: 0`, `efidisk0`, `tpmstate0`, one
  cloud-init drive, no other CD
- `grep -c "$PKR_VAR_build_password" <the log>`: `0`
- In a first clone: `Get-HotFix` shows this month's update; `powercfg /a` has no hibernation; `Get-Service DiagTrack`
  is disabled; `Get-LocalUser` shows `Administrator` disabled; the clock is right with time sync stopped
  (`w32tm /query /status`, then compare with the node's `date -u`)

## What goes wrong, in short

| Sign | Cause |
|---|---|
| Packer stops before the VM exists, over making the CD | `xorriso` is not installed where Packer runs |
| A 403 from the API | the token's role lacks a privilege; the message names the call |
| The ISO download fails after a long wait | `task_timeout` (2 hours here) or a wrong checksum; Microsoft replaces the evaluation ISO now and then |
| The VM sits in the firmware | the boot prompt was missed: step 2 |
| Setup asks a question | step 3 |
| "Waiting for SSH" for ever | step 4 |
| `cleanup: FAILED: Windows still wants a restart` | an update needs two restarts; run the build again, or add a second restart before the cleanup |
| A clone answers ping and has its name and address, but SSH **times out** (not refused); inside, the rule `OpenSSH-Server-In-TCP` is on `Private` only and the network is `Public` | a template built before the fix in `sysprep.ps1` (step 8): Windows Update reset the rule. Rebuild. In such a clone, through the guest agent: `Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any` |
| `cleanup: FAILED: An object at the specified path ...\SoftwareDistribution\Download\... does not exist.` | a build before the fix in `cleanup.ps1` (step 8): a folder vanished while it was being deleted (seen on Core). Fixed |
| `sysprep: FAILED` | step 8; the log shows sysprep's own error |
| `sysprep: this Windows is already generalized` on a first build | an old check (`GeneralizationState` is 7 on a fresh install too); fixed: the script reads `ImageState` |
| `SYSPRP WinMain: Unable to parse command-line arguments` | the answer file's path with spaces after `/unattend:`; fixed: sysprep runs from the file's folder with its bare name |
| "Error converting VM to template, could not stop" | Windows did not shut down in the time Proxmox waits. Shut the VM down by hand; the alternative is sysprep with `/shutdown`, started detached |
| The post-processor fails | `curl` missing, or the token may not change the VM's options. The template exists; set it by hand: `qm set <id> --localtime 0` |
| A clone has its user and password, but SSH by key is refused; cloudbase-init's log has `Cannot load user profile: 'The device is not ready.'` and, on every boot, `SetUserSSHPublicKeysPlugin` failing with `[WinError 2]` | the service ran during Windows setup: a template built before the `SetupComplete.cmd` fix (step 7). Rebuild the template. In such a clone by hand: delete the value `CreateUserPlugin` under `HKLM\SOFTWARE\Cloudbase Solutions\Cloudbase-Init\<id>\Plugins` and `Start-Service cloudbase-init` |
| A clone's `C:` is about 0.9 GB short of the disk and does not grow (`Get-Partition`: a `Recovery` partition behind it) | a template built before the fix in `cleanup.ps1` (step 8): Setup made a WinRE partition. Rebuild |
| `cleanup: FAILED: ... still holds a password` | an answer file copy setup left that the list in `cleanup.ps1` does not know yet: add it there |
| A build that died half-way | the VM with the build's id is still there and is not a template. Remove it before the next build |

## The tests

`tests/run` before every commit: `packer fmt`, `packer init`, `packer validate` with the example values and dummy
secrets, the answer files well-formed, no private address or name of one environment anywhere, PSScriptAnalyzer
when `pwsh` is installed. None of it starts a VM: the real test is a build.
