#!/usr/bin/env python3
"""
send_email.py — Send a plain-text email, optionally attaching every file in a folder
(e.g. a log directory). Intended for cron jobs / automation.

All configuration comes from environment variables; nothing is hardcoded.

Required:
  SMTP_HOST       SMTP server hostname
  FROM_ADDR       Sender address                     e.g. reports@example.com
  TO_ADDR         Recipient(s), comma-separated      e.g. admin@example.com,ops@example.com

Optional:
  SMTP_PORT       SMTP port (default: 587, or 465 when SMTP_SECURITY=ssl)
  SMTP_SECURITY   starttls (default) | ssl | none
  SMTP_USER       SMTP username (if unset, no AUTH is attempted)
  SMTP_PASSWORD   SMTP password (required when SMTP_USER is set)
  EMAIL_SUBJECT   Subject line   (default: "System Log Report from <hostname>")
  EMAIL_BODY      Body text      (default: short automated-report message)
  LOG_FOLDER      Folder whose files are attached (non-recursive)
  MAX_ATTACH_MB   Skip attachments larger than this (default: 20)

Usage:
  export SMTP_HOST=smtp.example.com FROM_ADDR=reports@example.com TO_ADDR=admin@example.com
  export SMTP_USER=reports@example.com SMTP_PASSWORD='...'   # e.g. from a secrets manager
  LOG_FOLDER=/var/log/myapp python3 send_email.py

Requirements:
  Python 3.8+ (standard library only).

Exit codes: 0 sent, 1 error, 2 configuration error.
"""

import mimetypes
import os
import smtplib
import socket
import ssl
import sys
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from pathlib import Path


def get_config() -> dict:
    env = os.environ.get
    security = env("SMTP_SECURITY", "starttls").strip().lower()
    if security not in ("starttls", "ssl", "none"):
        print(f"Error: SMTP_SECURITY must be starttls, ssl or none (got {security!r})", file=sys.stderr)
        sys.exit(2)

    default_port = "465" if security == "ssl" else "587"
    hostname = socket.gethostname()
    config = {
        "host": env("SMTP_HOST", ""),
        "port": env("SMTP_PORT", default_port),
        "security": security,
        "user": env("SMTP_USER", ""),
        "password": env("SMTP_PASSWORD", ""),
        "from_addr": env("FROM_ADDR", ""),
        "to_addrs": [a.strip() for a in env("TO_ADDR", "").split(",") if a.strip()],
        "subject": env("EMAIL_SUBJECT", f"System Log Report from {hostname}"),
        "body": env("EMAIL_BODY", f"Automated report from {hostname}."),
        "log_folder": env("LOG_FOLDER", ""),
        "max_attach_mb": env("MAX_ATTACH_MB", "20"),
    }

    missing = []
    if not config["host"]:
        missing.append("SMTP_HOST")
    if not config["from_addr"]:
        missing.append("FROM_ADDR")
    if not config["to_addrs"]:
        missing.append("TO_ADDR")
    if config["user"] and not config["password"]:
        missing.append("SMTP_PASSWORD")
    if missing:
        print(f"Error: missing required environment variable(s): {', '.join(missing)}", file=sys.stderr)
        sys.exit(2)

    try:
        config["port"] = int(config["port"])
        config["max_attach_mb"] = float(config["max_attach_mb"])
    except ValueError as e:
        print(f"Error: invalid numeric setting: {e}", file=sys.stderr)
        sys.exit(2)

    if config["security"] == "none" and config["user"]:
        print("Warning: SMTP_SECURITY=none with SMTP_USER set — credentials would be sent "
              "in clear text; refusing.", file=sys.stderr)
        sys.exit(2)

    return config


def attach_files(msg: EmailMessage, folder_path: str, max_mb: float) -> int:
    """Attach all regular files in folder_path to msg. Returns number attached."""
    folder = Path(folder_path)
    if not folder.is_dir():
        print(f"Warning: LOG_FOLDER '{folder_path}' not found or not a directory.", file=sys.stderr)
        return 0

    max_bytes = int(max_mb * 1024 * 1024)
    attached = 0
    for f in sorted(folder.iterdir()):
        if not f.is_file():
            continue
        try:
            size = f.stat().st_size
            if size > max_bytes:
                print(f"Warning: skipping '{f.name}' ({size} bytes > {max_mb} MB limit)", file=sys.stderr)
                continue
            ctype, encoding = mimetypes.guess_type(f.name)
            if ctype is None or encoding is not None:
                ctype = "application/octet-stream"
            maintype, subtype = ctype.split("/", 1)
            msg.add_attachment(f.read_bytes(), maintype=maintype, subtype=subtype, filename=f.name)
            attached += 1
            print(f"  Attached: {f.name}")
        except OSError as e:
            print(f"Warning: could not attach '{f.name}': {e}", file=sys.stderr)

    return attached


def send_email(config: dict) -> None:
    msg = EmailMessage()
    msg["From"] = config["from_addr"]
    msg["To"] = ", ".join(config["to_addrs"])
    msg["Subject"] = config["subject"]
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid()

    body = config["body"]
    if config["log_folder"]:
        # Body must be set before attachments are added.
        msg.set_content(body + "\n\n(see attachments)")
        n = attach_files(msg, config["log_folder"], config["max_attach_mb"])
        print(f"{n} file(s) attached.")
    else:
        msg.set_content(body)

    context = ssl.create_default_context()
    print(f"Connecting to {config['host']}:{config['port']} ({config['security']}) ...")
    if config["security"] == "ssl":
        server = smtplib.SMTP_SSL(config["host"], config["port"], context=context, timeout=60)
    else:
        server = smtplib.SMTP(config["host"], config["port"], timeout=60)

    with server:
        server.ehlo()
        if config["security"] == "starttls":
            server.starttls(context=context)
            server.ehlo()
        if config["user"]:
            server.login(config["user"], config["password"])
        server.send_message(msg, from_addr=config["from_addr"], to_addrs=config["to_addrs"])

    print(f"Email sent to {', '.join(config['to_addrs'])}")


def main() -> int:
    cfg = get_config()
    try:
        send_email(cfg)
    except smtplib.SMTPAuthenticationError as e:
        print(f"SMTP auth failed: {e}", file=sys.stderr)
        return 1
    except smtplib.SMTPException as e:
        print(f"SMTP error: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"Connection error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
