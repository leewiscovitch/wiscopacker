# The pinned tools. `packer init packer/` installs the plugins; bump a version here, read that version's docs,
# and note it in docs/build.md "Versions".
packer {
  required_version = "~> 1.16.0"

  required_plugins {
    proxmox = {
      version = "1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
    windows-update = {
      version = "0.18.5"
      source  = "github.com/rgl/windows-update"
    }
  }
}
