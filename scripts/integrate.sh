#!/bin/bash
# Wires the panel into Proxmox VE, and unwires it again.
#
# Two stock files have to be touched, and both edits are idempotent:
#
#   /usr/share/perl5/PVE/API2/Disks.pm   registers the API subclass
#   /usr/share/pve-manager/index.html.tpl  loads the panel's JavaScript
#
# pvemanagerlib.js is deliberately NOT touched. The panel installs itself into
# the menus with a runtime Ext override, so a pve-manager upgrade can never
# leave a half-applied patch behind.
#
# Both installers use this, so there is one implementation of the edits rather
# than one per packaging format.

set -euo pipefail

DISKS_PM="/usr/share/perl5/PVE/API2/Disks.pm"
INDEX_TPL="/usr/share/pve-manager/index.html.tpl"
BACKUP_DIR="/var/backups/pve-disk-io"

usage() {
    echo "usage: $0 {patch|unpatch|status}" >&2
    exit 2
}

require_pve() {
    for f in "$DISKS_PM" "$INDEX_TPL"; do
        if [ ! -f "$f" ]; then
            echo "missing $f - is this a Proxmox VE node?" >&2
            exit 1
        fi
    done
}

do_patch() {
    require_pve
    mkdir -p "$BACKUP_DIR"

    # Keep one pristine copy. Never overwrite it: after a pve-manager upgrade
    # the "original" on disk is the new stock file, which is what we want to
    # keep, but only if we have not already patched it.
    [ -f "$BACKUP_DIR/Disks.pm.orig" ] || cp -a "$DISKS_PM" "$BACKUP_DIR/Disks.pm.orig"
    [ -f "$BACKUP_DIR/index.html.tpl.orig" ] || cp -a "$INDEX_TPL" "$BACKUP_DIR/index.html.tpl.orig"

    perl -0777 -i -pe '
        if (!/Disks::IO/) {
            s{(use PVE::API2::Disks::ZFS;\n)}{$1use PVE::API2::Disks::IO;\n};
            s{(__PACKAGE__->register_method\(\{\n    subclass => "PVE::API2::Disks::ZFS",\n    path => .zfs.,\n\}\);\n)}
             {$1\n__PACKAGE__->register_method({\n    subclass => "PVE::API2::Disks::IO",\n    path => "io",\n});\n};
        }
    ' "$DISKS_PM"

    grep -q 'Disks::IO' "$DISKS_PM" || { echo "failed to register the API subclass" >&2; exit 1; }

    perl -0777 -i -pe '
        if (!/pve-disk-io\.js/) {
            s{(^\s*<script type="text/javascript" src="/pve2/js/pvemanagerlib\.js\?ver=\[% version %\]"></script>\n)}
             {$1    <script type="text/javascript" src="/pve2/js/pve-disk-io.js?ver=[% version %]"></script>\n}m;
        }
    ' "$INDEX_TPL"

    grep -q 'pve-disk-io\.js' "$INDEX_TPL" || { echo "failed to add the script tag" >&2; exit 1; }

    # Never restart the API into code that does not compile.
    perl -I/usr/share/perl5 -c /usr/share/perl5/PVE/DiskIO.pm
    perl -I/usr/share/perl5 -c /usr/share/perl5/PVE/API2/Disks/IO.pm
    perl -I/usr/share/perl5 -c "$DISKS_PM"
}

do_unpatch() {
    if [ -f "$BACKUP_DIR/index.html.tpl.orig" ]; then
        cp -a "$BACKUP_DIR/index.html.tpl.orig" "$INDEX_TPL"
    elif [ -f "$INDEX_TPL" ]; then
        perl -0777 -i -pe 's{^\s*<script[^\n]*pve-disk-io\.js[^\n]*\n}{}m' "$INDEX_TPL"
    fi

    if [ -f "$BACKUP_DIR/Disks.pm.orig" ]; then
        cp -a "$BACKUP_DIR/Disks.pm.orig" "$DISKS_PM"
    elif [ -f "$DISKS_PM" ]; then
        perl -0777 -i -pe '
            s{use PVE::API2::Disks::IO;\n}{};
            s{\n__PACKAGE__->register_method\(\{\n    subclass => "PVE::API2::Disks::IO",\n    path => .io.,\n\}\);\n}{};
        ' "$DISKS_PM"
    fi

    [ -f "$DISKS_PM" ] && perl -I/usr/share/perl5 -c "$DISKS_PM"
}

do_status() {
    local registered="no" loaded="no"
    grep -q 'Disks::IO' "$DISKS_PM" 2>/dev/null && registered="yes"
    grep -q 'pve-disk-io\.js' "$INDEX_TPL" 2>/dev/null && loaded="yes"
    echo "API subclass registered: $registered"
    echo "panel script loaded:     $loaded"
}

case "${1:-}" in
    patch) do_patch ;;
    unpatch) do_unpatch ;;
    status) do_status ;;
    *) usage ;;
esac
