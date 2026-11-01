#!/bin/bash
# Builds libidevice_ffi.a and the matching C header for iOS arm64.
# Pinned commit, explicit feature set: the prebuilt Locus library was built
# without `afc`, which is why linking AFC failed.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

PINNED="89702099f4d7552f704f93b4526756abda319ceb"
FEATURES="afc,tunnel_tcp_stack,ring"
DEST="$ROOT/Vendor/idevice"
SRC="$ROOT/.build/idevice"

mkdir -p "$DEST" "$ROOT/.build"

if [ -s "$DEST/libidevice_ffi.a" ] && [ -s "$DEST/idevice.h" ] && [ "${1:-}" != "--force" ]; then
  echo "idevice ffi already present"
  exit 0
fi

if [ ! -d "$SRC/.git" ]; then
  echo "cloning idevice $PINNED"
  git clone --quiet https://github.com/jkcoxson/idevice.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$PINNED" || true
git -C "$SRC" checkout --quiet --force "$PINNED"

rustup target add aarch64-apple-ios >/dev/null

echo "cargo build $FEATURES"
cd "$SRC/ffi"
cargo build --release --no-default-features --features "$FEATURES" --target aarch64-apple-ios

cp "$SRC/ffi/target/aarch64-apple-ios/release/libidevice_ffi.a" "$DEST/"
cp "$SRC/ffi/idevice.h" "$DEST/"

# Fail here, not in Xcode, if the feature set drifted.
for symbol in afc_client_connect_rsd afc_get_device_info pairable_host_accept \
              tunnel_create_rppairing rsd_get_services; do
  if ! nm -g "$DEST/libidevice_ffi.a" 2>/dev/null | grep -q "_${symbol}$"; then
    echo "missing symbol $symbol in libidevice_ffi.a" >&2
    exit 1
  fi
done

echo "ffi ready"
ls -lh "$DEST/libidevice_ffi.a" "$DEST/idevice.h"
