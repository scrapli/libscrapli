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

sed -i.bak -E "s|(\.major =)(.*)|\1 ${MAJOR},|g" build.zig
sed -i.bak -E "s|(.minor =)(.*)|\1 ${MINOR},|g" build.zig
sed -i.bak -E "s|(.patch =)(.*)|\1 ${PATCH},|g" build.zig
sed -i.bak -E "s|(.pre =)(.*)|\1 ${PRE},|g" build.zig
rm build.zig.bak

sed -i.bak -E "s|(\.version = )(.*)|\1\"${VERSION}\",|g" build.zig.zon
rm build.zig.zon.bak
