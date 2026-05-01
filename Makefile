# Jetforge — build & app-bundle helpers.
#
# `swift build` produces a plain mach-o executable. macOS apps need a
# `.app` bundle (Info.plist, dock icon, menu bar). This Makefile wraps
# `swift build` and assembles a minimal bundle in `dist/`.

CONFIG ?= debug
BIN_NAME = jetforge
APP_NAME = Jetforge.app
BUILD_DIR = .build/$(CONFIG)
DIST_DIR = dist
APP_BUNDLE = $(DIST_DIR)/$(APP_NAME)

# Some users have a global git config rewriting https:// → ssh://
# (`url.<...>.insteadOf` rules). SPM can't authenticate via SSH from its
# subprocess, so version resolution silently fails with messages like
# "no versions of 'swift-argument-parser' match the requirement 1.0.0..<2.0.0".
# Bypass the user's global config for SPM by pointing it at a sentinel.
SWIFT = GIT_CONFIG_GLOBAL=/dev/null swift

.PHONY: all build app run release clean test resolve

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
	@# Copy SPM-generated resource bundles. SwiftPM names them `<Package>_<Target>.bundle`
	@# and the auto-generated `Bundle.module` accessor for executable targets resolves
	@# them at `Bundle.main.bundleURL/<Pkg>_<Tgt>.bundle` — which on a `.app` means the
	@# top of the bundle (sibling of `Contents/`), NOT `Contents/Resources/`. Place the
	@# bundle there so `Image("…", bundle: .module)` actually finds the assets.
	@for b in $(BUILD_DIR)/*_*.bundle; do \
		[ -d "$$b" ] && cp -R "$$b" "$(APP_BUNDLE)/"; \
	done
	@printf "APPL????" > "$(APP_BUNDLE)/Contents/PkgInfo"
	@# Ad-hoc sign so Gatekeeper doesn't kill it on first launch.
	@codesign --force --deep --sign - "$(APP_BUNDLE)" 2>/dev/null || true
	@echo "Built $(APP_BUNDLE)"

run: app
	@# `open` on a .app just foregrounds the existing instance; kill the
	@# running copy first so we always launch the freshly built binary.
	@pkill -x $(BIN_NAME) 2>/dev/null; true
	@sleep 0.2
	open "$(APP_BUNDLE)"

release:
	$(MAKE) app CONFIG=release

clean:
	rm -rf .build dist

test: resolve
	$(SWIFT) test
