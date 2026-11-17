# wiscopacker: instructions for AI agents and humans

Canonical instruction file for every agent working in this repo (Claude Code reads it via `CLAUDE.md`).

Packer templates that build Windows VM templates on Proxmox VE, the AWS way (`README.md`). Public.

## Rules

- **No value of any one lab.** No address, node name, storage id, bridge, user name, domain or URL of a real
  environment as a default, in an example or in a comment. Examples use `pve1`, `local`, `local-lvm`, `vmbr0`,
  `192.0.2.x` / `example.com`. Whoever runs the build passes their values as a var file
- **No secret in the repo, in a log or in the image.** Secrets reach Packer only from the environment
  (`PKR_VAR_...`); every such variable is `sensitive = true`. The build password is random per build and never
  written down; the build account is disabled before sysprep
- **Every version pinned** (Packer plugins, cloudbase-init, `virtio-win`, ISOs by checksum)
- **Argument names from the current docs** of the pinned versions, not from memory
- PowerShell for Windows, bash for Linux; two spaces; lowercase file names; double quotes unless it changes
  behaviour. Scripts are idempotent and stop with a non-zero exit and one clear line on failure
- **`tests/run` before every commit** (once it exists): `packer fmt -check`, `packer validate` with
  `packer/example.pkrvars.hcl`, the answer files well-formed, a check for lab values, PSScriptAnalyzer if `pwsh`
  is installed. The real test is a build
- Explain as well as automate: `docs/` says each step, why it is there, what to check, what goes wrong
- Small commits about one thing, with the reason in the message. No force-push, no history rewrite
