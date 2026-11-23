#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BIN="$(mktemp -d)/agent-tests"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc Sources/CliHeads/ClaudeProtocol.swift Sources/CliHeads/AgentProtocols.swift Sources/CliHeads/SavedHead.swift Sources/CliHeads/SessionCatalog.swift Tests/AgentTests.swift -o "$BIN"
"$BIN"
