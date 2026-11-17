# wiscopacker

Windows Server 2025 and Windows 11 templates for Proxmox VE, built with Packer, the way AWS builds its official
Windows AMIs. Bake an image, launch a VM from it, let it configure itself on first boot (cloud-init drive and
cloudbase-init), then manage it over SSH. Nobody touches the console in between.

For anyone running Proxmox VE who wants Windows guests made like cloud instances. Every value is a variable:
nothing here is tied to one lab.

**Status:** being built. Nothing usable yet.

## The AWS loop, mapped

| AWS | Here |
|---|---|
| AMI | a Proxmox VM template, built by Packer (`proxmox-iso`) |
| `aws_instance` | a VM cloned from the template (OpenTofu or Terraform, `bpg/proxmox`) |
| user data + EC2Launch | Proxmox's cloud-init drive (configdrive2) + cloudbase-init |
| SSM / WinRM | OpenSSH server in the template |
| what runs after launch | Ansible (or anything else over SSH) |

## What AWS does to its Windows AMIs, and what this does

| AWS does | Here |
|---|---|
| ISO hash checked | `iso_checksum` for both ISOs, pinned in variables |
| ENA/NVMe/PV drivers | VirtIO drivers and the QEMU guest agent, `virtio-win` pinned |
| EC2Launch v2 | cloudbase-init, pinned |
| SSM agent | OpenSSH server |
| AWS PowerShell tools, CloudFormation scripts, desktop links | nothing |
| pending renames and reboots handled before capture | the same, before sysprep |
| Windows Update until clean | the same (skippable with a variable, for fast test builds) |
| updates then switched off | not copied: clones keep Windows Update on |
| time zone UTC, `RealTimeIsUniversal`, secure time seeding off | the same; the VM's clock is set to UTC too (`localtime` off), or every boot starts off by the host's offset |
| Amazon Time Sync | Windows' default time source |
| high performance, hibernation off and its file gone, display never off | the same |
| visual effects "best performance", screen saver password off | the same |
| page file system-managed | Windows' default already; checked, not set |
| telemetry service off | the same |
| remote PowerShell on, execution policy `Unrestricted` | OpenSSH instead; execution policy `RemoteSigned` |
| `.dmp` files, event logs, temp files deleted | the same, the last step before sysprep |
| sysprep with `PersistAllDeviceInstalls` | the same, so the VirtIO drivers stay bound |
| no administrator password in the image | the build account's password is random per build and never stored; the account is disabled before sysprep; each clone's login comes from its cloud-init drive |
| SQL Server items, instance store volumes | nothing |

## More

`docs/` (the build step by step, why each step is there, what to check) comes with the first working build.
