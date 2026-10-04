#!/bin/zsh

# Privacy-conscious macOS diagnostic log collector.
# Creates a redacted ZIP without collecting document contents or browser history.

emulate -L zsh
setopt pipefail null_glob
umask 077

SCRIPT_VERSION="1.0.0"
MINUTES=30
PROCESS_NAME=""
OUTPUT_DIR="$PWD"
INCLUDE_CRASH_REPORTS=0

usage() {
  cat <<'EOF'
Usage: log-collector.zsh [options]

  --minutes N              Collect error/fault logs from the last N minutes
                           (default: 30; maximum: 1440).
  --process NAME           Limit unified logs to an exact process name.
  --include-crash-reports  Include up to 10 recent user crash reports.
  --output DIR             Destination directory for the ZIP (default: current).
  -h, --help               Show this help.

The collector redacts the home path, user/computer names, email addresses,
IP addresses, MAC addresses, UUIDs, and serial-number fields. Review the ZIP
before sharing it because application logs can still contain sensitive text.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --minutes)
      shift
      [[ $# -gt 0 ]] || { print -u2 "Missing value for --minutes"; exit 64; }
      MINUTES="$1"
      ;;
    --process)
      shift
      [[ $# -gt 0 ]] || { print -u2 "Missing value for --process"; exit 64; }
      PROCESS_NAME="$1"
      ;;
    --include-crash-reports) INCLUDE_CRASH_REPORTS=1 ;;
    --output)
      shift
      [[ $# -gt 0 ]] || { print -u2 "Missing value for --output"; exit 64; }
      OUTPUT_DIR="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage >&2; exit 64 ;;
  esac
  shift
done

if [[ "$MINUTES" != <-> ]] || (( MINUTES < 1 || MINUTES > 1440 )); then
  print -u2 "--minutes must be a whole number from 1 to 1440"
  exit 64
fi

if [[ -n "$PROCESS_NAME" && ! "$PROCESS_NAME" =~ '^[A-Za-z0-9 ._+-]+$' ]]; then
  print -u2 "--process contains unsupported characters"
  exit 64
fi

mkdir -p -- "$OUTPUT_DIR" || { print -u2 "Cannot create output directory: $OUTPUT_DIR"; exit 73; }
OUTPUT_DIR="${OUTPUT_DIR:A}"

# Fall back to /tmp when TMPDIR is unset (e.g. under some MDM/launchd contexts).
tmp_base="${${TMPDIR:-/tmp}%/}"
temp_root=$(mktemp -d "${tmp_base}/mac-log-collector.XXXXXX") || exit 70
bundle_dir="$temp_root/mac-log-bundle"
raw_dir="$temp_root/raw"
mkdir -p -- "$bundle_dir" "$raw_dir"

cleanup() {
  [[ -n "$temp_root" && "$temp_root" == "${tmp_base}/mac-log-collector."* ]] && rm -rf -- "$temp_root"
}
trap cleanup EXIT INT TERM HUP

console_user=$(stat -f '%Su' /dev/console 2>/dev/null)
computer_name=$(scutil --get ComputerName 2>/dev/null)
local_hostname=$(scutil --get LocalHostName 2>/dev/null)

redact_stream() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$HOME" ]] && line=${line//$HOME/<HOME>}
    [[ -n "$console_user" && "$console_user" != "root" ]] && line=${line//$console_user/<USER>}
    [[ -n "$computer_name" ]] && line=${line//$computer_name/<COMPUTER>}
    [[ -n "$local_hostname" ]] && line=${line//$local_hostname/<HOSTNAME>}
    print -r -- "$line"
  done | sed -E \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<EMAIL>/g' \
    -e 's/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/<MAC>/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<IPV4>/g' \
    -e 's/([[:xdigit:]]{1,4}:){3,7}[[:xdigit:]]{0,4}/<IPV6>/g' \
    -e 's/([[:xdigit:]]{1,4}:){1,7}:[[:xdigit:]]{0,4}/<IPV6>/g' \
    -e 's/(^|[^[:xdigit:]:])::[[:xdigit:]]+/\1<IPV6>/g' \
    -e 's/[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}/<UUID>/g' \
    -e 's/(Serial Number[^:]*:)[[:space:]]*[^[:space:]]+/\1 <SERIAL>/Ig'
}

capture() {
  local filename="$1"
  shift
  {
    print "Command: ${(q-)@}"
    print "---"
    "$@"
  } > "$raw_dir/$filename" 2>&1
  redact_stream < "$raw_dir/$filename" > "$bundle_dir/$filename"
  rm -f -- "$raw_dir/$filename"
}

print "Collecting macOS diagnostics..."

capture "os.txt" sw_vers
capture "uptime.txt" uptime
capture "storage.txt" df -h /
capture "memory.txt" memory_pressure -Q
capture "virtual-memory.txt" vm_stat
capture "power.txt" pmset -g batt
capture "filevault.txt" fdesetup status
capture "firewall.txt" /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
capture "gatekeeper.txt" spctl --status
capture "system-integrity.txt" csrutil status
capture "management.txt" profiles status -type enrollment
capture "update-schedule.txt" softwareupdate --schedule
capture "network-state.txt" scutil --nwi
capture "dns.txt" scutil --dns
capture "system-extensions.txt" systemextensionsctl list

predicate='eventType == logEvent AND (messageType == error OR messageType == fault)'
if [[ -n "$PROCESS_NAME" ]]; then
  predicate+=" AND process == \"$PROCESS_NAME\""
fi

print "Collecting ${MINUTES} minute(s) of error and fault logs..."
{
  print "Predicate: $predicate"
  print "---"
  /usr/bin/log show --last "${MINUTES}m" --style compact --predicate "$predicate"
} > "$raw_dir/unified-errors.txt" 2>&1
redact_stream < "$raw_dir/unified-errors.txt" > "$bundle_dir/unified-errors.txt"
rm -f -- "$raw_dir/unified-errors.txt"

crash_count=0
if (( INCLUDE_CRASH_REPORTS )); then
  mkdir -p -- "$bundle_dir/crash-reports"
  typeset -a crash_files
  crash_files=(
    "$HOME/Library/Logs/DiagnosticReports"/*.crash(N.om[1,10])
    "$HOME/Library/Logs/DiagnosticReports"/*.ips(N.om[1,10])
  )
  for crash_file in $crash_files; do
    (( crash_count >= 10 )) && break
    if [[ -n "$PROCESS_NAME" && "${crash_file:t:l}" != *"${PROCESS_NAME:l}"* ]]; then
      continue
    fi
    redact_stream < "$crash_file" > "$bundle_dir/crash-reports/report-$(( crash_count + 1 )).txt"
    (( crash_count++ ))
  done
fi

cat > "$raw_dir/manifest.txt" <<EOF
macOS diagnostic bundle
Collector version: ${SCRIPT_VERSION}
Created: $(date '+%Y-%m-%d %H:%M:%S %Z')
Unified log window: ${MINUTES} minute(s)
Process filter: ${PROCESS_NAME:-none}
Crash reports included: ${crash_count}

Default redactions:
- Home directory and console username
- Computer name and local hostname
- Email, IP, and MAC addresses
- UUIDs and serial-number fields

Not collected:
- Document contents
- Browser history or cookies
- Keychain contents
- Messages or email stores
- Full sysdiagnose

Review every file before sharing. Application-generated messages can contain
sensitive values that do not match an automatic redaction pattern.
EOF
redact_stream < "$raw_dir/manifest.txt" > "$bundle_dir/README.txt"
rm -f -- "$raw_dir/manifest.txt"

timestamp=$(date '+%Y%m%d-%H%M%S')
archive="$OUTPUT_DIR/mac-log-bundle-${timestamp}.zip"
if (cd "$temp_root" && /usr/bin/zip -qry "$archive" "${bundle_dir:t}"); then
  print "Created: $archive"
  print "Review the archive before sending it to another person or service."
else
  print -u2 "Unable to create diagnostic archive"
  exit 74
fi
