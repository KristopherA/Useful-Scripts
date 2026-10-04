# Useful Scripts

Some scripts to do specific tasks. Many are simple one-liners to accomplish a task. Trying not to reinvent the wheel.

All site-specific values (hosts, subnets, paths, servers, tokens) are config variables at the top of each script, overridable with environment variables. Read a script before running it, and test on a non-production machine first. Scripts marked (destructive) delete or change data.

## macOS

| Script | Purpose |
|---|---|
| `macOS/battery-health.sh` | Battery health, cycle count, charge state (Intel and Apple Silicon) |
| `macOS/disk-cleanup.sh` | Clear caches, logs, Trash, old crash reports (destructive; `--include-archives` for device backups) |
| `macOS/dock_clean_v2.sh` | Reset the Dock to a configured app list (`DOCK_APPS`) |
| `macOS/force-smb23.sh` | Force SMB 2/3 via `/etc/nsmb.conf` |
| `macOS/macos-compliance-check.sh` | Check FileVault, firewall, screensaver lock, updates, etc. against configurable thresholds |
| `macOS/map-network-shares.sh` | Mount SMB shares from a `network-shares.conf` list |
| `macOS/slow-mac-triage.sh` | CPU, memory pressure, swap, disk I/O, panics, crashes |
| `macOS/startup-items-audit.sh` | Audit LaunchAgents/Daemons, login items, kexts and signatures |
| `macOS/upgrade-readiness.sh` | Check a Mac is ready for a major macOS upgrade |
| `macOS/user-offboard.sh` | Archive and disable a local user (destructive; `--dry-run`) |
| `macOS/wifi-diagnostics.sh` | Wi-Fi signal, DNS, gateway and latency checks |
| `macOS/loaner-cleaning/` | Wipe user data on loaner Macs (destructive; `--dry-run`) |
| `macOS/macos-workstation-toolkit/` | health-check, security-audit, log-collector, app-repair (zsh) |

## Linux

| Script | Purpose |
|---|---|
| `Linux/linux-server-audit.sh` | Broad security/config audit of a Debian/Ubuntu server |
| `Linux/linux-diagnostic-scripts/` | healthcheck, cert-audit, docker-diag, network-diag, patch-check, pve-preflight, what-changed |
| `Linux/Monitoring/network-picture.sh` | Snapshot of interfaces, routes, sockets, DNS |
| `Linux/Monitoring/proc-network-picture.sh` | Same, read straight from `/proc` (no extra tools) |
| `Linux/Monitoring/log-disk-space-to-graylog.sh` | Send disk usage to a Graylog GELF input |
| `Linux/setup/linux-hardening.sh` | Baseline hardening: SSH, UFW, tmpfs `/tmp`, auto-updates |
| `Linux/setup/apt-repos.sh` | Add Docker/Elastic/Graylog repos with `signed-by` keyrings |
| `Linux/setup/configure-unattended-upgrades.sh` | Configure unattended-upgrades |
| `Linux/setup/install-docker.sh` | Install Docker Engine + Compose plugin |
| `Linux/setup/install-graylog-sidecar.sh` | Install and register Graylog Sidecar (optional Filebeat) |
| `Linux/setup/set-static-ip.sh` | Set a static IP with netplan (with backup/rollback) |

## Security

| Script | Purpose |
|---|---|
| `Security/cert_check.sh`, `Security/Cert-Check.ps1` | Validate a live endpoint or cert file: chain, hostname, expiry, key match |
| `Security/persistence-check.sh` | macOS persistence hunt (launchd, cron, login items, kexts) |
| `Security/ssh-keys-audit.sh` | macOS SSH key and sshd config audit |
| `Security/findbadacls.py` | Find macOS files with unusual ACLs |

## Windows

| Script | Purpose |
|---|---|
| `Windows/Find-ServiceAccounts.ps1` | Find likely service accounts in AD (SPNs, naming, password age) |

## Python

| Script | Purpose |
|---|---|
| `Python/send_email.py` | Send an email with attachments; SMTP settings from environment variables |

Example: `GRAYLOG_HOST=graylog.example.com ./Linux/Monitoring/log-disk-space-to-graylog.sh` sets one config value for a single run.
