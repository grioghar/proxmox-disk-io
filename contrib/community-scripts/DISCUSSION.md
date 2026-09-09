<!--
Draft for: https://github.com/community-scripts/ProxmoxVE/discussions
Category:  Ideas   (deliberately not "Request script" -- this is an offer to
                    contribute a tool I wrote, not a request to package
                    someone else's app, and the 1,000-star rule there is
                    aimed at the latter.)
Title:     Offering a host tool: disk I/O panel for the PVE web UI
-->

Hi — I've built a host-side tool and would like to offer it, if it's something
you'd take. Asking first rather than opening a PR cold.

**What it is:** a live disk I/O panel built into the Proxmox web UI. Per
physical disk it shows throughput, IOPS, utilisation, latency and queue depth,
and names which container or VM is driving each one. It adds recorded history
to the node Summary and to each guest's, and a Disk I/O page to every LXC and
VM.

Repo: https://github.com/grioghar/proxmox-disk-io (MIT, same as here)

**Why it might be worth having:** Proxmox will tell you a disk is busy but not
what is making it busy. The part I think is genuinely missing elsewhere is
**mergerfs / FUSE pools**: a container writing to a pool never touches a block
device, so the kernel — and every tool built on it, `iotop` and `pidstat`
included — credits the pool's daemon. On a media host that means the one
process you can see is the one you don't care about. This attributes that I/O
back to the container or host process that actually asked for it, per disk.

**How it would fit:** it's a host tool, so `tools/pve/` rather than `ct/` +
`install/`. I've written the wrapper in the style of `disk-health.sh` /
`add-iptag.sh` — sources `core.func`, `init_tool_telemetry`, whiptail menu with
install / uninstall / status, driven by `var_action` so it can run unattended.
It installs a signed-off `.deb` from the project's GitHub release rather than
vendoring several files into the script.

Two things I'd rather flag now than have you find:

1. **It patches two pve-manager-owned files** — `PVE/API2/Disks.pm` to register
   the API endpoints, and `index.html.tpl` to load the panel's JavaScript.
   Both edits are idempotent, both are reversed on uninstall, and pristine
   copies are kept in `/var/backups/pve-disk-io/`. `pvemanagerlib.js` is
   deliberately never touched — the UI attaches itself with runtime Ext
   overrides — so an upgrade can remove the integration but can never leave it
   half-applied. The `.deb` carries a dpkg trigger on those directories, so an
   upgrade re-applies it automatically. If touching those files is a
   non-starter for you, I'd rather know now.

2. **It's a multi-file project**, not a single self-contained script: two Perl
   modules, the UI JavaScript, a collector and a systemd timer. The
   `tools/pve/` entry is a thin installer around the release artifact, which is
   a slightly different shape from your existing tools.

Also worth being straight about the adoption bar in the Request-script
template: this is a new repo with no stars. I'm offering it as a contribution
rather than asking you to package someone else's project, but if you'd rather
it earned some usage first, that's a fair answer and I'll come back later.

Tested on Proxmox VE 9.2. Happy to open the PR against ProxmoxVED if you're
interested, or to drop it if it's not a fit.
