# Linux Diagnostic Script Suite

Version: 1.0.0

A set of read-only Bash collectors for first-response triage, change
investigation, and maintenance readiness on Ubuntu/Debian (and, for most of
them, other systemd-based Linux distributions).

## Contents

| Script | Purpose |
| --- | --- |
| `healthcheck.sh` | General first-response health collector. Reports OS/kernel, load, CPU, RAM, swap, filesystems/inodes, mounts, failed services, critical journal/kernel/OOM events, network/routes/DNS/sockets/firewall, time sync, updates/reboot state, recent boots, containers, SMART/ZFS status, and optional remote certificate details. |
| `network-diag.sh` | Follows the diagnostic chain from DNS to route selection, gateway/host ICMP, path trace, TCP connection, and optional TLS/STARTTLS validation. Includes local socket and firewall context without changing the network. |
| `cert-audit.sh` | Audits a list of remote TLS endpoints and/or local PEM certificates. Reports expiry, subject, issuer, SHA-256 fingerprint, hostname/chain validation, and warning/critical status. Exit codes follow monitoring conventions. |
| `docker-diag.sh` | Collects Docker host and selected/all-container state, health, restart count, resource limits, mounts, networks, ports, image metadata, daemon journal, events, and recent logs. Environment values are never emitted. Logs receive best-effort secret redaction but MUST still be reviewed before sharing. |
| `what-changed.sh` | Builds an incident timeline from APT/dpkg, modified configuration and certificate metadata, users/groups, SSH/sudo/auth logs, service events, reboots/kernel events, firewall/network files, cron/timers, Docker activity, and auditd when available. It cannot reconstruct changes the host never logged. |
| `pve-preflight.sh` | Proxmox VE maintenance/reboot readiness check. Assesses cluster quorum, HA, Ceph, configured storage/PBS availability, recent successful backup evidence, disk space, ZFS, failed services, replication, guests, package state, and an existing reboot requirement. It never migrates guests or changes the cluster. |
| `patch-check.sh` | Ubuntu/Debian patch-readiness assessment. Uses an APT simulation to count pending/security/kernel updates and removals; checks held packages, package index age, existing reboot/restart requirements, root/boot free space, an optional backup marker, failed services, and MySQL/Docker/Proxmox detection. It deliberately does NOT run `apt update`, install anything, or restart/reboot. |

## Compatibility and safety

These scripts target Ubuntu and Debian-family Linux systems with Bash 4 or
newer and GNU userland. `healthcheck.sh`, `network-diag.sh`, `cert-audit.sh`,
`docker-diag.sh`, and `what-changed.sh` are also useful on many other systemd
Linux distributions, although package/log locations may differ.
`pve-preflight.sh` is specifically for Proxmox VE.

Every script is read-only with respect to system configuration and services.
They create only the requested report file and short-lived private temporary
files. Most collectors continue when optional dependencies are absent and say
what was skipped. Root is recommended for complete health/change/Docker reports
and required for the Proxmox preflight.

Diagnostic reports can contain hostnames, addresses, usernames, process command
lines, file paths, and application log content. Review every report before
sending it outside your organization. Docker environment variable values are
always redacted; Docker log redaction is heuristic, not a security guarantee.

## Installation

Copy the scripts you want to the host, verify them, and mark them executable:

```sh
mkdir -p "$HOME/linux-diag"
cp ./*.sh "$HOME/linux-diag/"
cd "$HOME/linux-diag"
bash -n ./*.sh
chmod 0755 -- ./*.sh
```

For system-wide installation after review:

```sh
for s in healthcheck network-diag cert-audit docker-diag what-changed pve-preflight patch-check; do
  sudo install -o root -g root -m 0755 "$s.sh" /usr/local/sbin/
done
```

Each script supports `--help` and `--version`. Start with `--help`; it lists the
script-specific options and exit-code contract.

## Configuration

`healthcheck.sh` reads two optional environment variables for its outbound
connectivity tests (skip them entirely with `--no-network`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `HC_DNS_TEST_HOST` | `ubuntu.com` | Hostname resolved to test outbound DNS |
| `HC_PING_TARGET` | `1.1.1.1` | Address pinged to test outbound ICMP |

All other behavior is controlled by command-line options.

## Dependencies

Required for all scripts: bash (4+), GNU coreutils, and standard GNU/Linux
tools (awk, sed, grep, find).

Script-specific required dependencies:

| Script | Requires |
| --- | --- |
| `network-diag.sh` | `getent` (libc-bin) or `dig` (dnsutils); `ip` (iproute2) |
| `cert-audit.sh` | `openssl` |
| `docker-diag.sh` | Docker Engine CLI and access to the Docker daemon |
| `what-changed.sh` | GNU `date` and `find` (coreutils/findutils) |
| `pve-preflight.sh` | Proxmox VE tools; must run as root on a PVE node |
| `patch-check.sh` | `apt-get` and `apt-mark` (apt) |

Recommended optional dependencies:

- General/network: iproute2, iputils-ping, iputils-tracepath, dnsutils,
  netcat-openbsd, traceroute, openssl, ufw, nftables
- Health: systemd, util-linux, procps, smartmontools, zfsutils-linux, chrony,
  Docker CLI when Docker is used
- Change timeline: systemd journal, auditd, Docker CLI when Docker is used
- Patch readiness: needrestart, systemd
- Proxmox: pve-cluster/pve-manager tools, plus ceph and zfs tools when those
  technologies are configured

On Ubuntu, a useful optional-tool installation command is:

```sh
sudo apt-get install iproute2 iputils-ping iputils-tracepath dnsutils \
  netcat-openbsd traceroute openssl smartmontools needrestart
```

Do not install optional packages during an incident or maintenance window
unless that change is approved. Missing optional tools are reported and skipped.

## Examples

General health report:

```sh
sudo healthcheck.sh
sudo healthcheck.sh --cert mail.example.com:443 \
  --cert ldap.example.com:636 -o /tmp/server-health.txt
```

Network and TCP diagnosis:

```sh
sudo network-diag.sh db.example.com 3306
network-diag.sh --tls www.example.com 443 -o web-network-report.txt
network-diag.sh --starttls smtp mail.example.com 25
network-diag.sh --starttls mysql db.example.com 3306
```

Certificate target file (`targets.txt`):

```text
# Direct TLS; optional second field overrides SNI
mail.example.com:443
192.0.2.10:443 www.example.com
ldap.example.com:636

# STARTTLS protocol is the optional third field
mail.example.com:25 mail.example.com smtp
db.example.com:3306 db.example.com mysql

# Local certificate
/etc/ssl/certs/internal-service.pem
/etc/ssl/certs/web.pem web.example.com
```

Run the audit:

```sh
cert-audit.sh --warning 45 --critical 14 targets.txt
```

Docker host or single-container diagnostics:

```sh
sudo docker-diag.sh
sudo docker-diag.sh app-db --since 6h --tail 500
sudo docker-diag.sh --no-logs -o docker-safe-summary.txt
```

Change timeline:

```sh
sudo what-changed.sh --since "2 days ago"
sudo what-changed.sh --since "2026-01-15 08:00" -o changes.txt
```

Proxmox preflight:

```sh
sudo pve-preflight.sh
sudo pve-preflight.sh --backup-hours 24 --warn-disk 75 --fail-disk 90
```

Patch readiness (after your approved package-index refresh):

```sh
sudo patch-check.sh
sudo patch-check.sh --backup-marker /var/lib/backup/last-success \
  --backup-hours 24 -o patch-readiness.txt
```

## Exit codes and automation

| Script | Exit codes |
| --- | --- |
| `healthcheck.sh`, `docker-diag.sh`, `what-changed.sh` | 0 completed cleanly; 1 completed with warnings; 2 usage error; 3 unavailable |
| `network-diag.sh` | 0 requested chain passed; 1 an essential test failed; 2 usage error; 3 required local capability/report creation unavailable |
| `cert-audit.sh` (monitoring convention) | 0 OK; 1 WARNING; 2 CRITICAL; 3 UNKNOWN or usage error |
| `pve-preflight.sh` | 0 READY; 1 READY WITH CAUTION; 2 DO NOT PROCEED; 3 cannot assess |
| `patch-check.sh` | 0 READY; 1 READY WITH CAUTION; 2 NOT READY; 3 cannot assess |

When automating, capture both the report and the exit code. Exit 1 often means
the script completed successfully but found something that needs human review.

## Operational notes

1. Read the report before acting. These tools gather evidence; they do not
   prove root cause or replace application-specific maintenance procedures.
2. Treat reports as potentially sensitive incident data.
3. Compare repeated reports only when collected with similar privileges and
   dependencies.
4. A successful preflight is a point-in-time result, not a guarantee. Confirm
   backups are restorable and that console/rollback access works.
5. `cert-audit.sh` uses the host trust store unless `--cafile` is supplied.
   Private PKI endpoints require the appropriate CA bundle for successful
   validation.
