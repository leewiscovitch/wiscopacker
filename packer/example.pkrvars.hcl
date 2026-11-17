# Example values: copy to <name>.pkrvars.hcl (not committed) and put in your own.
#   export PKR_VAR_proxmox_token_secret=...   # the API token's secret
#   export PKR_VAR_build_password=...         # random, 16+ letters and digits, new for every build
#   packer build -only "*.server-2025" -var-file <name>.pkrvars.hcl packer/

proxmox_url      = "https://pve1.example.com:8006/api2/json"
proxmox_token_id = "packer@pve!build"
proxmox_insecure = false

node          = "pve1"
vm_id         = 9000
template_name = "windows-server-2025"

disk_storage       = "local-lvm"
iso_storage        = "local"
cloud_init_storage = "local-lvm"
bridge             = "vmbr0"

# Windows Server 2025 evaluation, from Microsoft's Evaluation Center (the link there redirects to a file like
# this one; Microsoft replaces it with a newer build now and then). Check the checksum of what you download.
windows_iso_url      = "https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso"
windows_iso_checksum = "sha256:7b052573ba7894c9924e3e87ba732ccd354d18cb75a883efa9b900ea125bfd51"
# Server Core instead: "Windows Server 2025 Standard Evaluation" (no "(Desktop Experience)"), with its own vm_id
# and template_name.
image_name = "Windows Server 2025 Standard Evaluation (Desktop Experience)"

# virtio-win, pinned. The answer file takes its drivers from the folders "2k25" of this ISO.
virtio_iso_url      = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"
virtio_iso_checksum = "sha256:303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"

clone_username = "admin"
