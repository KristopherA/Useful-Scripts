#!/bin/bash
# install-docker.sh - Install Docker Engine + Compose plugin from Docker's official APT repo.
#
# Usage:
#   sudo ./install-docker.sh
#   sudo DOCKER_USER=alice ./install-docker.sh    # also add a user to the docker group
#
# Requirements: root, internet access to download.docker.com.
# Supported:    Ubuntu and Debian (amd64/arm64).

set -euo pipefail

# ---- Configuration (override via environment) ------------------------------
DOCKER_USER="${DOCKER_USER:-}"        # optional user to add to the 'docker' group
RUN_HELLO_WORLD="${RUN_HELLO_WORLD:-yes}"
# -----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) DISTRO="$ID" ;;
  *) echo "Unsupported distro: ${ID:-unknown} (Ubuntu/Debian only)." >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive

# Add Docker's official GPG key
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository (deb822 format)
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DISTRO}
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Remove a legacy one-line docker.list if present to avoid duplicate-source warnings
rm -f /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

if [[ -n "$DOCKER_USER" ]]; then
  usermod -aG docker "$DOCKER_USER"
  echo "Added $DOCKER_USER to the docker group (log out/in to take effect)."
fi

if [[ "$RUN_HELLO_WORLD" == "yes" ]]; then
  docker run --rm hello-world
fi

docker --version
docker compose version
echo "Docker installation complete."
