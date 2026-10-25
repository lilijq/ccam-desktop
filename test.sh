#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p .build-cache
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/Theme.swift Tests/ThemeTests.swift -o .build-cache/theme-tests
.build-cache/theme-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/Core.swift Tests/CoreTests.swift -o .build-cache/core-tests
.build-cache/core-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/ProjectStore.swift Tests/ProjectTests.swift -o .build-cache/project-tests
.build-cache/project-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/OperationPresentation.swift Tests/OperationPresentationTests.swift -o .build-cache/presentation-tests
.build-cache/presentation-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/TerminalCommandFilter.swift Tests/TerminalCommandFilterTests.swift -o .build-cache/filter-tests
.build-cache/filter-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/Core.swift Source/CommandCatalog.swift Source/FeatureIndex.swift Tests/FeatureIndexTests.swift -o .build-cache/features-tests
.build-cache/features-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/ProjectStore.swift Source/BrowserLockStore.swift Tests/BrowserLockTests.swift -o .build-cache/browser-lock-tests
.build-cache/browser-lock-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/Core.swift Source/ProjectStore.swift Source/BrowserLockStore.swift Source/BrowserRouting.swift Tests/BrowserRoutingTests.swift -o .build-cache/browser-routing-tests
.build-cache/browser-routing-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/BrowserSettingsGuard.swift Tests/BrowserSettingsGuardTests.swift -o .build-cache/browser-settings-tests
.build-cache/browser-settings-tests
/usr/bin/python3 Tests/pty_tests.py
/usr/bin/python3 Tests/ccam_integration.py
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" -I .build-cache/SwiftTerm \
  -import-objc-header Source/PTYBridge.h .build-cache/PTYBridge.o .build-cache/SwiftTerm/libSwiftTerm.a \
  Source/Core.swift Source/CommandCatalog.swift Source/PTYSession.swift Tests/TerminalTests.swift -o .build-cache/terminal-tests
.build-cache/terminal-tests
/usr/bin/python3 Tests/command_coverage.py
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" -import-objc-header Source/PTYBridge.h .build-cache/PTYBridge.o \
  Source/Core.swift Source/GlobalPool.swift Source/PTYSession.swift Source/PoolCoordinator.swift Tests/PoolTests.swift -o .build-cache/pool-tests
.build-cache/pool-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" -D PROJECT_FILES_CORE_ONLY Source/ProjectFiles.swift Tests/ProjectFilesTests.swift -o .build-cache/files-tests
.build-cache/files-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" -D PROJECT_GIT_CORE_ONLY Source/ProjectGit.swift Tests/ProjectGitTests.swift -o .build-cache/git-tests
.build-cache/git-tests
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" Source/Core.swift Source/ProjectStore.swift Source/GlobalPool.swift Source/ChatStore.swift Source/ChatRuntime.swift Tests/ChatTests.swift -o .build-cache/chat-tests
.build-cache/chat-tests
if [[ -f 'CCAM Desktop.app.zip' ]]; then
  CCAM_VERIFY_DIR="$(mktemp -d /private/tmp/ccam-verify.XXXXXX)"
  trap '/bin/rm -rf "$CCAM_VERIFY_DIR"' EXIT
  ditto -x -k --norsrc 'CCAM Desktop.app.zip' "$CCAM_VERIFY_DIR"
  codesign --verify --deep --strict "$CCAM_VERIFY_DIR/CCAM Desktop.app"
  plutil -lint "$CCAM_VERIFY_DIR/CCAM Desktop.app/Contents/Info.plist"
else
  codesign --verify --deep --strict 'CCAM Desktop.app'
  plutil -lint 'CCAM Desktop.app/Contents/Info.plist'
fi
