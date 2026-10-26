#!/bin/zsh
# Focus Guard 맥 앱을 빌드해서 app/FocusGuard.app 을 만든다.
# 기록은 앱 밖(data.json)에 저장되므로 다시 빌드해도 지워지지 않는다.
set -euo pipefail
cd "$(dirname "$0")"

APP=FocusGuard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/FocusGuard" Sources/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.focusguard.app</string>
  <key>CFBundleName</key><string>FocusGuard</string>
  <key>CFBundleDisplayName</key><string>Focus Guard</string>
  <key>CFBundleExecutable</key><string>FocusGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>집중 시간에 분산 사이트 탭을 차단 페이지로 바꾸고, 딴짓 시간을 기록하려고 브라우저의 현재 탭 주소를 확인해요.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built $(pwd)/$APP"
