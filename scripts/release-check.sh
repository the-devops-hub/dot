#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag>"
  exit 1
fi

# Strip leading 'v'
VERSION="${TAG#v}"

# Extract version from Cargo.toml
CODE_VERSION=$(grep '^version' Cargo.toml | head -1 | sed 's/version = "\(.*\)"/\1/')

if [[ "$VERSION" != "$CODE_VERSION" ]]; then
  echo "ERROR: Tag '$TAG' does not match version in Cargo.toml ('$CODE_VERSION')"
  echo "  Update version in Cargo.toml to '$VERSION' before tagging."
  exit 1
fi

echo "OK: version $VERSION matches Cargo.toml"

# Verify tests pass
cargo test --all
