#!/bin/bash
# Builds KnockMac.app (Release, hardened runtime, ad-hoc signed) and packages
# it into KnockMac.dmg with a clean signature that survives Gatekeeper's
# strict xattr check on macOS Sequoia+.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_PATH="build/Build/Products/Release/KnockMac.app"
ENTITLEMENTS="$ROOT/build/Build/Intermediates.noindex/KnockMac.build/Release/KnockMac.build/KnockMac.app.xcent"
DMG="$ROOT/KnockMac.dmg"
RW_DMG="/tmp/knockmac_rw.dmg"
STAGING="/tmp/knockmac_stage"

echo "→ Cleaning source xattrs"
xattr -cr KnockMac KnockMac.xcodeproj

echo "→ Building Release"
xcodebuild -project KnockMac.xcodeproj -scheme KnockMac -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="-" \
    OTHER_CODE_SIGN_FLAGS="--options=runtime" \
    clean build > /tmp/knockmac_build.log 2>&1 || true

if [[ ! -d "$APP_PATH" ]]; then
    echo "Build failed. See /tmp/knockmac_build.log"
    tail -20 /tmp/knockmac_build.log
    exit 1
fi

echo "→ Signing app with hardened runtime"
xattr -cr "$APP_PATH"
/usr/bin/codesign --force --deep --sign - --options=runtime \
    --entitlements "$ENTITLEMENTS" --timestamp=none --generate-entitlement-der \
    "$APP_PATH"

echo "→ Staging DMG contents"
rm -rf "$STAGING" "$RW_DMG" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "→ Cleaning any stale KnockMac mounts"
for v in /Volumes/KnockMac*; do
    [[ -d "$v" ]] && hdiutil detach "$v" -force > /dev/null 2>&1 || true
done

echo "→ Creating writable DMG"
hdiutil create -volname "KnockMac" -srcfolder "$STAGING" -ov -format UDRW \
    -size 30m "$RW_DMG" > /dev/null

MOUNT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | \
    grep -o '/Volumes/KnockMac[^[:space:]]*' | head -1)
if [[ -z "$MOUNT" ]]; then
    # Fallback for mount paths containing spaces.
    MOUNT=$(ls -td /Volumes/KnockMac* 2>/dev/null | head -1)
fi
[[ -n "$MOUNT" ]] || { echo "Mount failed"; exit 1; }

echo "→ Styling window at $MOUNT"
osascript <<EOF
tell application "Finder"
    tell disk "KnockMac"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 850, 520}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "KnockMac.app" of container window to {170, 180}
        set position of item "Applications" of container window to {480, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
sleep 1

echo "→ Stripping xattrs added by Finder and re-signing in-place"
xattr -cr "$MOUNT/KnockMac.app"
find "$MOUNT/KnockMac.app" -name "._*" -delete 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - --options=runtime \
    --entitlements "$ENTITLEMENTS" --timestamp=none --generate-entitlement-der \
    "$MOUNT/KnockMac.app"
codesign --verify --deep --strict "$MOUNT/KnockMac.app"

hdiutil detach "$MOUNT" > /dev/null

echo "→ Compressing DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" > /dev/null

echo "→ Signing DMG"
codesign --force --sign - "$DMG"

rm -rf "$STAGING" "$RW_DMG"
ls -lah "$DMG"
echo "✓ Done"
