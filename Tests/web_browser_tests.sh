#!/bin/zsh
# Run from a normal graphical macOS session. Restricted execution sandboxes may
# forbid WebKit child processes even when localhost networking is permitted.
set -eu
cd -- "${0:A:h:h}"
web_sources=(Source/*.swift)
web_sources=(${web_sources:#Source/main.swift})
swiftc -swift-version 5 -module-cache-path "$PWD/.build-cache" -I .build-cache/SwiftTerm \
  -import-objc-header Source/PTYBridge.h .build-cache/PTYBridge.o .build-cache/SwiftTerm/libSwiftTerm.a \
  $web_sources Tests/WebBrowserTests.swift -o .build-cache/web-browser-tests
CCAM_WEB_STAGE="$(mktemp -d /private/tmp/ccam-web-qa.XXXXXX)"
trap '/bin/rm -rf "$CCAM_WEB_STAGE"' EXIT
python3 - "$PWD" "$CCAM_WEB_STAGE" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
repo,stage=map(Path,sys.argv[1:]); app=stage/'WebQA.app'; output=repo/'.build-cache/web-qa'
(app/'Contents/MacOS').mkdir(parents=True); (output/'screenshots').mkdir(parents=True,exist_ok=True)
shutil.copyfile(repo/'.build-cache/web-browser-tests',app/'Contents/MacOS/WebQA'); (app/'Contents/MacOS/WebQA').chmod(0o755)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'WebQA','CFBundleIdentifier':'local.ccam.web.tests','CFBundleName':'CCAM Web Tests','CFBundlePackageType':'APPL','NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsArbitraryLoadsInWebContent':True},'CCAMTestRepository':str(repo),'CCAMTestOutput':str(output)}))
PY
codesign --force --deep --sign - "$CCAM_WEB_STAGE/WebQA.app"
result=0
"$CCAM_WEB_STAGE/WebQA.app/Contents/MacOS/WebQA" || result=$?
cat .build-cache/web-qa/web-qa.log
exit "$result"
