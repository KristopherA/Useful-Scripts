#!/usr/bin/env bash
# network-diag.sh - read-only DNS, route, reachability, TCP, and TLS diagnosis
#
# Usage:        ./network-diag.sh [--tls|--starttls PROTO] [-o FILE] HOST [PORT]
# Requirements: bash 4+, getent or dig, iproute2; optional: ping, tracepath/traceroute,
#               nc, openssl, ss, ufw/nft/iptables.

set -uo pipefail
umask 077

VERSION="1.0.0"
TIMEOUT=7
OUTPUT=""
TLS_MODE="auto"
STARTTLS=""
SNI=""

usage() {
  cat <<'EOF'
Usage: network-diag.sh [OPTIONS] HOST [PORT]

Options:
  -o, --output FILE        Write a report as well as a console summary
  -t, --timeout SECONDS    Per-test timeout (default: 7)
      --tls                Force a direct TLS handshake
      --no-tls             Do not attempt TLS
      --starttls PROTOCOL  Use OpenSSL STARTTLS (smtp, imap, pop3, ftp,
                           xmpp, xmpp-server, irc, postgres, mysql, lmtp)
      --sni NAME           TLS server name (default: HOST)
  -h, --help               Show help
      --version            Show version

Examples:
  network-diag.sh db.example.com 3306 --starttls mysql
  network-diag.sh --tls --sni www.example.com 192.0.2.10 443

Exit codes: 0 all requested essential tests passed; 1 DNS/route/TCP/TLS failed;
            2 invalid usage; 3 required local capability unavailable.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n==== %s ====\n' "$1"; }
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@" 2>&1 || printf '[command exited %s]\n' "$?"; }
timed() {
  if have timeout; then timeout "$TIMEOUT" "$@"; elif have gtimeout; then gtimeout "$TIMEOUT" "$@"; else "$@"; fi
}

args=()
while (($#)); do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
    -t|--timeout) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { echo "Invalid timeout" >&2; exit 2; }; TIMEOUT=$2; shift 2 ;;
    --tls) TLS_MODE=yes; shift ;;
    --no-tls) TLS_MODE=no; shift ;;
    --starttls) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; STARTTLS=$2; TLS_MODE=yes; shift 2 ;;
    --sni) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SNI=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "network-diag.sh $VERSION"; exit 0 ;;
    --) shift; args+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${#args[@]} -ge 1 && ${#args[@]} -le 2 ]] || { usage >&2; exit 2; }
HOST=${args[0]}
PORT=${args[1]:-}
[[ -n $HOST && $HOST != *[[:space:]]* ]] || { echo "Invalid host" >&2; exit 2; }
if [[ -n $PORT && ! $PORT =~ ^[0-9]+$ ]] || [[ -n $PORT && (PORT -lt 1 || PORT -gt 65535) ]]; then
  echo "Port must be 1-65535" >&2; exit 2
fi
SNI=${SNI:-$HOST}
if [[ $TLS_MODE == auto ]]; then
  case "$PORT" in 443|465|563|636|853|989|990|992|993|994|995) TLS_MODE=yes ;; *) TLS_MODE=no ;; esac
fi

FAIL=0
CAP_ERROR=0
DNS_OK=0
ROUTE_OK=0
TCP_OK=0
TLS_OK=0

diagnose() {
  echo "Network diagnostic report"
  echo "Generated: $(date --iso-8601=seconds 2>/dev/null || date)"
  echo "Host: $HOST"
  echo "Port: ${PORT:-not requested}"
  echo "Timeout: ${TIMEOUT}s"
  echo "TLS: $TLS_MODE${STARTTLS:+ (STARTTLS $STARTTLS)}"
  echo "NOTICE: All tests are read-only; firewall output may require root."

  section "Local identity and interfaces"
  run hostname
  if have ip; then run ip -brief address; else echo "MISSING: ip (package: iproute2)"; fi

  section "DNS resolution"
  if have getent; then
    if timed getent ahosts "$HOST"; then DNS_OK=1; else echo "FAIL: system resolver could not resolve $HOST"; FAIL=1; fi
  elif have dig; then
    if timed dig +time="$TIMEOUT" +tries=1 "$HOST" A "$HOST" AAAA; then DNS_OK=1; else echo "FAIL: dig could not resolve $HOST"; FAIL=1; fi
  else
    echo "ERROR: neither getent nor dig is available"; CAP_ERROR=1
  fi
  if have resolvectl; then run resolvectl status; elif [[ -r /etc/resolv.conf ]]; then run cat /etc/resolv.conf; fi
  have dig && run dig +time="$TIMEOUT" +tries=1 "$HOST" A
  have dig && run dig +time="$TIMEOUT" +tries=1 "$HOST" AAAA

  section "Route selection"
  if have ip; then
    # `ip route get` requires an address, so resolve hostnames first.
    route4=$HOST; route6=$HOST
    if have getent && [[ ! $HOST =~ ^[0-9.]+$ && $HOST != *:* ]]; then
      route4=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1 {print $1}')
      route6=$(getent ahostsv6 "$HOST" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}')
    fi
    if [[ -n ${route4:-} ]] && ip route get "$route4" 2>&1; then ROUTE_OK=1; else echo "FAIL: no IPv4 route decision for target"; FAIL=1; fi
    [[ -n ${route6:-} ]] && { ip -6 route get "$route6" 2>&1 || true; }
    run ip route
  else
    echo "MISSING: ip; route diagnosis is incomplete"; CAP_ERROR=1
  fi

  section "Gateway and host reachability"
  if have ip && have ping; then
    gateway=$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')
    if [[ -n ${gateway:-} ]]; then timed ping -c 2 -W "$TIMEOUT" "$gateway" 2>&1 || echo "WARNING: gateway did not answer ICMP"; fi
  fi
  if have ping; then timed ping -c 3 -W "$TIMEOUT" "$HOST" 2>&1 || echo "WARNING: target did not answer ICMP (ICMP may be filtered)"; fi
  if have tracepath; then timed tracepath -m 12 "$HOST" 2>&1 || true
  elif have traceroute; then timed traceroute -m 12 -w "$TIMEOUT" "$HOST" 2>&1 || true
  else echo "SKIPPED: install tracepath (iputils-tracepath) or traceroute for path tracing"; fi

  section "TCP connectivity"
  if [[ -z $PORT ]]; then
    echo "SKIPPED: no port supplied"
    TCP_OK=1
  elif have nc; then
    if timed nc -vz -w "$TIMEOUT" "$HOST" "$PORT" 2>&1; then TCP_OK=1; else echo "FAIL: TCP connection failed"; FAIL=1; fi
  elif have bash; then
    # $1/$2 are intentionally expanded by the child bash.
    # shellcheck disable=SC2016
    if timed bash -c 'exec 3<>/dev/tcp/$1/$2' bash "$HOST" "$PORT" 2>/dev/null; then
      echo "PASS: TCP connection succeeded (bash /dev/tcp)"; TCP_OK=1
    else
      echo "FAIL: TCP connection failed"; FAIL=1
    fi
  else
    echo "ERROR: nc and bash /dev/tcp are unavailable"; CAP_ERROR=1
  fi

  section "TLS handshake and certificate"
  if [[ $TLS_MODE == no ]]; then
    echo "SKIPPED: TLS not requested or not inferred for this port"
    TLS_OK=1
  elif [[ -z $PORT ]]; then
    echo "FAIL: TLS requested without a port"; FAIL=1
  elif ! have openssl; then
    echo "ERROR: openssl is required for TLS diagnosis"; CAP_ERROR=1
  else
    tls_args=(s_client -connect "${HOST}:${PORT}" -servername "$SNI" -verify_hostname "$SNI" -verify_return_error -showcerts)
    [[ -n $STARTTLS ]] && tls_args+=(-starttls "$STARTTLS")
    tmp_cert=$(mktemp)
    if printf '' | timed openssl "${tls_args[@]}" >"$tmp_cert" 2>&1; then
      echo "PASS: TLS handshake and chain/hostname validation succeeded"; TLS_OK=1
    else
      echo "FAIL: TLS handshake, chain, or hostname validation failed"; FAIL=1
    fi
    sed -n '1,120p' "$tmp_cert"
    if sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$tmp_cert" | openssl x509 -noout -subject -issuer -serial -dates -fingerprint -sha256 -ext subjectAltName 2>&1; then :; fi
    rm -f "$tmp_cert"
  fi

  section "Sockets and firewall context"
  have ss && run ss -s
  have ss && run ss -lntup
  if have ufw; then run ufw status verbose; fi
  if have nft; then run nft list ruleset; elif have iptables; then run iptables -S; fi

  section "Result"
  printf 'DNS=%s ROUTE=%s TCP=%s TLS=%s LOCAL_CAPABILITY_ERROR=%s\n' "$DNS_OK" "$ROUTE_OK" "$TCP_OK" "$TLS_OK" "$CAP_ERROR"
  if ((CAP_ERROR)); then echo "INCOMPLETE"; elif ((FAIL)); then echo "FAIL"; else echo "PASS"; fi
}

if [[ -n $OUTPUT ]]; then
  if ! : >"$OUTPUT" 2>/dev/null; then echo "Cannot create report: $OUTPUT" >&2; exit 3; fi
  diagnose >"$OUTPUT"
  cat "$OUTPUT"
else
  diagnose
fi
((CAP_ERROR == 0)) || exit 3
((FAIL == 0)) || exit 1
exit 0
