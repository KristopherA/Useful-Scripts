#!/usr/bin/env bash
#
# cert_check.sh — Validate local certificate files and remote TLS services
#
# Purpose:
#   - Local files (PEM, DER, PKCS#12/PFX, PKCS#7/P7B): parse, print summary
#     (subject, issuer, serial, validity, SHA-256 fingerprint, SAN, key usage),
#     verify trust chain against a CA bundle, check hostname in SAN, check
#     expiry, and confirm a private key matches the certificate.
#   - Remote services: connect with openssl s_client (optionally STARTTLS for
#     SMTP/LDAP/IMAP/POP3), verify chain + hostname, print leaf details.
#
# Requirements:
#   bash 3.2+, openssl (OpenSSL 1.1.1+ recommended; LibreSSL may lack
#   -verify_hostname / -starttls ldap), awk, grep, sed, mktemp.
#
# Run with --help for usage.

set -u

usage() {
cat <<'EOF'
cert_check.sh — validate certificate files and remote TLS services

Examples
  ./cert_check.sh --file server.pem --cafile /etc/ssl/certs/ca-certificates.crt --hostname app.example.com
  CERT_CHECK_PASSWORD='secret' ./cert_check.sh --file bundle.p12 --type p12 --cafile root.pem
  ./cert_check.sh --file chain.p7b --type p7b
  ./cert_check.sh --remote www.example.com --port 443 --service https
  ./cert_check.sh --remote mail.example.com --port 25 --service smtp
  ./cert_check.sh --file cert.pem --key key.pem

Options
  --file PATH           Local certificate or bundle
  --type TYPE           auto, pem, der, p12, pfx, p7b, p7c (default: auto, by extension)
  --cafile PATH         CA bundle or root CA PEM
  --intermediate PATH   Intermediate PEM bundle
  --hostname NAME       Expected hostname for SAN check
  --key PATH            Private key for key-match validation
  --password PASS       Password for PKCS#12 bundle (prefer env CERT_CHECK_PASSWORD;
                        a password on the command line is visible to other users)
  --remote HOST         Remote service hostname
  --port PORT           Remote port, default 443
  --service TYPE        https, smtp, ldap, imap, pop3, generic (default https)
  --help                Show help

Exit codes: 0 = checks completed with no FAIL, 1 = one or more FAIL, 2 = usage/setup error
EOF
}

FILE=""
TYPE="auto"
CAFILE=""
INTERMEDIATE=""
EXPECTED_HOST=""
KEYFILE=""
# Password may come from the environment to keep it out of `ps` output.
CERT_CHECK_PASSWORD="${CERT_CHECK_PASSWORD:-}"
REMOTE=""
PORT="443"
SERVICE="https"

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2 ;;
    --type) TYPE="${2:-}"; shift 2 ;;
    --cafile) CAFILE="${2:-}"; shift 2 ;;
    --intermediate) INTERMEDIATE="${2:-}"; shift 2 ;;
    --hostname) EXPECTED_HOST="${2:-}"; shift 2 ;;
    --key) KEYFILE="${2:-}"; shift 2 ;;
    --password) CERT_CHECK_PASSWORD="${2:-}"; shift 2 ;;
    --remote) REMOTE="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --service) SERVICE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 2; }
}

need_cmd openssl
need_cmd awk
need_cmd grep
need_cmd sed
need_cmd mktemp

FAILURES=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }

tmpdir="$(mktemp -d)"
chmod 700 "$tmpdir"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

detect_type() {
  local path="$1"
  local lower
  lower="$(printf '%s' "$path" | tr 'A-Z' 'a-z')"
  case "$lower" in
    *.pem|*.crt) printf 'pem' ;;
    *.cer|*.der) printf 'der' ;;
    *.p12|*.pfx|*.pkcs12) printf 'p12' ;;
    *.p7b|*.p7c|*.pkcs7) printf 'p7b' ;;
    *) printf 'pem' ;;
  esac
}

print_x509_summary() {
  local cert="$1"
  openssl x509 -in "$cert" -noout -subject -issuer -serial -dates -fingerprint -sha256 || return 1
  echo
  info "Subject Alternative Name"
  openssl x509 -in "$cert" -text -noout | grep -A 1 'Subject Alternative Name'
  echo
  info "Key Usage / Extended Key Usage / Basic Constraints"
  openssl x509 -in "$cert" -text -noout | grep -A 1 -E 'X509v3 (Key Usage|Extended Key Usage|Basic Constraints)'
  echo
  info "Public Key / Signature"
  openssl x509 -in "$cert" -text -noout | grep -E 'Signature Algorithm|Public-Key:' | sort -u
}

check_expiry() {
  local cert="$1"
  if openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
    if openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1; then
      pass "Certificate is within its validity period"
    else
      warn "Certificate expires within 30 days"
    fi
  else
    fail "Certificate is expired"
  fi
}

verify_chain() {
  local cert="$1"
  if [ -n "$CAFILE" ] && [ -n "$INTERMEDIATE" ]; then
    if openssl verify -CAfile "$CAFILE" -untrusted "$INTERMEDIATE" "$cert"; then
      pass "Trust chain validation succeeded"
    else
      fail "Trust chain validation failed"
    fi
  elif [ -n "$CAFILE" ]; then
    if openssl verify -CAfile "$CAFILE" "$cert"; then
      pass "Trust validation succeeded"
    else
      fail "Trust validation failed"
    fi
  else
    warn "No --cafile supplied, skipping trust validation"
  fi
}

check_hostname_local() {
  local cert="$1"
  local name="$2"
  [ -n "$name" ] || return 0
  # Exact (fixed-string, whole-entry) match against the DNS SAN entries.
  if openssl x509 -in "$cert" -noout -text \
      | grep -A 1 'Subject Alternative Name' \
      | grep -oE 'DNS:[^,[:space:]]+' | sed 's/^DNS://' \
      | grep -qixF -- "$name"; then
    pass "Hostname found in SAN: $name"
  else
    warn "Hostname not found with exact DNS match in SAN (wildcards not evaluated): $name"
  fi
}

check_key_match() {
  local cert="$1"
  local key="$2"
  [ -n "$key" ] || return 0
  local cert_hash key_hash
  cert_hash="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform pem 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')"
  key_hash="$(openssl pkey -in "$key" -pubout -outform pem 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')"
  if [ -n "$cert_hash" ] && [ "$cert_hash" = "$key_hash" ]; then
    pass "Certificate and private key match"
  else
    fail "Certificate and private key do not match, or key could not be read"
  fi
}

validate_pem_or_der() {
  local infile="$1"
  local mode="$2"
  local cert="$tmpdir/leaf.pem"
  if [ "$mode" = "der" ]; then
    if ! openssl x509 -inform DER -in "$infile" -out "$cert" >/dev/null 2>&1; then
      fail "DER certificate could not be parsed"
      exit 1
    fi
  else
    cp "$infile" "$cert"
    if ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
      fail "PEM certificate could not be parsed"
      exit 1
    fi
  fi
  pass "Certificate parsed successfully"
  print_x509_summary "$cert"
  check_expiry "$cert"
  verify_chain "$cert"
  check_hostname_local "$cert" "$EXPECTED_HOST"
  check_key_match "$cert" "$KEYFILE"
}

# Run openssl pkcs12 with the password passed via environment (not argv).
p12() {
  if [ -n "$CERT_CHECK_PASSWORD" ]; then
    CERT_CHECK_PASSWORD="$CERT_CHECK_PASSWORD" openssl pkcs12 -passin env:CERT_CHECK_PASSWORD "$@"
  else
    openssl pkcs12 -passin pass: "$@"
  fi
}

validate_p12() {
  local infile="$1"
  local cert="$tmpdir/p12-cert.pem"
  local ca="$tmpdir/p12-ca.pem"
  local key="$tmpdir/p12-key.pem"

  if ! p12 -in "$infile" -info -nodes -nokeys >/dev/null 2>&1; then
    fail "PKCS#12 bundle could not be parsed (wrong password, or legacy encryption — try OpenSSL 3 with -legacy)"
    exit 1
  fi
  pass "PKCS#12 bundle parsed successfully"

  p12 -in "$infile" -clcerts -nokeys -out "$cert" >/dev/null 2>&1
  p12 -in "$infile" -cacerts -nokeys -out "$ca" >/dev/null 2>&1 || true
  ( umask 077; p12 -in "$infile" -nocerts -nodes -out "$key" >/dev/null 2>&1 ) || true

  if [ -s "$cert" ]; then
    pass "Leaf certificate extracted from PKCS#12"
    print_x509_summary "$cert"
    check_expiry "$cert"
    if [ -n "$CAFILE" ]; then
      if [ -s "$ca" ] && [ -z "$INTERMEDIATE" ]; then
        INTERMEDIATE="$ca"
      fi
      verify_chain "$cert"
    else
      warn "No --cafile supplied, trust validation skipped"
    fi
    check_hostname_local "$cert" "$EXPECTED_HOST"
    if [ -s "$key" ]; then
      check_key_match "$cert" "$key"
    else
      warn "No private key extracted from PKCS#12"
    fi
  else
    fail "No leaf certificate found in PKCS#12 bundle"
    exit 1
  fi
}

validate_p7b() {
  local infile="$1"
  local inform="PEM"
  if ! openssl pkcs7 -in "$infile" -print_certs -noout >/dev/null 2>&1; then
    if openssl pkcs7 -inform DER -in "$infile" -print_certs -noout >/dev/null 2>&1; then
      inform="DER"
    else
      fail "PKCS#7 bundle could not be parsed"
      exit 1
    fi
  fi
  pass "PKCS#7 bundle parsed successfully (${inform})"
  info "Certificates found in PKCS#7 bundle"
  openssl pkcs7 -inform "$inform" -in "$infile" -print_certs -text -noout
  warn "PKCS#7 usually contains certificates only and not a private key"
}

validate_remote() {
  local host="$1"
  local port="$2"
  local service="$3"
  local starttls=()
  case "$service" in
    https|generic) ;;
    smtp) starttls=(-starttls smtp) ;;
    ldap) starttls=(-starttls ldap) ;;
    imap) starttls=(-starttls imap) ;;
    pop3) starttls=(-starttls pop3) ;;
    *)
      warn "Unknown service type, using generic TLS"
      ;;
  esac

  info "Connecting to $host:$port with service=$service"
  local out="$tmpdir/sclient.txt"
  # ${arr[@]+...} keeps `set -u` happy with empty arrays on bash 3.2 (macOS).
  if ! openssl s_client ${starttls[@]+"${starttls[@]}"} -connect "$host:$port" \
        -servername "$host" -verify_hostname "$host" -showcerts </dev/null >"$out" 2>&1; then
    warn "s_client returned non-zero status, review output below"
  fi

  sed -n '1,220p' "$out"
  echo

  if grep -q 'Verify return code: 0 (ok)' "$out"; then
    pass "Remote verification returned code 0"
  else
    fail "Remote verification did not return code 0"
  fi

  local leaf="$tmpdir/remote-leaf.pem"
  awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' "$out" > "$leaf"
  if [ -s "$leaf" ] && openssl x509 -in "$leaf" -noout -subject -issuer -dates -fingerprint -sha256; then
    pass "Remote leaf certificate extracted"
    check_expiry "$leaf"
  else
    fail "Could not extract remote leaf certificate"
  fi
}

if [ -n "$FILE" ] && [ -n "$REMOTE" ]; then
  echo "Use either --file or --remote, not both." >&2
  exit 2
fi

if [ -z "$FILE" ] && [ -z "$REMOTE" ]; then
  usage
  exit 2
fi

if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || { echo "File not found: $FILE" >&2; exit 2; }
  if [ "$TYPE" = "auto" ]; then
    TYPE="$(detect_type "$FILE")"
  fi
  info "File validation started"
  info "Detected type: $TYPE"
  case "$TYPE" in
    pem) validate_pem_or_der "$FILE" "pem" ;;
    der) validate_pem_or_der "$FILE" "der" ;;
    p12|pfx) validate_p12 "$FILE" ;;
    p7b|p7c) validate_p7b "$FILE" ;;
    *)
      echo "Unsupported type: $TYPE" >&2
      exit 2
      ;;
  esac
fi

if [ -n "$REMOTE" ]; then
  validate_remote "$REMOTE" "$PORT" "$SERVICE"
fi

if [ "$FAILURES" -gt 0 ]; then
  info "Validation completed with ${FAILURES} failure(s)"
  exit 1
fi
pass "Validation completed"
exit 0
