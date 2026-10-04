# macOS User Data Cleanup Script

`clean_user_data.sh` clears user data on macOS to prepare a loaner or shared laptop for the next person.

## What it does

- Clears user caches from `~/Library/Caches/`
- Clears browser histories, cookies, and local storage for Safari, Chrome, and Firefox
- Clears general web data from `~/Library/Cookies/` and `~/Library/WebKit/`
- Clears user logs from `~/Library/Logs/`
- Clears recent documents, applications, and servers from Finder
- Clears saved application states (may affect app resume behavior)
- Empties the Trash
- Removes all files from the Downloads folder
- Removes all files from the Desktop

## Usage

1. Quit all browsers and applications.
2. Open Terminal and change to the directory containing the script.
3. Preview what would be deleted:
   ```bash
   ./clean_user_data.sh --dry-run
   ```
4. Run it (you will be asked to type `YES` to confirm):
   ```bash
   ./clean_user_data.sh
   ```
   Use `--yes` to skip the prompt when running unattended.

## Warning

This script permanently deletes data. Back up any important files before running. It removes all files from Downloads and Desktop and clears browser data, logs, caches, and more. It only affects the user who runs it and refuses to run as root.

## Requirements

- macOS
- Bash

## Troubleshooting

- Permission errors: run as the user whose data you want to clear (not with `sudo`).
- Some browser data might require closing the browser first.
- After running, restart browsers and applications so changes take effect.
- If applications behave strangely after clearing saved states, you may need to reconfigure them.
