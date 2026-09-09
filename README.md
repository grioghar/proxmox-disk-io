# Proxmox VE — Disk I/O Activity panel

A live view of what the physical disks in a node are doing, and which guests
are responsible, added to the Proxmox VE web UI under **Node → Disks → I/O
Activity**.

## What it shows

**Per physical disk** — throughput, IOPS, utilisation, average latency, queue
depth, in-flight requests, and the guest currently generating most of that
disk's load. Bus type (SATA / USB / NVMe) is shown because it usually explains
the latency.

**Per guest** — read/write rate, IOPS, share of total guest I/O, and which
physical disks each guest touches. Selecting a disk rescopes this grid to that
disk alone, so "what is hammering `sdc`?" is one click.

**Throughput chart** — aggregate read/write over a rolling window, drawn with
Proxmox's own `RRDChart` widget so it matches the rest of the UI.

## How the numbers are produced

The API returns raw monotonic counters plus a high-resolution timestamp; the
browser derives every rate from the delta between two samples. The server stays
stateless and the rates reflect real elapsed time rather than an assumed
interval.

| Source | Used for |
| --- | --- |
| `/proc/diskstats` | per-disk throughput, IOPS, utilisation, latency, queue |
| `/sys/block/*`, `/run/udev/data/b*` | model, serial, size, bus, scheduler |
| cgroup v2 `io.stat` | per-container I/O, per device |
| QMP `query-blockstats` | per-VM I/O, per drive |

Guest names and the VM drive-to-disk mapping are cached for 30s (and refreshed
immediately when an unseen guest appears), because reading them means one
pmxcfs round trip per guest and pmxcfs is a FUSE filesystem replicated across
the cluster. On a node with 49 guests that cache took the endpoint from ~120ms
to ~32ms and removed roughly 50 config reads per poll. Measured end to end over
HTTPS it answers in ~60ms.

Three details worth knowing:

- **Containers.** The cgroup io controller charges every layer of the stack, so
  a container on LVM appears against both the dm device and the physical disk
  underneath. Summing all lines would double count, so only physical disks are
  counted. This was verified to be exact: for a sample container, the physical
  disk's byte count equalled the sum of its dm children.

- **VMs.** `qemu.slice` does not enable the io controller, so per-VM cgroup
  stats are empty. Numbers come from QMP instead, and each drive is mapped to
  its physical disks through the storage layer (`PVE::Storage::path`, then
  walking `/sys/dev/block/*/slaves`). Raw `/dev/disk/by-id/...` passthrough
  drives bypass the storage layer and are resolved directly. A drive spanning
  several disks is split evenly rather than charged to one spindle.

## Install

```bash
sudo scripts/install.sh
```

Then hard-reload the browser (Ctrl-Shift-R).

The installer is idempotent, checks Perl syntax before restarting anything, and
backs the stock files up to `/root/config-backups/disk-io/`.

| | |
| --- | --- |
| new | `/usr/share/perl5/PVE/API2/Disks/IO.pm` |
| edit | `/usr/share/perl5/PVE/API2/Disks.pm` — registers the subclass |
| new | `/usr/share/pve-manager/js/pve-disk-io.js` |
| edit | `/usr/share/pve-manager/index.html.tpl` — loads the panel |

`pvemanagerlib.js` is deliberately **not** patched. The panel adds itself to the
node menu with a runtime Ext override, so a `pve-manager` upgrade can never
leave a half-applied patch behind. An upgrade does overwrite `index.html.tpl`
and remove the two new files, so re-run `install.sh` after upgrading
`pve-manager`.

## Uninstall

```bash
sudo scripts/uninstall.sh
```

Restores the stock files from the backups and removes the two added files.

## Notes for anyone extending this

Two ExtJS traps cost real debugging time here, both worth knowing:

- **Do not use `'use strict'` in a file that calls `callParent()`.** ExtJS
  implements `callParent` via `Function.prototype.caller`, which is `null` under
  strict mode, so every `callParent` throws `Cannot read properties of null
  (reading '$owner')`. Because the panel's classes are defined inside
  `Ext.onReady`, that exception aborted the whole ready chain and the web UI
  came up blank.

- **Do not name a component method `render`.** It shadows
  `Ext.Component.render()`, so the layout calls your function with its own
  arguments. The same applies to `update*` and `apply*`, which are the config
  system's updater/applier naming convention.

There is a browser harness under `docs/harness.md` for testing changes against
the real ExtJS and `pvemanagerlib.js` offline, without touching a live node.
