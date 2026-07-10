# OpenClaw Monitor

A native macOS menu bar app that keeps an eye on your OpenClaw gateway — checking its health on a configurable schedule and automatically attempting a restart if something goes wrong.

## Download

**[⬇ Download OpenClaw Monitor v1.2.1](https://github.com/ScottPhillips/openclaw-monitor/releases/download/v1.2.1/OpenClawMonitor-1.2.1.dmg)**

> **macOS security warning:** newer versions of macOS may show "damaged and should be moved to Trash" for unsigned apps downloaded from the internet. The DMG is fine — this is Gatekeeper blocking it. See the install instructions below for the fix.

---

## What it does

OpenClaw Monitor sits in your menu bar and periodically runs OpenClaw diagnostic commands. The icon reflects current health at a glance — and shows channel counts when data is available:

| Icon | Meaning |
|------|---------|
| `🟢 3/4` | Gateway healthy · 3 of 4 channels OK |
| `🟢 OClaw` | Gateway healthy (no channel data yet) |
| `🔴 OClaw` | One or more checks failed |
| `⟳ OClaw` | Check in progress |
| `⚪ OClaw` | Not yet checked |
| `⚠️ OClaw` | `openclaw` not found on PATH |

### Check levels

| Level | Commands run |
|-------|-------------|
| **Basic** (auto) | `openclaw gateway probe` · `openclaw health --json` · Dashboard ping · `openclaw channels status --probe` |
| **Deep** (manual) | Basic + `openclaw status --deep` · `openclaw security audit --deep` |

### Auto-repair

When a check fails, OpenClaw Monitor tries to fix things automatically:

1. Runs `openclaw gateway restart` in the background
2. Waits 10 seconds, then re-checks
3. If still failing → sends a notification and highlights **⚠️ Reinstall Gateway…** in the menu
4. You can confirm the reinstall from the menu, which runs `openclaw gateway reinstall`

Notifications are deduplicated — you won't be spammed if the same failure persists across multiple scheduled checks. Use **Mute Notifications for 1 hr** from the menu during planned maintenance.

### Menu layout

```
🟢 3/4
────────────────────────────────
Status:  OK ✓
Last check:  14:23:05  [basic]
  Healthy since 2:30 PM
────────────────────────────────
🟢 Channels ▶
  🟢  iMessage
  🟢  Telegram
────────────────────────────────
Basic Check
Deep Check
Show Last Output…
Show History…
────────────────────────────────
OpenClaw Server ▶
  Restart Gateway…
  Stop Gateway…
  ──
  Reinstall Gateway…
  ──
  Open Control Panel
  Open Gateway Log
────────────────────────────────
Set Interval…
  Auto-check every 30 min
🔕 Mute Notifications for 1 hr
────────────────────────────────
Check For Update…
About OpenClaw Monitor…
────────────────────────────────
Quit
```

When a check fails, the failing check names appear directly in the menu:

```
Status:  Error ✗
  ↳ RPC probe, Channels
```

---

## Install

1. Download the DMG from the link above
2. Open the DMG, drag **OpenClaw Monitor** into your **Applications** folder
3. Open **Terminal** and run:
   ```bash
   xattr -cr "/Applications/OpenClaw Monitor.app"
   ```
4. Launch the app normally — macOS will no longer block it

> **Why is this needed?** macOS Gatekeeper quarantines files downloaded from the internet. Without a paid Apple Developer ID, the only way to clear the quarantine flag is with `xattr -cr`. This is a one-time step.

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

The check interval is stored in `UserDefaults` (key `intervalMinutes`, default `30`). Change it via **Set Interval…** in the menu — the dropdown offers 5, 15, 30, 60, or 120 minute presets, and the setting persists across restarts.

---

## Project layout

```
openclaw-monitor/
├── Package.swift
├── Makefile
├── Sources/OpenClawMonitor/
│   ├── main.swift                # NSApp setup, no-Dock-icon policy
│   ├── AppDelegate.swift         # App lifecycle
│   ├── CommandRunner.swift       # Async Process wrapper (login-shell PATH)
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
