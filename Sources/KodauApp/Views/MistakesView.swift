import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KodauCore

/// "Lỗi hay gặp" — the corrections Kodau got wrong, straight from the local correction log.
///
/// Top mistakes first (how often the same word was fixed), then the newest events. Everything stays on this
/// machine; the export button writes the exact corpus format `make bench` reads.
public struct MistakesView: View {
    @EnvironmentObject private var appState: AppState

    @State private var mistakes: [CorrectionMistake] = []
    @State private var events: [CorrectionEvent] = []
    @State private var statusBanner: String? = nil
    @State private var showClearConfirm: Bool = false

    private static let mistakeLimit = 20
    private static let eventLimit = 50

    public init() {}

    public var body: some View {
        PageScaffold("Lỗi hay gặp", subtitle: subtitle) {
            VStack(spacing: 0) {
                controls
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.md) {
                        mistakesCard
                        recentCard
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                }
            }
        }
        .onAppear(perform: reload)
        .alert("Xoá nhật ký lỗi?", isPresented: $showClearConfirm) {
            Button("Hủy", role: .cancel) {}
            Button("Xoá nhật ký", role: .destructive) {
                appState.store.clearCorrectionEvents()
                reload()
                statusBanner = "Đã xoá nhật ký lỗi."
            }
        } message: {
            Text("Chỉ xoá các lần bạn sửa dấu. Từ điển và bộ nhớ đã học vẫn giữ nguyên.")
        }
    }

    private var subtitle: String {
        if events.isEmpty {
            return "Những lần Kodau thêm dấu sai sẽ hiện ở đây, lưu cục bộ trên máy bạn."
        }
        return "\(events.count) lần gần đây · \(mistakes.count) kiểu lỗi · lưu cục bộ trên máy bạn."
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Button {
                    exportCorpus()
                } label: {
                    Label("Xuất bộ kiểm thử (.jsonl)", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(events.isEmpty)
                .help("Lưu các câu đã sửa thành bộ kiểm thử cho `make bench`.")

                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Làm mới")

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Xoá nhật ký", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(events.isEmpty)
            }

            if let banner = statusBanner {
                HStack(spacing: Space.xs) {
                    Text(banner)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Ẩn") { statusBanner = nil }
                        .buttonStyle(.borderless)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Top mistakes

    private var mistakesCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Từ hay bị sai dấu")
                .font(Typography.section)

            if mistakes.isEmpty {
                emptyRow("Chưa có lỗi nào được ghi. Cứ gõ bình thường, Kodau chỉ ghi lại khi bạn sửa dấu.")
            } else {
                mistakeHeader
                Divider()
                ForEach(Array(mistakes.enumerated()), id: \.offset) { index, mistake in
                    mistakeRow(mistake)
                    if index < mistakes.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .kodauCard()
    }

    private var mistakeHeader: some View {
        HStack(spacing: Space.xs) {
            Text("Từ gốc")
                .frame(width: 92, alignment: .leading)
            Text("Kodau ra")
                .frame(width: 92, alignment: .leading)
            Text("Đúng là")
                .frame(width: 92, alignment: .leading)
            Text("Số lần")
                .frame(width: 52, alignment: .trailing)
            Text("Ví dụ")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.captionMedium)
        .foregroundStyle(.secondary)
    }

    private func mistakeRow(_ mistake: CorrectionMistake) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(mistake.baseWord)
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(mistake.wrongSurface)
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(mistake.rightSurface)
                .font(Typography.bodyMedium)
                .frame(width: 92, alignment: .leading)
            Text("\(mistake.count)")
                .font(Typography.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(mistake.exampleSentence)
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Recent events

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Gần đây")
                .font(Typography.section)

            if events.isEmpty {
                emptyRow("Chưa có lần sửa nào. Thử gõ một câu, bấm Space rồi chọn từ khác.")
            } else {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    eventRow(event)
                    if index < events.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .kodauCard()
    }

    private func eventRow(_ event: CorrectionEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(event.action.label)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.finalOutput)
                    .font(Typography.bodyMedium)
                    .lineLimit(1)
                Text(event.rawClause)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.xs)

            if !event.wrongSurface.isEmpty, event.wrongSurface != event.rightSurface {
                Text("\(event.wrongSurface) → \(event.rightSurface)")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(event.createdAt, format: .dateTime.day().month().hour().minute())
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Data

    private func reload() {
        mistakes = appState.store.topCorrectionMistakes(limit: Self.mistakeLimit)
        events = appState.store.recentCorrectionEvents(limit: Self.eventLimit)
    }

    private func exportCorpus() {
        let content = appState.store.exportCorrectionCorpusJSONL()
        guard !content.isEmpty else {
            statusBanner = "Chưa có câu nào đủ để xuất (cần câu sửa giữ nguyên số từ)."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Xuất bộ kiểm thử Kodau (JSONL)"
        panel.nameFieldStringValue = "kodau_mistakes.jsonl"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            let lines = content.split(separator: "\n").count
            statusBanner = "Đã xuất \(lines) câu vào \(url.lastPathComponent)."
        } catch {
            statusBanner = "Lỗi khi xuất: \(error.localizedDescription)"
        }
    }
}
