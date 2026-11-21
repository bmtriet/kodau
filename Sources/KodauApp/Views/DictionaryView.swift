import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KodauCore

/// Personal Dictionary & Offline Brain Memory viewer/trainer.
public struct DictionaryView: View {
    @EnvironmentObject private var appState: AppState

    private enum MemorySection: String, CaseIterable, Identifiable {
        case words = "Từ vựng đã học"
        case phrases = "Cụm từ & Câu"
        var id: String { rawValue }
    }

    @State private var section: MemorySection = .words
    @State private var searchText: String = ""
    @State private var entries: [LearnedEntry] = []
    @State private var phrases: [LearnedPhrase] = []

    @State private var showImportSheet: Bool = false
    @State private var importCorpusText: String = ""
    @State private var statusBanner: String? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar header
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Từ điển & Bộ nhớ Offline")
                            .font(.title2.bold())
                        Text("Toàn bộ từ vựng, ngữ cảnh và câu đã học đều lưu cục bộ trên máy bạn bằng SQLite.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        showImportSheet = true
                    } label: {
                        Label("Nạp văn bản để dạy nhanh", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        exportJSONL()
                    } label: {
                        Label("Xuất dataset JSONL", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    Picker("Mục", selection: $section) {
                        ForEach(MemorySection.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Tìm kiếm từ không dấu, từ có dấu hoặc cụm từ...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                    Button {
                        reloadData()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Làm mới danh sách")
                }

                if let banner = statusBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(banner)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("Ẩn") {
                            statusBanner = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(20)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Content List
            if section == .words {
                wordsListView
            } else {
                phrasesListView
            }
        }
        .onAppear {
            reloadData()
        }
        .onChange(of: searchText) { _, _ in
            reloadData()
        }
        .onChange(of: section) { _, _ in
            reloadData()
        }
        .sheet(isPresented: $showImportSheet) {
            importCorpusSheet
        }
    }

    // MARK: - Words List

    @ViewBuilder
    private var wordsListView: some View {
        if entries.isEmpty {
            emptyStateView(
                icon: "text.book.closed",
                title: searchText.isEmpty ? "Chưa có từ vựng nào được ghi nhớ" : "Không tìm thấy từ phù hợp",
                subtitle: "Hãy gõ trong Playground, sử dụng bộ gõ toàn hệ thống, hoặc bấm \"Nạp văn bản để dạy nhanh\" để nạp ngay tin nhắn/email tiếng Việt của bạn."
            )
        } else {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Text(entry.baseWord)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(entry.surfaceForm)
                                .font(.body.weight(.semibold))
                        }
                        .frame(minWidth: 180, alignment: .leading)

                        if !entry.prevContext.isEmpty {
                            Text("sau \"\(entry.prevContext)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }

                        Spacer()

                        // EN / VI badge
                        Text(entry.isEnglish ? "EN" : "VI")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                (entry.isEnglish ? Color.gray : Color.blue).opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(entry.isEnglish ? Color.secondary : Color.blue)

                        // Verified badge
                        if entry.userVerified {
                            Label("Bạn đã xác nhận", systemImage: "checkmark.seal.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                        }

                        Text("\(entry.count) lần")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 52, alignment: .trailing)

                        Button(role: .destructive) {
                            appState.store.deleteEntry(
                                baseWord: entry.baseWord,
                                surfaceForm: entry.surfaceForm
                            )
                            reloadData()
                            appState.refreshStats()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Xóa mục này")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Phrases List

    @ViewBuilder
    private var phrasesListView: some View {
        if phrases.isEmpty {
            emptyStateView(
                icon: "quote.bubble",
                title: searchText.isEmpty ? "Chưa có cụm từ / câu nào" : "Không tìm thấy cụm từ phù hợp",
                subtitle: "Các câu được Gemini phục hồi hoặc bạn tự chỉnh sửa sẽ xuất hiện tại đây để Kodau phản hồi tức thì <1ms cho các lần sau."
            )
        } else {
            List {
                ForEach(phrases) { phrase in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phrase.restoredText)
                                .font(.body.weight(.medium))
                            Text(phrase.rawNoDiacritics)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(phrase.source)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.purple)

                                if phrase.userCorrected {
                                    Label("Đã sửa", systemImage: "checkmark.seal.fill")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }

                            Text("Dùng \(phrase.useCount) lần")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            appState.store.deletePhrase(id: phrase.id)
                            reloadData()
                            appState.refreshStats()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Xóa câu này")
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Import Corpus Sheet

    private var importCorpusSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nạp văn bản để dạy nhanh (Import Corpus)")
                        .font(.title3.bold())
                    Text("Dán các đoạn tin nhắn, email, ghi chú tiếng Việt (có dấu) xen kẽ tiếng Anh quen dùng của bạn. Kodau sẽ tự động trích xuất từ vựng & cặp từ ngữ cảnh vào bộ nhớ Offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            TextEditor(text: $importCorpusText)
                .font(.body)
                .padding(8)
                .frame(minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Button("Dán từ Clipboard") {
                    if let str = NSPasteboard.general.string(forType: .string) {
                        importCorpusText = str
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Hủy") {
                    showImportSheet = false
                }
                .buttonStyle(.bordered)

                Button {
                    let count = appState.store.importCorpus(importCorpusText)
                    importCorpusText = ""
                    showImportSheet = false
                    reloadData()
                    appState.refreshStats()
                    statusBanner = "Đã nạp và học thành công \(count) đơn vị từ vựng/ngữ cảnh vào bộ não Offline!"
                } label: {
                    Label("Nạp & Học ngay", systemImage: "brain.head.profile")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importCorpusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
    }

    // MARK: - Data Actions

    private func reloadData() {
        entries = appState.store.fetchLearnedEntries(search: searchText, limit: 300)
        phrases = appState.store.fetchLearnedPhrases(search: searchText, limit: 200)
    }

    private func exportJSONL() {
        let content = appState.store.exportDatasetJSONL()
        let panel = NSSavePanel()
        panel.title = "Xuất bộ dữ liệu cá nhân Kodau (JSONL)"
        panel.nameFieldStringValue = "kodau_personal_dataset.jsonl"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                statusBanner = "Đã xuất dataset thành công tới \(url.lastPathComponent)"
            } catch {
                statusBanner = "Lỗi khi xuất dataset: \(error.localizedDescription)"
            }
        }
    }
}
