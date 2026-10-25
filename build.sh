#!/bin/zsh
set -eu
cd -- "${0:A:h}"
DEST="$PWD/CCAM Desktop.app"
CCAM_BUILD_STAGE="$(mktemp -d /private/tmp/ccam-build.XXXXXX)"
trap '/bin/rm -rf "$CCAM_BUILD_STAGE"' EXIT
APP="$CCAM_BUILD_STAGE/CCAM Desktop.app"
BUILD="$PWD/.build-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/SwiftTerm"
vendor_sources=(Vendor/SwiftTerm/Sources/SwiftTerm/**/*.swift(N))
rebuild=0
[[ -f "$BUILD/SwiftTerm/libSwiftTerm.a" ]] || rebuild=1
for source in $vendor_sources; do
  [[ "$source" -nt "$BUILD/SwiftTerm/libSwiftTerm.a" ]] && rebuild=1
done
if (( rebuild )); then
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$BUILD" \
    -emit-library -static -emit-module -module-name SwiftTerm -emit-module-path "$BUILD/SwiftTerm/SwiftTerm.swiftmodule" \
    $vendor_sources -o "$BUILD/SwiftTerm/libSwiftTerm.a"
fi
app_sources=(Source/*.swift)
clang -O2 -mmacosx-version-min=13.0 -c Source/PTYBridge.c -o "$BUILD/PTYBridge.o"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$BUILD" -framework AppKit \
  -I "$BUILD/SwiftTerm" -import-objc-header Source/PTYBridge.h "$BUILD/PTYBridge.o" "$BUILD/SwiftTerm/libSwiftTerm.a" \
  $app_sources \
  -o "$APP/Contents/MacOS/CCAMDesktop"
cp "$APP/Contents/MacOS/CCAMDesktop" "$APP/Contents/MacOS/CCAMBrowser"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CCAMDesktop</string>
<key>CFBundleIdentifier</key><string>local.ccam.desktop</string>
<key>CFBundleName</key><string>CCAM Desktop</string>
<key>CFBundleDisplayName</key><string>CCAM Desktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.13.1</string>
<key>CFBundleVersion</key><string>32</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [ -f Source/AppIcon.icns ]; then cp Source/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Vendor/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/CCAM-Desktop-LICENSE.txt"
mkdir -p "$APP/Contents/Resources/Translation"
cp Resources/Translation/translate_worker.py Resources/Translation/native_translation.py Resources/Translation/NOTICE.md scripts/setup_translation.py scripts/setup_native_translation.py "$APP/Contents/Resources/Translation/"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Keep the signed archive free of metadata added by cloud-synced folders.
ditto -c -k --norsrc --keepParent "$APP" "$PWD/CCAM Desktop.app.zip"
if [[ "${CCAM_BUILD_COPY_APP:-1}" != "0" ]]; then
  ditto --norsrc "$APP" "$DEST"
  echo "Built: $DEST"
fi
echo "Signed archive: $PWD/CCAM Desktop.app.zip"
