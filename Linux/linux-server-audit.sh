#!/bin/bash
#
# linux-server-audit.sh — Linux Server Security Audit
#
# Comprehensive audit for Ubuntu 20.04 / 22.04 / 24.04 (Debian-compatible).
# Covers system info, user security, SSH, firewall, network exposure,
# pending updates, running services, filesystem security, kernel hardening,
# logging/monitoring, and scheduled tasks.
#
# Must be run as root for full coverage.
#
# Usage:
#   sudo ./linux-server-audit.sh
#   sudo ./linux-server-audit.sh --no-suid    # skip SUID scan (faster)
#   sudo ./linux-server-audit.sh --json       # also write JSON summary
#
# Report saved to: ${REPORT_DIR}/${REPORT_PREFIX}-<hostname>-<date>.txt
#   (default: /var/log/server-audit-<hostname>-<date>.txt)
#
# Requirements: bash 4+, GNU coreutils, systemd, iproute2 (ss/ip).
#   Optional: ufw/iptables/nft, fail2ban, auditd, debsums, docker.

set -uo pipefail

# ── Configuration (override via environment) ──────────────────────────
REPORT_DIR="${REPORT_DIR:-/var/log}"            # where report files are written
REPORT_PREFIX="${REPORT_PREFIX:-server-audit}"  # report file name prefix
LOG_SHIPPER_SERVICE="${LOG_SHIPPER_SERVICE:-filebeat}"  # systemd unit that ships logs off-host

# ── CLI flags ─────────────────────────────────────────────────────────
SKIP_SUID=false
WRITE_JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-suid) SKIP_SUID=true ;;
    --json)    WRITE_JSON=true ;;
    *) ;;
  esac
  shift
done

[[ "${EUID}" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

# ── Report setup ──────────────────────────────────────────────────────
HOSTNAME_S=$(hostname -s)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="${REPORT_DIR}/${REPORT_PREFIX}-${HOSTNAME_S}-${TIMESTAMP}.txt"
JSON_FILE="${REPORT_DIR}/${REPORT_PREFIX}-${HOSTNAME_S}-${TIMESTAMP}.json"

# ── Colours ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ── Counters ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0; INFO_N=0

# ── Output helpers ────────────────────────────────────────────────────
_log()    { echo -e "$1" | tee -a "$REPORT_FILE"; }
pass()    { _log "${GREEN}  ✓ PASS${RESET}  $*"; PASS=$(( PASS + 1 )); }
fail()    { _log "${RED}  ✗ FAIL${RESET}  $*"; FAIL=$(( FAIL + 1 )); }
warn()    { _log "${YELLOW}  ⚠ WARN${RESET}  $*"; WARN=$(( WARN + 1 )); }
info()    { _log "${CYAN}  ℹ INFO${RESET}  $*"; INFO_N=$(( INFO_N + 1 )); }
detail()  { _log "     ${DIM}$*${RESET}"; }
section() { _log ""; _log "${BOLD}── $1${RESET}"; }

# Safe command wrapper — returns empty string if command not found
run() { command -v "$1" &>/dev/null && "$@" 2>/dev/null || echo ""; }

sysctl_val() { sysctl -n "$1" 2>/dev/null || echo ""; }

# ── Header ────────────────────────────────────────────────────────────
{
  echo "════════════════════════════════════════════════════════"
  echo "  Linux Server Security Audit"
  echo "  Host:    $(hostname -f 2>/dev/null || hostname)"
  echo "  OS:      $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
  echo "  Kernel:  $(uname -r)"
  echo "  Date:    $(date)"
  echo "  Report:  ${REPORT_FILE}"
  echo "════════════════════════════════════════════════════════"
} | tee "$REPORT_FILE"

# ══════════════════════════════════════════════════════════════════════
# 1. SYSTEM INFORMATION
# ══════════════════════════════════════════════════════════════════════
section "1. System Information"

# Uptime
UPTIME=$(uptime -p 2>/dev/null || uptime)
info "Uptime: ${UPTIME}"

# CPU
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo)
info "CPU: ${CPU_MODEL} (${CPU_CORES} cores)"

# Load average
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
LOAD_1=$(echo "$LOAD" | awk '{print $1}')
LOAD_WARN=$(awk "BEGIN {print ($LOAD_1 > $CPU_CORES * 2) ? 1 : 0}")
if [[ "$LOAD_WARN" -eq 1 ]]; then
  warn "Load average: ${LOAD}  (${CPU_CORES} cores — high load)"
else
  info "Load average: ${LOAD}"
fi

# RAM
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
RAM_USED_PCT=$(awk "BEGIN {printf \"%d\", (1-$RAM_AVAIL_KB/$RAM_TOTAL_KB)*100}")
RAM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $RAM_TOTAL_KB/1024/1024}")
info "RAM: ${RAM_TOTAL_GB} GB total — ${RAM_USED_PCT}% in use"

# Swap
SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE_KB=$(grep SwapFree /proc/meminfo | awk '{print $2}')
if [[ "$SWAP_TOTAL_KB" -gt 0 ]]; then
  SWAP_USED_PCT=$(awk "BEGIN {printf \"%d\", (1-$SWAP_FREE_KB/$SWAP_TOTAL_KB)*100}")
  [[ "$SWAP_USED_PCT" -gt 50 ]] \
    && warn "Swap: ${SWAP_USED_PCT}% used — memory pressure may be occurring" \
    || info "Swap: ${SWAP_USED_PCT}% used"
else
  info "Swap: none configured"
fi

# ══════════════════════════════════════════════════════════════════════
# 2. DISK
# ══════════════════════════════════════════════════════════════════════
section "2. Disk Usage"

while IFS= read -r line; do
  PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
  MOUNT=$(echo "$line" | awk '{print $6}')
  if   [[ "${PCT:-0}" -ge 95 ]]; then fail "Disk ${MOUNT}: ${PCT}% full — critically low"
  elif [[ "${PCT:-0}" -ge 85 ]]; then warn "Disk ${MOUNT}: ${PCT}% full"
  else                                 pass "Disk ${MOUNT}: ${PCT}% used  ($(echo "$line" | awk '{print $4}') free)"
  fi
done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
  | grep -vE "^Filesystem|tmpfs|udev|overlay|shm" | grep "^/")

# Inode usage
while IFS= read -r line; do
  PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
  MOUNT=$(echo "$line" | awk '{print $6}')
  [[ "${PCT:-0}" -ge 90 ]] && warn "Inodes ${MOUNT}: ${PCT}% — filesystem may fill before disk"
done < <(df -i 2>/dev/null | grep -vE "^Filesystem|tmpfs|udev" | grep "^/" || true)

# /tmp mount options
TMP_OPTS=$(findmnt -n -o OPTIONS /tmp 2>/dev/null || grep " /tmp " /proc/mounts | awk '{print $4}')
if echo "$TMP_OPTS" | grep -q "noexec"; then
  pass "/tmp mounted noexec"
else
  warn "/tmp is NOT mounted noexec — executables can run from /tmp"
fi
if echo "$TMP_OPTS" | grep -q "nosuid"; then
  pass "/tmp mounted nosuid"
else
  warn "/tmp is NOT mounted nosuid"
fi

# ══════════════════════════════════════════════════════════════════════
# 3. USER & ACCOUNT SECURITY
# ══════════════════════════════════════════════════════════════════════
section "3. User & Account Security"

# UIDs 0 (should only be root)
UID0_USERS=$(awk -F: '$3==0 {print $1}' /etc/passwd | tr '\n' ' ')
if [[ "$UID0_USERS" == "root " ]] || [[ "$UID0_USERS" == "root" ]]; then
  pass "UID 0: only root"
else
  fail "Multiple UID 0 accounts: ${UID0_USERS}"
fi

# Users with empty passwords
EMPTY_PASS=$(awk -F: '($2=="" || $2=="!!" || $2=="!") && $1!~/^[+\-]/ {print $1}' \
             /etc/shadow 2>/dev/null | tr '\n' ' ')
# Also check via passwd
EMPTY_PASS2=$(awk -F: '$2=="" {print $1}' /etc/passwd 2>/dev/null | tr '\n' ' ')
COMBINED_EMPTY=$(echo "$EMPTY_PASS $EMPTY_PASS2" | xargs)
if [[ -n "$COMBINED_EMPTY" ]]; then
  fail "Accounts with empty/blank password: ${COMBINED_EMPTY}"
else
  pass "No accounts with empty passwords"
fi

# Accounts not locked but with no recent login (> 90 days, interactive shell)
STALE_USERS=""
while IFS=: read -r uname _ uid _ _ home shell; do
  [[ "$uid" -lt 1000 ]] && continue
  [[ "$shell" =~ nologin|false|sync ]] && continue
  # (fixed: previously grepped selected awk fields, so "Never logged in" never matched)
  LAST=$(lastlog -u "$uname" 2>/dev/null | tail -1)
  if echo "$LAST" | grep -q "Never logged in"; then
    STALE_USERS="${STALE_USERS} ${uname}(never)"
  fi
done < /etc/passwd
[[ -n "$STALE_USERS" ]] \
  && warn "Accounts that have never logged in:${STALE_USERS}" \
  || pass "No stale never-logged-in accounts found"

# Sudo / admin users
SUDO_USERS=$(getent group sudo 2>/dev/null | cut -d: -f4)
WHEEL_USERS=$(getent group wheel 2>/dev/null | cut -d: -f4)
ADMIN_USERS=$(getent group admin 2>/dev/null | cut -d: -f4)
ALL_ADMINS=$(echo "$SUDO_USERS $WHEEL_USERS $ADMIN_USERS" | tr ',' ' ' | tr ' ' '\n' \
             | sort -u | grep -v '^$' | tr '\n' ' ')
info "Sudo/admin users: ${ALL_ADMINS:-none}"

# Root login shell
ROOT_SHELL=$(getent passwd root | cut -d: -f7)
[[ "$ROOT_SHELL" == "/bin/bash" ]] || [[ "$ROOT_SHELL" == "/bin/sh" ]] \
  && info "Root shell: ${ROOT_SHELL} (normal)" \
  || info "Root shell: ${ROOT_SHELL}"

# Password aging for privileged accounts
PASS_AGE_ISSUES=""
while IFS= read -r auser; do
  auser=$(echo "$auser" | xargs)
  [[ -z "$auser" ]] && continue
  MAX_AGE=$(chage -l "$auser" 2>/dev/null | grep "Maximum" | awk -F: '{print $2}' | xargs)
  if [[ "$MAX_AGE" == "never" ]] || [[ "${MAX_AGE:-0}" -gt 365 ]]; then
    PASS_AGE_ISSUES="${PASS_AGE_ISSUES} ${auser}(no expiry)"
  fi
done < <(echo "$ALL_ADMINS" | tr ' ' '\n')
[[ -n "$PASS_AGE_ISSUES" ]] \
  && warn "Admin accounts with no password expiry:${PASS_AGE_ISSUES}" \
  || pass "Admin account password policies look configured"

# Last logins
_log ""
_log "  ${DIM}Recent logins:${RESET}"
last -n 8 2>/dev/null | head -8 | while IFS= read -r line; do detail "$line"; done

# ══════════════════════════════════════════════════════════════════════
# 4. SSH CONFIGURATION
# ══════════════════════════════════════════════════════════════════════
section "4. SSH Configuration"

SSHD_CONF="/etc/ssh/sshd_config"
if [[ ! -f "$SSHD_CONF" ]]; then
  info "sshd_config not found — SSH may not be installed"
else
  # Helper: read effective sshd value (handles Include directives)
  ssh_val() {
    local key="$1"
    sshd -T 2>/dev/null | grep -i "^${key} " | awk '{print $2}' | head -1
  }

  ROOT_LOGIN=$(ssh_val PermitRootLogin)
  case "${ROOT_LOGIN,,}" in
    no)                  pass  "PermitRootLogin: no" ;;
    prohibit-password)   warn  "PermitRootLogin: prohibit-password — key-only root; consider 'no'" ;;
    forced-commands-only)info  "PermitRootLogin: forced-commands-only" ;;
    *)                   fail  "PermitRootLogin: ${ROOT_LOGIN:-not set} — should be 'no'" ;;
  esac

  PASS_AUTH=$(ssh_val PasswordAuthentication)
  case "${PASS_AUTH,,}" in
    no)   pass  "PasswordAuthentication: no (key-only)" ;;
    yes)  warn  "PasswordAuthentication: yes — consider key-only auth" ;;
    *)    warn  "PasswordAuthentication: ${PASS_AUTH:-not set}" ;;
  esac

  PK_AUTH=$(ssh_val PubkeyAuthentication)
  [[ "${PK_AUTH,,}" == "yes" ]] \
    && pass "PubkeyAuthentication: yes" \
    || warn "PubkeyAuthentication: ${PK_AUTH:-not set}"

  MAX_AUTH=$(ssh_val MaxAuthTries)
  MAX_AUTH="${MAX_AUTH:-6}"
  [[ "$MAX_AUTH" -le 4 ]] \
    && pass "MaxAuthTries: ${MAX_AUTH}" \
    || warn "MaxAuthTries: ${MAX_AUTH} — recommend ≤ 4"

  MAX_SESS=$(ssh_val MaxSessions)
  info "MaxSessions: ${MAX_SESS:-default(10)}"

  ALLOW_USERS=$(ssh_val AllowUsers)
  ALLOW_GROUPS=$(ssh_val AllowGroups)
  if [[ -n "$ALLOW_USERS" ]] || [[ -n "$ALLOW_GROUPS" ]]; then
    pass "SSH access restricted: AllowUsers=${ALLOW_USERS:-not set}  AllowGroups=${ALLOW_GROUPS:-not set}"
  else
    warn "No AllowUsers/AllowGroups — all local accounts can attempt SSH"
  fi

  IDLE_TIMEOUT=$(ssh_val ClientAliveInterval)
  IDLE_COUNT=$(ssh_val ClientAliveCountMax)
  if [[ "${IDLE_TIMEOUT:-0}" -gt 0 ]]; then
    TIMEOUT_MIN=$(( IDLE_TIMEOUT * ${IDLE_COUNT:-3} / 60 ))
    pass "SSH idle timeout: ${IDLE_TIMEOUT}s × ${IDLE_COUNT:-3} = ~${TIMEOUT_MIN} min"
  else
    warn "No SSH idle timeout configured (ClientAliveInterval not set)"
  fi

  X11=$(ssh_val X11Forwarding)
  [[ "${X11,,}" == "no" ]] \
    && pass "X11 forwarding: disabled" \
    || warn "X11 forwarding: ${X11:-not set} — disable on servers"

  # Port
  SSH_PORT=$(ssh_val Port)
  SSH_PORT="${SSH_PORT:-22}"
  [[ "$SSH_PORT" -ne 22 ]] \
    && info "SSH port: ${SSH_PORT} (non-standard — security by obscurity, not a substitute for hardening)" \
    || info "SSH port: 22 (default)"

  # SSH service status
  if systemctl is-active ssh &>/dev/null || systemctl is-active sshd &>/dev/null; then
    info "SSH service: active"
  else
    info "SSH service: not running"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 5. FIREWALL
# ══════════════════════════════════════════════════════════════════════
section "5. Firewall"

if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1)
  if echo "$UFW_STATUS" | grep -qi "active"; then
    pass "UFW: active"
    # Show rules summary (non-verbose)
    ufw status 2>/dev/null | grep -v "^Status\|^$\|^To\|^--" \
      | head -20 | while IFS= read -r line; do detail "$line"; done
  else
    fail "UFW: inactive — run: ufw enable"
  fi

  # Default policies
  UFW_DEF_IN=$(ufw status verbose 2>/dev/null | awk '/Default:/ {print $2}')
  UFW_DEF_OUT=$(ufw status verbose 2>/dev/null | awk '/Default:/ {print $4}')
  [[ "${UFW_DEF_IN,,}" == "deny" ]] \
    && pass "UFW default inbound: deny" \
    || warn "UFW default inbound: ${UFW_DEF_IN:-unknown} — should be 'deny'"

elif command -v iptables &>/dev/null; then
  IPT_RULES=$(iptables -L INPUT --line-numbers 2>/dev/null | wc -l)
  if [[ "$IPT_RULES" -gt 3 ]]; then
    pass "iptables: rules present (${IPT_RULES} INPUT chain lines)"
    iptables -L INPUT -n --line-numbers 2>/dev/null | head -15 \
      | while IFS= read -r line; do detail "$line"; done
  else
    warn "iptables: minimal rules — INPUT chain appears mostly open"
  fi
else
  fail "No firewall tool found (ufw or iptables)"
fi

# nftables check
if command -v nft &>/dev/null; then
  NFT_RULES=$(nft list ruleset 2>/dev/null | grep -c "rule" || true)
  [[ "$NFT_RULES" -gt 0 ]] && info "nftables: ${NFT_RULES} rule(s) active"
fi

# ══════════════════════════════════════════════════════════════════════
# 6. NETWORK & LISTENING SERVICES
# ══════════════════════════════════════════════════════════════════════
section "6. Network & Listening Services"

# Interfaces
_log "  ${DIM}Interfaces:${RESET}"
ip -br addr 2>/dev/null | while IFS= read -r line; do detail "$line"; done

# Listening ports mapped to processes
_log ""
_log "  ${DIM}Listening ports:${RESET}"
if command -v ss &>/dev/null; then
  ss -tlnp 2>/dev/null | while IFS= read -r line; do detail "$line"; done
elif command -v netstat &>/dev/null; then
  netstat -tlnp 2>/dev/null | while IFS= read -r line; do detail "$line"; done
fi

# Count externally exposed ports (bound to 0.0.0.0 or ::)
EXTERNAL_PORTS=$(ss -tlnp 2>/dev/null \
  | awk '{print $4}' | grep -E "^(0\.0\.0\.0|\*|\[::\]|::):" \
  | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')
info "Externally bound ports: ${EXTERNAL_PORTS:-none}"

# Check for common unexpected services
UNEXPECTED=""
for SVC in telnet rsh rlogin ftp vsftpd proftpd apache2 nginx; do
  if systemctl is-active "$SVC" &>/dev/null; then
    UNEXPECTED="${UNEXPECTED} ${SVC}"
  fi
done
if [[ -n "$UNEXPECTED" ]]; then
  warn "Potentially unexpected services running:${UNEXPECTED}"
fi

# IPv4 forwarding (should be off unless this is a router/VPN)
IP_FWD=$(sysctl_val net.ipv4.ip_forward)
if [[ "$IP_FWD" == "1" ]]; then
  warn "IPv4 forwarding: enabled — expected only on routers/VPN gateways"
else
  pass "IPv4 forwarding: disabled"
fi

# Active connections summary
CONN_COUNT=$(ss -tnp 2>/dev/null | grep -c ESTAB || true)
info "Established connections: ${CONN_COUNT}"

# ══════════════════════════════════════════════════════════════════════
# 7. PACKAGE UPDATES
# ══════════════════════════════════════════════════════════════════════
section "7. Package Updates"

if command -v apt-get &>/dev/null; then
  # Refresh package index silently
  apt-get update -qq 2>/dev/null || warn "apt-get update failed — check network/repo config"

  # Pending updates
  TOTAL_UPDATES=$(apt-get -s upgrade 2>/dev/null | grep "^Inst" | wc -l | tr -d ' ')
  SECURITY_UPDATES=$(apt-get -s upgrade 2>/dev/null | grep "^Inst" \
                     | grep -ic "security" || true)

  if [[ "$SECURITY_UPDATES" -gt 0 ]]; then
    fail "Security updates pending: ${SECURITY_UPDATES}  (${TOTAL_UPDATES} total)"
    apt-get -s upgrade 2>/dev/null | grep "^Inst" | grep -i "security" | head -10 \
      | while IFS= read -r line; do detail "$line"; done
  elif [[ "$TOTAL_UPDATES" -gt 0 ]]; then
    warn "Non-security updates pending: ${TOTAL_UPDATES}"
  else
    pass "System fully up to date"
  fi

  # Last apt history
  LAST_UPDATE=$(stat -c %y /var/cache/apt/pkgcache.bin 2>/dev/null | cut -d' ' -f1)
  info "Last apt cache refresh: ${LAST_UPDATE:-unknown}"

  # Auto-upgrade config
  AUTO_UPG_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
  if [[ -f "$AUTO_UPG_FILE" ]]; then
    AUTO_UPG=$(grep "Unattended-Upgrade" "$AUTO_UPG_FILE" | grep '"1"' | wc -l)
    [[ "$AUTO_UPG" -ge 1 ]] \
      && pass "Unattended security upgrades: configured" \
      || warn "Unattended-Upgrade not set to '1' in ${AUTO_UPG_FILE}"
  else
    warn "${AUTO_UPG_FILE} not found — unattended-upgrades may not be configured"
  fi
else
  info "apt not found — skipping package update checks"
fi

# ══════════════════════════════════════════════════════════════════════
# 8. SERVICES
# ══════════════════════════════════════════════════════════════════════
section "8. Services"

# Failed units
FAILED_UNITS=$(systemctl list-units --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [[ -n "$FAILED_UNITS" ]]; then
  fail "Failed systemd units: ${FAILED_UNITS}"
else
  pass "No failed systemd units"
fi

# Key service checks
check_svc() {
  local svc="$1" label="$2" expected="$3"  # expected: active | inactive
  local status
  status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
  if [[ "$expected" == "active" ]]; then
    [[ "$status" == "active" ]] && pass "${label}: running" || warn "${label}: ${status}"
  else
    [[ "$status" == "active" ]] && warn "${label}: running (should it be?)" || pass "${label}: not active"
  fi
}

check_svc ssh         "SSH"                  active
check_svc sshd        "SSHd"                 active
check_svc ufw         "UFW firewall"         active
check_svc fail2ban    "Fail2Ban"             active
check_svc "$LOG_SHIPPER_SERVICE" "${LOG_SHIPPER_SERVICE} (log shipping)" active
check_svc cron        "Cron"                 active
check_svc rsyslog     "rsyslog"              active
check_svc postfix     "Postfix (mail)"       inactive
check_svc telnet      "Telnet"               inactive
check_svc rpcbind     "rpcbind/portmapper"   inactive

# Services with automatic restart disabled for key daemons
for SVC in ssh fail2ban; do
  if systemctl is-active "$SVC" &>/dev/null; then
    RESTART_POLICY=$(systemctl show "$SVC" -p Restart 2>/dev/null | cut -d= -f2)
    [[ "$RESTART_POLICY" != "always" ]] && [[ "$RESTART_POLICY" != "on-failure" ]] \
      && warn "${SVC}: restart policy is '${RESTART_POLICY}' — consider 'on-failure'"
  fi
done

# ══════════════════════════════════════════════════════════════════════
# 9. FAIL2BAN
# ══════════════════════════════════════════════════════════════════════
section "9. Fail2Ban"

if command -v fail2ban-client &>/dev/null && systemctl is-active fail2ban &>/dev/null; then
  pass "Fail2Ban: installed and running"

  # Show active jails
  JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | xargs)
  info "Jails: ${JAILS:-none}"

  # SSH jail stats
  if echo "$JAILS" | grep -q "sshd\|ssh"; then
    SSH_JAIL_NAME=$(echo "$JAILS" | tr ',' '\n' | grep -i "ssh" | head -1 | xargs)
    BANNED=$(fail2ban-client status "$SSH_JAIL_NAME" 2>/dev/null \
             | grep "Banned IP" | awk -F: '{print $2}' | xargs)
    TOTAL_BANNED=$(fail2ban-client status "$SSH_JAIL_NAME" 2>/dev/null \
                   | grep "Total banned" | awk -F: '{print $2}' | xargs)
    info "SSH jail '${SSH_JAIL_NAME}': ${TOTAL_BANNED:-0} total bans, currently ${BANNED:-0} IPs banned"
  else
    warn "No SSH jail active in Fail2Ban — add [sshd] jail to /etc/fail2ban/jail.local"
  fi
else
  fail "Fail2Ban: not running — install and configure for SSH brute-force protection"
fi

# Recent brute-force attempts (from auth log)
AUTH_LOG="/var/log/auth.log"
[[ -f /var/log/secure ]] && AUTH_LOG="/var/log/secure"

if [[ -f "$AUTH_LOG" ]]; then
  FAIL_COUNT=$(grep -c "Failed password" "$AUTH_LOG" 2>/dev/null || true)
  FAIL_RECENT=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | tail -5)
  if [[ "$FAIL_COUNT" -gt 100 ]]; then
    warn "Auth failures in ${AUTH_LOG}: ${FAIL_COUNT} total"
    echo "$FAIL_RECENT" | while IFS= read -r line; do detail "$line"; done
  else
    info "Auth failures in log: ${FAIL_COUNT}"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 10. KERNEL HARDENING (sysctl)
#     CIS Ubuntu Linux Benchmark
# ══════════════════════════════════════════════════════════════════════
section "10. Kernel Hardening (sysctl)"

check_sysctl() {
  local key="$1" expected="$2" label="$3"
  local val; val=$(sysctl_val "$key")
  if [[ "$val" == "$expected" ]]; then
    pass "${label}: ${val}"
  else
    fail "${label}: ${val:-not set} (expected ${expected}) — add '${key}=${expected}' to /etc/sysctl.d/99-hardening.conf"
  fi
}

check_sysctl "kernel.randomize_va_space"          "2"  "ASLR (randomize_va_space)"
check_sysctl "kernel.dmesg_restrict"              "1"  "dmesg restricted to root"
check_sysctl "kernel.kptr_restrict"               "2"  "Kernel pointer restriction"
check_sysctl "fs.suid_dumpable"                   "0"  "SUID core dumps disabled"
check_sysctl "net.ipv4.tcp_syncookies"            "1"  "TCP SYN cookie protection"
check_sysctl "net.ipv4.conf.all.accept_redirects" "0"  "ICMP redirect accept disabled"
check_sysctl "net.ipv4.conf.all.send_redirects"   "0"  "ICMP redirect send disabled"
check_sysctl "net.ipv4.conf.all.accept_source_route" "0" "Source routing disabled"
check_sysctl "net.ipv4.conf.all.log_martians"     "1"  "Log martian packets"
check_sysctl "net.ipv4.conf.all.rp_filter"        "1"  "Reverse path filtering"
check_sysctl "net.ipv6.conf.all.accept_redirects" "0"  "IPv6 redirect accept disabled"
check_sysctl "net.ipv6.conf.all.accept_source_route" "0" "IPv6 source routing disabled"

# Ptrace scope (0=all, 1=parent, 2=root, 3=none)
PTRACE=$(sysctl_val "kernel.yama.ptrace_scope")
if   [[ "${PTRACE:-0}" -ge 2 ]]; then pass  "ptrace_scope: ${PTRACE} (restricted)"
elif [[ "${PTRACE:-0}" -eq 1 ]]; then warn  "ptrace_scope: 1 — only parent can ptrace; consider 2"
else                                   fail  "ptrace_scope: ${PTRACE:-0} — unrestricted ptrace"
fi

# ══════════════════════════════════════════════════════════════════════
# 11. FILE SYSTEM SECURITY
# ══════════════════════════════════════════════════════════════════════
section "11. Filesystem Security"

# Permissions on critical files
check_perms() {
  local file="$1" max_perms="$2" label="$3"
  [[ -e "$file" ]] || { info "${label}: not found"; return; }
  local perms; perms=$(stat -c "%a" "$file" 2>/dev/null)
  # Compare octal — file perms should not exceed max_perms
  if [[ "${perms:-777}" -le "$max_perms" ]]; then
    pass "${label}: permissions ${perms} (ok)"
  else
    fail "${label}: permissions ${perms} — should be ≤ ${max_perms}"
  fi
}

check_perms /etc/passwd    644  "/etc/passwd"
check_perms /etc/shadow    640  "/etc/shadow"
check_perms /etc/group     644  "/etc/group"
check_perms /etc/gshadow   640  "/etc/gshadow"
check_perms /etc/ssh/sshd_config 600 "/etc/ssh/sshd_config"
check_perms /boot/grub/grub.cfg  600 "/boot/grub/grub.cfg"

# Sticky bit on /tmp
TMP_STICKY=$(stat -c "%a" /tmp 2>/dev/null)
if [[ "${TMP_STICKY: -1}" == "t" ]] || [[ "$TMP_STICKY" =~ ^1 ]]; then
  pass "/tmp: sticky bit set"
else
  # Check numeric — 1xxx means sticky bit
  STICKY_INT=$(stat -c "%04a" /tmp 2>/dev/null | cut -c1)
  [[ "${STICKY_INT:-0}" == "1" ]] \
    && pass "/tmp: sticky bit set (${TMP_STICKY})" \
    || fail "/tmp: sticky bit NOT set — run: chmod +t /tmp"
fi

# World-writable files outside /tmp and /proc (limited scope for speed)
_log ""
_log "  ${DIM}Scanning for world-writable files in /etc /usr /var/www /home...${RESET}"
WW_FILES=$(find /etc /usr/local /var/www /home \
  -xdev -type f -perm -0002 -not -path "*/proc/*" 2>/dev/null | head -20)
if [[ -n "$WW_FILES" ]]; then
  fail "World-writable files found:"
  echo "$WW_FILES" | while IFS= read -r f; do detail "$(ls -la "$f")"; done
else
  pass "No world-writable files in /etc, /usr/local, /var/www, /home"
fi

# SUID/SGID binaries outside standard locations
if [[ "$SKIP_SUID" == "false" ]]; then
  _log ""
  _log "  ${DIM}Scanning for unexpected SUID binaries (pass --no-suid to skip)...${RESET}"

  # Known-safe SUID paths on standard Ubuntu
  SUID_FILES=$(find / -xdev -type f -perm -4000 2>/dev/null \
    | grep -vE "^/usr/bin/(sudo|su|newgrp|gpasswd|chfn|chsh|passwd|pkexec|umount|mount|ping|fusermount)$" \
    | grep -vE "^/usr/lib/(openssh/ssh-keysign|dbus-1.0/dbus-daemon-launch-helper|snapd/snap-confine|policykit-1/polkit-agent-helper-1|eject|pt_chown)$" \
    | grep -vE "^/bin/(su|umount|mount|ping|fusermount3?)$" \
    | head -20)

  if [[ -n "$SUID_FILES" ]]; then
    warn "Non-standard SUID binaries found — verify these are expected:"
    echo "$SUID_FILES" | while IFS= read -r f; do detail "$(ls -la "$f")"; done
  else
    pass "No unexpected SUID binaries found"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 12. LOGGING & MONITORING
# ══════════════════════════════════════════════════════════════════════
section "12. Logging & Monitoring"

# syslog / rsyslog
if systemctl is-active rsyslog &>/dev/null; then
  pass "rsyslog: active"
elif systemctl is-active syslog &>/dev/null; then
  pass "syslog: active"
else
  warn "Neither rsyslog nor syslog is active"
fi

# journald persistent storage
JOURNAL_STORAGE=$(grep -i "^Storage" /etc/systemd/journald.conf 2>/dev/null | cut -d= -f2)
if [[ "${JOURNAL_STORAGE,,}" == "persistent" ]]; then
  pass "journald: persistent storage configured"
elif [[ -d /var/log/journal ]]; then
  pass "journald: persistent (journal directory exists)"
else
  warn "journald: storage may be volatile — logs lost on reboot"
  info "Fix: mkdir -p /var/log/journal && systemctl restart systemd-journald"
fi

# Journal disk usage
JOURNAL_SIZE=$(journalctl --disk-usage 2>/dev/null | grep -oE "[0-9]+\.[0-9]+[GMK]" | head -1)
info "Journal disk usage: ${JOURNAL_SIZE:-unknown}"

# Log rotate
if command -v logrotate &>/dev/null; then
  pass "logrotate: installed"
else
  warn "logrotate: not found"
fi

# Log shipping to a central log server (unit name set by LOG_SHIPPER_SERVICE)
if systemctl is-active "$LOG_SHIPPER_SERVICE" &>/dev/null; then
  pass "${LOG_SHIPPER_SERVICE}: active (shipping logs to central log server)"
else
  warn "${LOG_SHIPPER_SERVICE}: not active — logs not being shipped off-host"
fi

# Audit daemon
if systemctl is-active auditd &>/dev/null; then
  pass "auditd: active"
  AUDIT_RULES=$(auditctl -l 2>/dev/null | grep -c "^-" || true)
  info "Audit rules loaded: ${AUDIT_RULES}"
else
  info "auditd: not running — consider enabling for compliance logging"
fi

# ══════════════════════════════════════════════════════════════════════
# 13. SCHEDULED TASKS
# ══════════════════════════════════════════════════════════════════════
section "13. Scheduled Tasks"

# System crontab
if [[ -f /etc/crontab ]]; then
  CRON_ENTRIES=$(grep -v '^#\|^$' /etc/crontab | wc -l)
  info "/etc/crontab: ${CRON_ENTRIES} entries"
fi

# /etc/cron.d
CROND_COUNT=$(find /etc/cron.d -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
info "/etc/cron.d: ${CROND_COUNT} files"

# User crontabs
CRON_USERS=""
for UCRON in /var/spool/cron/crontabs/*; do
  [[ -f "$UCRON" ]] || continue
  UCRON_USER="${UCRON##*/}"
  ENTRY_COUNT=$(grep -v '^#\|^$' "$UCRON" 2>/dev/null | wc -l)
  CRON_USERS="${CRON_USERS} ${UCRON_USER}(${ENTRY_COUNT})"
done
[[ -n "$CRON_USERS" ]] \
  && info "User crontabs:${CRON_USERS}" \
  || info "No user crontabs found"

# systemd timers (often replace cron on modern Ubuntu)
TIMER_COUNT=$(systemctl list-timers --no-legend 2>/dev/null | wc -l | tr -d ' ')
info "Active systemd timers: ${TIMER_COUNT}"
systemctl list-timers --no-legend 2>/dev/null | awk '{print $1, $5}' \
  | head -10 | while IFS= read -r line; do detail "$line"; done

# ══════════════════════════════════════════════════════════════════════
# 14. INSTALLED PACKAGES AUDIT
# ══════════════════════════════════════════════════════════════════════
section "14. Installed Package Hygiene"

if command -v dpkg &>/dev/null; then
  PKG_COUNT=$(dpkg -l 2>/dev/null | grep "^ii" | wc -l)
  info "Installed packages: ${PKG_COUNT}"

  # Check for known-insecure or unnecessary packages
  RISKY_PKGS="telnet rsh-client rlogin nis talk tftpd xinetd"
  FOUND_RISKY=""
  for pkg in $RISKY_PKGS; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && FOUND_RISKY="${FOUND_RISKY} ${pkg}"
  done
  [[ -n "$FOUND_RISKY" ]] \
    && fail "Insecure/legacy packages installed:${FOUND_RISKY}  — remove with apt purge" \
    || pass "No known insecure packages installed"

  # Check for packages with known config issues
  # (fixed: `command -v` output previously leaked into DEBSUMS and broke the numeric test)
  if command -v debsums &>/dev/null; then
    DEBSUMS=$(debsums -c 2>/dev/null | wc -l | tr -d ' ')
  else
    DEBSUMS="N/A"
  fi
  if [[ "$DEBSUMS" != "N/A" ]] && [[ "$DEBSUMS" -gt 0 ]]; then
    warn "debsums: ${DEBSUMS} package file(s) modified — may indicate tampering"
  elif [[ "$DEBSUMS" == "0" ]]; then
    pass "debsums: all package files match expected checksums"
  else
    info "debsums: not installed (optional integrity check tool)"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# 15. DOCKER (if present)
# ══════════════════════════════════════════════════════════════════════
if command -v docker &>/dev/null; then
  section "15. Docker"

  if systemctl is-active docker &>/dev/null; then
    pass "Docker daemon: running"

    CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
    CONTAINERS_ALL=$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
    info "Containers: ${CONTAINERS} running / ${CONTAINERS_ALL} total"

    # Privileged containers
    PRIV=$(docker ps -q 2>/dev/null | xargs -I{} docker inspect {} \
           --format '{{.Name}}: Privileged={{.HostConfig.Privileged}}' 2>/dev/null \
           | grep "Privileged=true" || echo "")
    [[ -n "$PRIV" ]] \
      && fail "Privileged containers found: ${PRIV}" \
      || pass "No privileged containers"

    # Containers sharing host network
    HOST_NET=$(docker ps -q 2>/dev/null | xargs -I{} docker inspect {} \
               --format '{{.Name}}: NetworkMode={{.HostConfig.NetworkMode}}' 2>/dev/null \
               | grep "NetworkMode=host" || echo "")
    [[ -n "$HOST_NET" ]] \
      && warn "Containers using host network: ${HOST_NET}" \
      || pass "No containers on host network mode"

    # Docker daemon socket permissions
    if [[ -S /var/run/docker.sock ]]; then
      SOCK_PERMS=$(stat -c "%a" /var/run/docker.sock)
      SOCK_GROUP=$(stat -c "%G" /var/run/docker.sock)
      info "Docker socket: ${SOCK_PERMS} (group: ${SOCK_GROUP})"
      DOCKER_GROUP_MEMBERS=$(getent group docker 2>/dev/null | cut -d: -f4)
      [[ -n "$DOCKER_GROUP_MEMBERS" ]] \
        && info "Docker group members (have root-equivalent access): ${DOCKER_GROUP_MEMBERS}"
    fi
  else
    info "Docker: installed but daemon not running"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════
TOTAL_CHECKS=$(( PASS + FAIL + WARN ))
SCORE=0
[[ "$TOTAL_CHECKS" -gt 0 ]] && SCORE=$(( PASS * 100 / TOTAL_CHECKS ))

SUMMARY=$(cat <<EOF

════════════════════════════════════════════════════════
  SERVER AUDIT SUMMARY
  Host:   $(hostname -f 2>/dev/null || hostname)
  Date:   $(date)
════════════════════════════════════════════════════════
  PASS:   ${PASS}
  FAIL:   ${FAIL}
  WARN:   ${WARN}
  INFO:   ${INFO_N}
  ──────────────────────────────────────────────────────
  Score:  ${PASS}/${TOTAL_CHECKS} checks passed (${SCORE}%)
EOF
)

if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  SUMMARY+=$'\n  Status: ✓ Fully compliant'
elif [[ "$FAIL" -eq 0 ]]; then
  SUMMARY+=$'\n  Status: ⚠ '"${WARN}"' warning(s) — no critical failures'
else
  SUMMARY+=$'\n  Status: ✗ '"${FAIL}"' critical failure(s) require remediation'
fi

SUMMARY+=$'\n  Report: '"${REPORT_FILE}"
SUMMARY+=$'\n════════════════════════════════════════════════════════'

echo "$SUMMARY" | tee -a "$REPORT_FILE"

# ── Optional JSON summary ─────────────────────────────────────────────
if [[ "$WRITE_JSON" == "true" ]]; then
  cat > "$JSON_FILE" <<JSON
{
  "audit": {
    "host": "$(hostname -f 2>/dev/null || hostname)",
    "date": "$(date -Iseconds)",
    "os": "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")",
    "kernel": "$(uname -r)"
  },
  "results": {
    "pass": ${PASS},
    "fail": ${FAIL},
    "warn": ${WARN},
    "info": ${INFO_N},
    "total": ${TOTAL_CHECKS},
    "score_pct": ${SCORE}
  },
  "report_file": "${REPORT_FILE}"
}
JSON
  echo "  JSON summary: ${JSON_FILE}"
fi
