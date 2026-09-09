#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: grioghar
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/grioghar/proxmox-disk-io

# shellcheck source=/dev/null
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/misc/core.func)
# shellcheck source=/dev/null
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func) 2>/dev/null || true
load_functions
declare -f init_tool_telemetry &>/dev/null && init_tool_telemetry "pve-disk-io" "pve"

function header_info {
  clear
  cat <<"EOF"
    ____  _      __      ______  ______
   / __ \(_)____/ /__   /  _/ / / / __ \
  / / / / / ___/ //_/   / // / / / / / /
 / /_/ / (__  ) ,<    _/ // /_/ / /_/ /
/_____/_/____/_/|_|  /___/\____/\____/

EOF
}

APP="Disk I/O Panel"
var_repo="grioghar/proxmox-disk-io"
var_pkg="pve-disk-io"

header_info

if ! command -v pveversion &>/dev/null; then
  msg_error "No Proxmox VE detected. Run this on a Proxmox VE host."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  msg_error "This script must be run as root."
  exit 1
fi

# Read the action from the environment first so the script can be driven
# unattended, and only fall back to prompting when it is unset.
var_action="${var_action:-}"

if [ -z "$var_action" ]; then
  var_action=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "$APP" \
    --menu "\nAdds a live disk I/O panel to the Proxmox web UI: what each physical\ndisk is doing, which guests are responsible, and recorded history.\n\nSelect an action:" 17 74 3 \
    "install" "Install or update the panel" \
    "uninstall" "Remove the panel and restore stock files" \
    "status" "Show what is currently installed" \
    3>&1 1>&2 2>&3) || exit 0
fi

function latest_release() {
  curl -fsSL "https://api.github.com/repos/${var_repo}/releases/latest" |
    grep -oP '"tag_name":\s*"\K[^"]+' | head -n1
}

function do_install() {
  local release deb_url tmp_deb
  msg_info "Checking for dependencies"
  # librrds-perl is what the collector writes history through; the rest ships
  # with Proxmox VE already.
  if ! dpkg -s librrds-perl &>/dev/null || ! dpkg -s libjson-perl &>/dev/null; then
    apt-get update -qq &>/dev/null
    apt-get install -y -qq librrds-perl libjson-perl &>/dev/null
  fi
  msg_ok "Dependencies satisfied"

  msg_info "Resolving latest release"
  release="$(latest_release)"
  if [ -z "$release" ]; then
    msg_error "Could not reach the GitHub API to resolve a release"
    exit 1
  fi
  deb_url="https://github.com/${var_repo}/releases/download/${release}/${var_pkg}_${release#v}_all.deb"
  msg_ok "Latest release is ${release}"

  msg_info "Downloading ${var_pkg} ${release}"
  tmp_deb="$(mktemp --suffix=.deb)"
  if ! curl -fsSL -o "$tmp_deb" "$deb_url"; then
    rm -f "$tmp_deb"
    msg_error "Download failed: $deb_url"
    exit 1
  fi
  msg_ok "Downloaded ${var_pkg} ${release}"

  msg_info "Installing ${APP}"
  if ! apt-get install -y -qq "$tmp_deb" &>/dev/null; then
    rm -f "$tmp_deb"
    msg_error "Installation failed"
    exit 1
  fi
  rm -f "$tmp_deb"
  msg_ok "Installed ${APP} ${release}"

  echo -e "\n  Live view : Node -> Disks -> I/O Activity"
  echo -e "  Per guest : the guest -> Disk I/O"
  echo -e "  History   : Node -> Summary, and each guest's Summary\n"
  echo -e "  Hard-reload the browser (Ctrl-Shift-R) to pick up the new panel."
  echo -e "  History fills in over the next hour.\n"
}

function do_uninstall() {
  if ! dpkg -s "$var_pkg" &>/dev/null; then
    msg_error "${APP} is not installed"
    exit 1
  fi

  msg_info "Removing ${APP}"
  # remove, not purge: recorded history is kept so a reinstall picks it back
  # up. Purge the package by hand to discard it.
  apt-get remove -y -qq "$var_pkg" &>/dev/null
  msg_ok "Removed ${APP} and restored the stock Proxmox files"

  if [ -d /var/lib/pve-disk-io ]; then
    echo -e "\n  Recorded history kept in /var/lib/pve-disk-io"
    echo -e "  Discard it with: apt purge ${var_pkg}\n"
  fi
}

function do_status() {
  if dpkg -s "$var_pkg" &>/dev/null; then
    msg_ok "Installed: $(dpkg-query -W -f='${Version}' "$var_pkg")"
  else
    msg_error "Not installed"
    exit 0
  fi

  if [ -x /usr/share/pve-disk-io/integrate.sh ]; then
    /usr/share/pve-disk-io/integrate.sh status
  fi

  if systemctl is-active --quiet pve-disk-io-collector.timer; then
    msg_ok "History collector is running"
  else
    msg_error "History collector is not running"
  fi
}

case "$var_action" in
install) do_install ;;
uninstall) do_uninstall ;;
status) do_status ;;
*)
  msg_error "Unknown action: ${var_action}"
  exit 1
  ;;
esac

exit 0
