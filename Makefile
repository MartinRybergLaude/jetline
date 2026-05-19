# Jetline — build & app-bundle helpers.
#
# `swift build` produces a plain mach-o executable. macOS apps need a
# `.app` bundle (Info.plist, dock icon, menu bar). This Makefile wraps
# `swift build` and assembles a minimal bundle in `dist/`.
#
# Two flows:
#   make app       — dev build, ad-hoc signed, fast iteration
#   make release   — Developer ID signed + notarized + stapled + DMG

CONFIG ?= debug
BIN_NAME = jetline
APP_NAME = Jetline.app
BUILD_DIR = .build/$(CONFIG)
DIST_DIR = dist
APP_BUNDLE = $(DIST_DIR)/$(APP_NAME)

# Some users have a global git config rewriting https:// → ssh://
# (`url.<...>.insteadOf` rules). SPM can't authenticate via SSH from its
# subprocess, so version resolution silently fails with messages like
# "no versions of 'swift-argument-parser' match the requirement 1.0.0..<2.0.0".
# Bypass the user's global config for SPM by pointing it at a sentinel.
SWIFT = GIT_CONFIG_GLOBAL=/dev/null swift

# Release configuration. Override via env in CI.
DEVELOPER_ID   ?= Developer ID Application: MARTIN JOHANNES RYBERG LAUDE (X67GNG6U35)
NOTARY_PROFILE ?= jetline-notary
ENTITLEMENTS   := BundleResources/Jetline.entitlements
VERSION         = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" BundleResources/Info.plist)
DMG_NAME        = Jetline-$(VERSION).dmg

.PHONY: all build app run release-app sign dmg notarize release clean test resolve

all: app

resolve:
	$(SWIFT) package resolve

build: resolve
	$(SWIFT) build -c $(CONFIG)

app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(BIN_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(BIN_NAME)"
	@cp "BundleResources/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	@# Compile the Icon Composer source into Assets.car (live Liquid Glass on
	@# macOS 26+) plus AppIcon.icns (legacy fallback). actool accepts the
	@# .icon file directly as the document arg — wrapping it in an .xcassets
	@# silently produces nothing.
	@xcrun actool BundleResources/AppIcon.icon \
		--app-icon AppIcon \
		--compile "$(APP_BUNDLE)/Contents/Resources" \
		--output-partial-info-plist /dev/null \
		--platform macosx --target-device mac \
		--minimum-deployment-target 26.0 \
		--skip-app-store-deployment >/dev/null
	@# Copy SPM-generated resource bundles. SwiftPM's auto-generated
	@# `Bundle.module` accessor expects them at `Bundle.main.bundleURL/<Pkg>_<Tgt>.bundle`
	@# (the .app root, sibling of `Contents/`) — but that layout makes codesign
	@# reject the app with "unsealed contents in the bundle root". We place
	@# them under `Contents/Resources/` instead, and our code reads them via
	@# `Bundle.jetlineResources` (see Utilities/AppResources.swift). `Bundle.module`
	@# itself is never accessed.
	@for b in $(BUILD_DIR)/*_*.bundle; do \
		[ -d "$$b" ] && cp -R "$$b" "$(APP_BUNDLE)/Contents/Resources/"; \
	done
	@printf "APPL????" > "$(APP_BUNDLE)/Contents/PkgInfo"
	@# Embed Sparkle.framework. SPM links against the dylib but doesn't copy
	@# the xcframework into the bundle for executable products — we have to.
	@# Drop Downloader.xpc (only needed by sandboxed apps; we download directly).
	@FW=$$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1); \
	if [ -z "$$FW" ]; then echo "Sparkle.framework not found — run 'swift package resolve'"; exit 1; fi; \
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"; \
	rm -rf "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
	cp -R "$$FW" "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; \
	rm -rf "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"; \
	xattr -cr "$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	@# Ensure the binary can find embedded frameworks via @executable_path.
	@# Idempotent: skip if the rpath is already present.
	@otool -l "$(APP_BUNDLE)/Contents/MacOS/$(BIN_NAME)" | grep -q "path @executable_path/../Frameworks" \
		|| install_name_tool -add_rpath "@executable_path/../Frameworks" "$(APP_BUNDLE)/Contents/MacOS/$(BIN_NAME)"
	@# Ad-hoc re-sign the whole bundle. `install_name_tool` invalidated the
	@# toolchain's signature on the main binary; this re-seals everything.
	@# `--deep` is safe here because dev builds don't care about Sparkle's
	@# XPC service entitlements — for release, scripts/sign.sh signs each
	@# nested piece without `--deep`.
	@codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

run: app
	@# `open` on a .app just foregrounds the existing instance; kill the
	@# running copy first so we always launch the freshly built binary.
	@pkill -x $(BIN_NAME) 2>/dev/null; true
	@sleep 0.2
	open "$(APP_BUNDLE)"

# --- Release pipeline ----------------------------------------------------

release-app:
	$(MAKE) app CONFIG=release

sign: release-app
	./scripts/sign.sh "$(APP_BUNDLE)" "$(DEVELOPER_ID)" "$(ENTITLEMENTS)"

dmg: sign
	./scripts/build-dmg.sh "$(APP_BUNDLE)" "$(DIST_DIR)/$(DMG_NAME)" "$(DEVELOPER_ID)"

notarize: dmg
	xcrun notarytool submit "$(DIST_DIR)/$(DMG_NAME)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler staple "$(DIST_DIR)/$(DMG_NAME)"

release: notarize
	@echo "Release ready: $(DIST_DIR)/$(DMG_NAME)"

# Cut a new release: bump CFBundleShortVersionString, commit only the
# Info.plist change, tag vX.Y.Z, push branch + tag. CI handles the actual
# build/sign/notarize/publish. Default kind is patch.
.PHONY: ship ship-patch ship-minor ship-major

ship: ship-patch

ship-patch: KIND=patch
ship-minor: KIND=minor
ship-major: KIND=major

ship-patch ship-minor ship-major:
	@./scripts/bump-version.sh $(KIND)
	@NEW=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" BundleResources/Info.plist); \
		git add BundleResources/Info.plist && \
		git commit -m "Release $$NEW" && \
		git tag "v$$NEW" && \
		git push origin HEAD "v$$NEW" && \
		echo "Pushed v$$NEW — CI: https://github.com/MartinRybergLaude/jetline/actions"

# -------------------------------------------------------------------------

clean:
	rm -rf .build dist

test: resolve
	$(SWIFT) test
