# SpaceSwitch — one entry point for everything.
# Run `make` to see what is available.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT = SpaceSwitch.xcodeproj
SCHEME  = SpaceSwitch
DERIVED = build/DerivedData
APP     = $(DERIVED)/Build/Products/Release/SpaceSwitch.app
CLI     = .build/release/spaceswitch
PREFIX ?= /usr/local

XCB = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) \
      -destination 'platform=macOS,arch=arm64' -quiet

.PHONY: help app run build test lint format icon install uninstall clean ci

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

app: ## Build SpaceSwitch.app
	@$(XCB) -configuration Release build

run: app ## Build and launch the app
	@osascript -e 'tell application "SpaceSwitch" to quit' 2>/dev/null || true
	@sleep 1 && open $(APP)

build: ## Build the command line tool on its own
	@swift build -c release --product spaceswitch

test: ## Run the test suite
	@swift test

lint: ## Check formatting
	@swift format lint --recursive --strict Sources Tests

format: ## Reformat sources in place
	@swift format --in-place --recursive Sources Tests

icon: ## Re-render the app icon into the asset catalogue
	@swift Scripts/make-icon.swift

install: build ## Install the tool and background helper (asks for your password)
	@sudo install -d $(PREFIX)/bin
	@sudo install -m 0755 $(CLI) $(PREFIX)/bin/spaceswitch
	@sudo $(PREFIX)/bin/spaceswitch install

uninstall: ## Remove the tool and helper, and restore Dock
	@sudo $(PREFIX)/bin/spaceswitch uninstall || true
	@sudo rm -f $(PREFIX)/bin/spaceswitch

clean: ## Remove build products
	@rm -rf .build build

ci: lint test app ## Everything CI runs
	@codesign --verify --deep --strict $(APP)
	@$(APP)/Contents/Helpers/spaceswitch presets >/dev/null
	@echo "ok"
