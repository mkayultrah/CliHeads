#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Parse all Swift files without requiring an Apple SDK.
swiftc -frontend -parse Sources/CliHeads/*.swift
printf '%s\n' 'PASS: All CliHeads Swift source files parsed successfully'
