#!/bin/bash
# install-graylog-sidecar.sh - Install and register Graylog Sidecar on Debian/Ubuntu.
#
# Installs the Graylog Sidecar repository package and graylog-sidecar, writes the
# server URL, API token, node name and a node ID into sidecar.yml, then enables the
# service. Optionally installs Filebeat (as a Sidecar collector) from the Elastic repo.
#
# Usage:
#   sudo GRAYLOG_SERVER_URL=https://graylog.example.com:9000/api/ ./install-graylog-sidecar.sh
#   sudo GRAYLOG_SERVER_URL=... GRAYLOG_API_TOKEN=... NODE_NAME=web01 INSTALL_FILEBEAT=yes ./install-graylog-sidecar.sh
#   (GRAYLOG_API_TOKEN is prompted for, hidden, if not set. Create it in Graylog under
#    System > Sidecars > Create or reuse a token for the graylog-sidecar user.)
#
# Requirements: root, curl, a reachable Graylog server with a Sidecar API token.
# Supported:    Debian / Ubuntu (systemd).

set -euo pipefail

# ---- Configuration (override via environment) ------------------------------
GRAYLOG_SERVER_URL="${GRAYLOG_SERVER_URL:-}"     # REQUIRED, e.g. https://graylog.example.com:9000/api/
GRAYLOG_API_TOKEN="${GRAYLOG_API_TOKEN:-}"       # prompted (hidden) if empty
NODE_NAME="${NODE_NAME:-$(hostname -f 2>/dev/null || hostname)}"
NODE_ID="${NODE_ID:-}"                           # empty = generate a random UUID
SIDECAR_REPO_DEB="${SIDECAR_REPO_DEB:-graylog-sidecar-repository_1-5_all.deb}"
SIDECAR_REPO_BASE="${SIDECAR_REPO_BASE:-https://packages.graylog2.org/repo/packages}"
SIDECAR_CONFIG="${SIDECAR_CONFIG:-/etc/graylog/sidecar/sidecar.yml}"
INSTALL_FILEBEAT="${INSTALL_FILEBEAT:-no}"       # yes = also install Filebeat
ELASTIC_MAJOR="${ELASTIC_MAJOR:-8}"
# -----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if [[ -z "$GRAYLOG_SERVER_URL" ]]; then
  echo "Error: GRAYLOG_SERVER_URL is required (e.g. https://graylog.example.com:9000/api/)." >&2
  exit 1
fi

if [[ -z "$GRAYLOG_API_TOKEN" ]]; then
  read -rsp "Graylog Sidecar API token: " GRAYLOG_API_TOKEN; echo
  [[ -n "$GRAYLOG_API_TOKEN" ]] || { echo "Error: API token is required." >&2; exit 1; }
fi

if [[ -z "$NODE_ID" ]]; then
  NODE_ID="$(cat /proc/sys/kernel/random/uuid)"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg

# ---- Optional: Filebeat ------------------------------------------------------
if [[ "$INSTALL_FILEBEAT" == "yes" ]]; then
  echo "Installing Filebeat ${ELASTIC_MAJOR}.x..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --dearmor --yes -o /etc/apt/keyrings/elastic.gpg
  chmod a+r /etc/apt/keyrings/elastic.gpg
  echo "deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/${ELASTIC_MAJOR}.x/apt stable main" \
    > "/etc/apt/sources.list.d/elastic-${ELASTIC_MAJOR}.x.list"
  apt-get update
  apt-get install -y filebeat
  # Sidecar manages Filebeat itself; the standalone service is not needed.
  systemctl disable --now filebeat 2>/dev/null || true
fi

# ---- Graylog Sidecar ---------------------------------------------------------
TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

echo "Downloading $SIDECAR_REPO_DEB..."
curl -fsSL "$SIDECAR_REPO_BASE/$SIDECAR_REPO_DEB" -o "$TMPDIR_DL/$SIDECAR_REPO_DEB"
dpkg -i "$TMPDIR_DL/$SIDECAR_REPO_DEB"
apt-get update
apt-get install -y graylog-sidecar

[[ -f "$SIDECAR_CONFIG" ]] || { echo "Error: $SIDECAR_CONFIG not found." >&2; exit 1; }
cp -a "$SIDECAR_CONFIG" "$SIDECAR_CONFIG.bak.$(date +%Y%m%d%H%M%S)"

# Escape replacement-string specials (\, &, |) for sed
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

set_key() { # set_key key value  - replaces "key:" or "#key:" line, appends if absent
  local key="$1" val
  val="$(sed_escape "$2")"
  if grep -qE "^[#[:space:]]*${key}:" "$SIDECAR_CONFIG"; then
    sed -i -E "0,/^[#[:space:]]*${key}:.*/s||${key}: \"${val}\"|" "$SIDECAR_CONFIG"
  else
    printf '%s: "%s"\n' "$key" "$2" >> "$SIDECAR_CONFIG"
  fi
  echo "Set $key"
}

set_key server_url "$GRAYLOG_SERVER_URL"
set_key server_api_token "$GRAYLOG_API_TOKEN"
set_key node_id "$NODE_ID"
set_key node_name "$NODE_NAME"
chmod 600 "$SIDECAR_CONFIG"

echo "Enabling and starting graylog-sidecar..."
graylog-sidecar -service install 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now graylog-sidecar
systemctl --no-pager status graylog-sidecar || true
echo "Graylog Sidecar installed. Node name: $NODE_NAME  Node ID: $NODE_ID"
