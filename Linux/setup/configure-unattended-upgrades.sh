#!/bin/bash
# configure-unattended-upgrades.sh - Enable automatic APT updates and security patches.
#
# Installs unattended-upgrades and writes:
#   /etc/apt/apt.conf.d/20auto-upgrades           (periodic update/download/clean)
#   /etc/apt/apt.conf.d/52unattended-upgrades-local (overrides; the distro's
#                                                   50unattended-upgrades is left untouched)
#
# Usage:
#   sudo ./configure-unattended-upgrades.sh
#   sudo AUTO_REBOOT=false ./configure-unattended-upgrades.sh
#   sudo REBOOT_TIME=04:00 AUTOCLEAN_DAYS=14 ./configure-unattended-upgrades.sh
#
# Requirements: root.
# Supported:    Debian / Ubuntu.

set -euo pipefail

# ---- Configuration (override via environment) ------------------------------
AUTOCLEAN_DAYS="${AUTOCLEAN_DAYS:-7}"            # APT::Periodic::AutocleanInterval
REMOVE_UNUSED_DEPS="${REMOVE_UNUSED_DEPS:-true}" # true/false
AUTO_REBOOT="${AUTO_REBOOT:-true}"               # true/false: reboot if required
REBOOT_TIME="${REBOOT_TIME:-03:15}"              # HH:MM local time
# -----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
echo "Installing unattended-upgrades..."
apt-get install -y unattended-upgrades

echo "Writing /etc/apt/apt.conf.d/20auto-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "${AUTOCLEAN_DAYS}";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "Writing /etc/apt/apt.conf.d/52unattended-upgrades-local..."
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "${REMOVE_UNUSED_DEPS}";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
EOF

# Legacy 10periodic (older Ubuntu) can conflict with 20auto-upgrades; warn only.
if [[ -f /etc/apt/apt.conf.d/10periodic ]]; then
  echo "Note: /etc/apt/apt.conf.d/10periodic exists; 20auto-upgrades is read after it and takes precedence."
fi

echo "Validating configuration..."
apt-config dump | grep -E '^(APT::Periodic|Unattended-Upgrade::(Remove-Unused-Dependencies|Automatic-Reboot))' || true
unattended-upgrade --dry-run >/dev/null 2>&1 \
  && echo "unattended-upgrade dry run OK." \
  || echo "Warning: unattended-upgrade dry run reported problems; run 'unattended-upgrade --dry-run -d' to inspect." >&2

echo "Done."
