#!/bin/zsh
set -eu
cd -- "${0:A:h:h}"
ui_sources=(Source/*.swift)
ui_sources=(${ui_sources:#Source/main.swift})
ui_tests=(Tests/*UITests.swift)
swiftc -D CHAT_UI_FIXTURES -swift-version 5 -module-cache-path "$PWD/.build-cache" -I .build-cache/SwiftTerm \
  -import-objc-header Source/PTYBridge.h .build-cache/PTYBridge.o .build-cache/SwiftTerm/libSwiftTerm.a \
  $ui_sources $ui_tests Tests/ChatTests.swift -o .build-cache/chat-ui-tests
.build-cache/chat-ui-tests
