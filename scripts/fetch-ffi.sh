#!/bin/bash
# Fetches the idevice FFI header and static library.
# Source: jkcoxson/idevice (MIT), build published by ChrisMack32/Locus (MIT).
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="Vendor/idevice"
BASE="https://raw.githubusercontent.com/ChrisMack32/Locus/main/Vendor/idevice"

mkdir -p "$DEST"

echo "header"
curl -fL --retry 3 --max-time 120 "$BASE/idevice.h" -o "$DEST/idevice.h"

if [ ! -s "$DEST/libidevice_ffi.a" ]; then
  echo "static library (about 90 MB)"
  curl -fL --retry 3 --max-time 900 "$BASE/libidevice_ffi.a" -o "$DEST/libidevice_ffi.a.part"
  mv "$DEST/libidevice_ffi.a.part" "$DEST/libidevice_ffi.a"
fi

test -s "$DEST/idevice.h"
test -s "$DEST/libidevice_ffi.a"
ls -lh "$DEST"
