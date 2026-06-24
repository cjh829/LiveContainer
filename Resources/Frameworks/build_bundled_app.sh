#!/bin/bash
#
# Build-time pre-sign packager for the zero-copy bundled app.
#
# Produces Resources/Frameworks/BundledApp.framework containing the guest app
# already patched to a dylib and already signed, so LiveContainer can dlopen it
# in place (no copy, no runtime signing). Run this whenever the IPA or cert
# changes. Must run on a Mac whose keychain has the signing identity + the
# Apple WWDR chain.
#
# Usage:
#   ./build_bundled_app.sh /path/to/app.ipa
#
# Env:
#   IDENTITY   codesign identity (default: the cert.p12 distribution identity)
#   TEAMID     team id baked into entitlements (default: 4KLJCQDV55)
#   SKIP_SIGN  =1 to assemble without signing (for testing the layout only)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IPA="${1:?usage: build_bundled_app.sh <app.ipa>}"
CERT="${CERT:-$HERE/cert.p12}"
PASS="${PASS:-1111}"
TEAMID="${TEAMID:-4KLJCQDV55}"
IDENTITY="${IDENTITY:-Apple Distribution: quyou Technology CO., Ltd ($TEAMID)}"
# Fixed data container so guest data persists across launches.
CONTAINER_UUID="${CONTAINER_UUID:-B9111111-1111-4111-8111-111111111111}"

OUT="$HERE/BundledApp.framework"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "[1/6] unzip IPA"
unzip -q "$IPA" -d "$WORK"
APP="$(ls -d "$WORK"/Payload/*.app | head -1)"
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
BUNDLEID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "       app=$(basename "$APP") exec=$EXEC bundleId=$BUNDLEID"

echo "[2/6] patch main executable -> MH_DYLIB"
# thin to arm64 if the binary is fat
if /usr/bin/lipo -info "$APP/$EXEC" 2>/dev/null | grep -q "Architectures in the fat"; then
    /usr/bin/lipo "$APP/$EXEC" -thin arm64 -output "$APP/$EXEC.arm64"
    mv "$APP/$EXEC.arm64" "$APP/$EXEC"
fi
python3 "$HERE/macho_to_dylib.py" "$APP/$EXEC"

echo "[3/6] bake LCAppInfo.plist (fixed container, patch revision)"
cat > "$APP/LCAppInfo.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LCPatchRevision</key><integer>7</integer>
	<key>dontSign</key><true/>
	<key>LCDataUUID</key><string>$CONTAINER_UUID</string>
	<key>LCContainers</key>
	<array>
		<dict>
			<key>folderName</key><string>$CONTAINER_UUID</string>
			<key>name</key><string>Default</string>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "[4/6] write entitlements"
cat > "$WORK/ent.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key><string>$TEAMID.$BUNDLEID</string>
	<key>com.apple.developer.team-identifier</key><string>$TEAMID</string>
	<key>get-task-allow</key><false/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.SideStore.SideStore</string>
		<string>group.com.rileytestut.AltStore</string>
	</array>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAMID.*</string>
	</array>
</dict>
</plist>
ENT

SIGN_ID="$IDENTITY"
if [ "${SKIP_SIGN:-0}" != "1" ]; then
    # Import the p12 into an isolated temp keychain so signing works without
    # any manual keychain setup. Search list is restored on exit.
    KEYCHAIN="$WORK/bundled-signing.keychain-db"
    OLD_KEYCHAINS="$(security list-keychains -d user | sed -e 's/[\"\;]//g' -e 's/^[[:space:]]*//')"
    restore_keychains() { security list-keychains -d user -s $OLD_KEYCHAINS >/dev/null 2>&1 || true; }
    trap 'restore_keychains; rm -rf "$WORK"' EXIT
    security create-keychain -p "" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "" "$KEYCHAIN"
    security import "$CERT" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -f pkcs12 >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true
    security list-keychains -d user -s "$KEYCHAIN" $OLD_KEYCHAINS >/dev/null
    SIGN_ID="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/[0-9A-F]{40}/{print $2; exit}')"
    [ -n "$SIGN_ID" ] || { echo "ERROR: no signing identity from $CERT (wrong password?)"; exit 1; }
    KCFLAG=(--keychain "$KEYCHAIN")
else
    KCFLAG=()
fi

echo "[5/6] sign guest app (deep) with $SIGN_ID"
if [ "${SKIP_SIGN:-0}" != "1" ]; then
    /usr/bin/codesign --force --deep --timestamp=none "${KCFLAG[@]}" \
        --sign "$SIGN_ID" --entitlements "$WORK/ent.plist" \
        --generate-entitlement-der "$APP"
    /usr/bin/codesign -dv "$APP" 2>&1 | sed 's/^/       /'
else
    echo "       SKIP_SIGN=1 (layout-only build, NOT loadable on device)"
fi

echo "[6/6] assemble BundledApp.framework"
rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
cp "$CERT" "$OUT/cert.p12"
# minimal valid framework stub so the bundle is a real, signable FMWK
echo 'const char bundled_app_marker[] = "LiveContainer bundled app payload";' > "$WORK/stub.c"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
    -install_name @rpath/BundledApp.framework/BundledApp \
    -miphoneos-version-min=15.0 -o "$OUT/BundledApp" "$WORK/stub.c"
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>BundledApp</string>
	<key>CFBundleIdentifier</key><string>com.kdt.livecontainer.BundledApp</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>BundledApp</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>15.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict>
</plist>
PLIST
if [ "${SKIP_SIGN:-0}" != "1" ]; then
    /usr/bin/codesign --force "${KCFLAG[@]}" --sign "$SIGN_ID" "$OUT/BundledApp"
    /usr/bin/codesign --force "${KCFLAG[@]}" --sign "$SIGN_ID" "$OUT"
fi

echo "done -> $OUT"
echo "guest bundle id: $BUNDLEID  (update BundledApp.bundleId in BundledApp.swift if it changed)"
