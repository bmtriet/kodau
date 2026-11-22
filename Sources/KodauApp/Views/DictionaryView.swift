import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KodauCore

/// Personal dictionary: every learned word pair and phrase, searchable, importable and exportable.
public struct DictionaryView: View {
    @EnvironmentObject private var appState: AppState

    private enum Section: String, CaseIterable, Identifiable {
        case words = "Từ vựng"
        case phrases = "Cụm từ"
        var id: String { rawValue }
    }

    @State private var section: Section = .words
    @State private var searchText: String = ""
    @State private var entries: [LearnedEntry] = []
    @State private var phrases: [LearnedPhrase] = []

    @State private var showImportSheet: Bool = false
    @State private var importCorpusText: String = ""
    @State private var statusBanner: String? = nil

    public init() {}

    public var body: some View {
        PageScaffold("Từ điển", subtitle: subtitle) {
            VStack(spacing: 0) {
                controls
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)

                Divider()

                if section == .words {
                    wordsList
                } else {
                    phrasesList
                }
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

    private var subtitle: String {
        let count = section == .words ? entries.count : phrases.count
        let noun = section == .words ? "từ" : "cụm từ"
        return "\(count) \(noun) đã học, lưu cục bộ trên máy bạn."
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Picker("Mục", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                searchField

                Spacer(minLength: 0)

                Button {
                    showImportSheet = true
                } label: {
                    Label("Nạp văn bản", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    exportJSONL()
                } label: {
                    Label("Xuất JSONL", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    reloadData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Làm mới danh sách")
            }

            if let banner = statusBanner {
                HStack(spacing: Space.xs) {
                    Text(banner)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Ẩn") {
                        statusBanner = nil
                    }
                    .buttonStyle(.borderless)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Space.xxs + 2) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            TextField("Tìm từ không dấu hoặc có dấu", text: $searchText)
                .textFieldStyle(.plain)
                .font(Typography.body)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 4)
        .frame(maxWidth: 260)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: - Words

    @ViewBuilder
    private var wordsList: some View {
        if entries.isEmpty {
            emptyState(
                icon: "book.closed",
                title: searchText.isEmpty ? "Chưa có từ nào được ghi nhớ" : "Không tìm thấy từ phù hợp",
                message: searchText.isEmpty
                    ? "Gõ thử ở tab Gõ thử, hoặc nạp văn bản để dạy nhanh."
                    : "Thử một từ khoá khác."
            )
        } else {
            List(entries) { entry in
                DictionaryWordRow(entry: entry) {
                    appState.store.deleteEntry(
                        baseWord: entry.baseWord,
                        surfaceForm: entry.surfaceForm
                    )
                    reloadData()
                    appState.refreshStats()
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Phrases

    @ViewBuilder
    private var phrasesList: some View {
        if phrases.isEmpty {
            emptyState(
                icon: "text.bubble",
                title: searchText.isEmpty ? "Chưa có cụm từ nào" : "Không tìm thấy cụm từ phù hợp",
                message: searchText.isEmpty
                    ? "Những câu Kodau đã xử lý hoặc bạn tự sửa sẽ được nhớ để dùng lại tức thì."
                    : "Thử một từ khoá khác."
            )
        } else {
            List(phrases) { phrase in
                DictionaryPhraseRow(phrase: phrase) {
                    appState.store.deletePhrase(id: phrase.id)
                    reloadData()
                    appState.refreshStats()
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: Space.xs) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Typography.bodySemibold)
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.lg)
    }

    // MARK: - Import Sheet

    private var importCorpusSheet: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nạp văn bản để dạy nhanh")
                    .font(Typography.section)
                Text("Dán tin nhắn, email hoặc ghi chú tiếng Việt. Kodau tự trích từ vựng và ngữ cảnh vào bộ nhớ offline.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)

            Divider()

            TextEditor(text: $importCorpusText)
                .font(Typography.body)
                .padding(Space.xs)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 240)

            Divider()

            HStack(spacing: Space.xs) {
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
                    statusBanner = "Đã học \(count) đơn vị từ vựng/ngữ cảnh."
                } label: {
                    Text("Nạp & học")
                }
                .buttonStyle(.borderedProminent)
                .disabled(importCorpusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Space.md)
        }
        .frame(width: 540, height: 400)
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
                statusBanner = "Đã xuất \(url.lastPathComponent)."
            } catch {
                statusBanner = "Lỗi khi xuất: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Rows

/// One learned pair. Marks are shown only for exceptions (English word, unconfirmed entry);
/// the delete button appears on hover in a neutral colour.
private struct DictionaryWordRow: View {
    let entry: LearnedEntry
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text(entry.baseWord)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(entry.surfaceForm)
                    .font(Typography.bodyMedium)
            }
            .frame(minWidth: 170, alignment: .leading)

            if !entry.prevContext.isEmpty {
                Text(entry.prevContext)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.xs)

            if entry.isEnglish {
                Text("EN")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .help("Từ tiếng Anh, Kodau giữ nguyên")
            } else if !entry.userVerified {
                Image(systemName: "questionmark.circle")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .help("Chưa được bạn xác nhận")
            }

            Text("\(entry.count)")
                .font(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
                .help("Số lần đã gặp")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Xóa mục này")
            .frame(width: 18)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct DictionaryPhraseRow: View {
    let phrase: LearnedPhrase
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(phrase.restoredText)
                    .font(Typography.bodyMedium)
                    .lineLimit(2)
                Text(phrase.rawNoDiacritics)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.xs)

            if phrase.userCorrected {
                Image(systemName: "checkmark.seal")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .help("Bạn đã tự sửa câu này")
            }

            Text("\(phrase.useCount)")
                .font(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Số lần dùng")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help("Xóa câu này")
            .frame(width: 18)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
