#!/bin/bash
# Build "Inkpage.app": a release build wrapped in an app bundle and signed for local use.
#   ./bundle.sh            -> build/Inkpage.app
# The Keychain and the web view's saved data need a bundle identifier, which a bare executable lacks.
set -euo pipefail
cd "$(dirname "$0")"
# The linker would otherwise record the deployment target as the SDK the app was built with,
# and macOS then draws the app in the look of that system instead of the current one.
sdk="$(xcrun --show-sdk-version)"
swift build -c release --product SNotes -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$sdk" 2>&1 | grep -E "error|Build complete" | tail -3
bin="$(swift build -c release --show-bin-path)/SNotes"
app="build/Inkpage.app"
rm -rf "$app" build/SNotes.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Inkpage"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.krushock.inkpage</string>
    <key>CFBundleName</key><string>Inkpage</string>
    <key>CFBundleDisplayName</key><string>Inkpage</string>
    <key>CFBundleExecutable</key><string>Inkpage</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Inkpage records from the microphone when you choose Insert › Voice Recording in a note.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Sign with a development identity when one exists: the Keychain ties the saved account to the
# app's signature, and an ad hoc signature changes with every build. SNOTES_ADHOC=1 forces ad hoc.
identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
if [ -n "$identity" ] && [ -z "${SNOTES_ADHOC:-}" ] && codesign --force --sign "$identity" "$app" 2>/dev/null; then
  echo "signed with $identity"
else
  codesign --force --sign - "$app" 2>&1 | tail -1
fi
echo "built $app"
