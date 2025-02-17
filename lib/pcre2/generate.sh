#!/bin/sh

set -e

rm r-f pcre2
git clone --branch pcre2-10.45 --depth 1 https://github.com/PCRE2Project/pcre2

rm pcre2/build.zig
rm pcre2/build.zig.zon || true

echo Successfully removed upstream build.zig file!