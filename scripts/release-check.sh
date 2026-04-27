#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag>"
  exit 1
fi

# Strip leading 'v'
VERSION="${TAG#v}"

# Extract version from src/version.zig
CODE_VERSION=$(grep 'pub const current' src/version.zig | sed 's/.*"\(.*\)".*/\1/')

if [[ "$VERSION" != "$CODE_VERSION" ]]; then
  echo "ERROR: Tag '$TAG' does not match version in src/version.zig ('$CODE_VERSION')"
  echo "  Update CURRENT in src/version.zig to '$VERSION' before tagging."
  exit 1
fi

echo "OK: version $VERSION matches src/version.zig"

# Verify it builds and tests pass
zig build test --summary all
