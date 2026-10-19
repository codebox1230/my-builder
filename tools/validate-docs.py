"""Validate the docs set: ASCII-only, internal links resolve, no secret values.

Usage: python tools/validate-docs.py
Exit 0 = clean.
"""
import io
import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(BASE, "docs")

# Strings that must never appear in a committed file.
FORBIDDEN = [
    "tskey-auth-",
    "tskey-client-",
    "gho_",
    "ghp_",
    "github_pat_",
    "5WL42!aUvAWiTnlKQ32c",   # RDP password used during testing
    "GPVmX0zo",               # VNC password used during testing
    "hhSYOZ7yNhY0XoaAFyFj",   # earlier VNC password
    "100.107.124.107",        # this PC's tailnet IP
    "100.79.22.14",           # test Windows VM tailnet IP
    "100.94.190.17",          # test Mac VM tailnet IP
    "pgdcsedyp@",             # tailnet domain
    "AAAAC3NzaC1lZDI1NTE5",   # SSH public key body
]

LINK_RE = re.compile(r"\[[^\]]+\]\(([^)#]+?)(?:#[^)]*)?\)")


def main():
    fails = 0
    checked = 0

    targets = []
    for root, dirs, files in os.walk(BASE):
        dirs[:] = [d for d in dirs if d not in (".git", "infra",
                                                "private-repo-trigger")]
        for f in files:
            if f.endswith(".md"):
                targets.append(os.path.join(root, f))

    print("Markdown files found:", len(targets))

    for path in sorted(targets):
        rel = os.path.relpath(path, BASE)
        raw = io.open(path, encoding="utf-8").read()

        # 1. ASCII only
        bad = sorted(set(hex(ord(c)) for c in raw if ord(c) > 127))
        if bad:
            print("FAIL | non-ASCII in", rel, bad)
            fails += 1

        # 2. no secret values
        for token in FORBIDDEN:
            if token in raw:
                print("FAIL | secret-like value in", rel, "->", token[:18])
                fails += 1

        # 3. internal links resolve
        for target in LINK_RE.findall(raw):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            resolved = os.path.normpath(
                os.path.join(os.path.dirname(path), target))
            checked += 1
            if not os.path.exists(resolved):
                print("FAIL | broken link in", rel, "->", target)
                fails += 1

        # 4. no empty doc (a stub with no content is worse than nothing)
        if len(raw.strip()) < 120 and "template" not in rel.lower():
            print("FAIL | suspiciously short doc:", rel)
            fails += 1

    print("Internal links checked:", checked)
    print("Result: %s" % ("FAILURES: %d" % fails if fails else "all clean"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
