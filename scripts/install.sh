#!/bin/bash
# Install the Disk I/O Activity panel into Proxmox VE.
#
# Adds two new files and makes two small, idempotent edits to stock files:
#
#   new   /usr/share/perl5/PVE/DiskIO.pm          shared stats + RRD layout
#   new   /usr/share/perl5/PVE/API2/Disks/IO.pm   the API endpoints
#   edit  /usr/share/perl5/PVE/API2/Disks.pm      registers them as a subclass
#   new   /usr/local/sbin/pve-disk-io-collector   records history once a minute
#   new   /etc/systemd/system/pve-disk-io-collector.{service,timer}
#   new   /usr/share/pve-manager/js/pve-disk-io.js  the panel and summary graph
#   edit  /usr/share/pve-manager/index.html.tpl     loads them
#
# pvemanagerlib.js is deliberately NOT touched: the panel installs itself into
# the node menu with a runtime Ext override, so a pve-manager upgrade can never
# leave a half-applied patch behind. An upgrade does overwrite index.html.tpl
# and remove the two new files, so re-run this script after upgrading
# pve-manager. Run uninstall.sh to revert.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

for f in "$DISKS_PM" "$INDEX_TPL"; do
    if [ ! -f "$f" ]; then
        echo "missing $f - is this a Proxmox VE node?" >&2
        exit 1
    fi
done

mkdir -p "$BACKUP_DIR"

echo "==> installing modules"
install -m 0644 "$SRC_DIR/perl/DiskIO.pm" "$SHARED_MODULE"
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

# Cache-bust on the panel's own content, not on [% version %]. That template
# variable is the pve-manager version, which does not change when this file is
# redeployed -- so browsers kept serving the previously cached panel and a
# reinstall appeared to do nothing until someone hard-reloaded.
PANEL_VER="$(md5sum "$SRC_DIR/js/pve-disk-io.js" | cut -c1-12)"

PANEL_VER="$PANEL_VER" perl -0777 -i -pe '
    my $tag = qq{    <script type="text/javascript" src="/pve2/js/pve-disk-io.js?ver=$ENV{PANEL_VER}"></script>\n};
    # Replace any tag we added before, so repeated installs do not stack up.
    if (s{^[^\n]*pve-disk-io\.js[^\n]*\n}{$tag}m) {
        # updated in place
    } else {
        s{(^\s*<script type="text/javascript" src="/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]"></script>\n)}{$1$tag}m;
    }
' "$INDEX_TPL"

if ! grep -q 'pve-disk-io\.js' "$INDEX_TPL"; then
    echo "failed to add the script tag to $INDEX_TPL" >&2
    exit 1
fi

echo "==> installing the history collector"
install -m 0755 "$SRC_DIR/bin/pve-disk-io-collector" "$COLLECTOR"
install -m 0644 "$SRC_DIR/systemd/pve-disk-io-collector.service" "$UNIT_DIR/"
install -m 0644 "$SRC_DIR/systemd/pve-disk-io-collector.timer" "$UNIT_DIR/"

# Never restart the API into code that does not compile.
echo "==> checking syntax"
perl -I/usr/share/perl5 -c "$SHARED_MODULE"
perl -I/usr/share/perl5 -c "$API_MODULE"
perl -I/usr/share/perl5 -c "$DISKS_PM"

echo "==> starting the collector"
systemctl daemon-reload
systemctl enable --now pve-disk-io-collector.timer
# Seed one sample immediately so the RRDs exist before the first timer tick.
systemctl start pve-disk-io-collector.service || true

echo "==> restarting pvedaemon and pveproxy"
systemctl restart pvedaemon pveproxy

echo
echo "Installed."
echo "  live view : Node -> Disks -> I/O Activity"
echo "  history   : Node -> Summary (fills in over the next few minutes)"
echo "Hard-reload the browser (Ctrl-Shift-R) to pick up the new script."
