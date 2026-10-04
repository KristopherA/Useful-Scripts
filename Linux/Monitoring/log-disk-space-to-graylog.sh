#!/usr/bin/env bash
#
# log-disk-space-to-graylog.sh - send per-filesystem disk usage to Graylog as
# GELF messages (one message per real filesystem) over a TLS-wrapped GELF TCP
# input. Suitable for running from cron, e.g. hourly.
#
# Usage:
#   GRAYLOG_HOST=graylog.example.com ./log-disk-space-to-graylog.sh
#
# Requirements: bash 4+, coreutils df, jq, openssl.
#   sudo apt install jq
#   The Graylog GELF TCP input must have TLS enabled and use the null-byte
#   delimiter (use_null_delimiter: true - Graylog's recommended default).
#
# Each message carries _is_disk_report=true plus _file_system, _file_system_type,
# _disk_size, _used, _available, _percentage_used and _mount_point fields so you
# can build dashboards/alerts on them.

# ── Configuration (override via environment) ────────────────────────────────
# Becomes the 'source' field in Graylog (called 'host' in the GELF format).
SOURCE_HOST="${SOURCE_HOST:-$(hostname -f 2>/dev/null || hostname)}"
# Graylog server and GELF TCP (TLS) input port.
GRAYLOG_HOST="${GRAYLOG_HOST:-graylog.example.com}"
GRAYLOG_PORT="${GRAYLOG_PORT:-12201}"
# GELF/syslog severity level for the messages (6 = informational).
GELF_LEVEL="${GELF_LEVEL:-6}"
# ────────────────────────────────────────────────────────────────────────────

command -v jq >/dev/null 2>&1 || { echo "jq is required (sudo apt install jq)" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

# The standard df output includes many pseudo filesystems:
#
# Filesystem      Size  Used Avail Use% Mounted on
# udev             63G     0   63G   0% /dev
# tmpfs            13G  5.7M   13G   1% /run
# /dev/sda2       224G  168G   46G  79% /
# tmpfs            63G     0   63G   0% /dev/shm
# /dev/sdb1       3.6T  1.9G  3.4T   1% /srv/data
# /dev/loop2       71M   71M     0 100% /snap/lxd/16926
# /dev/sda1       511M  5.3M  506M   2% /boot/efi
#
# So we exclude temp filesystems, mounted snaps, overlays and the EFI partition.
# -h - human readable values.
# -T - filesystem type, ext4, tmpfs, etc...
# -x - exclude from the output this filesystem type.
# df -h -T -x devtmpfs -x tmpfs -x squashfs -x vfat -x overlay
# Filesystem     Type  Size  Used Avail Use% Mounted on
# /dev/sda2      ext4  224G  168G   46G  79% /
# /dev/sdb1      ext4  3.6T  1.9G  3.4T   1% /srv/data

# GELF message format: https://go2docs.graylog.org/current/getting_in_log_data/gelf.html
# Syslog levels used by GELF:
# Number  Severity       Keyword   Description
#   0     Emergency      emerg     System is unusable.
#   1     Alert          alert     Should be corrected immediately.
#   2     Critical       crit      Critical conditions.
#   3     Error          err       Error conditions.
#   4     Warning        warning   May indicate that an error will occur if action is not taken.
#   5     Notice         notice    Events that are unusual, but not error conditions.
#   6     Informational  info      Normal operational messages that require no action.
#   7     Debug          debug     Information useful to developers for debugging.

# Put the df output lines into an array.
readarray -t df_output <<<"$(df -h -T -x devtmpfs -x tmpfs -x squashfs -x vfat -x overlay)"
for output_line in "${df_output[@]}"; do
  # Word-split the line into an array (mount points containing spaces are not supported).
  # /dev/sda2  ext4  224G  168G   46G  79% /
  # shellcheck disable=SC2206
  line_array=($output_line)
  file_system="${line_array[0]:-}"
  file_system_type="${line_array[1]:-}"
  disk_size="${line_array[2]:-}"
  used="${line_array[3]:-}"
  available="${line_array[4]:-}"
  percentage_used="${line_array[5]:-}"
  mount_point="${line_array[6]:-}"
  # Skip the header (and any blank line).
  if [[ -n "$file_system" && "$file_system" != "Filesystem" ]]; then
    # jq validates and produces clean JSON, avoiding quoting mistakes.
    # -n - use `null` as the single input value; -c - compact, single-line output.
    gelf_message=$(
      jq -nc \
        --arg host "$SOURCE_HOST" \
        --arg short_message "$output_line" \
        --arg file_system "$file_system" \
        --arg file_system_type "$file_system_type" \
        --arg disk_size "$disk_size" \
        --arg used "$used" \
        --arg available "$available" \
        --arg percentage_used "$percentage_used" \
        --arg mount_point "$mount_point" \
        --arg level "$GELF_LEVEL" \
        '{ "version": "1.1", "_is_disk_report":"true", "host": $host, "short_message": $short_message, "level": $level , "_file_system": $file_system, "_file_system_type":$file_system_type, "_disk_size":$disk_size, "_used":$used, "_available":$available, "_percentage_used":$percentage_used, "_mount_point":$mount_point }'
    )
    # Terminate each message with a NUL byte for the GELF TCP null delimiter.
    # (fixed: was `echo -n -e $gelf_message"\0"` - unquoted and with -e, which
    #  could alter the JSON via word splitting/backslash interpretation)
    printf '%s\0' "$gelf_message" | openssl s_client -connect "${GRAYLOG_HOST}:${GRAYLOG_PORT}" &>/dev/null
  fi
done
