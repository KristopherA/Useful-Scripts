#!/bin/bash
# apt-repos.sh - Add third-party APT repositories using signed-by keyrings.
#
# Adds the Elastic (Elasticsearch/Filebeat/etc.) and Docker CE repositories
# using the modern /etc/apt/keyrings + "signed-by=" pattern (no apt-key).
#
# Usage:
#   sudo ./apt-repos.sh
#   sudo ENABLE_DOCKER=no ELASTIC_MAJOR=9 ./apt-repos.sh
#
# Requirements: root, curl, gpg (installed automatically if missing).
# Supported:    Ubuntu 20.04+ and Debian 11+ (amd64/arm64).

set -euo pipefail

# ---- Configuration (override via environment) ------------------------------
ENABLE_ELASTIC="${ENABLE_ELASTIC:-yes}"   # yes/no
ELASTIC_MAJOR="${ELASTIC_MAJOR:-8}"       # Elastic major version (e.g. 8 or 9)
ENABLE_DOCKER="${ENABLE_DOCKER:-yes}"     # yes/no
KEYRING_DIR="/etc/apt/keyrings"
# -----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d "$KEYRING_DIR"

# shellcheck disable=SC1091
. /etc/os-release

if [[ "$ENABLE_ELASTIC" == "yes" ]]; then
  echo "Adding Elastic ${ELASTIC_MAJOR}.x repository..."
  curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
    | gpg --dearmor --yes -o "$KEYRING_DIR/elastic.gpg"
  chmod a+r "$KEYRING_DIR/elastic.gpg"
  echo "deb [signed-by=$KEYRING_DIR/elastic.gpg] https://artifacts.elastic.co/packages/${ELASTIC_MAJOR}.x/apt stable main" \
    > "/etc/apt/sources.list.d/elastic-${ELASTIC_MAJOR}.x.list"
  echo "Elastic repo added."
fi

if [[ "$ENABLE_DOCKER" == "yes" ]]; then
  case "${ID:-}" in
    ubuntu|debian) DOCKER_DISTRO="$ID" ;;
    *) echo "Docker repo: unsupported distro '${ID:-unknown}', skipping." >&2; DOCKER_DISTRO="" ;;
  esac
  if [[ -n "$DOCKER_DISTRO" ]]; then
    echo "Adding Docker repository..."
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
      -o "$KEYRING_DIR/docker.asc"
    chmod a+r "$KEYRING_DIR/docker.asc"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEYRING_DIR/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    echo "Docker repo added."
  fi
fi

apt-get update
echo "Done."
