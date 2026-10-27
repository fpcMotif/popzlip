#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
clang -fobjc-arc -O2 -mmacosx-version-min=14.0 -Wall -Werror -c native/shim.m -o build/shim.o
rm -f build/libpopzlip_shim.a
ar rcs build/libpopzlip_shim.a build/shim.o
scriptc build src/main.ts --ffi native/ffi.json -o build/popzlip >/dev/null

app=build/PopzlipTS.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp bundle/Info.plist "$app/Contents/Info.plist"
cp build/popzlip "$app/Contents/MacOS/popzlip"
codesign --force --sign - "$app" >/dev/null 2>&1
echo "built build/popzlip and $app"
