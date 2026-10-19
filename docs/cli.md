# CLI reference

`cli/cloudvm.ps1` - one file, no dependencies beyond `gh`, Tailscale, and
Windows OpenSSH.

## Prerequisites

| Requirement | Check |
|---|---|
| `gh` authenticated as `codebox1230` | `gh api user -q .login` |
| Tailscale installed and joined | `tailscale status` |
| SSH key at `~/.ssh/cloud-builder` | `ssh -i ~/.ssh/cloud-builder -i` |
| Windows OpenSSH client | `C:\Windows\System32\OpenSSH\ssh.exe` (built in) |

Override with env vars: `CLOUDVM_REPO` (default `codebox1230/my-builder`),
`CLOUDVM_KEY` (default `~/.ssh/cloud-builder`).

## Commands

```
cloudvm status                        # recent runs + online session VMs
cloudvm up --os windows|mac [--hours N]
cloudvm ssh [--os windows|mac] [--run ID] [-c "command"]
cloudvm push <local> <remote> [--os ..] [--run ID]
cloudvm pull <remote> <local> [--os ..] [--run ID]
cloudvm down [--os windows|mac]
cloudvm build --repo owner/name [--branch B] [--runner R]
                 [--build-command CMD] [--artifact-path PATH]
```

### status

Shows the last runs from GitHub and the session VMs currently joined to your
tailnet. This is the fastest way to know what is alive.

```
== Recent runs (codebox1230/my-builder) ==
in_progress   Build and Verify (Mac Screen)   ... 38059043548  1m40s

== Online session VMs (tailnet) ==
Hostname                 IP            OS
mac-builder-38059043548  <mac-tailnet-ip> macOS
build-verify-38058478219 <windows-tailnet-ip>  windows
```

### up

Dispatches a session workflow and waits for the VM to join the tailnet.

```powershell
cloudvm up --os windows --hours 2
cloudvm up --os mac --hours 1
```

Polls every 15 s for up to 10 minutes. Prints the resolved IP and user on
success, or tells you which run to inspect on timeout.

### ssh

Without `-c`, opens an interactive shell. With `-c`, runs one command and
exits.

```powershell
cloudvm ssh --os windows -c "npm test"
cloudvm ssh --os mac -c "xcodebuild -version"
cloudvm ssh                          # interactive, auto-detects OS
```

Auto-detect prefers a Windows session if both are online; pass `--os` to be
explicit.

### push / pull

```powershell
cloudvm push .\dist.zip C:/Users/Builder/dist.zip --os windows
cloudvm pull C:/Users/Builder/results.json .\results.json --os windows
cloudvm push ./app.apk /tmp/app.apk --os mac
```

Paths are native to the target OS. Use forward slashes for Windows remote
paths to avoid escaping issues.

### down

Cancels in-progress **session** runs. It matches by workflow name
(`*Mac*` vs `*Cloud VM*`) and never touches headless `build-private` runs.

```powershell
cloudvm down              # all sessions
cloudvm down --os mac     # Mac session only
```

Cancelling destroys the VM immediately and removes the tailnet node. Note:
cancelled runs lose their logs permanently - read the live log first.

### build

Headless build with wait and artifact download.

```powershell
cloudvm build --repo codebox1230/my-private-app --branch main --runner ubuntu-latest
```

Downloads artifacts to `.cloud-build-artifacts/<run-id>/` in the current
directory.

## Design notes

Two non-obvious constraints shaped the implementation:

**No `param()` block.** A declared parameter block makes PowerShell reject
unknown `--flags` before the script body runs, so `--os` / `--run` would fail
with "A positional parameter cannot be found that accepts argument". The
script reads `$args` directly instead.

**Remote commands use `-c "cmd"`, not `-- cmd`.** PowerShell consumes a
bare `--` as its own end-of-parameters marker, so it never reaches `$args`.
The parser treats `--` as a separator and `-c` / `--command` as the
command-taking flag.

Both are invisible in normal use but are the reason a naive rewrite breaks.

## Agent usage

The CLI is the intended interface for an agent driving cloud VMs:

```powershell
cloudvm up --os windows --hours 1
cloudvm push .\.env.example C:/Users/Builder/.env --os windows
cloudvm ssh --os windows -c "npm ci && npm run build"
cloudvm pull C:/workspace/private-code/build/output.js .\.output.js --os windows
cloudvm down
```

No GUI, no password prompts, no local toolchain - every build runs on the
VM.

## Exit codes and failures

| Symptom | Cause | Fix |
|---|---|---|
| `No session VM online.` | no VM joined the tailnet | `cloudvm status`, then `gh run view <id>` |
| `Permission denied (publickey)` | key not installed | Windows admin key file must be in `administrators_authorized_keys` |
| `repository not found` on clone | token lacks the repo | token scope must list that repo |
| `Input required and not supplied: token` | empty `PRIVATE_REPO_TOKEN` | set the secret |
