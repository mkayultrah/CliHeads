#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swiftc Sources/CliHeads/ClaudeProtocol.swift Tests/main.swift -o /tmp/cliheads-smoke
/tmp/cliheads-smoke
