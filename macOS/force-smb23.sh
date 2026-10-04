#!/bin/bash
#
# force-smb23.sh - Disable SMB1 on macOS clients (SMB2/SMB3 only)
#
# Sets protocol_vers_map=6 in the [default] section of /etc/nsmb.conf,
# preserving any other existing settings. A timestamped backup of the
# existing file is made first.
#
# Usage:
#   sudo ./force-smb23.sh
#
# Requirements: macOS, root privileges.
# After running, disconnect and reconnect any mounted SMB shares.

set -euo pipefail

NSMB_CONF="${NSMB_CONF:-/etc/nsmb.conf}"
BACKUP="${NSMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script with sudo or as root."
    exit 1
  fi
}

backup_if_exists() {
  if [[ -f "$NSMB_CONF" ]]; then
    cp "$NSMB_CONF" "$BACKUP"
    echo "Backed up existing config to: $BACKUP"
  fi
}

write_config() {
  if [[ -f "$NSMB_CONF" ]]; then
    awk '
      BEGIN { in_default=0; found_default=0; set_done=0 }

      /^\[default\][[:space:]]*$/ {
        found_default=1
        in_default=1
        print
        next
      }

      /^\[/ && $0 !~ /^\[default\][[:space:]]*$/ {
        if (in_default && !set_done) {
          print "protocol_vers_map=6"
          set_done=1
        }
        in_default=0
        print
        next
      }

      {
        if (in_default && $0 ~ /^protocol_vers_map[[:space:]]*=/) {
          if (!set_done) {
            print "protocol_vers_map=6"
            set_done=1
          }
          next
        }
        print
      }

      END {
        if (found_default) {
          if (in_default && !set_done) {
            print "protocol_vers_map=6"
          }
        } else {
          print "[default]"
          print "protocol_vers_map=6"
        }
      }
    ' "$NSMB_CONF" > "$TMP"
  else
    cat > "$TMP" <<'EOF'
[default]
protocol_vers_map=6
EOF
  fi

  install -m 644 "$TMP" "$NSMB_CONF"
  rm -f "$TMP"
}

show_result() {
  echo
  echo "Updated $NSMB_CONF:"
  grep -A 5 -n '^\[default\]$' "$NSMB_CONF" || true
  echo
  echo "Done."
  echo "Disconnect and reconnect any mounted SMB shares for the change to take effect."
  echo "This sets protocol_vers_map=6, which disables SMB1 and leaves SMB2/SMB3 available."
}

require_root
backup_if_exists
write_config
show_result
