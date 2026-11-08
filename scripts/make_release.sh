#!/bin/bash
# Baut TidyMac als Release, prüft die Signatur und packt die App als ZIP
# für GitHub-Releases: build/release/TidyMac-<Version>.zip (+ SHA-256).
set -euo pipefail
cd "$(dirname "$0")/.."

# xcodebuild braucht Xcode, nicht nur die Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' TidyMac.xcodeproj/project.pbxproj | head -1)
APP=build/DerivedData/Build/Products/Release/TidyMac.app
ZIP=build/release/TidyMac-$VERSION.zip

echo "→ Baue TidyMac $VERSION (Release) …"
xcodebuild -project TidyMac.xcodeproj -scheme TidyMac -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -quiet clean build

echo "→ Prüfe Signatur …"
codesign --verify --deep --strict "$APP"

mkdir -p build/release
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ $ZIP"
shasum -a 256 "$ZIP"
