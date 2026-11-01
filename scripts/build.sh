#!/bin/bash
# Builds an unsigned IPA. Run on macOS with Xcode and xcodegen.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/fetch-ffi.sh

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen missing: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

xcodebuild \
  -project Airlift.xcodeproj \
  -scheme Airlift \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="build/Build/Products/Release-iphoneos/Airlift.app"
test -d "$APP"

rm -rf dist
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && /usr/bin/zip -qry ../Airlift-unsigned.ipa Payload)

echo "Airlift-unsigned.ipa"
ls -lh Airlift-unsigned.ipa
