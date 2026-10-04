# macOS Workstation Toolkit

Four standalone, user-level zsh scripts for macOS Monterey 12 or later. They do
not request administrator credentials and do not install software.

## Quick start

In Terminal, change to this folder and make the scripts executable once:

```zsh
chmod +x health-check.zsh app-repair.zsh security-audit.zsh log-collector.zsh
```

Every script supports `--help`.

## Health check

Runs a fast, read-only review of the operating system, storage, memory, battery,
core security controls, MDM status, network route, and update schedule.

```zsh
./health-check.zsh
./health-check.zsh --full --output "$HOME/Desktop/health-report.txt"
```

`--full` adds DNS, internet, and available-update checks. It can take several
minutes. Exit code `0` means no warnings; `1` means attention is recommended.

## App repair

Quits one app and moves its standard caches and saved state into a timestamped,
recoverable backup. It does not clear documents, cookies, keychains, account
databases, or group containers.

Preview the action first:

```zsh
./app-repair.zsh --app /Applications/Slack.app --dry-run
```

Perform the repair:

```zsh
./app-repair.zsh --app /Applications/Slack.app
```

For a deeper reset, add `--reset-preferences`. That option also backs up the
app's plist preferences, so it may reset user-facing settings. Backups are kept
under `~/Library/Application Support/Workstation Repair/Backups/` and can be
restored manually if needed.

For unattended use, specify a validated bundle identifier and `--yes`. Test the
exact app first; some vendors store caches in nonstandard or group-container
locations that this deliberately conservative script does not touch.

## Security audit

Checks FileVault, SIP, Gatekeeper, firewall, automatic update settings, automatic
login, screen-lock timing, MDM enrollment, local admin membership, common remote
services, and XProtect package information.

```zsh
./security-audit.zsh
./security-audit.zsh --require-mdm --check-updates
```

Exit codes are suitable for management tooling:

- `0`: no findings
- `1`: warnings or incomplete checks
- `2`: one or more failures

This is a baseline audit, not a compliance certification. Configuration profiles
and the MDM console remain authoritative because managed settings are not always
fully visible through local preference files.

## Log collector

Creates a redacted ZIP containing a limited system snapshot and recent unified
error/fault logs. The default window is 30 minutes.

```zsh
./log-collector.zsh --output "$HOME/Desktop"
./log-collector.zsh --minutes 60 --process Slack --include-crash-reports --output "$HOME/Desktop"
```

The collector does not gather documents, browser history, cookies, keychain
contents, messages, email stores, or a full `sysdiagnose`. It redacts common
identifiers, but no automatic filter is perfect. Review the ZIP before sharing.

## Deployment notes

- Run these scripts as the signed-in user, not as root.
- Code-sign and notarize a packaged version if distributing outside your MDM.
- Adjust warning thresholds and controls to match your own policy.
- Test on each macOS version and app build used in your environment.
- For automated collection, obtain user notice/consent and define retention and
  access controls for the resulting archives.
