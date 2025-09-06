#!/bin/bash
set -euo pipefail

LIBSCRAPLI_TAG="${1:-}"
VERSION="${LIBSCRAPLI_TAG#v}"

IFS='-' read -r BASE PRE <<<"$VERSION"
IFS='.' read -r MAJOR MINOR PATCH <<<"$BASE"

if [[ -z "$PRE" ]]; then
    PRE="null"
else
    PRE="\"$PRE\""
fi

sed -i -E "s|(\.major =)(.*)|\1 ${MAJOR},|g" build.zig
sed -i -E "s|(.minor =)(.*)|\1 ${MINOR},|g" build.zig
sed -i -E "s|(.patch =)(.*)|\1 ${PATCH},|g" build.zig
sed -i -E "s|(.pre =)(.*)|\1 ${PRE},|g" build.zig

sed -i -E "s|(\.version = )(.*)|\1\"${VERSION}\",|g" build.zig.zon
