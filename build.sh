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
clang -O2 -mmacosx-version-min=13.0 -c Source/PTYBridge.c -o "$BUILD/PTYBridge.o"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$BUILD" -framework AppKit \
  -I "$BUILD/SwiftTerm" -import-objc-header Source/PTYBridge.h "$BUILD/PTYBridge.o" "$BUILD/SwiftTerm/libSwiftTerm.a" \
  Source/Theme.swift Source/NetworkEnvironment.swift Source/Core.swift Source/QuotaSummary.swift Source/ProjectStore.swift Source/BrowserLockStore.swift Source/BrowserRouting.swift Source/BrowserSettingsGuard.swift Source/BrowserLockWindow.swift Source/GlobalPool.swift Source/PoolCoordinator.swift Source/CommandCatalog.swift Source/UI.swift Source/OperationPresentation.swift Source/OperationWindow.swift Source/PTYSession.swift Source/TerminalCommandFilter.swift Source/TerminalWorkspace.swift Source/FeatureIndex.swift Source/CommandCenterView.swift Source/TaskComposer.swift Source/ChatAttachments.swift Source/AttachmentComposer.swift Source/ChatStore.swift Source/ChatRuntime.swift Source/ProjectChatView.swift Source/ProjectFiles.swift Source/ProjectGit.swift Source/ProjectWorkspace.swift Source/WorkspaceSidebar.swift Source/App.swift Source/App+Projects.swift Source/main.swift \
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
<key>CFBundleShortVersionString</key><string>2.4.0</string>
<key>CFBundleVersion</key><string>14</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [ -f Source/AppIcon.icns ]; then cp Source/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp Vendor/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp LICENSE "$APP/Contents/Resources/CCAM-Desktop-LICENSE.txt"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
# Keep the signed archive free of metadata added by cloud-synced folders.
ditto -c -k --norsrc --keepParent "$APP" "$PWD/CCAM Desktop.app.zip"
if [[ "${CCAM_BUILD_COPY_APP:-1}" != "0" ]]; then
  ditto --norsrc "$APP" "$DEST"
  echo "Built: $DEST"
fi
echo "Signed archive: $PWD/CCAM Desktop.app.zip"
