#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"

IM_NAME="KodauIM"
IM_DIR="${HOME}/Library/Input Methods"
IM_BUNDLE="${IM_DIR}/${IM_NAME}.app"
IM_CONTENTS="${IM_BUNDLE}/Contents"
IM_MACOS="${IM_CONTENTS}/MacOS"
IM_RESOURCES="${IM_CONTENTS}/Resources"

echo "==> Building Kodau & KodauIM (release)..."
cd "${PROJECT_ROOT}"
swift build -c release

IM_BIN="${PROJECT_ROOT}/.build/release/${IM_NAME}"
if [[ ! -f "${IM_BIN}" ]]; then
    echo "Error: KodauIM release binary not found at ${IM_BIN}" >&2
    exit 1
fi

echo "==> Stopping any running ${IM_NAME} instance..."
pkill -x "${IM_NAME}" 2>/dev/null || true
sleep 0.3

echo "==> Assembling ${IM_BUNDLE}..."
mkdir -p "${IM_DIR}" "${BUILD_DIR}"
rm -rf "${IM_BUNDLE}"
mkdir -p "${IM_MACOS}" "${IM_RESOURCES}/en.lproj" "${IM_RESOURCES}/vi.lproj"

cp "${IM_BIN}" "${IM_MACOS}/${IM_NAME}"
chmod +x "${IM_MACOS}/${IM_NAME}"

echo "==> Generating Input Menu bar icon (menu_icon.tiff)..."
MENU_ICON_SRC="${BUILD_DIR}/gen_menu_icon.swift"
MENU_ICON_BIN="${BUILD_DIR}/gen_menu_icon"
cat > "${MENU_ICON_SRC}" <<'EOF'
import Foundation
import AppKit

let outPath = CommandLine.arguments[1]

func renderTemplateImage(px: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: 18, height: 18)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    let rect = NSRect(x: 1.0, y: 2.0, width: 16.0, height: 14.0)
    let border = NSBezierPath(roundedRect: rect, xRadius: 3.2, yRadius: 3.2)
    border.lineWidth = 1.25
    NSColor.black.setStroke()
    border.stroke()

    let font = NSFont.systemFont(ofSize: 8.6, weight: .bold)
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black,
        .paragraphStyle: para
    ]
    let label = NSString(string: "KD")
    let size = label.size(withAttributes: attrs)
    let drawRect = NSRect(
        x: (18.0 - size.width) / 2.0,
        y: (18.0 - size.height) / 2.0 + 0.3,
        width: size.width,
        height: size.height
    )
    label.draw(in: drawRect, withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: 18, height: 18))
if let rep1x = renderTemplateImage(px: 18) { image.addRepresentation(rep1x) }
if let rep2x = renderTemplateImage(px: 36) { image.addRepresentation(rep2x) }
image.isTemplate = true

if let tiffData = image.tiffRepresentation {
    try tiffData.write(to: URL(fileURLWithPath: outPath))
}
EOF
swiftc "${MENU_ICON_SRC}" -framework AppKit -o "${MENU_ICON_BIN}"
"${MENU_ICON_BIN}" "${IM_RESOURCES}/menu_icon.tiff"
rm -f "${MENU_ICON_SRC}" "${MENU_ICON_BIN}"

echo "==> Writing InputMethodKit Info.plist & localized names..."
cat > "${IM_CONTENTS}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>vi</string>
    <key>CFBundleDisplayName</key>
    <string>Kodau</string>
    <key>CFBundleExecutable</key>
    <string>KodauIM</string>
    <key>CFBundleIdentifier</key>
    <string>com.kodau.inputmethod.KodauIM</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Kodau</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>InputMethodConnectionName</key>
    <string>KodauIM_Connection</string>
    <key>InputMethodServerControllerClass</key>
    <string>KodauIMController</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>TISInputSourceID</key>
    <string>com.kodau.inputmethod.KodauIM</string>
    <key>TISIntendedLanguage</key>
    <string>vi</string>
    <key>tsInputMethodCharacterRepertoireKey</key>
    <array>
        <string>Latn</string>
    </array>
    <key>tsInputMethodIconFileKey</key>
    <string>menu_icon.tiff</string>
    <key>ComponentInputModeDict</key>
    <dict>
        <key>tsInputModeListKey</key>
        <dict>
            <key>com.kodau.inputmethod.KodauIM.smart</key>
            <dict>
                <key>TISIntendedLanguage</key>
                <string>vi</string>
                <key>tsInputModeDefaultStateKey</key>
                <true/>
                <key>tsInputModeIsVisibleKey</key>
                <true/>
                <key>tsInputModeKeyEquivalentModifiersKey</key>
                <integer>4608</integer>
                <key>tsInputModeMenuIconFileKey</key>
                <string>menu_icon.tiff</string>
                <key>tsInputModePaletteIconFileKey</key>
                <string>menu_icon.tiff</string>
                <key>tsInputModePrimaryInScriptKey</key>
                <true/>
                <key>tsInputModeScriptKey</key>
                <string>smUnicodeScript</string>
            </dict>
        </dict>
        <key>tsVisibleInputModeOrderedArrayKey</key>
        <array>
            <string>com.kodau.inputmethod.KodauIM.smart</string>
        </array>
    </dict>
</dict>
</plist>
PLIST

cat > "${IM_RESOURCES}/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Kodau";
"CFBundleDisplayName" = "Kodau";
"com.kodau.inputmethod.KodauIM" = "Kodau";
"com.kodau.inputmethod.KodauIM.smart" = "Kodau (Smart Vi/En)";
STRINGS

cat > "${IM_RESOURCES}/vi.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleName" = "Kodau";
"CFBundleDisplayName" = "Kodau";
"com.kodau.inputmethod.KodauIM" = "Kodau";
"com.kodau.inputmethod.KodauIM.smart" = "Kodau (Việt Không Dấu + Anh)";
STRINGS

echo "==> Ad-hoc code signing ${IM_BUNDLE}..."
codesign --force --deep --sign - "${IM_BUNDLE}"

echo "==> Registering Kodau in macOS Input Sources (TIS)..."
REG_SRC="${BUILD_DIR}/register_tis.swift"
REG_BIN="${BUILD_DIR}/register_tis"
cat > "${REG_SRC}" <<'EOF'
import Foundation
import Carbon

// Usage: register_tis register <bundle>   |   register_tis count
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "count"
if mode == "register", CommandLine.arguments.count > 2 {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    print("    TISRegisterInputSource status: \(TISRegisterInputSource(url as CFURL))")
} else {
    let filter = [kTISPropertyBundleID as String: "com.kodau.inputmethod.KodauIM"] as CFDictionary
    let sources = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    print(sources.count)
}
EOF
swiftc "${REG_SRC}" -framework Carbon -o "${REG_BIN}"

# macOS processes the bundle change asynchronously and drops any registration made right after the
# bundle was modified (Kodau then vanishes from Input Sources). Let it settle, register again, and
# verify from a separate process until the registration sticks.
REGISTERED=0
for attempt in 1 2 3 4 5; do
    sleep 4
    "${REG_BIN}" register "${IM_BUNDLE}"
    sleep 6
    COUNT="$("${REG_BIN}" count)"
    echo "    attempt ${attempt}: ${COUNT} Kodau input source(s) visible to macOS"
    if [[ "${COUNT}" -ge 2 ]]; then
        REGISTERED=1
        break
    fi
done
rm -f "${REG_SRC}" "${REG_BIN}"
if [[ "${REGISTERED}" -ne 1 ]]; then
    echo "Warning: Kodau registration did not stick yet; log out and back in so macOS rescans ~/Library/Input Methods." >&2
fi

echo "==> Rebuilding Kodau.app Dashboard (synced with KodauIM)..."
"${SCRIPT_DIR}/build_app.sh"

echo ""
echo "✅ Native macOS Input Method installed: ${IM_BUNDLE}"
echo "   macOS requires you to add third-party input methods yourself (once):"
echo "   System Settings -> Keyboard -> Text Input -> Input Sources: Edit... -> + -> Vietnamese -> 'Kodau (Smart Vi/En)' -> Add"
echo "   If it is not listed yet, log out and log back in, then try again."
