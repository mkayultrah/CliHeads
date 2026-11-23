#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/stack-layout-tests"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc Sources/CliHeads/MagneticSnapEngine.swift Sources/CliHeads/BubbleStackLayout.swift Tests/StackLayoutTests.swift -o "$BIN"
"$BIN"
