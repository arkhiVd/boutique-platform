#!/usr/bin/env bash
# actionlint in CI without a Go toolchain on the runner: download the release binary.
# Pinned version, checksum verified against the GitHub release.
set -euo pipefail
VERSION="1.7.11"
URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/actionlint_${VERSION}_linux_amd64.tar.gz"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
curl -sSL --max-time 120 -o "$DIR/a.tgz" "$URL"
tar -xzf "$DIR/a.tgz" -C "$DIR"
# actionlint takes file paths, not the directory, in the pinned version.
for f in .github/workflows/*.yaml .github/workflows/*.yml; do
  [[ -e "$f" ]] && "$DIR/actionlint" "$f"
done
