#!/bin/bash
# Install the Disk I/O panel into Proxmox VE from a source checkout.
#
# For a packaged install use the .deb instead (see packaging/build-deb.sh),
# which additionally re-applies itself when pve-manager is upgraded. This
# script has no such hook, so re-run it after upgrading pve-manager.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

echo "==> installing files"
install -D -m 0644 "$SRC_DIR/perl/DiskIO.pm" /usr/share/perl5/PVE/DiskIO.pm
install -D -m 0644 "$SRC_DIR/perl/IO.pm" /usr/share/perl5/PVE/API2/Disks/IO.pm
install -D -m 0644 "$SRC_DIR/js/pve-disk-io.js" /usr/share/pve-manager/js/pve-disk-io.js
install -D -m 0755 "$SRC_DIR/bin/pve-disk-io-collector" /usr/sbin/pve-disk-io-collector
install -D -m 0755 "$SRC_DIR/scripts/integrate.sh" /usr/share/pve-disk-io/integrate.sh
install -D -m 0644 "$SRC_DIR/systemd/pve-disk-io-collector.service" \
    /lib/systemd/system/pve-disk-io-collector.service
install -D -m 0644 "$SRC_DIR/systemd/pve-disk-io-collector.timer" \
    /lib/systemd/system/pve-disk-io-collector.timer

echo "==> wiring into Proxmox VE"
/usr/share/pve-disk-io/integrate.sh patch

echo "==> starting the collector"
systemctl daemon-reload
systemctl enable --now pve-disk-io-collector.timer
# Seed a sample immediately so the RRDs exist before the first timer tick.
systemctl start pve-disk-io-collector.service || true

echo "==> restarting pvedaemon and pveproxy"
systemctl restart pvedaemon pveproxy

cat <<'DONE'

Installed.
  live view : Node -> Disks -> I/O Activity
  per guest : the guest -> Disk I/O
  history   : Node -> Summary, and each guest's Summary

Hard-reload the browser (Ctrl-Shift-R) to pick up the new script.
DONE
