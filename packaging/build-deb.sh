#!/bin/bash
# Build pve-disk-io_<version>_all.deb.
#
# Needs dpkg-deb, so run it on a Debian-ish machine -- the Proxmox node itself
# is the obvious one. Produces the .deb in dist/.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(awk -F': ' '/^Version:/ {print $2}' "$SRC_DIR/packaging/debian/control")"
PKG="pve-disk-io"
STAGE="$(mktemp -d)"
OUT="$SRC_DIR/dist"

trap 'rm -rf "$STAGE"' EXIT

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found - build this on a Debian based host (the PVE node will do)" >&2
    exit 1
fi

echo "==> staging $PKG $VERSION"

install -D -m 0644 "$SRC_DIR/perl/DiskIO.pm"   "$STAGE/usr/share/perl5/PVE/DiskIO.pm"
install -D -m 0644 "$SRC_DIR/perl/IO.pm"       "$STAGE/usr/share/perl5/PVE/API2/Disks/IO.pm"
install -D -m 0644 "$SRC_DIR/js/pve-disk-io.js" "$STAGE/usr/share/pve-manager/js/pve-disk-io.js"
install -D -m 0755 "$SRC_DIR/bin/pve-disk-io-collector" "$STAGE/usr/sbin/pve-disk-io-collector"
install -D -m 0755 "$SRC_DIR/bin/pve-disk-io-smart" "$STAGE/usr/sbin/pve-disk-io-smart"
install -D -m 0755 "$SRC_DIR/scripts/integrate.sh" "$STAGE/usr/share/pve-disk-io/integrate.sh"
install -D -m 0644 "$SRC_DIR/systemd/pve-disk-io-collector.service" \
    "$STAGE/lib/systemd/system/pve-disk-io-collector.service"
install -D -m 0644 "$SRC_DIR/systemd/pve-disk-io-smart.service" \
    "$STAGE/lib/systemd/system/pve-disk-io-smart.service"
install -D -m 0644 "$SRC_DIR/systemd/pve-disk-io-smart.timer" \
    "$STAGE/lib/systemd/system/pve-disk-io-smart.timer"
install -D -m 0644 "$SRC_DIR/systemd/pve-disk-io-collector.timer" \
    "$STAGE/lib/systemd/system/pve-disk-io-collector.timer"
install -D -m 0644 "$SRC_DIR/README.md" "$STAGE/usr/share/doc/$PKG/README.md"
install -D -m 0644 "$SRC_DIR/packaging/debian/copyright" "$STAGE/usr/share/doc/$PKG/copyright"

install -d -m 0755 "$STAGE/DEBIAN"
install -m 0644 "$SRC_DIR/packaging/debian/control"  "$STAGE/DEBIAN/control"
install -m 0644 "$SRC_DIR/packaging/debian/triggers" "$STAGE/DEBIAN/triggers"
install -m 0755 "$SRC_DIR/packaging/debian/postinst" "$STAGE/DEBIAN/postinst"
install -m 0755 "$SRC_DIR/packaging/debian/prerm"    "$STAGE/DEBIAN/prerm"
install -m 0755 "$SRC_DIR/packaging/debian/postrm"   "$STAGE/DEBIAN/postrm"

# The two PVE files this edits belong to other packages, so they are not listed
# as conffiles; the integration helper owns those edits and reverses them.

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null

echo "==> built $DEB"
dpkg-deb --info "$DEB" | sed -n '1,12p'
echo
echo "install with:  apt install $DEB"
