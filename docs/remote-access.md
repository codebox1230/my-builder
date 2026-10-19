# Remote access

Three ways into a session VM, for two audiences: agents (scriptable, no GUI)
and humans (desktop).

## Which protocol for which OS

| OS | Human | Agent |
|---|---|---|
| Windows | RDP (`mstsc`) on 3389 | SSH on 22 |
| macOS | Screen Sharing (VNC) on 5900 | SSH on 22 |
| Linux | VNC/X11 (self-hosted only) | SSH on 22 |

**macOS does not speak RDP.** It ships VNC Screen Sharing. A true RDP server
on macOS means third-party licensed software (NuoRDS) which is pointless on a
VM that dies in an hour. The older `iRAPP` is dead and does not run on Apple
Silicon at all.

## SSH (the agent path)

### Why key auth

Passwords do not suit automation - there is nothing to type them into. The
public key lives in the repo secret `SSH_PUBKEY`; the workflow installs it on
the VM at boot. The private key never leaves `~/.ssh/cloud-builder`.

```powershell
ssh -i "$HOME/.ssh/cloud-builder" -o BatchMode=yes -o StrictHostKeyChecking=no `
    Builder@<windows-tailnet-ip> "hostname"
```

| OS | User | Notes |
|---|---|---|
| Windows | `Builder` | also in Administrators + Remote Desktop Users |
| macOS | `runner` | the standard GitHub runner account |

### Windows: the admin key file

**Members of the Administrators group have their per-user
`authorized_keys` ignored by sshd.** The key must also be installed at:

```
C:\ProgramData\ssh\administrators_authorized_keys
```

with ownership by `NT AUTHORITY\SYSTEM` and inheritance stripped. Without
this, key auth fails closed with a bare `Permission denied (publickey)` and no
hint about the cause. The workflow does both installs.

### Verified working commands

```powershell
# remote exec
ssh -i "$HOME/.ssh/cloud-builder" Builder@<ip> "hostname; whoami"

# file up
scp -i "$HOME/.ssh/cloud-builder" .\file.txt Builder@<ip>:C:/Users/Builder/file.txt

# file down
scp -i "$HOME/.ssh/cloud-builder" Builder@<ip>:C:/Users/Builder/file.txt .\file.txt

# macOS variant
ssh -i "$HOME/.ssh/cloud-builder" runner@<ip> "uname -m"
```

## Finding the IP

```powershell
tailscale status
```

Peer hostnames embed the run ID, which makes correlation trivial:

| Hostname pattern | Meaning |
|---|---|
| `build-verify-<run_id>` | Windows session |
| `mac-builder-<run_id>` | macOS session |

IPs are in the `100.64.0.0/10` range. They change every run - a new VM, a
new tailnet node.

## RDP (Windows, human path)

1. `cloudvm status` (or admin.tailscale.com) for the IP
2. `mstsc /v:<ip>` - Remote Desktop Connection on Windows
3. username `Builder`, password from `RDP_PASSWORD`

Hardening already applied on the VM:

| Setting | Value |
|---|---|
| NLA (`UserAuthentication`) | 1 - credentials required before session start |
| `SecurityLayer` | 2 - TLS handshake |
| `MinEncryptionLevel` | 3 - 128-bit |

## Screen Sharing (macOS, human path)

Any VNC client: TigerVNC, TightVNC, UltraVNC. **Not RealVNC** - its free
tier only connects to RealVNC Server, and a Mac running Apple's VNC server
counts as a third-party server that triggers a paywall.

```
address: <ip>:5900
username: runner
password: <VNC_PASSWORD>   (exactly 8 characters)
```

### The legacy-auth trap

macOS Screen Sharing offers two auth methods:

- **Apple user auth** - username + system account password
- **Legacy VNC auth** - password only, the classic RFB handshake

Standard VNC clients and noVNC only speak the legacy one. `kickstart
-setvncpw` is supposed to set it, but on this image it does not store the
value - verified with both the flag form and a stdin-pipe form. The server
advertises the legacy type but rejects every password.

What does work: set the **system account password** with `sysadminctl` in the
same run, and use the Apple auth path. The legacy path is still advertised
(`RFB` handshake offers `[30,33,36,2,35]`), it just cannot be populated
reliably.

## Browser access (macOS, no client install)

`mac-screen.yml` has an optional `browser_link` mode: noVNC served over
websockify behind a self-signed TLS cert, published via Tailscale Funnel.

```
https://<ip>:6080/vnc.html
```

Status: unreliable. The browser needs `crypto.subtle`, which requires HTTPS -
served with a self-signed cert so Chrome warns before you can proceed. The
Funnel step also stalled in testing and was time-boxed to 60 s. It defaults
to **off**. Use SSH instead.

## Agent workflow

The full loop, with no local compute and no git round-trip for quick
iterations:

```powershell
cloudvm up --os windows --hours 1
cloudvm push .\.env.example C:/Users/Builder/.env --os windows
cloudvm ssh --os windows -c "npm ci"
cloudvm ssh --os windows -c "npm run build"
cloudvm pull C:/workspace/private-code/build\app.js .\app.js --os windows
cloudvm down
```

For longer-lived work, commit and push so the VM clones it - the cloud only
ever sees pushed state.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | key not installed, or Windows admin key file missing | check `administrators_authorized_keys` |
| `Connection timed out` | VM not on the tailnet yet | `tailscale status`, wait for the `up` step |
| `Host key verification failed` | IP reused with a new key | `-o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL` |
| RDP client connects then disconnects | NLA rejected the credentials | confirm `RDP_PASSWORD` matches what the workflow set |
| VNC `Security negotiation failed` | client forced Apple auth | use TigerVNC (standard auth), not RealVNC |
| VNC `Authentication failure` | password mismatch | the password is exactly 8 chars |
