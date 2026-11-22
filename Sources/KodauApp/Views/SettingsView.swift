import SwiftUI
import KodauCore

/// Native macOS settings screen: grouped `Form` with short footers and tooltips instead of
/// long help paragraphs.
public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var newBundleID: String = ""
    @State private var showResetConfirm: Bool = false
    @State private var customGeminiModelInput: String = ""
    @State private var isUsingCustomModel: Bool = false

    private var defaultGeminiModel: String {
        AppConfig.availableGeminiModels.first ?? "gemini-3.5-flash-lite"
    }

    private let quickExcludePresets: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Xcode", "com.apple.dt.Xcode")
    ]

    public init() {}

    public var body: some View {
        PageScaffold("Cài đặt") {
            Form {
                typingSection
                brainSection
                inputSourceSection
                advancedSection
                dataSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .alert("Xóa toàn bộ bộ nhớ đã học?", isPresented: $showResetConfirm) {
            Button("Hủy", role: .cancel) {}
            Button("Xóa toàn bộ", role: .destructive) {
                appState.store.resetAllData()
                appState.refreshStats()
            }
        } message: {
            Text("Từ vựng, cụm từ và số lượt chuyển đổi sẽ bị xóa vĩnh viễn. API Key được giữ nguyên.")
        }
    }

    // MARK: - Gõ phím

    private var typingSection: some View {
        Section("Gõ phím") {
            Picker("Chế độ gõ", selection: Binding(
                get: { appState.config.typingMode },
                set: { appState.setMode($0) }
            )) {
                ForEach(TypingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .help("⌃⇧Space để chuyển nhanh giữa KD / VNI / EN")

            Picker("Thêm dấu", selection: Binding(
                get: { appState.config.triggerMode },
                set: { appState.setTriggerMode($0) }
            )) {
                ForEach(ConversionTriggerMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .help("⌥Space luôn thêm dấu ngay cho dòng đang gõ.")

            Toggle("Popup gợi ý từ sau khi thêm dấu", isOn: Binding(
                get: { appState.config.showCandidateHUD },
                set: {
                    appState.config.showCandidateHUD = $0
                    appState.saveConfig()
                }
            ))
            .help("Thanh nhỏ ở đáy màn hình để chọn từ khác. Tắt cũng không ảnh hưởng ⌥1…5 và ⌥Esc.")

            Toggle("Cho phép gõ số VNI trong chế độ Thông minh", isOn: Binding(
                get: { appState.config.inlineVNIOverrideEnabled },
                set: {
                    appState.config.inlineVNIOverrideEnabled = $0
                    appState.saveConfig()
                }
            ))
            .help("Ví dụ ban5 → bạn, ngay khi đang ở chế độ Thông minh.")

            Toggle("Đặt dấu kiểu mới (hòa, khỏe, thủy)", isOn: Binding(
                get: { appState.config.modernTonePlacement },
                set: {
                    appState.config.modernTonePlacement = $0
                    appState.saveConfig()
                }
            ))
            .help("Tắt để dùng kiểu cũ: hoà, khoẻ, thuỷ.")
        }
    }

    // MARK: - AI & Offline

    private var brainSection: some View {
        Section {
            Picker("Chiến lược", selection: Binding(
                get: { appState.config.brainStrategy },
                set: { appState.setStrategy($0) }
            )) {
                ForEach(BrainStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.config.hasAPIKey ? "Đã có API Key" : "Chưa có API Key")
                        .font(Typography.body)
                    Text(appState.maskedAPIKeyDisplay)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Nhập / Kiểm tra") {
                    appState.showAPIKeyDialog = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Picker("Model Gemini", selection: Binding(
                get: {
                    if isUsingCustomModel || !AppConfig.availableGeminiModels.contains(appState.config.geminiModel) {
                        return "__custom__"
                    }
                    return appState.config.geminiModel
                },
                set: { newValue in
                    if newValue == "__custom__" {
                        isUsingCustomModel = true
                        if customGeminiModelInput.isEmpty {
                            customGeminiModelInput = appState.config.geminiModel
                        }
                    } else {
                        isUsingCustomModel = false
                        appState.config.geminiModel = newValue
                        appState.saveConfig()
                    }
                }
            )) {
                ForEach(AppConfig.availableGeminiModels, id: \.self) { model in
                    Text(model == defaultGeminiModel ? "\(model) (mặc định)" : model).tag(model)
                }
                Divider()
                Text("Tùy chỉnh…").tag("__custom__")
            }

            if isUsingCustomModel || !AppConfig.availableGeminiModels.contains(appState.config.geminiModel) {
                HStack(spacing: Space.xs) {
                    TextField("Tên model", text: $customGeminiModelInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Áp dụng") {
                        let trimmed = customGeminiModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        appState.config.geminiModel = trimmed.isEmpty ? defaultGeminiModel : trimmed
                        appState.saveConfig()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            LabeledContent("Hạn mức mỗi ngày") {
                HStack(spacing: Space.xxs + 2) {
                    TextField("0", value: Binding(
                        get: { appState.config.dailyGeminiCallLimit },
                        set: {
                            appState.config.dailyGeminiCallLimit = max(0, $0)
                            appState.saveConfig()
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    Text("lượt")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)

                    TextField("0", value: Binding(
                        get: { Int(appState.config.dailyGeminiBudgetVND.rounded()) },
                        set: {
                            appState.config.dailyGeminiBudgetVND = Double(max(0, $0))
                            appState.saveConfig()
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    Text("₫")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .help("Đặt 0 để không giới hạn. Chạm hạn mức, Kodau tự chạy offline đến hết ngày.")

            Toggle("Sửa lỗi chính tả rõ ràng bằng Gemini", isOn: Binding(
                get: { appState.config.fixTyposEnabled },
                set: {
                    appState.config.fixTyposEnabled = $0
                    appState.saveConfig()
                }
            ))
            .help("Chỉ sửa từ gõ sai 1–2 ký tự (dnag → đang). Không viết tắt, không viết lại câu.")

            Picker("Thời điểm gọi Gemini", selection: Binding(
                get: { appState.config.geminiTiming },
                set: {
                    appState.config.geminiTiming = $0
                    appState.saveConfig()
                }
            )) {
                ForEach(GeminiTiming.allCases) { timing in
                    Text(timing.displayName).tag(timing)
                }
            }
            .help(appState.config.geminiTiming.subtitle)

            sliderRow(
                title: "Ngưỡng tự tin offline",
                valueText: "\(Int((appState.config.localConfidenceThreshold * 100).rounded()))%",
                help: "Thấp hơn = xử lý offline nhiều hơn. Cao hơn = nhờ Gemini kiểm tra kỹ hơn."
            ) {
                Slider(
                    value: Binding(
                        get: { appState.config.localConfidenceThreshold },
                        set: {
                            appState.config.localConfidenceThreshold = $0
                            appState.saveConfig()
                        }
                    ),
                    in: 0.50...0.98,
                    step: 0.02
                )
            }

            if appState.config.geminiTiming == .perSentence {
                sliderRow(
                    title: "Chờ ngừng gõ trước khi gửi câu",
                    valueText: String(format: "%.1f giây", Double(appState.config.sentencePauseMilliseconds) / 1000.0),
                    help: "Áp dụng khi bạn dừng gõ giữa câu."
                ) {
                    Slider(
                        value: Binding(
                            get: { Double(appState.config.sentencePauseMilliseconds) },
                            set: {
                                appState.config.sentencePauseMilliseconds = Int($0.rounded())
                                appState.saveConfig()
                            }
                        ),
                        in: 800...4000,
                        step: 100
                    )
                }
            }

            sliderRow(
                title: "Giãn cách giữa 2 lần gọi",
                valueText: appState.config.minGeminiIntervalSeconds <= 0
                    ? "Không giới hạn"
                    : String(format: "%.1f giây", appState.config.minGeminiIntervalSeconds),
                help: "0 = không giới hạn."
            ) {
                Slider(
                    value: Binding(
                        get: { appState.config.minGeminiIntervalSeconds },
                        set: {
                            appState.config.minGeminiIntervalSeconds = $0
                            appState.saveConfig()
                        }
                    ),
                    in: 0...5,
                    step: 0.5
                )
            }

            sliderRow(
                title: "Độ trễ chờ ngừng gõ (thời gian thực)",
                valueText: "\(appState.config.debounceMilliseconds) ms",
                help: "Chỉ dùng khi chọn Thời gian thực."
            ) {
                Slider(
                    value: Binding(
                        get: { Double(appState.config.debounceMilliseconds) },
                        set: {
                            appState.config.debounceMilliseconds = Int($0.rounded())
                            appState.saveConfig()
                        }
                    ),
                    in: 150...1200,
                    step: 50
                )
            }

            Toggle("Tự động gợi ý 100% Offline khi đạt Giai đoạn 4", isOn: Binding(
                get: { appState.config.autoSuggestOfflineMode },
                set: {
                    appState.config.autoSuggestOfflineMode = $0
                    appState.saveConfig()
                }
            ))
            .help("Hiện nút chuyển offline một lần khi bộ nhớ đã đủ mạnh.")
        } header: {
            Text("AI & Offline")
        } footer: {
            Text("Kodau luôn thêm dấu được khi offline; Gemini chỉ giúp học nhanh hơn.")
        }
    }

    // MARK: - Bộ gõ hệ thống

    private var inputSourceSection: some View {
        Section {
            HStack(spacing: Space.xs) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(kodauIMStatusTitle)
                    .font(Typography.body)
                Spacer()
                switch appState.kodauIMStatus {
                case .installedNotEnabled:
                    Button("Mở Input Sources") {
                        appState.openInputSourcesSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                case .enabledNotSelected:
                    Button("Chọn Kodau") {
                        appState.selectKodauIM()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                case .notInstalled:
                    EmptyView()
                case .active:
                    EmptyView()
                }
            }
            .help(kodauIMStatusCaption)

            Toggle("Luôn hiện biểu tượng Kodau trên thanh menu", isOn: Binding(
                get: { appState.config.alwaysShowMenuBarIcon },
                set: {
                    appState.config.alwaysShowMenuBarIcon = $0
                    appState.saveConfig()
                }
            ))
            .help("Mặc định tắt: KodauIM đã có menu riêng trên thanh menu.")

            Toggle("Chế độ cũ: chặn phím toàn hệ thống", isOn: Binding(
                get: { appState.config.legacyEventTapEnabled },
                set: {
                    appState.config.legacyEventTapEnabled = $0
                    appState.saveConfig()
                }
            ))
            .help("Cần quyền Trợ năng. Chỉ dùng khi KodauIM không hoạt động trong một ứng dụng cụ thể.")

            if appState.config.legacyEventTapEnabled && !appState.accessibilityGranted {
                HStack(spacing: Space.xs) {
                    Text("Chế độ cũ cần quyền Trợ năng để hoạt động.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cấp quyền") {
                        appState.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            LabeledContent("Bảo vệ mật khẩu") {
                Label(
                    appState.isSecureInputActive ? "Đang tạm dừng" : "Bật",
                    systemImage: appState.isSecureInputActive ? "lock.fill" : "lock.shield"
                )
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            }
            .help("macOS tự tắt bộ gõ trong ô mật khẩu, khoá và hộp thoại bảo mật.")
        } header: {
            Text("Bộ gõ hệ thống")
        } footer: {
            Text(kodauIMStatusCaption)
        }
    }

    // MARK: - Nâng cao

    private var advancedSection: some View {
        Section {
            Toggle("Học khi bạn sửa lại chữ đã có dấu", isOn: Binding(
                get: { appState.config.learnFromEditsEnabled },
                set: {
                    appState.config.learnFromEditsEnabled = $0
                    appState.saveConfig()
                }
            ))
            .help("Hiện thông báo xác nhận ở đáy màn hình, ⌥↩ để học.")

            Toggle("Học từ vựng khi gõ VNI", isOn: Binding(
                get: { appState.config.learnFromVNIMode },
                set: {
                    appState.config.learnFromVNIMode = $0
                    appState.saveConfig()
                }
            ))

            HStack(spacing: Space.xs) {
                TextField("Bundle ID, vd: com.apple.Terminal", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                Button("Thêm") {
                    addExcludedBundleID(newBundleID)
                    newBundleID = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: Space.xxs) {
                ForEach(quickExcludePresets, id: \.bundleID) { preset in
                    let alreadyAdded = appState.config.excludedBundleIDs.contains(preset.bundleID)
                    Button(preset.name) {
                        addExcludedBundleID(preset.bundleID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(alreadyAdded)
                }
            }

            if !appState.config.excludedBundleIDs.isEmpty {
                ForEach(appState.config.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            appState.config.excludedBundleIDs.removeAll { $0 == bundleID }
                            appState.saveConfig()
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Bỏ khỏi danh sách ngoại lệ")
                    }
                }
            }
        } header: {
            Text("Nâng cao")
        } footer: {
            Text("Ứng dụng ngoại lệ luôn nhận phím gốc, không thêm dấu.")
        }
    }

    // MARK: - Dữ liệu

    private var dataSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Xóa bộ nhớ đã học")
                        .font(Typography.body)
                    Text("Đưa từ điển và thống kê về trạng thái ban đầu.")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Xóa dữ liệu") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } header: {
            Text("Dữ liệu")
        }
    }

    // MARK: - Helpers

    private func sliderRow<Content: View>(
        title: String,
        valueText: String,
        help: String,
        @ViewBuilder slider: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(title)
                    .font(Typography.body)
                Spacer()
                Text(valueText)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            slider()
        }
        .help(help)
    }

    private var statusIcon: String {
        switch appState.kodauIMStatus {
        case .active: return "checkmark.circle.fill"
        case .notInstalled: return "exclamationmark.circle"
        default: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch appState.kodauIMStatus {
        case .active: return .green
        case .notInstalled: return .orange
        default: return .secondary
        }
    }

    private var kodauIMStatusTitle: String {
        switch appState.kodauIMStatus {
        case .active: return "KodauIM đang hoạt động"
        case .enabledNotSelected: return "KodauIM đã bật, chưa được chọn"
        case .installedNotEnabled: return "KodauIM chưa có trong Input Sources"
        case .notInstalled: return "KodauIM chưa cài"
        }
    }

    private var kodauIMStatusCaption: String {
        switch appState.kodauIMStatus {
        case .active:
            return "Bộ gõ Kodau đang là nguồn nhập hiện tại."
        case .enabledNotSelected:
            return "Dùng tổ hợp chuyển nguồn nhập của macOS để chọn Kodau."
        case .installedNotEnabled:
            return "Cài đặt Hệ thống → Bàn phím → Nguồn nhập → + → Kodau."
        case .notInstalled:
            return "Chạy `make install` để cài KodauIM."
        }
    }

    private func addExcludedBundleID(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !appState.config.excludedBundleIDs.contains(trimmed) {
            appState.config.excludedBundleIDs.append(trimmed)
            appState.saveConfig()
        }
    }
}
