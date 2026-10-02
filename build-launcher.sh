#!/bin/sh
# Build a local native front end; no developer account or Xcode app required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/build/Bedrock for Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/swift-module-cache"
xcrun swiftc -parse-as-library -O -target arm64-apple-macos15.0 -module-cache-path "$ROOT/build/swift-module-cache" \
  "$ROOT/launcher/BedrockLauncher.swift" -o "$APP/Contents/MacOS/BedrockLauncher"
xcrun swiftc -O -module-cache-path "$ROOT/build/swift-module-cache" "$ROOT/launcher/Icon.swift" -o "$ROOT/build/make-icon"
"$ROOT/build/make-icon" "$ROOT/build/AppIcon.iconset"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/python3 - "$ROOT" "$APP" <<'PY'
import pathlib, plistlib, sys
root, app = sys.argv[1:]
with (pathlib.Path(app) / 'Contents/Info.plist').open('wb') as out:
    plistlib.dump(dict(CFBundleExecutable='BedrockLauncher', CFBundleIdentifier='local.bedrock.mac.launcher',
        CFBundleName='Bedrock for Mac', CFBundleDisplayName='Bedrock for Mac',
        CFBundlePackageType='APPL', CFBundleIconFile='AppIcon', CFBundleVersion='2', CFBundleShortVersionString='0.2.0',
        LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True, BedrockProjectPath=root), out)
PY
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
