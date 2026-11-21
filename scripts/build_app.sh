#!/usr/bin/env bash
set -euo pipefail

# Stable local signing identity (see scripts/setup_signing.sh); falls back to ad-hoc ("-") when absent.
SIGN_IDENTITY="${KODAU_SIGN_IDENTITY:-Kodau Local Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"${SIGN_IDENTITY}\""; then
    SIGN_ARG="${SIGN_IDENTITY}"
else
    SIGN_ARG="-"
    echo "Note: '${SIGN_IDENTITY}' not found, signing ad-hoc. Run ./scripts/setup_signing.sh once so macOS keeps the Accessibility permission across rebuilds."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
APP_NAME="Kodau"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"

echo "==> Building ${APP_NAME} (release)..."
cd "${PROJECT_ROOT}"
swift build -c release

BIN_PATH="${PROJECT_ROOT}/.build/release/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Error: Release binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}" "${ICONSET_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${ICONSET_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> Generating macOS AppIcon.icns..."
ICON_GEN_SRC="${BUILD_DIR}/gen_icon.swift"
ICON_GEN_BIN="${BUILD_DIR}/gen_icon"
cat > "${ICON_GEN_SRC}" <<'EOF'
import Foundation
import AppKit
import CoreGraphics

let iconsetPath = CommandLine.arguments[1]
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(px: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let s = CGFloat(px)
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Gradient background: electric blue -> deep indigo
    let colors = [
        CGColor(red: 0.14, green: 0.46, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.34, green: 0.24, blue: 0.88, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Subtle top highlight sheen
    let sheenColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }
    ctx.restoreGState()

    // Border highlight
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.24))
    ctx.setLineWidth(max(1.0, s * 0.015))
    ctx.strokePath()
    ctx.restoreGState()

    // Draw "KD" typography + Vietnamese acute accent bar above
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext

    // Accent mark (Vietnamese diacritic motif)
    let accentPath = NSBezierPath()
    accentPath.move(to: NSPoint(x: s * 0.46, y: s * 0.72))
    accentPath.line(to: NSPoint(x: s * 0.62, y: s * 0.80))
    accentPath.lineWidth = max(1.5, s * 0.055)
    accentPath.lineCapStyle = .round
    NSColor(calibratedRed: 0.52, green: 0.96, blue: 0.80, alpha: 1.0).setStroke()
    accentPath.stroke()

    let font = NSFont.systemFont(ofSize: s * 0.40, weight: .heavy)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let text = NSString(string: "KD")
    let textSize = text.size(withAttributes: attrs)
    let textRect = CGRect(
        x: (s - textSize.width) / 2.0,
        y: (s - textSize.height) / 2.0 - s * 0.05,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

for item in sizes {
    if let data = renderIcon(px: item.px) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(item.name)
        try? data.write(to: outURL)
    }
}
EOF
swiftc "${ICON_GEN_SRC}" -framework AppKit -framework CoreGraphics -o "${ICON_GEN_BIN}"
"${ICON_GEN_BIN}" "${ICONSET_DIR}"
rm -f "${ICON_GEN_SRC}" "${ICON_GEN_BIN}"

if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
fi
rm -rf "${ICONSET_DIR}"

echo "==> Writing Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>vi</string>
    <key>CFBundleDisplayName</key>
    <string>Kodau</string>
    <key>CFBundleExecutable</key>
    <string>Kodau</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.kodau.inputmethod</string>
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
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Kodau cần quyền Trợ năng và sự kiện bàn phím để tự động phục hồi dấu tiếng Việt toàn hệ thống (và tự động tạm dừng trong ô mật khẩu).</string>
</dict>
</plist>
PLIST

echo "==> Code signing ${APP_BUNDLE} (identity: ${SIGN_ARG})..."
codesign --force --deep --sign "${SIGN_ARG}" "${APP_BUNDLE}"

echo ""
echo "✅ Built successfully: ${APP_BUNDLE}"
echo "   Run with: open \"${APP_BUNDLE}\""
