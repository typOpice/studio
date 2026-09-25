#!/bin/bash
# Builds the editor and the play client, each wrapped in a minimal .app bundle.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

bundle() {
    local app="$1" executable="$2" binary="$3" identifier="$4" name="$5"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN_DIR/$binary" "$app/Contents/MacOS/$executable"

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>$executable</string>
    <key>CFBundleIdentifier</key><string>$identifier</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>Finds and hosts games on your local network.</string>
    <key>NSBonjourServices</key><array><string>_studioplay._tcp</string></array>
</dict>
</plist>
PLIST

    codesign --force --deep --sign - "$app" 2>/dev/null || true
    echo "Built $app"
}

bundle "Studio.app"       "Studio" "StudioApp"    "local.studio.workspace" "Studio"
bundle "StudioClient.app" "Client" "StudioClient" "local.studio.client"    "Studio Client"

# The editor's "Client" button looks for this next to its own binary.
cp "$BIN_DIR/StudioClient" "Studio.app/Contents/MacOS/StudioClient"
codesign --force --sign - "Studio.app" 2>/dev/null || true
