<div align="center">
  <img src="scripts/AppIcon.icns" width="96" alt="OpenClaw Monitor icon">

  # OpenClaw Monitor

  **A native macOS menu bar app that keeps an eye on your OpenClaw gateway.**

  [![Release](https://img.shields.io/github/v/release/ScottPhillips/openclaw-monitor?style=flat-square)](https://github.com/ScottPhillips/openclaw-monitor/releases/latest)
  [![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square)](https://github.com/ScottPhillips/openclaw-monitor/releases/latest)
  [![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square)](https://swift.org)
  [![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

</div>

---

## ⬇️ Download

**[⬇ Download OpenClawMonitor-1.0.0.dmg](https://github.com/ScottPhillips/openclaw-monitor/releases/download/v1.0.0/OpenClawMonitor-1.0.0.dmg)**

> **First launch:** right-click the app → **Open** (or go to System Settings → Privacy & Security → Open Anyway).
> This is required because the app is not yet notarized with an Apple Developer account.

---

## What it does

OpenClaw Monitor sits quietly in your menu bar and periodically runs OpenClaw diagnostics.
It surfaces problems immediately and attempts automatic recovery — so you find out about a broken gateway before your users do.

### Status at a glance

| Icon | Meaning |
|------|---------|
| 🟢 OClaw | All checks passed |
| 🔴 OClaw | One or more checks failed |
| ⟳ OClaw | Check or repair in progress |
| ⚪ OClaw | Not yet checked |

### Three check levels

| Level | Commands run |
|-------|-------------|
| **Basic** (auto) | `openclaw status` |
| **Medium** | + `openclaw gateway status` · `openclaw health --json` |
| **Deep** | + `openclaw status --deep` · `openclaw security audit --deep` |

The periodic auto-check always uses **Basic**.
Trigger **Medium** or **Deep** manually from the menu when you want more confidence.

### Auto-repair

When a check fails OpenClaw Monitor tries to fix things without bothering you:

1. Runs `openclaw gateway restart` automatically
2. Waits 10 s, then re-checks
3. If still failing → macOS notification + **⚠️ Reinstall Gateway…** is highlighted in the menu
4. Confirm the reinstall and `openclaw gateway reinstall` runs

---

## Installation

1. [Download the DMG](https://github.com/ScottPhillips/openclaw-monitor/releases/latest/download/OpenClawMonitor-1.0.0.dmg)
2. Open the DMG and drag **OpenClaw Monitor** into **Applications**
3. Launch it — it appears in your menu bar with no Dock icon

To have it start automatically at login:
**System Settings → General → Login Items → +** → select *OpenClaw Monitor*

---

## Menu reference

```
🟢 OClaw
─────────────────────────────
Status:  OK ✓
Last check:  14:23:05  [basic]
─────────────────────────────
Check Now                     ← Basic check on demand
Medium Check
Deep Check
Show Last Output…             ← Scrollable output from the last run
─────────────────────────────
Restart Gateway…              ← Manual gateway restart (with confirm dialog)
Reinstall Gateway…            ← Manual reinstall (with confirm dialog)
─────────────────────────────
Set Interval…                 ← Change auto-check cadence (default: 30 min)
  Auto-check every 30 min
─────────────────────────────
Quit
```

---

## Building from source

**Requirements:** macOS 13+, Xcode Command Line Tools (`xcode-select --install`)

```bash
git clone https://github.com/ScottPhillips/openclaw-monitor.git
cd openclaw-monitor

# Run locally (debug build)
swift run

# Build a distributable DMG
pip3 install Pillow          # only needed once, for icon generation
python3 scripts/make_icon.py
make dmg                     # output → dist/OpenClawMonitor-1.0.0.dmg
```

### Makefile targets

| Target | Description |
|--------|-------------|
| `make` | Debug build (fast, for development) |
| `make bundle` | Release binary → `.app` bundle in `dist/` |
| `make dmg` | Bundle → distributable `.dmg` in `dist/` |
| `make clean` | Remove `dist/` and `.build/` |

### Code signing & notarization *(optional)*

Notarized apps open without a security warning on any Mac.

```bash
# Sign
IDENTITY="Developer ID Application: Your Name (TEAMID)" make sign

# Notarize (store credentials once with xcrun notarytool store-credentials first)
IDENTITY="..." APPLE_ID="you@example.com" TEAM_ID="XXXXXXXX" make notarize
```

---

## Project layout

```
openclaw-monitor/
├── Package.swift                    Swift Package manifest (macOS 13+)
├── Makefile                         Build, bundle, DMG, sign, notarize
├── Sources/OpenClawMonitor/
│   ├── main.swift                   NSApplication setup (accessory policy = no Dock icon)
│   ├── AppDelegate.swift            App lifecycle
│   ├── CommandRunner.swift          Async Process wrapper with enriched PATH
│   ├── Monitor.swift                Check logic, auto-repair, interval timer
│   └── StatusBarController.swift   NSStatusItem, NSMenu, dialogs
└── scripts/
    ├── make_icon.py                 Generates AppIcon.icns via Pillow
    ├── AppIcon.icns                 App icon (all sizes)
    ├── Info.plist                   Bundle metadata template
    └── entitlements.plist           Hardened runtime entitlements
```

---

## License

MIT — see [LICENSE](LICENSE).
