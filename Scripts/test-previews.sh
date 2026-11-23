#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/CliHeads/PreviewPolicy.swift Tests/PreviewPolicyTests.swift -o "$TEST_DIR/test-previews"
"$TEST_DIR/test-previews"
