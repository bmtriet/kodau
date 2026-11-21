import Cocoa
import SwiftUI
import KodauCore

/// Non-activating toast shown at the bottom-center of the screen when the user re-edits a word Kodau restored
/// (e.g. `bán → bạn`). The user confirms with a click or `⌥↩`; ignoring it (or `Bỏ qua`) learns nothing.
/// Never takes keyboard focus away from the app being typed in.
@MainActor
final class CorrectionToastController {

    static let shared = CorrectionToastController()

    private var panel: NSPanel?
    private var autoHideTimer: Timer?
    private(set) var pending: EditCorrectionCandidate?

    /// Called when the user confirms the pending candidate.
    var onConfirm: ((EditCorrectionCandidate) -> Void)?

    var isVisible: Bool { pending != nil && (panel?.isVisible ?? false) }

    func show(_ candidate: EditCorrectionCandidate, near caretRect: NSRect?) {
        pending = candidate
        render(ToastView(
            candidate: candidate,
            state: .asking,
            onConfirm: { [weak self] in self?.confirm() },
            onDismiss: { [weak self] in self?.dismiss() }
        ), screen: screen(for: caretRect))
        scheduleAutoHide(after: 10)
    }

    /// Confirms the pending candidate (button click or `⌥↩`). Returns false when nothing is pending.
    @discardableResult
    func confirm() -> Bool {
        guard let candidate = pending else { return false }
        pending = nil
        onConfirm?(candidate)
        render(ToastView(candidate: candidate, state: .learned, onConfirm: {}, onDismiss: { [weak self] in self?.dismiss() }),
               screen: panel?.screen)
        scheduleAutoHide(after: 1.4)
        return true
    }

    func dismiss() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        pending = nil
        panel?.orderOut(nil)
    }

    // MARK: - Private

    private func render(_ view: ToastView, screen: NSScreen?) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let width = max(360, min(size.width, 760))
        let height = max(52, size.height)

        let panel = ensurePanel()
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: width, height: height))

        if let screen = screen ?? NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 48))
        }
        panel.orderFrontRegardless()
    }

    private func scheduleAutoHide(after seconds: TimeInterval) {
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        created.level = .statusBar
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.becomesKeyOnlyIfNeeded = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel = created
        return created
    }
}

private struct ToastView: View {
    enum State { case asking, learned }

    let candidate: EditCorrectionCandidate
    let state: State
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state == .learned ? "checkmark.seal.fill" : "graduationcap.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state == .learned ? Color.green : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(state == .learned ? "Kodau đã học từ này" : "Kodau học từ bạn vừa sửa?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if !candidate.contextBefore.isEmpty {
                        Text(candidate.contextBefore)
                            .foregroundStyle(.secondary)
                    }
                    Text(candidate.originalSurface)
                        .strikethrough(true, color: .red.opacity(0.8))
                        .foregroundStyle(.red.opacity(0.85))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(candidate.correctedSurface)
                        .fontWeight(.bold)
                        .foregroundStyle(.green)
                    if let next = candidate.next1 {
                        Text(next)
                            .foregroundStyle(.secondary)
                    }
                    Text("(\(candidate.baseWord))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 14))
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if state == .asking {
                Button(action: onConfirm) {
                    HStack(spacing: 5) {
                        Text("Học từ này")
                            .font(.system(size: 12, weight: .semibold))
                        Text("⌥↩")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Bỏ qua")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .padding(6)
    }
}
