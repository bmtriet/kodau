import AppKit
import SwiftUI
import KodauCore

/// Non-activating floating HUD panel that appears near the bottom-center of the screen while a clause is
/// composing, allowing instant 1-click or `⌥1..5` correction without stealing focus from the active editor.
/// Mirrors `KodauApp/System/CandidatePanel.swift` and picks its screen from the caret rectangle like
/// `CorrectionToastController`.
@MainActor
final class CandidatePopupController {

    static let shared = CandidatePopupController()

    private var panel: NSPanel?
    private var autoHideTimer: Timer?

    var onSelectCandidate: ((String) -> Void)?
    var onUndo: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    private init() {}

    func show(alternative: WordAlternative, near caretRect: NSRect?) {
        autoHideTimer?.invalidate()

        let hudView = CandidateHUDView(
            alternative: alternative,
            onSelect: { [weak self] candidate in
                self?.hide()
                self?.onSelectCandidate?(candidate)
            },
            onUndo: { [weak self] in
                self?.hide()
                self?.onUndo?()
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: hudView)
        let fittingSize = hostingView.fittingSize
        let width = max(320, min(fittingSize.width + 8, 720))
        let height = max(46, fittingSize.height)

        let panel = ensurePanel()
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: width, height: height))

        if let screen = screen(for: caretRect) ?? NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - (width / 2.0), y: visible.minY + 42.0))
        }

        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func screen(for caretRect: NSRect?) -> NSScreen? {
        if let rect = caretRect, rect != .zero {
            let point = NSPoint(x: rect.midX, y: rect.midY)
            if let match = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
                return match
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 48),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        created.level = .statusBar
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.ignoresMouseEvents = false
        created.hidesOnDeactivate = false
        created.becomesKeyOnlyIfNeeded = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel = created
        return created
    }
}

private struct CandidateHUDView: View {
    let alternative: WordAlternative
    let onSelect: (String) -> Void
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(alternative.baseWord)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())

            Divider()
                .frame(height: 18)

            ForEach(Array(alternative.candidates.prefix(5).enumerated()), id: \.offset) { index, word in
                let isSelected = (word == alternative.selected)
                Button {
                    onSelect(word)
                } label: {
                    HStack(spacing: 4) {
                        Text("⌥\(index + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        Text(word)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(Color.primary.opacity(0.07)),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 18)

            Button {
                onUndo()
            } label: {
                HStack(spacing: 3) {
                    Text("⌥Esc")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text("giữ gốc")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Hoàn tác về từ không dấu / tiếng Anh và dạy Kodau ghi nhớ")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .padding(4)
    }
}
