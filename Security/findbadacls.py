#!/usr/bin/env python3
"""
findbadacls.py — Find macOS file ACL entries that reference unresolvable
users or groups (orphaned ACEs, e.g. from deleted accounts or a departed
directory domain).

Reads file paths from stdin (one per line) and prints `chmod -a#` commands
that would remove each bad ACE. Nothing is changed unless you pipe the
output to a shell.

Usage:
  # Review what would be removed
  find /path/to/check | python3 findbadacls.py

  # Apply the fixes (review first!)
  find /path/to/check | python3 findbadacls.py | sudo sh

  # Paths containing newlines: not supported (input is line-delimited)

Requirements:
  macOS (uses libc acl_* and the membership API mbr_uuid_to_id), Python 3.9+.
"""

import os
import shlex
import sys
from ctypes import (
    POINTER, Structure, byref, c_char_p, c_int, c_ubyte, c_uint, c_void_p, cdll,
)
from ctypes.util import find_library

if sys.platform != "darwin":
    print("Error: this script only supports macOS.", file=sys.stderr)
    sys.exit(1)

# ── Load libc (libSystem on macOS) ─────────────────────────────────────
_libc_name = find_library("c")
if not _libc_name:
    print("Error: could not locate libc", file=sys.stderr)
    sys.exit(1)

libc = cdll.LoadLibrary(_libc_name)

# ── ACL constants (from <sys/acl.h>) ──────────────────────────────────
ACL_TYPE_EXTENDED = 0x00000100
ACL_FIRST_ENTRY = 0
ACL_NEXT_ENTRY = -1

# ── libc function signatures ──────────────────────────────────────────
acl_get_file = libc.acl_get_file
acl_get_file.argtypes = [c_char_p, c_int]
acl_get_file.restype = c_void_p

acl_free = libc.acl_free
acl_free.argtypes = [c_void_p]
acl_free.restype = c_int


class ACLEntry(Structure):
    pass


acl_get_entry = libc.acl_get_entry
acl_get_entry.argtypes = [c_void_p, c_int, POINTER(POINTER(ACLEntry))]
acl_get_entry.restype = c_int

acl_get_qualifier = libc.acl_get_qualifier
acl_get_qualifier.argtypes = [POINTER(ACLEntry)]
acl_get_qualifier.restype = POINTER(c_ubyte * 16)

mbr_uuid_to_id = libc.mbr_uuid_to_id
mbr_uuid_to_id.argtypes = [(c_ubyte * 16), POINTER(c_uint), POINTER(c_int)]
mbr_uuid_to_id.restype = c_int


def find_bad_aces(filename: str) -> list[int]:
    """Return indexes of ACEs on `filename` whose qualifier UUID does not resolve."""
    acl = acl_get_file(os.fsencode(filename), ACL_TYPE_EXTENDED)
    if not acl:
        # No extended ACL (or not readable) — nothing to report.
        return []

    bad_aces: list[int] = []
    try:
        entry = POINTER(ACLEntry)()
        uid = c_uint()
        idtype = c_int()
        ace_i = 0

        while True:
            which = ACL_FIRST_ENTRY if ace_i == 0 else ACL_NEXT_ENTRY
            if acl_get_entry(acl, which, byref(entry)) != 0:
                break

            q_uuid = acl_get_qualifier(entry)
            if q_uuid:
                try:
                    if mbr_uuid_to_id(q_uuid.contents, byref(uid), byref(idtype)) != 0:
                        bad_aces.append(ace_i)
                finally:
                    acl_free(q_uuid)

            ace_i += 1
    finally:
        acl_free(acl)

    return bad_aces


def main() -> int:
    exit_code = 0
    for line in sys.stdin:
        path = line.rstrip("\n")
        if not path or not os.path.lexists(path):
            continue
        try:
            bad = find_bad_aces(path)
        except Exception as e:  # noqa: BLE001 — keep scanning other files
            print(f"# Error processing {path!r}: {e}", file=sys.stderr)
            exit_code = 1
            continue

        # Remove highest index first so earlier indexes stay valid.
        for i in sorted(bad, reverse=True):
            print(f"/bin/chmod -a# {i} {shlex.quote(path)}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
