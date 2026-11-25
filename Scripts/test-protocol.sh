#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/protocol-tests"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc Sources/CliHeads/ClaudeProtocol.swift Tests/main.swift -o "$BIN"
"$BIN"
