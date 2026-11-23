#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/magnetic-snap-tests"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc Sources/CliHeads/MagneticSnapEngine.swift Sources/CliHeads/BubbleStackLayout.swift Tests/MagneticSnapTests.swift -o "$BIN"
"$BIN"
