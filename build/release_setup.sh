#!/bin/bash
set -euo pipefail

release_tag="${1:-}"

if [[ -z "$release_tag" ]]; then
    echo "release tag is required" >&2
    exit 1
fi

if [[ -z "${GITHUB_ENV:-}" ]]; then
    echo "GITHUB_ENV is required" >&2
    exit 1
fi

release_version="${release_tag#v}"

./build/update_version.sh "$release_tag"

source .github/vars.env

{
    echo "RELEASE_VERSION=$release_version"
    echo "ZIG_VERSION=$ZIG_VERSION"
} >> "$GITHUB_ENV"
