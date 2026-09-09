#!/bin/bash
# Install the Disk I/O Activity panel into Proxmox VE.
#
# Adds two new files and makes two small, idempotent edits to stock files:
#
#   new   /usr/share/perl5/PVE/API2/Disks/IO.pm   the API endpoint
#   edit  /usr/share/perl5/PVE/API2/Disks.pm      registers it as a subclass
#   new   /usr/share/pve-manager/js/pve-disk-io.js  the panel
#   edit  /usr/share/pve-manager/index.html.tpl     loads the panel
#
# pvemanagerlib.js is deliberately NOT touched: the panel installs itself into
# the node menu with a runtime Ext override, so a pve-manager upgrade can never
# leave a half-applied patch behind. An upgrade does overwrite index.html.tpl
# and remove the two new files, so re-run this script after upgrading
# pve-manager. Run uninstall.sh to revert.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="/root/config-backups/disk-io"

API_MODULE="/usr/share/perl5/PVE/API2/Disks/IO.pm"
DISKS_PM="/usr/share/perl5/PVE/API2/Disks.pm"
PANEL_JS="/usr/share/pve-manager/js/pve-disk-io.js"
INDEX_TPL="/usr/share/pve-manager/index.html.tpl"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

for f in "$DISKS_PM" "$INDEX_TPL"; do
    if [ ! -f "$f" ]; then
        echo "missing $f - is this a Proxmox VE node?" >&2
        exit 1
    fi
done

mkdir -p "$BACKUP_DIR"

echo "==> installing API module"
install -m 0644 "$SRC_DIR/perl/IO.pm" "$API_MODULE"

echo "==> registering /nodes/{node}/disks/io"
[ -f "$BACKUP_DIR/Disks.pm.orig" ] || cp -a "$DISKS_PM" "$BACKUP_DIR/Disks.pm.orig"
perl -0777 -i -pe '
    if (!/Disks::IO/) {
        s{(use PVE::API2::Disks::ZFS;\n)}{$1use PVE::API2::Disks::IO;\n};
        s{(__PACKAGE__->register_method\(\{\n    subclass => "PVE::API2::Disks::ZFS",\n    path => .zfs.,\n\}\);\n)}
         {$1\n__PACKAGE__->register_method({\n    subclass => "PVE::API2::Disks::IO",\n    path => "io",\n});\n};
    }
' "$DISKS_PM"

if ! grep -q 'Disks::IO' "$DISKS_PM"; then
    echo "failed to register the subclass in $DISKS_PM" >&2
    exit 1
fi

echo "==> installing panel"
install -m 0644 "$SRC_DIR/js/pve-disk-io.js" "$PANEL_JS"

echo "==> adding the script tag"
[ -f "$BACKUP_DIR/index.html.tpl.orig" ] || cp -a "$INDEX_TPL" "$BACKUP_DIR/index.html.tpl.orig"
perl -0777 -i -pe '
    if (!/pve-disk-io\.js/) {
        s{(^\s*<script type="text/javascript" src="/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]"></script>\n)}
         {$1    <script type="text/javascript" src="/pve2/js/pve-disk-io.js?ver=[% version %]"></script>\n}m;
    }
' "$INDEX_TPL"

if ! grep -q 'pve-disk-io\.js' "$INDEX_TPL"; then
    echo "failed to add the script tag to $INDEX_TPL" >&2
    exit 1
fi

# Never restart the API into code that does not compile.
echo "==> checking syntax"
perl -I/usr/share/perl5 -c "$API_MODULE"
perl -I/usr/share/perl5 -c "$DISKS_PM"

echo "==> restarting pvedaemon and pveproxy"
systemctl restart pvedaemon pveproxy

echo
echo "Installed. Open a node in the web UI: Disks -> I/O Activity."
echo "Hard-reload the browser (Ctrl-Shift-R) to pick up the new script."
