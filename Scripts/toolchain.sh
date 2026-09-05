#!/bin/bash
# Prints the DEVELOPER_DIR to use for a given purpose, because no single
# toolchain on a typical machine can do both jobs.
#
#   sdk    newest macOS SDK. macOS decides which control appearance an app gets
#          from the SDK it was linked against, so anything shipped to users has
#          to be built with an SDK at least as new as the running system. That
#          is often the Command Line Tools rather than Xcode.
#
#   test   a toolchain carrying the test frameworks. XCTest and swift-testing
#          ship inside Xcode and are absent from the Command Line Tools.
set -euo pipefail

candidates() {
    xcode-select -p 2>/dev/null || true
    echo /Library/Developer/CommandLineTools
    ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null || true
}

case "${1:-sdk}" in
sdk)
    best_dir=""
    best=0
    while read -r dir; do
        [ -d "$dir" ] || continue
        version="$(DEVELOPER_DIR="$dir" xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
        case "$version" in '' | *[!0-9]*) continue ;; esac
        if [ "$version" -gt "$best" ]; then
            best="$version"
            best_dir="$dir"
        fi
    done < <(candidates)

    [ -n "$best_dir" ] || {
        echo "no macOS SDK found; install Xcode or the Command Line Tools" >&2
        exit 1
    }
    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$best" -lt "$os_major" ]; then
        echo "warning: newest macOS SDK is $best but this system is $os_major;" >&2
        echo "         the app will be drawn with older system controls." >&2
    fi
    echo "$best_dir"
    ;;

test)
    while read -r dir; do
        frameworks="$dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
        if [ -d "$frameworks/Testing.framework" ] || [ -d "$frameworks/XCTest.framework" ]; then
            echo "$dir"
            exit 0
        fi
    done < <(candidates)

    echo "no toolchain with the test frameworks; they ship with Xcode, not the" >&2
    echo "Command Line Tools. Install Xcode to run the tests." >&2
    exit 1
    ;;

*)
    echo "usage: toolchain.sh [sdk|test]" >&2
    exit 2
    ;;
esac
