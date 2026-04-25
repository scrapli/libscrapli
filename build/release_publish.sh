#!/bin/bash
set -euo pipefail

release_tag="${1:-}"
source_path="${2:-}"
renamed_path="${3:-}"

if [[ -z "$release_tag" ]]; then
    echo "release tag is required" >&2
    exit 1
fi

if [[ -z "$source_path" ]]; then
    echo "source path is required" >&2
    exit 1
fi

if [[ -z "$renamed_path" ]]; then
    echo "renamed path is required" >&2
    exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "GITHUB_TOKEN is required" >&2
    exit 1
fi

mv "$source_path" "$renamed_path"
sha256sum "$renamed_path" > "$renamed_path.sha256"

gh release upload "$release_tag" \
    "$renamed_path" \
    "$renamed_path.sha256" \
    --clobber
