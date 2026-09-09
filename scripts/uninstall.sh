#!/bin/bash
# Remove the Disk I/O Activity panel and restore the stock Proxmox VE files.

set -euo pipefail

BACKUP_DIR="/root/config-backups/disk-io"

SHARED_MODULE="/usr/share/perl5/PVE/DiskIO.pm"
API_MODULE="/usr/share/perl5/PVE/API2/Disks/IO.pm"
COLLECTOR="/usr/local/sbin/pve-disk-io-collector"
UNIT_DIR="/etc/systemd/system"
DISKS_PM="/usr/share/perl5/PVE/API2/Disks.pm"
PANEL_JS="/usr/share/pve-manager/js/pve-disk-io.js"
INDEX_TPL="/usr/share/pve-manager/index.html.tpl"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

echo "==> stopping the history collector"
systemctl disable --now pve-disk-io-collector.timer 2>/dev/null || true
rm -f "$UNIT_DIR/pve-disk-io-collector.timer" "$UNIT_DIR/pve-disk-io-collector.service"
systemctl daemon-reload

echo "==> removing the script tag"
if [ -f "$BACKUP_DIR/index.html.tpl.orig" ]; then
    cp -a "$BACKUP_DIR/index.html.tpl.orig" "$INDEX_TPL"
else
    perl -0777 -i -pe 's{^\s*<script[^\n]*pve-disk-io\.js[^\n]*\n}{}m' "$INDEX_TPL"
fi

echo "==> unregistering the API endpoint"
if [ -f "$BACKUP_DIR/Disks.pm.orig" ]; then
    cp -a "$BACKUP_DIR/Disks.pm.orig" "$DISKS_PM"
else
    perl -0777 -i -pe '
        s{use PVE::API2::Disks::IO;\n}{};
        s{\n__PACKAGE__->register_method\(\{\n    subclass => "PVE::API2::Disks::IO",\n    path => .io.,\n\}\);\n}{};
    ' "$DISKS_PM"
fi

echo "==> removing added files"
rm -f "$SHARED_MODULE" "$API_MODULE" "$PANEL_JS" "$COLLECTOR"

# Recorded history is deliberately left in place: reinstalling picks it back
# up, and silently discarding months of data on an uninstall would be rude.
if [ -d /var/lib/pve-disk-io ]; then
    echo "    (recorded history kept in /var/lib/pve-disk-io - delete it manually if unwanted)"
fi

echo "==> checking syntax"
perl -I/usr/share/perl5 -c "$DISKS_PM"

echo "==> restarting pvedaemon and pveproxy"
systemctl restart pvedaemon pveproxy

echo
echo "Removed. Hard-reload the browser (Ctrl-Shift-R)."
