# Windows Server 2025 as a Proxmox VE template. The steps, and why each is there: docs/build.md.
#   packer build -only "*.server-2025" -var-file <your>.pkrvars.hcl packer/

locals {
  # This folder as a full path: a relative one is read from where packer was started for some arguments
  # and from this folder for others.
  root = abspath(path.root)

  # cloudbase-init, pinned: the guest downloads this MSI and checks the hash before it runs it.
  cloudbase_init_version = "1.1.9"
  cloudbase_init_url     = "https://github.com/cloudbase/cloudbase-init/releases/download/1.1.9/CloudbaseInitSetup_1_1_9_x64.msi"
  cloudbase_init_sha256  = "ffbf80515a7311ed00800276a6af7aab23b41d7acf13e79ce3d2d56844f638f7"

  # The label of the CD the build makes. The scripts find that CD by this label, not by a drive letter.
  build_cd_label = "WPBUILD"

  # The password goes into XML: the variable allows letters and digits only, this is the second lock.
  build_password_xml = replace(replace(replace(var.build_password, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")

  cloudbase_init_values = {
    username = var.clone_username
  }

  # What every script run by Packer gets. Nothing secret: Packer writes these into a file in the guest.
  script_environment = [
    "BUILD_CD_LABEL=${local.build_cd_label}",
    "CLONE_USERNAME=${var.clone_username}",
    "TIME_ZONE=${var.time_zone}",
    "CLOUDBASE_INIT_VERSION=${local.cloudbase_init_version}",
    "CLOUDBASE_INIT_URL=${local.cloudbase_init_url}",
    "CLOUDBASE_INIT_SHA256=${local.cloudbase_init_sha256}",
  ]
}

source "proxmox-iso" "server-2025" {
  # --- The API ---
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = var.proxmox_insecure
  node                     = var.node
  # One limit for every API task. The longest is the node downloading the Windows ISO (about 8 GB).
  task_timeout = "2h"

  # --- The VM (the template keeps all of it) ---
  vm_id                = var.vm_id
  vm_name              = var.template_name
  template_name        = var.template_name
  template_description = coalesce(var.template_description, "${var.image_name}, built ${formatdate("YYYY-MM-DD", timestamp())} with Packer.")

  # "win11" is Proxmox's type for Windows 11, Server 2022 and Server 2025. It also makes the cloud-init drive
  # a configdrive2 with the password in plain text, which is what cloudbase-init reads.
  os              = "win11"
  machine         = "q35"
  bios            = "ovmf"
  cpu_type        = var.cpu_type
  sockets         = 1
  cores           = var.cores
  memory          = var.memory
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  efi_config {
    efi_storage_pool  = var.disk_storage
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  tpm_config {
    tpm_storage_pool = var.disk_storage
    tpm_version      = "v2.0"
  }

  disks {
    type         = "scsi"
    storage_pool = var.disk_storage
    disk_size    = var.disk_size
    io_thread    = true
    discard      = true
    ssd          = true
  }

  network_adapters {
    model    = "virtio"
    bridge   = var.bridge
    vlan_tag = var.vlan_tag
  }

  # --- Three CDs, all SATA: q35 has two IDE slots only, and Windows Setup reads SATA without a driver.
  # All three are taken out of the template at the end.
  boot_iso {
    type             = "sata"
    index            = "0"
    iso_url          = var.windows_iso_url
    iso_checksum     = var.windows_iso_checksum
    iso_storage_pool = var.iso_storage
    iso_download_pve = true
    unmount          = true
  }

  additional_iso_files {
    type             = "sata"
    index            = "1"
    iso_url          = var.virtio_iso_url
    iso_checksum     = var.virtio_iso_checksum
    iso_storage_pool = var.iso_storage
    iso_download_pve = true
    unmount          = true
  }

  # Made here (xorriso), uploaded, deleted after the build: the answer file and what runs before Packer can
  # connect. Windows Setup looks for autounattend.xml in the root of every drive.
  additional_iso_files {
    type             = "sata"
    index            = "2"
    iso_storage_pool = var.iso_storage
    unmount          = true
    cd_label         = local.build_cd_label
    cd_files = [
      "${local.root}/scripts/install-guest-tools.ps1",
      "${local.root}/scripts/enable-communicator.ps1",
      "${local.root}/files/sshd_config",
    ]
    cd_content = {
      "autounattend.xml" = templatefile("${local.root}/answer-files/server-2025/autounattend.xml", {
        build_password = local.build_password_xml
        image_name     = var.image_name
        time_zone      = var.time_zone
        cd_label       = local.build_cd_label
      })
      "cloudbase-init.conf"          = templatefile("${local.root}/files/cloudbase-init.conf.pkrtpl", local.cloudbase_init_values)
      "cloudbase-init-unattend.conf" = templatefile("${local.root}/files/cloudbase-init-unattend.conf.pkrtpl", local.cloudbase_init_values)
    }
  }

  # The empty disk first, so the firmware falls through to the Windows CD now and boots the disk from the
  # first reboot on. No network boot.
  boot = "order=scsi0;sata0"

  # "Press any key to boot from CD or DVD": the only keystrokes of the build. The arrow key does nothing
  # anywhere else, so sending it for a while is safe.
  boot_wait    = "2s"
  boot_command = ["<up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait><up><wait>"]

  # The template gets an empty cloud-init drive; a clone's settings fill it.
  cloud_init              = true
  cloud_init_storage_pool = var.cloud_init_storage

  # --- How Packer gets in: SSH as the build account. The address comes from the guest agent. ---
  communicator = "ssh"
  ssh_username = "Administrator"
  ssh_password = var.build_password
  ssh_timeout  = var.ssh_timeout
}

build {
  sources = ["source.proxmox-iso.server-2025"]

  # The guest tools (drivers, agent) were installed at first logon; this restart finishes them.
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # Windows Update until nothing is left; the plugin restarts Windows as often as needed.
  dynamic "provisioner" {
    labels   = ["windows-update"]
    for_each = var.skip_windows_update ? [] : [1]
    content {
      search_criteria = "BrowseOnly=0 and IsInstalled=0"
      filters = [
        # "Update for Windows Security platform" installs only for a user at the desktop and would loop here.
        "exclude:$_.Title -like '*KB5007651*'",
        "include:$true",
      ]
      restart_timeout = "2h"
    }
  }

  provisioner "powershell" {
    script           = "${local.root}/scripts/tune.ps1"
    environment_vars = local.script_environment
  }

  # After the updates and the settings: what waits for a restart is done before anything is cleaned or captured.
  provisioner "windows-restart" {
    restart_timeout = "1h"
  }

  # After the last restart, so its service never starts in the build VM (it must first run in a clone).
  provisioner "powershell" {
    script           = "${local.root}/scripts/install-cloudbase-init.ps1"
    environment_vars = local.script_environment
  }

  provisioner "powershell" {
    script           = "${local.root}/scripts/cleanup.ps1"
    environment_vars = local.script_environment
  }

  # The last thing that runs in Windows. It disables the account Packer is logged in with, so Packer must not
  # connect again to tidy up (skip_clean); the script removes Packer's files itself. Packer then shuts the VM
  # down through the API and makes it a template.
  provisioner "powershell" {
    script           = "${local.root}/scripts/sysprep.ps1"
    environment_vars = local.script_environment
    skip_clean       = true
  }

  # The plugin cannot set a VM's "localtime". Proxmox gives a Windows guest local time in its hardware clock,
  # the template reads that clock as UTC (tune.ps1, RealTimeIsUniversal): the two must agree, so the template
  # is set to localtime=0 over the API. Needs curl where Packer runs.
  post-processor "shell-local" {
    environment_vars = [
      "PVE_URL=${var.proxmox_url}",
      "PVE_TOKEN=${var.proxmox_token_id}=${var.proxmox_token_secret}",
      "PVE_NODE=${var.node}",
      "PVE_VMID=${var.vm_id}",
      "PVE_CURL_OPTIONS=${var.proxmox_insecure ? "--insecure" : ""}",
    ]
    inline = [
      "curl --fail --silent --show-error $PVE_CURL_OPTIONS --request PUT --header \"Authorization: PVEAPIToken=$PVE_TOKEN\" --data localtime=0 \"$PVE_URL/nodes/$PVE_NODE/qemu/$PVE_VMID/config\" > /dev/null",
      "echo \"template $PVE_VMID: localtime=0\"",
    ]
  }
}
