# Space Switch Speed — one entry point for everything.
# Run `make` to see what is available.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT = SpaceSwitchSpeed.xcodeproj
SCHEME  = SpaceSwitchSpeed
DERIVED = build/DerivedData
APP     = $(DERIVED)/Build/Products/Release/Space Switch Speed.app
INSTALLED = /Applications/Space Switch Speed.app
# The version is set once, in the project; the disk image is named after it.
VERSION ?= $(shell sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' $(PROJECT)/project.pbxproj | head -1)
DMG     = build/SpaceSwitchSpeed-$(VERSION).dmg

XCB = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) \
      -destination 'platform=macOS,arch=arm64' -quiet

.PHONY: help app run install test lint format check-dock fetch-dock icon banner background release clean verify ci
.NOTPARALLEL:

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

app: ## Build Space Switch Speed.app
	@$(XCB) -configuration Release build

run: app ## Build and launch the app
	@osascript -e 'tell application id "com.bisak.spaceswitchspeed" to quit' 2>/dev/null || true
	@sleep 1 && open "$(APP)"

install: app ## Build the app and put it in /Applications, replacing any copy there
	@osascript -e 'tell application id "com.bisak.spaceswitchspeed" to quit' 2>/dev/null || true
	@rm -rf "$(INSTALLED)" && ditto "$(APP)" "$(INSTALLED)"
	@echo "installed $(INSTALLED)"

test: ## Run the test suite
	@swift test

lint: ## Check formatting
	@swift format lint --recursive --strict Sources Tests

format: ## Reformat sources in place
	@swift format --in-place --recursive Sources Tests

check-dock: ## Check whether Dock is still patchable (DOCK=path, default this Mac's)
	@swift run --quiet dock-check $(DOCK)

fetch-dock: ## Extract another release's Dock for check-dock (MACOS=15.0, or an ipsw URL)
	@Scripts/fetch-dock.sh $(MACOS)

icon: ## Re-render the app icon into the asset catalogue
	@swift Scripts/make-icon.swift

banner: ## Re-render the README banner (needs Google Chrome and Pillow): build the HTML, capture it, encode it
	@python3 Scripts/make-banner.py

background: ## Re-render the disk image's window background
	@swift Scripts/make-dmg-background.swift

release: ci ## Verify everything, then package the app as a disk image for a release
	@Scripts/make-dmg.sh "$(APP)" $(VERSION) $(DMG)
	@echo "wrote $(DMG) (upload this to the Releases page)"

clean: ## Remove build products, keeping the Dock corpus that fetch-dock builds
	@rm -rf .build
	@[ ! -d build ] || find build -mindepth 1 -maxdepth 1 ! -name docks -exec rm -rf {} +

verify: lint test app ## Lint, test, build the app, and check its signature and its helper
	@codesign --verify --deep --strict "$(APP)"
	@"$(APP)/Contents/Helpers/spaceswitchspeed" >/dev/null

ci: verify check-dock ## Everything verify does, plus this Mac's Dock
	@echo "ok"
