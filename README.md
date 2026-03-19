# OpenClaw Monitor

A native macOS menu bar app that keeps an eye on your OpenClaw gateway — checking its health on a configurable schedule and automatically attempting a restart if something goes wrong.

## Download

**[⬇ Download OpenClaw Monitor v1.1.0](https://github.com/ScottPhillips/openclaw-monitor/releases/download/v1.1.0/OpenClawMonitor-1.1.0.dmg)**

> **First launch:** right-click the app → **Open** (the app is not yet notarized, so macOS will warn you the first time).

---

## What it does

OpenClaw Monitor sits in your menu bar and periodically runs OpenClaw diagnostic commands. The icon changes to reflect current health:

| Icon | Meaning |
|------|---------|
| 🟢 OClaw | Everything is healthy |
| 🔴 OClaw | One or more checks failed |
| ⟳ OClaw | Check in progress |
| ⚪ OClaw | Not yet checked |

### Check levels

| Level | Commands run |
|-------|-------------|
| **Basic** (auto) | `openclaw status` |
| **Medium** | + `openclaw gateway status` · `openclaw health --json` |
| **Deep** | + `openclaw status --deep` · `openclaw security audit --deep` |

The periodic auto-check always uses **Basic**. Medium and Deep can be triggered manually from the menu at any time.

### Auto-repair

When a check fails, OpenClaw Monitor tries to fix things automatically:

1. Runs `openclaw gateway restart` in the background
2. Waits 10 seconds, then re-checks
3. If still failing → sends a second notification and highlights **⚠️ Reinstall Gateway…** in the menu
4. You can confirm the reinstall from the menu, which runs `openclaw gateway reinstall`

### Menu layout

```
🟢 OClaw
────────────────────────────────
Status:  OK ✓
Last check:  14:23:05  [basic]
────────────────────────────────
Check Now
Medium Check
Deep Check
Show Last Output…
────────────────────────────────
Restart Gateway…
Reinstall Gateway…
────────────────────────────────
Set Interval…
  Auto-check every 30 min
────────────────────────────────
Quit
```

---

## Install

1. Download the DMG from the link above
2. Open the DMG, drag **OpenClaw Monitor** into your **Applications** folder
3. Right-click → **Open** on first launch (bypasses unsigned-app warning)

To start automatically at login: **System Settings → General → Login Items → +** → select OpenClaw Monitor.

---

## Build from source

**Requirements:** macOS 13+, Swift 5.9+ (Xcode Command Line Tools — no full Xcode needed)

```bash
git clone https://github.com/ScottPhillips/openclaw-monitor.git
cd openclaw-monitor
swift run          # build + launch immediately
```

### Makefile targets

| Command | What it does |
|---------|-------------|
| `make` / `make build` | Debug build |
| `make release` | Release binary only |
| `make bundle` | Release binary → `.app` in `dist/` |
| `make dmg` | `.app` → `.dmg` in `dist/` |
| `make sign IDENTITY="…"` | Code-sign the bundle |
| `make notarize IDENTITY="…" APPLE_ID="…" TEAM_ID="…"` | Notarize with Apple |
| `make clean` | Remove `dist/` and `.build/` |

### Regenerate the app icon

```bash
pip3 install Pillow
python3 scripts/make_icon.py
```

---

## Configuration

The check interval is stored in `UserDefaults` (key `intervalMinutes`, default `30`). Change it via **Set Interval…** in the menu — persists across restarts.

---

## Project layout

```
openclaw-monitor/
├── Package.swift
├── Makefile
├── Sources/OpenClawMonitor/
│   ├── main.swift                # NSApp setup, no-Dock-icon policy
│   ├── AppDelegate.swift         # App lifecycle
│   ├── CommandRunner.swift       # Async Process wrapper (enriched PATH)
│   ├── Monitor.swift             # Health checks, auto-repair, timer
│   └── StatusBarController.swift # Menu bar UI
└── scripts/
    ├── make_icon.py              # Icon generator (requires Pillow)
    ├── AppIcon.icns              # Compiled icon (all sizes 16–1024 px)
    ├── Info.plist                # Bundle metadata
    └── entitlements.plist        # Hardened-runtime entitlements
```

---

## License

MIT — see [LICENSE](LICENSE).
