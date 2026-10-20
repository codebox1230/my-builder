# Workflow reference

Four workflows. All live in `.github/workflows/`.

## Quick matrix

| Workflow | Runner | Access | Gates | Concurrency |
|---|---|---|---|---|
| `build-private.yml` | picker, default `windows-2022` | none - artifacts | none | unlimited |
| `rdp-cloud-vm.yml` | `windows-2022` | RDP + SSH | authorize + environment | one at a time |
| `mac-screen.yml` | `macos-latest` | VNC + SSH | authorize + environment | one at a time (`mac-screen-session`) |
| `android-device-matrix.yml` | `ubuntu-24.04` matrix | none - artifacts | none | one matrix at a time |

All four are triggered with `workflow_dispatch`. `build-private.yml` also
accepts `repository_dispatch` from the private-repo trigger.

---

## build-private.yml

Headless. No desktop, no tunnel, no interactive access. Just clone, build,
upload, clean.

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `repo` | yes | `YOUR_USERNAME/YOUR_PRIVATE_REPO` | **placeholder default - always pass a real `owner/name`** |
| `branch` | no | `main` | tag or SHA also work |
| `runner` | yes | `windows-2022` | `ubuntu-latest` / `windows-2022` / `macos-latest` / `cirun-azure-win` / `cirun-azure-linux` |
| `build_command` | no | empty | empty = auto-detect |
| `artifact_path` | no | empty | empty = auto-locate |

### Auto-detected build commands

| Marker in repo root | Command |
|---|---|
| `*.sln` | `dotnet build <sln> -c Release -o build\output` |
| `*.csproj` | `dotnet build <proj> -c Release -o build\output` |
| `package.json` | `npm ci` (or yarn/pnpm) then `npm run build --if-present` |
| `Cargo.toml` | `cargo build --release` |
| `go.mod` | `go build -o build/output ./...` |
| `pyproject.toml` / `setup.py` | `python -m build` |
| `CMakeLists.txt` | `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release` then `cmake --build build` |
| `Makefile` | `make release`, falling back to `make all` then `make` |
| `*.xcodeproj` / `*.xcworkspace` | `xcodebuild ... -destination 'generic/platform=macOS'` |
| `Package.swift` | `swift build -c release` |

Artifact search order: `build/Release`, `build/release`, `build/output`,
`.build/release`, `dist`, `target/release`, `bin/Release`, `build/`.

### Example

```bash
gh workflow run build-private.yml --repo codebox1230/my-builder \
  -f repo=codebox1230/my-private-app \
  -f branch=main \
  -f runner=ubuntu-latest
```

---

## rdp-cloud-vm.yml

Windows session. Builds first (real CI work), then opens a desktop for
verification.

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `private_repo` | no | empty | empty = skip the build entirely |
| `private_branch` | no | `main` | |
| `build_command` | no | empty | empty = auto-detect |
| `enable_rdp` | yes | `true` | `false` = no desktop |
| `session_hours` | no | `2` | 1-5 |
| `tunnel_type` | no | `tailscale` | or `cloudflare` |

### Steps in order

1. `authorize` - actor check (owner or `ALLOWED_ACTORS`)
2. `protected-cloud` environment gate
3. clone private repo (skipped if `private_repo` empty)
4. build project (skipped if empty)
5. upload artifacts (skipped if empty)
6. enable RDP - NLA + TLS + 128-bit
7. create user `Builder` with `RDP_PASSWORD`
8. enable OpenSSH Server + install `SSH_PUBKEY`
9. install Tailscale, join tailnet
10. verify RDP and SSH ports
11. print connection info
12. hold session open
13. cleanup - always runs

### Access

```
mstsc /v:<tailscale-ip>
username: Builder
password: <RDP_PASSWORD>
```

SSH for agents: `ssh -i ~/.ssh/cloud-builder Builder@<tailscale-ip>`

---

## mac-screen.yml

macOS session. Same shape as the Windows one.

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `private_repo` | no | empty | empty = skip build |
| `private_branch` | no | `main` | |
| `build_command` | no | empty | empty = auto-detect |
| `session_hours` | no | `1` | 1-5 |
| `browser_link` | no | `false` | noVNC over Funnel; known unreliable, off by default |

### Steps in order

1. `authorize` + environment gate
2. clone / build / upload (skipped if empty)
3. Tailscale joins tailnet
4. set `runner` system password via `sysadminctl`
5. enable Screen Sharing (legacy VNC password + Apple auth)
6. enable Remote Login (SSH) + install `SSH_PUBKEY`
7. diagnose offered RFB auth types
8. optional browser link
9. print connection info
10. hold session open
11. cleanup - always runs

### Access

SSH for agents (reliable):
```
ssh -i ~/.ssh/cloud-builder runner@<tailscale-ip>
```

VNC for humans: `<tailscale-ip>:5900`, username `runner`, password
`VNC_PASSWORD` (8 chars max).

---

## android-device-matrix.yml

Headless Android testing. Builds one debug APK, then runs it across a matrix
of emulated devices (hardware profile x API level) on KVM-accelerated
Ubuntu 24.04 runners. No physical devices, no desktop, no tunnel.

### Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `private_repo` | one of | empty | clone + build source |
| `private_branch` | no | `main` | branch, tag, or SHA |
| `apk_url` | one of | empty | prebuilt APK; skips clone and build |
| `apk_path` | no | empty | APK path in repo; empty = auto-locate |
| `build_command` | no | empty | empty = `./gradlew assembleDebug` |
| `api_levels` | no | `29,31,34` | comma-separated |
| `profiles` | no | `pixel_5,pixel_7,nexus_9` | comma-separated AVD profiles |
| `target` | no | `google_apis` | system image target |
| `test_mode` | no | `smoke` | `smoke` or `instrumentation` |
| `java_version` | no | `17` | JDK for the Gradle build |

One of `private_repo` or `apk_url` must be provided.

### Steps in order

1. `setup` - expand API levels x profiles into a matrix (max 12 jobs)
2. `build` - clone the private repo, build the APK once, upload it
3. `emulator` - per matrix cell: boot the AVD on KVM, install, test
4. upload per-device `logcat` and screenshot artifacts (always)

### Test modes

- `smoke` - launch the launcher activity, run a short random UI pass
  (`monkey`), fail on `FATAL EXCEPTION`, `ANR`, or a failed launch. Works
  with any APK, no test code needed.
- `instrumentation` - install the `androidTest` APK and run
  `am instrument`; fails on test failures.

### Example

```bash
gh workflow run android-device-matrix.yml --repo codebox1230/my-builder \
  -f private_repo=codebox1230/my-private-app \
  -f api_levels=29,31,34 \
  -f profiles=pixel_5,pixel_7,nexus_9
```

Useful profiles: `pixel_5`, `pixel_7`, `pixel_fold`, `pixel_tablet`,
`nexus_4`, `nexus_9`. The matrix cap is 12 jobs; API levels and profiles
multiply. See [android-device-testing.md](android-device-testing.md) for the
Firebase/Play layers that add real hardware.

---

## private-repo-trigger/trigger-build.yml (local only)

Copy into each private repo at `.github/workflows/trigger-build.yml`.

| Input | Default |
|---|---|
| `runner` | `ubuntu-latest` |
| `build_command` | empty |

On push to `main`, `master`, `develop`, or `release/*`, it POSTs a
`repository_dispatch` to the public repo. Requires
`PUBLIC_REPO_DISPATCH_TOKEN` in the private repo (a PAT with write access to
the public repo only).

Cost: ~10 seconds of the private repo's monthly minutes per trigger.

---

## Trigger gotchas

**Empty dispatch inputs are replaced by the input default.** Passing
`-f private_repo=""` does not send an empty string - GitHub substitutes the
declared default. Therefore:

- `private_repo` defaults must be `""`
- guards must exclude both `''` and the placeholder string

```yaml
if: ${{ github.event.inputs.private_repo != '' && github.event.inputs.private_repo != 'YOUR_USERNAME/YOUR_PRIVATE_REPO' }}
```

This bug cost one full Windows run that tried to clone
`YOUR_USERNAME/YOUR_PRIVATE_REPO` and failed.

## Validation

Always before pushing:

```bash
python tools/validate-workflows.py
```

YAML-parses every workflow, then syntax-checks each step's script block -
PowerShell via the .NET parser, bash via `bash -n`, with `${{ }}` expressions
stubbed out. Must report 38/38.
