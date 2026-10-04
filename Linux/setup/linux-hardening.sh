#!/bin/bash
# linux-hardening.sh - Baseline setup and hardening for a fresh Debian/Ubuntu server.
#
# Steps (each configurable below):
#   - Set timezone
#   - Optionally add third-party APT repos (runs ./apt-repos.sh if present)
#   - Full system update
#   - Set hostname and /etc/hosts entry
#   - Disable SSH root login
#   - UFW firewall: rate-limited SSH (optionally restricted to subnets) + extra ports
#   - Mount /tmp as tmpfs with noexec,nosuid,nodev
#   - Configure unattended upgrades (runs ./configure-unattended-upgrades.sh if present)
#   - Install Fail2Ban, Glances and optionally Filebeat
#
# Usage:
#   sudo ./linux-hardening.sh                       # interactive prompts for unset values
#   sudo NEW_HOSTNAME=web01 FQDN=web01.example.com HOST_IP=192.0.2.10 \
#        SSH_ALLOWED_SUBNETS="192.0.2.0/24 198.51.100.0/24" EXTRA_PORTS="80/tcp 443/tcp" \
#        TIMEZONE=Etc/UTC ./linux-hardening.sh
#
# Requirements: root, systemd, OpenSSH server.
# Supported:    Ubuntu 20.04+ and Debian 11+.
#
# WARNING: Enables UFW. If SSH_ALLOWED_SUBNETS is set and you are connecting from
# outside those subnets you WILL be locked out. Test on a console-accessible host first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Configuration (override via environment) ------------------------------
TIMEZONE="${TIMEZONE:-Etc/UTC}"                  # e.g. America/New_York
RUN_APT_REPOS="${RUN_APT_REPOS:-no}"             # yes = run ./apt-repos.sh
NEW_HOSTNAME="${NEW_HOSTNAME:-}"                 # prompted if empty (blank = keep current)
FQDN="${FQDN:-}"                                 # e.g. server01.example.com
HOST_IP="${HOST_IP:-}"                           # e.g. 192.0.2.10
SSH_ALLOWED_SUBNETS="${SSH_ALLOWED_SUBNETS:-}"   # space-separated CIDRs; empty = allow from anywhere (rate-limited)
EXTRA_PORTS="${EXTRA_PORTS-__prompt__}"          # e.g. "80/tcp 443/tcp"; set to "" to skip prompt
BASE_DIRS="${BASE_DIRS:-}"                       # optional dirs to create, e.g. "/opt/scripts /opt/backups"
HARDEN_TMP="${HARDEN_TMP:-yes}"                  # yes = tmpfs /tmp with noexec,nosuid,nodev
TMP_SIZE="${TMP_SIZE:-1G}"
LINK_VAR_TMP="${LINK_VAR_TMP:-no}"               # yes = replace /var/tmp with symlink to /tmp (non-persistent!)
EXTRA_PACKAGES="${EXTRA_PACKAGES:-fail2ban glances}"
INSTALL_FILEBEAT="${INSTALL_FILEBEAT:-no}"       # yes = install Filebeat (needs Elastic repo)
ASSUME_YES="${ASSUME_YES:-no}"                   # yes = no prompts; skip reboot prompt
# -----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

ask() { # ask VAR "prompt"  - prompt only if interactive and not ASSUME_YES
  local __var="$1" __prompt="$2" __val=""
  if [[ "$ASSUME_YES" != "yes" && -t 0 ]]; then
    read -rp "$__prompt" __val || true
  fi
  printf -v "$__var" '%s' "$__val"
}

# ---- Timezone ----------------------------------------------------------------
echo "Setting timezone to $TIMEZONE..."
timedatectl set-timezone "$TIMEZONE"

# ---- APT repositories --------------------------------------------------------
if [[ "$RUN_APT_REPOS" == "yes" ]]; then
  if [[ -f "$SCRIPT_DIR/apt-repos.sh" ]]; then
    bash "$SCRIPT_DIR/apt-repos.sh"
  else
    echo "Warning: $SCRIPT_DIR/apt-repos.sh not found; skipping repo setup." >&2
  fi
fi

# ---- System update -----------------------------------------------------------
echo "Updating the system..."
apt-get update
apt-get upgrade -y

# ---- Hostname / hosts --------------------------------------------------------
[[ -z "$NEW_HOSTNAME" ]] && ask NEW_HOSTNAME "Hostname (blank to keep '$(hostname)'): "
if [[ -n "$NEW_HOSTNAME" ]]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  echo "Hostname set to $NEW_HOSTNAME."
fi

[[ -z "$FQDN" ]] && ask FQDN "FQDN (e.g. server01.example.com, blank to skip /etc/hosts): "
if [[ -n "$FQDN" ]]; then
  [[ -z "$HOST_IP" ]] && ask HOST_IP "Internal IP for $FQDN (e.g. 192.0.2.10): "
  if [[ -n "$HOST_IP" ]]; then
    cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
$HOST_IP $FQDN ${FQDN%%.*}

# IPv6
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    echo "/etc/hosts updated (backup saved)."
  fi
fi

# ---- Base directories --------------------------------------------------------
if [[ -n "$BASE_DIRS" ]]; then
  # shellcheck disable=SC2086
  mkdir -p $BASE_DIRS
  echo "Created: $BASE_DIRS"
fi

# ---- SSH: disable root login -------------------------------------------------
echo "Disabling SSH root login..."
if grep -qE '^[#[:space:]]*PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i -E 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi
if grep -rqsE '^[[:space:]]*PermitRootLogin[[:space:]]+yes' /etc/ssh/sshd_config.d/; then
  echo "Warning: a file in /etc/ssh/sshd_config.d/ sets 'PermitRootLogin yes' and may override this." >&2
fi
sshd -t
systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "SSH root login disabled."

# ---- Firewall (UFW) ----------------------------------------------------------
echo "Configuring UFW..."
apt-get install -y ufw
if [[ -n "$SSH_ALLOWED_SUBNETS" ]]; then
  for net in $SSH_ALLOWED_SUBNETS; do
    ufw limit from "$net" to any port ssh proto tcp
  done
else
  echo "SSH_ALLOWED_SUBNETS not set: allowing SSH from anywhere (rate-limited)."
  ufw limit ssh
fi

if [[ "$EXTRA_PORTS" == "__prompt__" ]]; then
  ask EXTRA_PORTS "Additional ports to allow (e.g. 80/tcp 443/tcp, blank for none): "
fi
for port in $EXTRA_PORTS; do
  ufw allow "$port"
done
ufw --force enable
ufw status verbose

# ---- /tmp hardening ----------------------------------------------------------
if [[ "$HARDEN_TMP" == "yes" ]]; then
  echo "Securing /tmp..."
  if mountpoint -q /tmp; then
    echo "/tmp is already a separate mount; review its options manually: $(findmnt -no OPTIONS /tmp)"
  else
    if ! grep -qE '^[^#]*[[:space:]]/tmp[[:space:]]' /etc/fstab; then
      echo "tmpfs /tmp tmpfs defaults,nosuid,noexec,nodev,mode=1777,size=${TMP_SIZE} 0 0" >> /etc/fstab
    fi
    systemctl daemon-reload
    mount /tmp
    chmod 1777 /tmp
    echo "/tmp mounted as tmpfs (noexec,nosuid,nodev)."
  fi

  if [[ "$LINK_VAR_TMP" == "yes" && ! -L /var/tmp ]]; then
    mv /var/tmp /var/tmp.old
    ln -s /tmp /var/tmp
    cp -a /var/tmp.old/. /tmp/ 2>/dev/null || true
    rm -rf /var/tmp.old
    echo "/var/tmp now links to /tmp."
  fi
fi

# ---- Unattended upgrades -----------------------------------------------------
if [[ -f "$SCRIPT_DIR/configure-unattended-upgrades.sh" ]]; then
  bash "$SCRIPT_DIR/configure-unattended-upgrades.sh"
else
  echo "configure-unattended-upgrades.sh not found; enabling defaults only."
  apt-get install -y unattended-upgrades
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades
fi

# ---- Tools -------------------------------------------------------------------
if [[ -n "$EXTRA_PACKAGES" ]]; then
  # shellcheck disable=SC2086
  apt-get install -y $EXTRA_PACKAGES
fi
if [[ "$INSTALL_FILEBEAT" == "yes" ]]; then
  apt-get install -y filebeat
  systemctl enable --now filebeat
fi

apt-get autoremove -y

# ---- Summary -----------------------------------------------------------------
cat <<'EOF'

=== Hardening complete ===
Review manually:
  - Network config (/etc/netplan/*.yaml or /etc/network/interfaces)
  - TLS certificates, if applicable
  - Disk partitioning / mounts
  - Filebeat output config (/etc/filebeat/filebeat.yml), if installed
  - Firewall rules: ufw status verbose
EOF

if [[ "$ASSUME_YES" != "yes" && -t 0 ]]; then
  read -rp "Reboot now? (y/N): " REBOOT_CHOICE || true
  if [[ "${REBOOT_CHOICE,,}" == "y" ]]; then
    reboot
  fi
fi
echo "Remember to reboot to apply all changes."
