PROJECT  = ClaudeTracker.xcodeproj
SCHEME   = ClaudeTracker
APP      = ClaudeTracker.app
ZIP      = release/ClaudeTracker.zip
DMG      = release/ClaudeTracker.dmg

BUILD_DIR = release/build
DIST_DIR  = release/dist

# --- Signing ---
# Override when cert is available:
#   make sign SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?=

# --- Notarization ---
# Requires: APPLE_ID, APPLE_PASSWORD (app-specific), APPLE_TEAM_ID
APPLE_ID       ?=
APPLE_PASSWORD ?=
APPLE_TEAM_ID  ?=

# CI override: make build SIGNING_FLAGS="CODE_SIGNING_ALLOWED=NO"
SIGNING_FLAGS ?= CODE_SIGN_IDENTITY="-"

.PHONY: release build test lint run clean tag dmg zip sign notarize staple generate

# ── Full release pipeline ─────────────────────────────────────────────────────

release: build sign notarize staple dmg zip
	@echo ""
	@echo "  -> $(DMG)"
	@echo "  -> $(ZIP)"

# ── Lint ─────────────────────────────────────────────────────────────────────

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
	  echo "==> Linting..."; \
	  swiftlint lint --strict; \
	else \
	  echo "==> Skipping lint (swiftlint not installed — brew install swiftlint)"; \
	fi

# ── Test ─────────────────────────────────────────────────────────────────────

test: generate
	@echo "==> Running tests..."
	xcodebuild test \
	           -project $(PROJECT) \
	           -scheme ClaudeTrackerTests \
	           -destination 'platform=macOS' \
	           SWIFT_STRICT_CONCURRENCY=minimal \
	           $(SIGNING_FLAGS)

# ── Generate Xcode project (XcodeGen) ─────────────────────────────────────────
# project.yml is the source of truth; ClaudeTracker.xcodeproj is generated and
# git-ignored. build/test depend on this so the project is always in sync.

generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found — brew install xcodegen"; exit 1; }
	@echo "==> Generating $(PROJECT) from project.yml..."
	@xcodegen generate --quiet

# ── Build ─────────────────────────────────────────────────────────────────────

build: generate
	@echo "==> Building..."
	@pkill -9 -f "$(APP)" 2>/dev/null || true
	@rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeTracker-*
	@rm -rf $(BUILD_DIR) && mkdir -p $(BUILD_DIR)
	@xattr -w com.apple.xcode.CreatedByBuildSystem true "$(CURDIR)/$(BUILD_DIR)"
	xcodebuild -project $(PROJECT) \
	           -scheme $(SCHEME) \
	           -configuration Release \
	           -quiet \
	           clean build \
	           CONFIGURATION_BUILD_DIR="$(CURDIR)/$(BUILD_DIR)" \
	           SWIFT_STRICT_CONCURRENCY=minimal \
	           $(SIGNING_FLAGS)

# ── Code signing ─────────────────────────────────────────────────────────────

sign:
	@if [ -z "$(SIGN_IDENTITY)" ]; then \
	  echo "==> Skipping signing (SIGN_IDENTITY not set)"; \
	else \
	  echo "==> Signing with: $(SIGN_IDENTITY)"; \
	  codesign --deep --force --options runtime \
	    --sign "$(SIGN_IDENTITY)" \
	    --entitlements ClaudeTracker/ClaudeTracker.entitlements \
	    $(BUILD_DIR)/$(APP); \
	  codesign --verify --deep --strict $(BUILD_DIR)/$(APP); \
	  echo "  Signing verified."; \
	fi

# ── Notarization ─────────────────────────────────────────────────────────────

notarize:
	@if [ -z "$(APPLE_ID)" ]; then \
	  echo "==> Skipping notarization (APPLE_ID not set)"; \
	else \
	  echo "==> Notarizing..."; \
	  ditto -c -k --keepParent $(BUILD_DIR)/$(APP) /tmp/ClaudeTracker_notarize.zip; \
	  xcrun notarytool submit /tmp/ClaudeTracker_notarize.zip \
	    --apple-id "$(APPLE_ID)" \
	    --password "$(APPLE_PASSWORD)" \
	    --team-id "$(APPLE_TEAM_ID)" \
	    --wait; \
	  rm /tmp/ClaudeTracker_notarize.zip; \
	fi

staple:
	@if [ -z "$(APPLE_ID)" ]; then \
	  echo "==> Skipping stapling (APPLE_ID not set)"; \
	else \
	  echo "==> Stapling notarization ticket..."; \
	  xcrun stapler staple $(BUILD_DIR)/$(APP); \
	fi

# ── Packaging ────────────────────────────────────────────────────────────────

dmg:
	@echo "==> Creating DMG..."
	@rm -f $(DMG)
	@mkdir -p release
	@TMP=$$(mktemp -d) && \
	  cp -R $(BUILD_DIR)/$(APP) "$$TMP/$(APP)" && \
	  ln -s /Applications "$$TMP/Applications" && \
	  hdiutil create -volname "ClaudeTracker" -srcfolder "$$TMP" \
	    -ov -format UDZO "$(DMG)" -quiet && \
	  rm -rf "$$TMP"
	@echo "  -> $(DMG)"

zip:
	@echo "==> Creating ZIP..."
	@rm -rf $(DIST_DIR) && mkdir -p $(DIST_DIR)
	@cp -R $(BUILD_DIR)/$(APP) $(DIST_DIR)/$(APP)
	@cp install.command $(DIST_DIR)/install.command
	@chmod +x $(DIST_DIR)/install.command
	@rm -f $(ZIP)
	@cd $(DIST_DIR) && zip -rq "$(CURDIR)/$(ZIP)" .
	@echo "  -> $(ZIP)"

# ── Local dev ────────────────────────────────────────────────────────────────

run: build
	@echo "==> Installing and launching..."
	@rm -rf /Applications/$(APP)
	@cp -R $(BUILD_DIR)/$(APP) /Applications/$(APP)
	@open /Applications/$(APP)

# ── Release tagging ──────────────────────────────────────────────────────────

tag: lint
	@if [ -z "$(VERSION)" ]; then echo "Usage: make tag VERSION=1.0.0"; exit 1; fi
	@if [ -n "$$(git status --porcelain)" ]; then echo "Working directory is not clean — commit changes first"; exit 1; fi
	@sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "$(VERSION)"/' project.yml
	git add project.yml
	git commit -m "Bump version to $(VERSION)"
	git tag -a "v$(VERSION)" -m "v$(VERSION)"
	git push origin main
	git push origin "v$(VERSION)"

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean:
	@echo "==> Cleaning..."
	@pkill -9 -f "$(APP)" 2>/dev/null || true
	@rm -rf release
	@rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeTracker-*
