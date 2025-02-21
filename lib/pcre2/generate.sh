#!/bin/sh

set -e

export GIT_CONFIG_PARAMETERS="'advice.detachedHead=false'"

SUCCESS_MESSAGE="PCRE2 clone/setup OK!"

PCRE2_DIR="pcre2"
PCRE2_TAG="pcre2-10.45"
PCRE2_REPO="https://github.com/PCRE2Project/pcre2"

# we only need to clone/pull if we dont have the tag we want
if [ -d "$PCRE2_DIR/.git" ]; then
    cd "$PCRE2_DIR"

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")

    if [ "$CURRENT_BRANCH" = "$PCRE2_TAG" ] || [ "$CURRENT_TAG" = "$PCRE2_TAG" ]; then
        echo "$SUCCESS_MESSAGE"
        exit 0
    fi

    cd ..
    rm -rf "$PCRE2_DIR"
fi

git clone --branch "$PCRE2_TAG" --depth 1 "$PCRE2_REPO"

rm "$PCRE2_DIR/build.zig" || true
rm "$PCRE2_DIR/build.zig.zon" || true

echo "$SUCCESS_MESSAGE"
