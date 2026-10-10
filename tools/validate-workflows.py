"""Validate all workflow YAML files: parse + per-step shell syntax check.

PowerShell blocks: parsed with the .NET parser (Windows only).
Bash blocks: checked with `bash -n` (Git for Windows provides bash).
`${{ }}` GitHub expressions are replaced with dummies before parsing.

Usage: python tools/validate-workflows.py
Exit code 0 = all green.
"""
import io
import os
import re
import subprocess
import sys
import tempfile

import yaml

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.gettempdir()

WORKFLOWS = [
    ".github/workflows/build-private.yml",
    ".github/workflows/rdp-cloud-vm.yml",
    ".github/workflows/mac-screen.yml",
    "private-repo-trigger/.github/workflows/trigger-build.yml",
    ".cirun.yml",
]


def clean_gh_expr(script):
    return re.sub(r"\$\{\{.*?\}\}", "__GH_EXPR__", script, flags=re.DOTALL)


def find_bash():
    for candidate in (
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\Program Files (x86)\\Git\\bin\\bash.exe",
        "bash",
    ):
        try:
            subprocess.run([candidate, "--version"], capture_output=True,
                           timeout=30)
            return candidate
        except Exception:
            continue
    return None


def check_powershell(label, script):
    path = os.path.join(TMP, "wfcheck.ps1")
    io.open(path, "w", encoding="utf-8", newline="\n").write(script)
    ps = ("$e=$null;$t=$null;"
          "[void][System.Management.Automation.Language.Parser]::ParseFile("
          "'%s',[ref]$t,[ref]$e);"
          "if($e.Count -gt 0){$e|%%{'ERR: '+$_.Message}}else{'PS-OK'}"
          % path.replace("'", "''"))
    out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive",
                          "-Command", ps],
                         capture_output=True, text=True, timeout=60)
    combined = (out.stdout + out.stderr).strip()
    return ("PS-OK" in combined,
            "syntax OK" if "PS-OK" in combined else combined)


def check_bash(bash_exe, label, script):
    path = os.path.join(TMP, "wfcheck.sh")
    io.open(path, "w", encoding="utf-8", newline="\n").write(script)
    out = subprocess.run([bash_exe, "-n", path], capture_output=True,
                         text=True, timeout=60)
    combined = (out.stdout + out.stderr).strip()
    return (out.returncode == 0,
            "syntax OK" if out.returncode == 0 else combined)


def main():
    bash_exe = find_bash()
    total = 0
    fails = 0
    for rel in WORKFLOWS:
        path = os.path.join(BASE, rel)
        if not os.path.exists(path):
            print("SKIP (missing):", rel)
            continue
        raw = io.open(path, encoding="utf-8").read()
        non_ascii = sorted(set(hex(ord(c)) for c in raw if ord(c) > 127))
        if non_ascii:
            print("FAIL | non-ASCII chars in", rel, non_ascii)
            fails += 1
        try:
            data = yaml.safe_load(raw)
        except Exception as e:
            print("FAIL | YAML parse", rel, e)
            fails += 1
            continue
        print("YAML OK:", rel)
        for job_name, job in (data.get("jobs") or {}).items():
            runs_on = str(job.get("runs-on", ""))
            default_shell = ("pwsh" if "windows" in runs_on.lower()
                             else "bash")
            for step in job.get("steps", []):
                if "run" not in step:
                    continue
                shell = str(step.get("shell", default_shell)).lower()
                label = "%s | %s | %s" % (
                    rel.split("/")[-1], job_name,
                    step.get("name", "?")[:45])
                body = clean_gh_expr(step["run"])
                total += 1
                if "powershell" in shell or shell in ("pwsh", "ps1"):
                    ok, msg = check_powershell(label, body)
                else:
                    if not bash_exe:
                        print("SKIP (no bash):", label)
                        total -= 1
                        continue
                    ok, msg = check_bash(bash_exe, label, body)
                print(("PASS" if ok else "FAIL"), "|", label)
                if not ok:
                    fails += 1
                    print("     ", msg.replace("\n", " / "))
    print("Result: %d/%d passed" % (total - fails, total))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
