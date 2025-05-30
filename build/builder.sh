#!/bin/bash
set -euo pipefail

LIBSCRAPLI_TAG="${TAG:-}"
LIBSCRAPLI_TARGET="${TARGET:-}"
OUT_NAME="${OUT_NAME:-}"

if [[ -z "$LIBSCRAPLI_TAG" ]]; then
    git clone --depth 1 https://github.com/scrapli/libscrapli

elif [[ "$LIBSCRAPLI_TAG" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    git clone https://github.com/scrapli/libscrapli
    git -C ./libscrapli/ checkout "$LIBSCRAPLI_TAG"

else
    git clone --branch "$LIBSCRAPLI_TAG" --depth 1 --single-branch https://github.com/scrapli/libscrapli
fi

cd libscrapli

# hack to get openssl to not break on first build? i dunno... whatever
cd lib/openssl
zig build
cd ../..

zig build "-Dtarget=${LIBSCRAPLI_TARGET}" -freference-trace --summary all -- --release

cp zig-out/"${LIBSCRAPLI_TARGET}"/libscrapli.* /out/"${OUT_NAME}"
