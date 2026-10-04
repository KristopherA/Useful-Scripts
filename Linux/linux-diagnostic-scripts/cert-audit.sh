#!/usr/bin/env bash
# cert-audit.sh - audit remote TLS certificates and local PEM certificate files
#
# Usage:        ./cert-audit.sh [-w DAYS] [-c DAYS] [--cafile FILE] TARGET_FILE
# Requirements: bash 4+, openssl, GNU date (or BSD date fallback), timeout (optional).

set -uo pipefail
umask 077

VERSION="1.0.0"
WARN_DAYS=30
CRIT_DAYS=14
TIMEOUT=10
CAFILE=""
NO_VERIFY=0
PROTOCOL_SCAN=1

usage() {
  cat <<'EOF'
Usage: cert-audit.sh [OPTIONS] TARGET_FILE

TARGET_FILE format (blank lines and # comments are ignored):
  host:port [sni-name] [starttls-protocol]
  /path/to/certificate.pem

IPv6 endpoints must use brackets: [2001:db8::10]:443

Options:
  -w, --warning DAYS      Warning threshold (default: 30)
  -c, --critical DAYS     Critical threshold (default: 14)
  -t, --timeout SECONDS   Connection timeout (default: 10)
      --cafile FILE       Use an explicit CA bundle
      --no-verify         Report chain/hostname status without making it critical
      --no-protocol-scan  Skip TLS 1.0/1.1/1.2/1.3 acceptance probes
  -h, --help              Show help
      --version           Show version

Exit codes follow monitoring conventions: 0 OK; 1 WARNING; 2 CRITICAL;
                                          3 UNKNOWN/usage error.
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }
timed() {
  if have timeout; then timeout "$TIMEOUT" "$@"; elif have gtimeout; then gtimeout "$TIMEOUT" "$@"; else "$@"; fi
}

while (($#)); do
  case "$1" in
    -w|--warning) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { usage >&2; exit 3; }; WARN_DAYS=$2; shift 2 ;;
    -c|--critical) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || { usage >&2; exit 3; }; CRIT_DAYS=$2; shift 2 ;;
    -t|--timeout) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 3; }; TIMEOUT=$2; shift 2 ;;
    --cafile) [[ $# -ge 2 && -r $2 ]] || { echo "CA file is not readable" >&2; exit 3; }; CAFILE=$2; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --no-protocol-scan) PROTOCOL_SCAN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "cert-audit.sh $VERSION"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    *) [[ -z ${TARGET_FILE:-} ]] || { echo "Only one target file is allowed" >&2; exit 3; }; TARGET_FILE=$1; shift ;;
  esac
done
[[ -n ${TARGET_FILE:-} && -r $TARGET_FILE ]] || { usage >&2; exit 3; }
((CRIT_DAYS <= WARN_DAYS)) || { echo "Critical days must be <= warning days" >&2; exit 3; }
have openssl || { echo "openssl is required" >&2; exit 3; }

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT HUP INT TERM
overall=0
count=0

set_status() {
  local value=$1
  ((value > overall)) && overall=$value
}

epoch_now=$(date +%s)
printf '%-32s %-10s %8s  %s\n' "TARGET" "STATUS" "DAYS" "DETAIL"
printf '%-32s %-10s %8s  %s\n' "--------------------------------" "----------" "--------" "------"

while IFS= read -r raw || [[ -n $raw ]]; do
  line=${raw%%#*}
  read -r target sni starttls _ <<<"$line"
  [[ -n ${target:-} ]] || continue
  count=$((count + 1))
  cert="$tmpdir/cert-$count.pem"
  transcript="$tmpdir/connect-$count.txt"
  verify_ok=1
  host_match=1
  is_remote=0
  if [[ -f $target ]]; then
    if ! openssl x509 -in "$target" -out "$cert" 2>"$transcript"; then
      printf '%-32s %-10s %8s  %s\n' "$target" "CRITICAL" "-" "invalid or unreadable certificate"
      set_status 2
      continue
    fi
    verify_args=(verify)
    [[ -n $CAFILE ]] && verify_args+=(-CAfile "$CAFILE")
    openssl "${verify_args[@]}" "$cert" >/dev/null 2>&1 || verify_ok=0
    if [[ -n ${sni:-} ]]; then openssl x509 -in "$cert" -noout -checkhost "$sni" >/dev/null 2>&1 || host_match=0; fi
  else
    is_remote=1
    if [[ $target =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
      host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
    elif [[ $target =~ ^([^:]+):([0-9]+)$ ]]; then
      host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
    else
      printf '%-32s %-10s %8s  %s\n' "$target" "UNKNOWN" "-" "expected host:port or PEM path"
      set_status 3
      continue
    fi
    ((port >= 1 && port <= 65535)) || { printf '%-32s %-10s %8s  %s\n' "$target" "UNKNOWN" "-" "invalid port"; set_status 3; continue; }
    sni=${sni:-$host}
    ssl_args=(s_client -connect "$target" -servername "$sni" -verify_hostname "$sni" -verify_return_error -showcerts)
    [[ -n $CAFILE ]] && ssl_args+=(-CAfile "$CAFILE")
    [[ -n ${starttls:-} ]] && ssl_args+=(-starttls "$starttls")
    if ! printf '' | timed openssl "${ssl_args[@]}" >"$transcript" 2>&1; then verify_ok=0; fi
    if ! sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$transcript" | sed -n '1,/-----END CERTIFICATE-----/p' >"$cert"; then :; fi
    if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
      printf '%-32s %-10s %8s  %s\n' "$target" "CRITICAL" "-" "TLS connection/certificate retrieval failed"
      set_status 2
      continue
    fi
    openssl x509 -in "$cert" -noout -checkhost "$sni" >/dev/null 2>&1 || host_match=0
  fi

  enddate=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)
  endepoch=$(date -d "$enddate" +%s 2>/dev/null || date -j -f '%b %e %T %Y %Z' "$enddate" +%s 2>/dev/null || echo 0)
  if [[ ! $endepoch =~ ^[0-9]+$ ]] || ((endepoch == 0)); then
    printf '%-32s %-10s %8s  %s\n' "$target" "UNKNOWN" "-" "could not parse expiry: $enddate"
    set_status 3
    continue
  fi
  days=$(((endepoch - epoch_now) / 86400))
  subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')
  issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2-)
  sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

  status=OK; code=0; reason="expires $enddate"
  if ((days < 0)); then status=CRITICAL; code=2; reason="expired $((-days)) day(s) ago"
  elif ((days <= CRIT_DAYS)); then status=CRITICAL; code=2; reason="expires soon"
  elif ((days <= WARN_DAYS)); then status=WARNING; code=1; reason="expires soon"
  fi
  if ((host_match == 0 && NO_VERIFY == 0)); then status=CRITICAL; code=2; reason="hostname does not match CN/SAN"
  elif ((verify_ok == 0 && NO_VERIFY == 0)); then status=CRITICAL; code=2; reason="chain validation failed"
  elif ((verify_ok == 0)); then reason="$reason; validation failed (ignored)"
  fi
  set_status "$code"
  printf '%-32s %-10s %8d  %s\n' "$target" "$status" "$days" "$reason"
  printf '  Subject: %s\n  Issuer: %s\n  SHA256: %s\n' "$subject" "$issuer" "$fingerprint"
  [[ -n $sans ]] && printf '  SANs: %s\n' "$sans"
  [[ -n ${sni:-} ]] && printf '  SNI/hostname: %s; hostname match: %s; STARTTLS: %s\n' "$sni" "$([[ $host_match -eq 1 ]] && echo yes || echo no)" "${starttls:-no}"
  printf '  Chain validation: %s\n' "$([[ $verify_ok -eq 1 ]] && echo pass || echo fail)"
  if ((is_remote && PROTOCOL_SCAN)); then
    accepted=""
    for protocol in tls1 tls1_1 tls1_2 tls1_3; do
      if openssl s_client -help 2>&1 | grep -q -- "-$protocol"; then
        proto_args=(s_client -connect "$target" -servername "$sni" -brief "-$protocol")
        [[ -n ${starttls:-} ]] && proto_args+=(-starttls "$starttls")
        if printf '' | timed openssl "${proto_args[@]}" >"$tmpdir/protocol-$count-$protocol.txt" 2>&1 \
          && grep -qiE 'Protocol( version)?' "$tmpdir/protocol-$count-$protocol.txt"; then
          accepted+=" ${protocol/tls/TLS }"
        fi
      fi
    done
    printf '  Accepted protocol probes:%s\n' "${accepted:- none (or probes blocked)}"
  fi
done <"$TARGET_FILE"

((count > 0)) || { echo "UNKNOWN: target file contained no targets"; exit 3; }
case "$overall" in
  0) echo "SUMMARY: OK - $count target(s) checked" ;;
  1) echo "SUMMARY: WARNING - one or more certificates need attention" ;;
  2) echo "SUMMARY: CRITICAL - one or more checks failed" ;;
  *) echo "SUMMARY: UNKNOWN - one or more targets could not be assessed" ;;
esac
exit "$overall"
