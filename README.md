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

## History on the node Summary

The node Summary page gets a **Disk I/O** graph beside the CPU, memory and
network ones. It follows the page's existing Hour/Day/Week/Month/Year selector,
because it is built on the same `Proxmox.data.RRDStore` those graphs use.

By default it overlays every physical disk, one line each, so a spike is
immediately attributable to a spindle. A picker in the graph's header narrows
it to a single disk, which then splits into read and write.

PVE records `diskread`/`diskwrite` per *guest* already (that is the Disk IO
graph on each guest's own Summary), but a node's RRD has no disk fields at all
— only cpu, memory, network, root filesystem and pressure. So this adds its own.

- **Storage** — one RRD per disk under `/var/lib/pve-disk-io/rrd/<node>/`,
  with the same step and retention as PVE's node RRDs (60s, and RRAs at 1min /
  30min / 6h / 7d with AVERAGE and MAX), so the timeframe selector behaves
  identically.

- **Keyed on serial, not `sdX`.** Kernel names are not stable — USB enclosures
  in particular reorder across reboots — so history keyed on `sdb` would
  silently follow whichever drive enumerated second. Keying on the serial means
  a disk's history follows the physical drive. A disk that is currently
  detached stays listed (greyed as *detached*) so its history is still
  reachable.

- **Counters, not rates.** The collector writes raw counters into `DERIVE` data
  sources and lets rrdtool derive the rates, so it holds no state: a missed
  run, a restart or a reboot cannot produce a bogus spike.

- **Collection** — `pve-disk-io-collector.timer` runs once a minute, matching
  the RRD step. The collector reads only procfs and sysfs, so it needs neither
  the PVE API stack nor a long-running daemon.

Uninstalling stops the collector but deliberately leaves the recorded history
in `/var/lib/pve-disk-io/`.

## Seeing through a FUSE pool

A container writing to a mergerfs pool never touches a block device itself: it
makes a syscall, the mergerfs daemon on the host does the I/O, and so the block
layer -- and every cgroup built on it -- credits the daemon. Left alone, the
panel would truthfully report *"mergerfs is writing to sdh"* while hiding the
only thing worth knowing, which is who asked it to.

So the daemon is treated as what it is -- a passthrough. It is **not listed as a
consumer**; its per-disk bytes are handed to the callers holding files open on
the pool, and it is those callers that appear, both in the consumer list and as
a disk's **Top Consumer**:

| Disk | Top Consumer |
| --- | --- |
| sdh | sabnzbd (3130) (97%) |
| sdg | sabnzbd (3130) (86%) |
| sdf | plex (3111) (100%) |
| sdc | rebalance (rebalance-runner) (69%) |

Host callers count too: a rebalance script pooling media is as much a consumer
as a container is. Rows credited this way carry a **via pool** tag.

How it works:

- Open descriptors are matched on the pool's **st_dev**, not on a path prefix,
  because a container sees the pool at its own mountpoint (`/storage` in one,
  `/mnt/storage` in another). Matching on the path finds nothing.
- The disk behind each file comes from mergerfs's own
  `user.mergerfs.basepath` xattr, resolved through the mount table.
- The **quantity** shared out is block level throughout; only the **split**
  between callers comes from syscall counters (`rchar`/`wchar`, weighted by how
  many of each caller's open files sit on that disk). So a disk's attributed
  bytes still add up to what the disk really did.
- Callers are aggregated **by owner, not by pid**. Pids churn constantly here --
  a transcode or an unpack is a fresh process each time -- and matching on them
  dropped a caller from the comparison the moment its pid changed, sending that
  disk's whole load into the unattributed bucket.
- Writeback happens long after the write, usually once the file is closed, so a
  disk whose pool traffic has no caller *currently holding a descriptor on it*
  falls back to splitting across every active caller rather than blaming nobody.
- Only when nothing at all is using the pool does a *"no active caller"* row
  appear; dropping those bytes instead would leave the disk's totals not adding
  up.

The daemon that serves a pool is identified by holding `/dev/fuse` open with the
mountpoint in its command line, so it never looks like a caller of itself.

Finding which processes hold files open costs ~500ms, so that scan is cached for
30s -- a transcode or an unpack lasts minutes. Ordinary polls stay at ~60ms.
Untick **Trace FUSE pool** to skip it entirely, at the cost of the daemon
reappearing as the consumer.

## Per-guest views

Every LXC and VM gets a **Disk I/O** page of its own, next to the hardware it
describes (after Resources for a container, after Hardware for a VM). It shows
which physical disks that guest is touching right now, at what rate, and what
share of each disk's total traffic it accounts for. Because it runs the same
attribution as the node panel, I/O the guest does *through* a storage pool is
credited to the guest rather than to the pool's daemon.

Each guest's **Summary** also gains a *Disk I/O by Disk* graph. PVE already
graphs a guest's total read/write there; this adds which spindle it landed on,
which the stock guest RRDs cannot express.

That per-disk history needs its own collection, in one RRD per (guest, disk)
under `/var/lib/pve-disk-io/rrd/<node>/guests/`. Unlike the per-disk RRDs these
hold GAUGE rates rather than DERIVE counters: I/O reaching a disk through a
FUSE pool has to be apportioned between the pool's callers, and a share is a
rate, not something with a monotonic total behind it. The collector therefore
keeps the previous sample and computes over the whole interval; a gap outside
30-180s is skipped rather than averaged across, so a stopped collector or a
reboot cannot invent a plateau.

The apportioning lives in `PVE::DiskIO::attribute_io`, which is the same
algorithm as `distributePoolIO()` in the panel. The panel computes rates in the
browser so the API can stay stateless, and the collector cannot reuse that, so
both carry a note that they must be kept in step.

A disk a guest reaches **through a storage pool** is marked *(via pool)* in the
legend, because that series is apportioned from the pool daemon's totals rather
than measured against the guest -- the same distinction the live panel draws
with its `via pool` tag. A guest's own block I/O carries no marker. For plex,
for instance, the media disks are marked and its rootfs on nvme0n1 is not.

Host consumers are deliberately not recorded here -- this is guest history and
the charts are keyed on vmid -- so a host script like a rebalance job shows up
in the live panel but not in guest history.

**On the legend's position.** The series are drawn exactly as PVE draws its own,
filled and in the same style. The legend, though, is docked under the chart
rather than sitting in the header where PVE puts its. That is deliberate: no
stock PVE graph has more than three series, while these carry one per disk or
per guest. In the header such a legend either crushes the title out of
existence (measured: 825px of a 1158px header, leaving the title 67px) or, once
wrapped, overlaps the plot.

## How the numbers are produced

The API returns raw monotonic counters plus a high-resolution timestamp; the
browser derives every rate from the delta between two samples. The server stays
stateless and the rates reflect real elapsed time rather than an assumed
interval.

| Source | Used for |
| --- | --- |
| `/proc/diskstats` | per-disk throughput, IOPS, utilisation, latency, queue |
| `/sys/block/*`, `/run/udev/data/b*` | model, serial, size, bus, scheduler |
| cgroup v2 `io.stat` | per-container I/O, and per host systemd unit, per device |
| `/proc/pid/io` + mergerfs xattrs | containers reaching disks through a FUSE pool |
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

- **The host itself.** Work outside any guest -- mergerfs pooling media, a
  backup job -- lives in no guest cgroup, so attributing only guests leaves I/O
  showing on a disk with nothing accounting for it. systemd puts each unit in
  its own cgroup and `system.slice` *does* enable the io controller (unlike
  `qemu.slice`), so host work is attributed per device the same way containers
  are, for about 7ms. Units are labelled by what they are rather than by their
  unit name: `mnt-storage.mount` is shown as `/mnt/storage (mergerfs)`.

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
| new | `/usr/share/perl5/PVE/DiskIO.pm` — shared stats and RRD layout |
| new | `/usr/share/perl5/PVE/API2/Disks/IO.pm` — the API endpoints |
| edit | `/usr/share/perl5/PVE/API2/Disks.pm` — registers the subclass |
| new | `/usr/local/sbin/pve-disk-io-collector` |
| new | `/etc/systemd/system/pve-disk-io-collector.{service,timer}` |
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

- **Do not destroy a component from inside its own event handler.** The disk
  picker lives in the chart header it replaces, so rebuilding straight from its
  `change` handler left ExtJS running against a destroyed field. Defer it.

- `Proxmox.data.UpdateStore.startUpdate()` will not load until
  `Proxmox.Utils.authOK()` is true, which is worth knowing when a store looks
  stuck at zero records in a test harness.

There is a browser harness under `docs/harness.md` for testing changes against
the real ExtJS and `pvemanagerlib.js` offline, without touching a live node.
