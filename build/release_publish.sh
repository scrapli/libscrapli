#!/bin/bash
set -euo pipefail

release_tag="${1:-}"
source_path="${2:-}"
upload_display="${3:-}"

if [[ -z "$release_tag" ]]; then
    echo "release tag is required" >&2
    exit 1
fi

if [[ -z "$source_path" ]]; then
    echo "source path is required" >&2
    exit 1
fi

if [[ -z "$upload_display" ]]; then
    echo "upload_display path is required" >&2
    exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "GITHUB_TOKEN is required" >&2
    exit 1
fi

triple="$(echo "$source_path" | awk -F'/' '{print $(NF-1)}')"

dir="$(dirname "$source_path")"
base="$(basename "$source_path")"

name="${base%%.*}"
rest="${base#*.}"
rest="${rest#.}"

renamed="${dir}/${name}-${triple}.${rest}"

cp "$source_path" "$renamed"

sha256sum "$renamed" >"$renamed.sha256"

gh release upload \
    "$release_tag" \
    "$renamed#$upload_display" \
    "$renamed.sha256#$upload_display.sha256" \
    --clobber
