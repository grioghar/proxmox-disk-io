#!/bin/bash
# Remove the Disk I/O panel and restore the stock Proxmox VE files.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

echo "==> stopping the collector"
systemctl disable --now pve-disk-io-collector.timer 2>/dev/null || true
rm -f /lib/systemd/system/pve-disk-io-collector.timer \
      /lib/systemd/system/pve-disk-io-collector.service
systemctl daemon-reload

echo "==> unwiring from Proxmox VE"
if [ -x /usr/share/pve-disk-io/integrate.sh ]; then
    /usr/share/pve-disk-io/integrate.sh unpatch
fi

echo "==> removing files"
rm -f /usr/share/perl5/PVE/DiskIO.pm \
      /usr/share/perl5/PVE/API2/Disks/IO.pm \
      /usr/share/pve-manager/js/pve-disk-io.js \
      /usr/sbin/pve-disk-io-collector
rm -rf /usr/share/pve-disk-io

echo "==> restarting pvedaemon and pveproxy"
systemctl restart pvedaemon pveproxy

if [ -d /var/lib/pve-disk-io ]; then
    echo
    echo "Recorded history kept in /var/lib/pve-disk-io"
    echo "Delete it yourself if you do not want it: rm -rf /var/lib/pve-disk-io"
fi
