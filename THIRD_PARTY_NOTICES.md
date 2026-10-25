# Third-party notices

## SwiftTerm

`Vendor/SwiftTerm` contains the macOS, Apple-shared, and platform-neutral sources from [SwiftTerm v1.9.0](https://github.com/migueldeicaza/SwiftTerm/tree/v1.9.0). SwiftTerm is distributed under the MIT License. Its original copyright notices and license are preserved in [Vendor/SwiftTerm/LICENSE](Vendor/SwiftTerm/LICENSE), and the app bundles that license.

The source subset is described in [Vendor/SwiftTerm/README.txt](Vendor/SwiftTerm/README.txt). CCAM Desktop provides its own PTY process bridge and uses SwiftTerm for terminal rendering.

## External software

[CCAM](https://github.com/jhyunwoo/ccam), Claude Code, Google Chrome, macOS frameworks, and their trademarks belong to their respective owners. They are external prerequisites, not distributed under this project's license.

## Capability reference

[siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) informed the organization of chat, files, Git, and terminal workflows. CCAM Desktop independently implements these views in Swift/AppKit. It does not bundle that project's source, server, SDK integration, or interface assets. This is not an official integration or endorsement.
