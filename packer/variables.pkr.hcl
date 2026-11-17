# Every value of the build. None has a default that belongs to one environment: pass yours in a var file
# (example.pkrvars.hcl) and the two secrets from the environment (PKR_VAR_proxmox_token_secret,
# PKR_VAR_build_password).

# --- The Proxmox API ---

variable "proxmox_url" {
  type        = string
  description = "The API's address with its full path, e.g. https://pve1.example.com:8006/api2/json."
}

variable "proxmox_token_id" {
  type        = string
  description = "The API token's full id: user, realm and token name, e.g. packer@pve!build."
}

variable "proxmox_token_secret" {
  type        = string
  sensitive   = true
  description = "The token's secret. From the environment only: PKR_VAR_proxmox_token_secret."
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "true skips the check of the API's certificate (a node with its self-signed one)."
}

# --- Where the template goes ---

variable "node" {
  type        = string
  description = "The node that builds and then holds the template."
}

variable "vm_id" {
  type        = number
  description = "The id of the build VM and of the template it becomes. Must be free: the build never replaces a VM."

  validation {
    condition     = var.vm_id >= 100 && var.vm_id <= 999999999 && floor(var.vm_id) == var.vm_id
    error_message = "The vm_id must be a whole number from 100 to 999999999."
  }
}

variable "template_name" {
  type        = string
  description = "The template's name (a DNS name: letters, digits, hyphens)."
}

variable "template_description" {
  type        = string
  default     = ""
  description = "The template's description. Empty: the edition (image_name) and the build date."
}

variable "disk_storage" {
  type        = string
  description = "Storage for the system disk, the EFI disk and the TPM state."
}

variable "iso_storage" {
  type        = string
  description = "Storage (with content type ISO) for the two downloaded ISOs and the small one the build makes."
}

variable "cloud_init_storage" {
  type        = string
  description = "Storage for the template's cloud-init drive."
}

variable "bridge" {
  type        = string
  description = "The bridge the build VM's network card is on. It needs DHCP and the internet, and the machine running Packer must reach it on port 22."
}

variable "vlan_tag" {
  type        = string
  default     = ""
  description = "VLAN tag for the network card. Empty: none."
}

# --- What is installed ---

variable "windows_iso_url" {
  type        = string
  description = "The Windows ISO. The node downloads it itself."
}

variable "windows_iso_checksum" {
  type        = string
  description = "Its checksum, e.g. sha256:<64 hex digits>."
}

variable "virtio_iso_url" {
  type        = string
  description = "The virtio-win ISO (drivers, guest tools). A versioned URL, not the one that follows the newest."
}

variable "virtio_iso_checksum" {
  type        = string
  description = "Its checksum, e.g. sha256:<64 hex digits>."
}

variable "image_name" {
  type        = string
  description = "The edition to install: its name inside the ISO's sources/install.wim (wiminfo or dism /Get-WimInfo list them)."
}

variable "build_password" {
  type        = string
  sensitive   = true
  description = "Password of the Administrator account while the build runs. Random per build, never stored; the account is disabled before sysprep. From the environment only: PKR_VAR_build_password."

  # It is written into the answer file (XML), typed into no shell, and Windows wants three of four character
  # classes. Letters and digits only keeps every layer out of the way.
  validation {
    condition     = can(regex("^[A-Za-z0-9]{16,}$", var.build_password)) && can(regex("[A-Z]", var.build_password)) && can(regex("[a-z]", var.build_password)) && can(regex("[0-9]", var.build_password))
    error_message = "The build_password must be at least 16 characters, letters and digits only, with an upper-case letter, a lower-case letter and a digit."
  }
}

variable "clone_username" {
  type        = string
  description = "The administrator that cloudbase-init creates on a clone's first boot; password and SSH keys come from the clone's cloud-init drive. Baked into the template: Proxmox's drive does not carry the user name in a form cloudbase-init reads."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$", var.clone_username))
    error_message = "The clone_username must be 1 to 20 characters: letters, digits, dot, underscore, hyphen."
  }
}

# --- The VM ---

variable "cpu_type" {
  type        = string
  default     = "x86-64-v2-AES"
  description = "CPU type of the template (a clone can change it). The default is Proxmox's own for new VMs: runs on nearly any x86-64 node, Intel or AMD, and live-migrates between unlike ones. \"host\" gives every feature of the node's CPU (nested virtualization too), but live migration then needs the same CPU on every node."
}

variable "cores" {
  type        = number
  default     = 2
  description = "CPU cores of the template (a clone can change it)."
}

variable "memory" {
  type        = number
  default     = 4096
  description = "Memory in MiB (a clone can change it)."
}

variable "disk_size" {
  type        = string
  default     = "64G"
  description = "Size of the system disk. A clone with a bigger disk grows its C: on first boot."
}

# --- The build ---

variable "skip_windows_update" {
  type        = bool
  default     = false
  description = "true leaves Windows Update out: a build in minutes instead of hours, for testing the rest. Not for a template that is used."
}

variable "time_zone" {
  type        = string
  default     = "UTC"
  description = "Windows time zone id of the template (tzutil /l lists them)."
}

variable "ssh_timeout" {
  type        = string
  default     = "4h"
  description = "How long Packer waits for Windows to be installed and answer on SSH."
}
