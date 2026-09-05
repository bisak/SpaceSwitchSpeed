# SpaceSwitch — one entry point for everything.
# Run `make` to see what is available.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# No single toolchain here can both link against the newest SDK and run tests,
# so each target asks for the one it needs. See Scripts/toolchain.sh.
SDK_DEVELOPER_DIR  = $(shell Scripts/toolchain.sh sdk)
TEST_DEVELOPER_DIR = $(shell Scripts/toolchain.sh test)

APP = build/SpaceSwitch.app
CLI = .build/release/spaceswitch
PREFIX ?= /usr/local

.PHONY: help build app run test lint format icon install uninstall clean ci

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Build SDK:  $$(DEVELOPER_DIR=$(SDK_DEVELOPER_DIR) xcrun --show-sdk-version 2>/dev/null)  ($(SDK_DEVELOPER_DIR))"

build: ## Build the command line tool
	@DEVELOPER_DIR=$(SDK_DEVELOPER_DIR) swift build -c release --product spaceswitch

app: ## Build SpaceSwitch.app
	@Scripts/build-app.sh

run: app ## Build and launch the app
	@osascript -e 'tell application "SpaceSwitch" to quit' 2>/dev/null || true
	@sleep 1 && open $(APP)

test: ## Run the test suite
	@DEVELOPER_DIR=$(TEST_DEVELOPER_DIR) swift test

lint: ## Check formatting
	@DEVELOPER_DIR=$(SDK_DEVELOPER_DIR) swift format lint --recursive --strict Sources Tests

format: ## Reformat sources in place
	@DEVELOPER_DIR=$(SDK_DEVELOPER_DIR) swift format --in-place --recursive Sources Tests

icon: ## Regenerate the app icon
	@DEVELOPER_DIR=$(SDK_DEVELOPER_DIR) swift Scripts/make-icon.swift

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
	@$(APP)/Contents/Helpers/spaceswitch presets --refresh 120 >/dev/null
	@echo "ok"
