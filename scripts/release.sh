#!/usr/bin/env bash
# Builds a distributable Game Audio Asset Manager: universal (Apple Silicon and Intel), with Sparkle
# auto-updates, packaged as a zip (for updates) and a DMG (for people) in dist/.
#
#   scripts/release.sh
#
# Environment:
#   SIGN_IDENTITY="Developer ID Application: ..."   sign with a real identity (default: ad-hoc)
#   NOTARY_PROFILE=name   notarize and staple using a `notarytool store-credentials` profile
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="Game Audio Asset Manager"
FILE_NAME="GameAudioAssetManager"
FEED_URL="https://github.com/enso-works/game-audio-asset-manager/releases/latest/download/appcast.xml"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DERIVED="$ROOT/build-release"
OUT="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="$ROOT/dist"

info() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }

# --- Compile --------------------------------------------------------------------------------
info "Building $APP_NAME $VERSION ($BUILD_NUMBER) universal"
xcodegen generate --quiet
rm -rf "$DERIVED/Build/Products"
xcodebuild -project "$FILE_NAME.xcodeproj" -scheme "$FILE_NAME" -configuration Release \
    -derivedDataPath "$DERIVED" -quiet \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SPARKLE_FEED_URL="$FEED_URL" \
    build
rm -rf "$OUT/Contents/Frameworks/Sparkle.framework/Versions/B/"{Headers,PrivateHeaders,Modules} \
    "$OUT/Contents/Frameworks/Sparkle.framework/"{Headers,PrivateHeaders,Modules}

# --- Sign, innermost code first -------------------------------------------------------------
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    info "Signing with $SIGN_IDENTITY (hardened runtime)"
    SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
else
    info "Signing ad-hoc"
    SIGN=(codesign --force --sign -)
fi
SPARKLE="$OUT/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$OUT/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$OUT"
codesign --verify --deep --strict "$OUT"
# `file` prints one extra line per architecture for universal binaries.
is_macho() { [[ "$(file -b --mime-type "$1" | head -1)" == "application/x-mach-binary" ]]; }
# --deep does not look at code stored as resources, so check every binary for the team ID.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    TEAM_ID="$(codesign -dv "$OUT" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    while IFS= read -r -d '' file; do
        is_macho "$file" || continue
        details="$(codesign -dv "$file" 2>&1 || true)"
        [[ "$details" == *"TeamIdentifier=$TEAM_ID"* ]] || { echo "not signed by $TEAM_ID: $file" >&2; exit 1; }
    done < <(find "$OUT" -type f -print0)
fi
lipo -archs "$OUT/Contents/MacOS/$APP_NAME"

# --- Package --------------------------------------------------------------------------------
mkdir -p "$DIST"
ZIP="$DIST/$FILE_NAME-$VERSION-macos.zip"
DMG="$DIST/$FILE_NAME-$VERSION-macos.dmg"
rm -f "$ZIP" "$DMG"

notarize() {
    [[ -n "${NOTARY_PROFILE:-}" ]] || return 0
    info "Notarizing $(basename "$1")"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

info "Creating $ZIP"
ditto -c -k --keepParent "$OUT" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$ZIP"
    xcrun stapler staple "$OUT"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$OUT" "$ZIP"
fi

info "Creating $DMG"
STAGE="$(mktemp -d)"
cp -R "$OUT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format ULMO "$DMG"
rm -rf "$STAGE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    info "Checking Gatekeeper"
    xcrun stapler validate "$OUT"
    xcrun stapler validate "$DMG"
    spctl --assess --type execute --verbose "$OUT"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$FILE_NAME-$VERSION-checksums.txt")
info "Artifacts"
ls -lh "$DIST"
