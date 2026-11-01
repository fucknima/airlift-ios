#!/bin/bash
# Builds an unsigned IPA. Run on macOS with Xcode and xcodegen.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild missing; this script needs macOS with Xcode" >&2
  exit 1
fi

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
  CODE_SIGNING_REQUIRED=NO \
  STRIP_INSTALLED_PRODUCT=YES \
  DEAD_CODE_STRIPPING=YES \
  build

APP="build/Build/Products/Release-iphoneos/Airlift.app"
test -d "$APP"

rm -rf dist
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
(cd dist && /usr/bin/zip -qry ../Airlift-unsigned.ipa Payload)

echo "built Airlift-unsigned.ipa"
ls -lh Airlift-unsigned.ipa
