# Decision log

Why the system works the way it does. Each entry records a decision, the
alternatives, and the evidence - most of it earned by failure.

---

## D1: Public repo as the orchestration point

**Decision.** Workflows live in a public repo; the code being built lives in
private repos and is cloned at runtime.

**Alternatives.** A private repo hosting the workflows (capped minutes); a
self-hosted runner registered to a private repo (platform fee, now
postponed).

**Why.** Public repos get unlimited free Actions minutes and free artifact
and package storage. The workflow files contain no source. The private repo
is never exposed - only a token bridges them.

**Evidence.** Live runs against `octocat/Hello-World` completed green using
`PRIVATE_REPO_TOKEN` with the public repo.

---

## D2: Tailscale for tunnel, not ngrok/cloudflared/tmate

**Decision.** WireGuard mesh via Tailscale, with an ephemeral auth key.

**Alternatives.** `tmate` / `upterm` (terminal sharing; the action names are
explicitly on abuse-scanning lists), `ngrok` (relay domains are blacklisted),
Cloudflare quick tunnels (`trycloudflare.com` is watched), a public IP on
the VM (costs ~$3.65/month per static IP, exposes 22/3389 to scanners,
breaks on Spot eviction because the IP changes).

**Why.** Plain HTTPS to an ordinary-looking domain, outbound only, no relay
in the middle, no public inbound surface. Peer hostnames embed the run ID,
which makes identification trivial.

**Evidence.** Every session joined the tailnet and was reachable over SSH
from this PC with zero inbound exposure.

---

## D3: Cloud compute only, never the local machine

**Decision.** All builds run on cloud VMs. The local machine only edits text
and runs git.

**Why.** The stated goal was no local CPU spikes, no fan noise, no battery
drain. It also removes toolchain version drift between machines.

**Evidence.** `ubuntu-latest` ran a full build; `/dev/kvm` confirmed
hardware virtualisation is available for Android emulator work.

---

## D4: Build first, then open a desktop

**Decision.** The build runs before the RDP/VNC session opens, and cleanup
runs unconditionally afterwards.

**Why.** A workflow that only idles on a GUI is indistinguishable from
general-purpose compute abuse. A workflow that compiles code, uploads
artifacts, and exits is exactly what CI is for. The desktop is for
*verification*.

**Evidence.** Both session workflows run the build steps first, gate the
desktop behind an `enable_rdp` / `browser_link` input, and clean up with
`if: always()`.

---

## D5: `workflow_dispatch` only for session workflows

**Decision.** No `pull_request` or `pull_request_target` triggers anywhere.

**Why.** A public repo with a self-hosted runner is a remote code execution
surface: anyone can fork it and open a PR whose workflow runs on the
runner. `workflow_dispatch` cannot be triggered by a fork, and secrets are
never injected into fork runs.

**Reinforced by.** The `authorize` job checks `github.actor` against the
owner and `ALLOWED_ACTORS`, and the `protected-cloud` environment can require
manual approval.

---

## D6: SSH over RDP/VNC for agents

**Decision.** Agents use SSH (`ssh`, `scp`) with ed25519 key auth. Humans use
RDP on Windows and Screen Sharing on macOS.

**Why.** RDP and VNC are GUI protocols - no scriptable output, no file
transfer. SSH is text in, text out, and works identically on every OS. Key
auth means no password to type into a non-interactive prompt.

**Evidence.** Remote exec and file transfer verified in both directions on
both Windows and macOS from this PC.

---

## D7: Key auth installed to two locations on Windows

**Decision.** The public key goes into both
`C:\Users\Builder\.ssh\authorized_keys` **and**
`C:\ProgramData\ssh\administrators_authorized_keys` (SYSTEM-owned,
inheritance stripped).

**Why.** OpenSSH on Windows silently ignores the per-user file for accounts
in the Administrators group. `Builder` is an admin. Without the machine-wide
file, key auth fails closed with no diagnostic.

**Evidence.** Live failure first (`Permission denied (publickey)` with only
the user file installed), then success immediately after adding the admin
file.

---

## D8: `PRIVATE_REPO_TOKEN` is currently a temporary broad OAuth token

**Decision.** Documented as temporary and over-scoped, pending replacement
with a fine-grained PAT.

**Why.** It works and it is encrypted, but it carries `repo` + `workflow`
scopes across the whole account. Least privilege says scope it to
Contents:Read on the specific private repos.

**Status.** Outstanding. Not yet replaced.

---

## D9: `VNC_PASSWORD` is exactly 8 characters

**Decision.** Generate an 8-character password for the VNC path.

**Why.** The classic RFB VNC authentication truncates keys to 8 bytes. An
18-character password silently fails to authenticate for standard clients.
This was found by reading the protocol limit, after the long password had
already failed repeatedly.

**Evidence.** Classic VNCAuth (type 2) is advertised in the handshake;
standard VNC clients rejected a long password.

---

## D10: macOS legacy VNC password cannot be set reliably

**Decision.** Ship the macOS session with Apple user auth (system password
via `sysadminctl`) as the working path. Do not depend on the legacy VNC
password.

**Why.** `kickstart -setvncpw` does not persist the value on this image -
tried with the `-vncpw` flag form and with a stdin pipe. The server still
advertises the legacy type but rejects every password. Fighting it further
is wasted effort; SSH works perfectly on macOS and is what agents use.

**Evidence.** Multiple runs, both invocation forms, plus a direct RFB
handshake probe showing `[30,33,36,2,35]` offered.

---

## D11: `protected-cloud` has no reviewers yet

**Decision.** Leave the environment unreviewed while iterating; document it
as test mode.

**Why.** Required reviewers would block every session during development.
But it means the environment gate is currently inert - documented so it is
not mistaken for a production control.

**Status.** Outstanding. Add a reviewer before relying on it.

---

## D12: Browser access exists but is off by default

**Decision.** Keep `browser_link` in `mac-screen.yml` as an option,
defaulting to `false`.

**Why.** noVNC over websockify behind a self-signed cert is genuinely
nice - no client install. But it needs HTTPS (browser `crypto.subtle`
requires it), and the Tailscale Funnel step stalled in testing. SSH is
reliable and already available, so the browser path is opt-in.

---

## D13: One Mac session at a time

**Decision.** `concurrency: mac-screen-session` with
`cancel-in-progress: false`.

**Why.** Two simultaneous idle GUI sessions on a public repo is the exact
shape of the abuse pattern automated detection looks for. One at a time
also keeps the operator's view of "what is running" simple. Windows uses the
same pattern.

---

## D14: The local working copy is the git repo

**Decision.** `C:\Users\prati\public-repo-builder` is a clone with
`main` tracking `origin/main`. No separate staging directory.

**Why.** A throwaway staging clone in `Temp\opencode` was wiped twice by
another process's cleanup, losing uncommitted work twice. The canonical
local path is stable and self-documenting.

---

## D15: `infra/` and `private-repo-trigger/` are never published

**Decision.** Keep both local-only and enforce with `.gitignore`.

**Why.** `infra/` targets your Azure subscription. `private-repo-trigger/`
is meant to be copied into *your private* repos, not published in a public
one. Both would leak infrastructure details if pushed.

---

## D16: Validation is a script, not a checklist

**Decision.** `tools/validate-workflows.py` parses every YAML file and
syntax-checks every embedded script block (PowerShell via the .NET parser,
bash via `bash -n`).

**Why.** A YAML syntax error in a workflow means GitHub silently ignores the
file - the workflow just vanishes from the Actions tab. A PowerShell parse
error only surfaces after a 5-minute VM boot. Catching both locally turns a
5-minute feedback loop into a 2-second one.

**Evidence.** 65/65 blocks pass at time of writing (29/29 before the Android
matrix workflow was added, 38/38 before the Android screen session was added).

---

## D17: Publish adbd on the tailnet instead of tunnelling it

**Decision.** `android-screen.yml` keeps adbd on the runner's loopback. The
operator republishes it on the VM's tailnet interface with `socat`, and both
scrcpy and a phone browser connect to that address directly. SSH remains the
control path for commands.

**Why.** An SSH port-forward of the ADB socket and the scrcpy video port
stalls video while the process stays alive - the screen looks frozen but
input still lands, which sends debugging in the wrong direction. A single
`socat` listener has no tunnel state to renegotiate and survives adb
reconnects. It also costs nothing to leave running for the life of the VM,
and the device still never touches the public internet - only tailnet peers
can reach it.

**Cost.** `socat` is not preinstalled, so the setup installs it with
`apt-get`. The listener dies with the runner, which is the desired lifetime.

**Alternative rejected.** Reverse-forwarding the scrcpy port with
`ssh -R 27183:127.0.0.1:27183`: video stalls while audio and input continue,
and the tunnel needs manual recovery after every adb reconnect.
