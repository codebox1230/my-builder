# Android device testing

Testing an APK across many device types without buying any hardware.

## The three layers

| Layer | What it covers | Cost | Latency |
|---|---|---|---|
| **Emulator matrix** (your own runner) | API levels, screen sizes, densities, locales, orientations | **$0**, unlimited | minutes |
| **Firebase Test Lab** | real Pixels/Samsungs + virtual fleet, Robo auto-crawl | 10 virtual + 5 physical tests/day free | ~10 min |
| **Play Pre-Launch Report** | physical device matrix, automatic 5-min crawl | **free, unlimited** with a Play Console upload | hours after upload |

Use them in that order. Emulators catch 90% of issues at zero cost; Firebase
adds real hardware; Pre-Launch adds real hardware per release for free.

## Layer 1: emulator matrix on the GitHub runner

`ubuntu-latest` runners expose `/dev/kvm` (verified), so hardware-accelerated
emulators work. The standard tool is
`reactivecircus/android-emulator-runner`.

```yaml
name: Android Matrix
on:
  workflow_dispatch:
    inputs:
      api_levels: { default: '29,31,34' }
      profiles:  { default: 'pixel_5,pixel_7,nexus_4' }

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        api: [29, 31, 34]
        profile: [pixel_5, pixel_7]
    steps:
      - uses: actions/checkout@v4
        with: { path: app }
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - name: Gradle build
        working-directory: app
        run: ./gradlew assembleDebug
      - name: Emulator test
        uses: reactivecircus/android-emulator-runner@v2
        with:
          api-level: ${{ matrix.api }}
          profile: ${{ matrix.profile }}
          script: ./gradlew connectedDebugAndroidTest
          disable-animations: true
          emulator-options: -no-window -no-snapshot -gpu swiftshader_indirect
```

`fail-fast: false` matters: one profile failing should not abort the rest
of the matrix. `reactivecircus` caches the AVD between runs, which is what
keeps the matrix affordable in minutes rather than hours.

### Profiles worth covering

| Intent | Profile | Why |
|---|---|---|
| modern phone | `pixel_7` | current baseline |
| small/old phone | `nexus_4`, `pixel_2` | low memory, small screen, old API |
| tablet | `nexus_9` | large screen, multi-pane, different densities |
| API floor | `api 21` | your `minSdk` - the most common crash site |
| API latest | `api 34/35` | permission changes, foreground service rules |
| locale / RTL | set `locale` in the action | Arabic, Hindi, and right-to-left layouts |
| no-network / slow | disable radio in the test | app behaviour offline |

### Building the APK

The runner has the JDK preinstalled (Temurin 17 verified). Android SDK
components are not, so install what you need:

```yaml
- uses: android-actions/setup-android@v3
- run: sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"
- run: sdkmanager --licenses <<< "y"
```

Or let Gradle's `gradle/actions/setup-gradle` handle SDK downloads.

## Layer 2: Firebase Test Lab (free quota)

Spark plan: **10 virtual device tests + 5 physical device tests per day**,
resetting at 00:00 PST. After that, Blaze billing applies ($1/hr virtual,
$5/hr physical).

```bash
gcloud firebase test android run \
  --app app/build/outputs/apk/debug/app-debug.apk \
  --devices "pixel_2,nexus_4,nexus_6" \
  --device-os-version "26,29,33" \
  --use-orchestrator \
  --robo-script-path=robo_script.py
```

**Robo** (Robust Test Orchestrator) needs no test code - it crawls your app
autonomously, exercising flows you did not think to script. It is the single
highest-value thing to add to a device matrix.

Free quota is per day, so spread tests: a daily job for the physical slice,
a larger matrix on the emulator layer.

## Layer 3: Play Pre-Launch Report

Upload to a Play Console alpha or beta track and Google runs a free 5-minute
Robo test across a standardized matrix of **physical** devices, reporting
crashes, ANRs, screenshots, and security warnings. It does not consume
Firebase quota and costs nothing beyond the Play Console account fee ($25
one-time).

Best for release candidates: you get real-device coverage without writing a
single test.

## What you cannot get for free

- **Real device breadth at scale.** Firebase's 5 physical tests/day is the
  ceiling without paying.
- **Hardware quirks.** Camera, NFC, biometric sensors, foldables, weird
  OEM ROMs. Only physical devices or a paid farm cover these.
- **Play Store integrity checks.** Only real Play submission.

## Cost comparison

| Option | Devices | Free | Paid rate |
|---|---|---|---|
| Emulator matrix (own runner) | unlimited profiles | $0 | $0 (public repo minutes) |
| Firebase Test Lab | virtual + physical fleet | 10 + 5 per day | $1/hr virtual, $5/hr physical |
| Play Pre-Launch Report | physical matrix | unlimited | $0 (Console fee) |
| AWS Device Farm | physical only | 1,000 min one-time | $0.17/min |
| BrowserStack / Sauce Labs | large real fleet | trial only | subscription |

AWS Device Farm's one-time 1,000 minutes are worth burning on a single
broad sweep (many models, many OS versions) rather than on daily runs.

## Self-hosted alternatives

If you outgrow the free tiers:

- **Waydroid** in containers on your own Azure Spot VMs - a full Android
  container, many in parallel, infra cost only (~$0.02/hr per small VM).
- **STF / DeviceFarmer** - control dozens of USB-connected physical devices
  from a browser. Needs hardware, so it does not solve "avoid buying".

## Practical recipe

```
per commit   emulator matrix, 3 API levels x 3 profiles   $0
per day      Firebase: 5 physical + 5 virtual, with Robo   $0
per release  Play Pre-Launch Report                       $0
```

Total cost: zero, and coverage across virtual and real hardware.
