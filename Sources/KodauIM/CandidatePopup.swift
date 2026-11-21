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
    private var isHovering = false

    var onSelectCandidate: ((String) -> Void)?
    var onUndo: (() -> Void)?
    /// "Xem thêm" chip — same effect as `⌥6`: expand / page the focused word's candidates.
    var onExpand: (() -> Void)?
    /// "Gõ từ khác" chip — same effect as `⌥E`: retype the focused word in place.
    var onEditWord: (() -> Void)?
    /// Called whenever the panel actually leaves the screen (timer, click, explicit hide).
    var onHide: (() -> Void)?

    /// Current presentation, so the auto-hide timer knows whether the user is actively choosing.
    private var currentPresentation: CandidatePresentation?

    var isVisible: Bool { panel?.isVisible ?? false }

    private init() {}

    func show(_ presentation: CandidatePresentation, near caretRect: NSRect?) {
        autoHideTimer?.invalidate()
        currentPresentation = presentation

        let hudView = CandidateHUDView(
            presentation: presentation,
            onSelect: { [weak self] candidate in
                self?.hide()
                self?.onSelectCandidate?(candidate)
            },
            onUndo: { [weak self] in
                self?.hide()
                self?.onUndo?()
            },
            onExpand: { [weak self] in
                self?.onExpand?()
            },
            onEditWord: { [weak self] in
                self?.onEditWord?()
            },
            onClose: { [weak self] in
                self?.hide()
            },
            onHover: { [weak self] hovering in
                self?.setHovering(hovering)
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

        restartAutoHideTimer()
    }

    func hide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        isHovering = false
        currentPresentation = nil
        let wasVisible = panel?.isVisible ?? false
        panel?.orderOut(nil)
        if wasVisible {
            onHide?()
        }
    }

    // MARK: - Private

    private func restartAutoHideTimer() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        // Expanded (`⌥6`) lists and the inline retype (`⌥E`) sub-state keep the popup open: the user is choosing.
        guard !isHovering, currentPresentation?.keepsPopupOpen != true else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            autoHideTimer?.invalidate()
            autoHideTimer = nil
        } else if panel?.isVisible == true {
            restartAutoHideTimer()
        }
    }

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
    let presentation: CandidatePresentation
    let onSelect: (String) -> Void
    let onUndo: () -> Void
    let onExpand: () -> Void
    let onEditWord: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    private var alternative: WordAlternative { presentation.alternative }
    private var isGeminiChange: Bool { !presentation.geminiChanges.isEmpty }

    private var changeSummary: String {
        let items = presentation.geminiChanges.prefix(3).map { "\($0.from) → \($0.to)" }
        return "Gemini: " + items.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 6) {
            headerChip

            Divider()
                .frame(height: 14)

            candidatesSection

            Divider()
                .frame(height: 14)

            actionsSection

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Đóng")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(4)
        .onHover { hovering in
            onHover(hovering)
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        if let hint = presentation.editHint {
            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            ForEach(Array(alternative.candidates.prefix(5).enumerated()), id: \.offset) { index, word in
                candidateButton(index: index, word: word)
            }

            if alternative.candidates.count <= 1 {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func candidateButton(index: Int, word: String) -> some View {
        let isSelected = (word == alternative.selected)
        let shortcut = "⌥" + String(index + 1)
        return Button {
            onSelect(word)
        } label: {
            HStack(spacing: 3) {
                Text(shortcut)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                Text(word)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(Color.primary.opacity(0.05)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actionsSection: some View {
        if presentation.editHint == nil {
            expandButton
            editWordButton
        }

        Button {
            onUndo()
        } label: {
            Text(isGeminiChange ? "Hoàn tác" : "Giữ gốc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(isGeminiChange
              ? "Hoàn tác các từ Gemini vừa đổi (⌥Esc)"
              : "Hoàn tác về từ không dấu / tiếng Anh và dạy Kodau ghi nhớ (⌥Esc)")
    }

    /// "Thêm…" opens the focused word's full diacritic list, paged 5 at a time.
    private var expandButton: some View {
        let label = presentation.isExpanded
            ? "Trang " + String(presentation.page) + "/" + String(presentation.pageCount)
            : "Thêm…"
        return Button {
            onExpand()
        } label: {
            HStack(spacing: 3) {
                Text("⌥6")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(presentation.isExpanded ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Xem mọi dạng dấu hợp lệ của từ này (bấm lại để sang trang)")
    }

    /// "Gõ từ khác" retypes just this word in place.
    private var editWordButton: some View {
        Button {
            onEditWord()
        } label: {
            HStack(spacing: 3) {
                Text("⌥E")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("Gõ từ khác")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help("Gõ lại riêng từ này, không cần xoá các từ phía sau")
    }

    private var headerChip: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.editHint != nil ? "pencil" : "sparkles")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(isGeminiChange ? changeSummary : alternative.baseWord)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(0.05),
            in: Capsule()
        )
    }
}
