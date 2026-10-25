SwiftTerm 1.9.0 — vendored macOS terminal renderer
Source: https://github.com/migueldeicaza/SwiftTerm/tree/v1.9.0
License: MIT; see LICENSE. The application bundle includes a copy.

Included: Swift sources directly under Sources/SwiftTerm and its Apple/ and Mac/ directories.
Platform-specific iOS sources, samples and upstream tests are not included.
The empty upstream BufferSet.swift file is omitted.
Sources are compiled into a static library by ../../build.sh.
CCAM Desktop uses its own PTYSession and C PTYBridge for process execution;
SwiftTerm provides terminal emulation and the native AppKit terminal view.
