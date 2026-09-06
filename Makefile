# SpaceSwitchSpeed — one entry point for everything.
# Run `make` to see what is available.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT = SpaceSwitchSpeed.xcodeproj
SCHEME  = SpaceSwitchSpeed
DERIVED = build/DerivedData
APP     = $(DERIVED)/Build/Products/Release/SpaceSwitchSpeed.app
# The version is set once, in the project; the disk image is named after it.
VERSION ?= $(shell sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' $(PROJECT)/project.pbxproj | head -1)
DMG     = build/SpaceSwitchSpeed-$(VERSION).dmg

XCB = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) \
      -destination 'platform=macOS,arch=arm64' -quiet

.PHONY: help app run install test lint format check-dock fetch-dock icon banner background release clean ci

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

app: ## Build SpaceSwitchSpeed.app
	@$(XCB) -configuration Release build

run: app ## Build and launch the app
	@osascript -e 'tell application "SpaceSwitchSpeed" to quit' 2>/dev/null || true
	@sleep 1 && open $(APP)

install: app ## Build the app and put it in /Applications, replacing any copy there
	@osascript -e 'tell application "SpaceSwitchSpeed" to quit' 2>/dev/null || true
	@rm -rf /Applications/SpaceSwitchSpeed.app && ditto $(APP) /Applications/SpaceSwitchSpeed.app
	@echo "installed /Applications/SpaceSwitchSpeed.app"

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

release: app ## Build the app and package it as a disk image for a GitHub release
	@Scripts/make-dmg.sh $(APP) $(VERSION) $(DMG)
	@echo "wrote $(DMG) (upload this to the Releases page)"

clean: ## Remove build products
	@rm -rf .build build

ci: lint test app ## Run every check locally (do this before tagging a release)
	@codesign --verify --deep --strict $(APP)
	@$(APP)/Contents/Helpers/spaceswitchspeed >/dev/null
	@echo "ok"
