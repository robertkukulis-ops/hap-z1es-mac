#!/bin/zsh
# Builds the app and wraps it in a minimal HAP.app bundle (in App/build/),
# so it can be double-clicked and has its own identity for macOS.
set -e
cd "${0:A:h}"
swift build -c release --arch arm64 --arch x86_64   # runs on Apple silicon and Intel Macs
BUNDLE=build/HAP.app
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/apple/Products/Release/HAPPlayer "$BUNDLE/Contents/MacOS/HAP"
cp Icon/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"   # made by Icon/make-icon.swift
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HAP</string>
    <key>CFBundleDisplayName</key><string>HAP</string>
    <key>CFBundleIdentifier</key><string>app.hap-player.HAP</string>
    <key>CFBundleExecutable</key><string>HAP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>HAP talks to your Sony HAP player on the local network.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$BUNDLE"
echo "Built $PWD/$BUNDLE"

# ./make-app.sh --install also puts it in /Applications (replacing an older HAP.app there).
if [[ "$1" == "--install" ]]; then
    rm -rf /Applications/HAP.app
    ditto "$BUNDLE" /Applications/HAP.app
    echo "Installed /Applications/HAP.app"
fi
