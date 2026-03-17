# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Monitor — build & packaging Makefile
#
# Targets
#   make            → build (debug, for local dev)
#   make release    → build release binary only
#   make bundle     → build release + create .app bundle in dist/
#   make dmg        → bundle + create distributable .dmg in dist/
#   make clean      → remove dist/ and .build/
#
# Signed / notarized (requires Apple Developer account)
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" make sign
#   IDENTITY="..." APPLE_ID="you@example.com" TEAM_ID="XXXXXXXX" make notarize
#
# ─────────────────────────────────────────────────────────────────────────────

APP_NAME     := OpenClaw Monitor
BINARY_NAME  := OpenClawMonitor
BUNDLE_ID    := com.openclaw.monitor
VERSION      := 1.0.0
BUILD_NUMBER := 1

# Paths
SCRIPTS_DIR  := scripts
DIST_DIR     := dist
APP_BUNDLE   := $(DIST_DIR)/$(APP_NAME).app
DMG_NAME     := $(BINARY_NAME)-$(VERSION).dmg
DMG_PATH     := $(DIST_DIR)/$(DMG_NAME)
BINARY_SRC   := .build/release/$(BINARY_NAME)

# Signing (set via env or command line)
IDENTITY     ?=
APPLE_ID     ?=
TEAM_ID      ?=
KEYCHAIN_PROFILE ?= openclaw-notary

.PHONY: all build release bundle dmg sign notarize clean help

all: build

# ── Dev build (debug) ─────────────────────────────────────────────────────────
build:
	swift build

# ── Release binary ────────────────────────────────────────────────────────────
release:
	swift build -c release

# ── .app bundle ───────────────────────────────────────────────────────────────
bundle: release
	@echo "→ Creating app bundle at $(APP_BUNDLE)"
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"

	# Binary
	@cp "$(BINARY_SRC)" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"

	# Info.plist — stamp in version + build number
	@cp "$(SCRIPTS_DIR)/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	    "$(APP_BUNDLE)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" \
	    "$(APP_BUNDLE)/Contents/Info.plist"

	# App icon (optional — copy your .icns here if you have one)
	@if [ -f "$(SCRIPTS_DIR)/AppIcon.icns" ]; then \
	    cp "$(SCRIPTS_DIR)/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; \
	    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
	        "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true; \
	    echo "  ✓ Icon included"; \
	fi

	@echo "  ✓ Bundle ready: $(APP_BUNDLE)"

# ── DMG installer ─────────────────────────────────────────────────────────────
dmg: bundle
	@echo "→ Creating DMG at $(DMG_PATH)"
	@rm -f "$(DMG_PATH)"

	# Staging area: app + /Applications symlink (for drag-install UX)
	$(eval TMP := $(shell mktemp -d))
	@cp -R "$(APP_BUNDLE)" "$(TMP)/"
	@ln -s /Applications "$(TMP)/Applications"

	@hdiutil create \
	    -volname "$(APP_NAME)" \
	    -srcfolder "$(TMP)" \
	    -ov -format UDZO \
	    -imagekey zlib-level=9 \
	    "$(DMG_PATH)" > /dev/null

	@rm -rf "$(TMP)"
	@echo ""
	@echo "✓ Done! Distribute this file:"
	@echo "  $(DMG_PATH)"
	@echo ""
	@echo "ℹ️  Unsigned DMG — recipients must right-click → Open on first launch."
	@echo "   Run 'make sign' then 'make notarize' to remove that prompt."

# ── Code sign (requires Developer ID, skip for team-internal use) ─────────────
sign: bundle
	@if [ -z "$(IDENTITY)" ]; then \
	    echo "ERROR: Set IDENTITY= to your Developer ID certificate."; \
	    echo "  Example: IDENTITY=\"Developer ID Application: Jane Smith (ABCD1234)\" make sign"; \
	    exit 1; \
	fi
	@echo "→ Code signing with: $(IDENTITY)"
	codesign \
	    --force --deep \
	    --sign "$(IDENTITY)" \
	    --options runtime \
	    --entitlements "$(SCRIPTS_DIR)/entitlements.plist" \
	    "$(APP_BUNDLE)"
	@echo "→ Creating signed DMG"
	@$(MAKE) dmg
	codesign --sign "$(IDENTITY)" "$(DMG_PATH)"
	@echo "✓ Signed DMG: $(DMG_PATH)"

# ── Notarize (Apple-blessed — required for Gatekeeper-clean distribution) ─────
#
# Prerequisites:
#   1. Apple Developer account ($99/year) with Developer ID Application cert
#   2. Store credentials once:
#        xcrun notarytool store-credentials $(KEYCHAIN_PROFILE) \
#            --apple-id $(APPLE_ID) --team-id $(TEAM_ID) --password <app-specific-password>
#
notarize: sign
	@if [ -z "$(IDENTITY)" ] || [ -z "$(APPLE_ID)" ] || [ -z "$(TEAM_ID)" ]; then \
	    echo "ERROR: Set IDENTITY=, APPLE_ID=, and TEAM_ID= before notarizing."; \
	    exit 1; \
	fi
	@echo "→ Submitting $(DMG_PATH) to Apple notary service…"
	xcrun notarytool submit "$(DMG_PATH)" \
	    --keychain-profile "$(KEYCHAIN_PROFILE)" \
	    --wait
	@echo "→ Stapling notarization ticket to DMG…"
	xcrun stapler staple "$(DMG_PATH)"
	@echo "✓ Notarized DMG: $(DMG_PATH)"
	@echo "  Recipients can install without any security warnings."

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	@rm -rf "$(DIST_DIR)" .build
	@echo "✓ Cleaned"

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "OpenClaw Monitor — packaging targets"
	@echo ""
	@echo "  make              Debug build (for development)"
	@echo "  make bundle       Release build → .app bundle in dist/"
	@echo "  make dmg          Bundle → distributable .dmg in dist/"
	@echo ""
	@echo "  Signed (requires Apple Developer ID certificate):"
	@echo "  IDENTITY=\"Developer ID Application: ...\" make sign"
	@echo ""
	@echo "  Notarized (fully trusted by Gatekeeper):"
	@echo "  IDENTITY=\"...\" APPLE_ID=\"you@example.com\" TEAM_ID=\"XXXX\" make notarize"
	@echo ""
