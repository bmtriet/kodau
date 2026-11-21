import SwiftUI
import KodauCore

/// Full native macOS settings screen for Kodau.
public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var newBundleID: String = ""
    @State private var showResetConfirm: Bool = false
    @State private var customGeminiModelInput: String = ""
    @State private var isUsingCustomModel: Bool = false

    private var defaultGeminiModel: String {
        AppConfig.availableGeminiModels.first ?? "gemini-3.5-flash-lite"
    }

    private var kodauIMStatusTitle: String {
        switch appState.kodauIMStatus {
        case .active: return "KodauIM: Đang hoạt động"
        case .enabledNotSelected: return "KodauIM: Đã bật, chưa được chọn"
        case .installedNotEnabled: return "KodauIM: Đã cài, chưa thêm vào Input Sources"
        case .notInstalled: return "KodauIM: Chưa cài"
        }
    }

    private var kodauIMStatusCaption: String {
        switch appState.kodauIMStatus {
        case .active:
            return "Bộ gõ Kodau đang là nguồn nhập hiện tại. Không cần quyền Trợ năng và macOS tự tắt bộ gõ trong ô mật khẩu."
        case .enabledNotSelected:
            return "KodauIM đã có trong danh sách nguồn nhập. Bấm \"Chọn Kodau ngay\" hoặc dùng tổ hợp chuyển nguồn nhập của macOS để bắt đầu gõ."
        case .installedNotEnabled:
            return "Cài đặt Hệ thống → Bàn phím → Nguồn nhập: Sửa… → + → Tiếng Việt → Kodau (Smart Vi/En) → Thêm."
        case .notInstalled:
            return "Chạy `make install` trong thư mục dự án để cài KodauIM vào ~/Library/Input Methods."
        }
    }

    private let quickExcludePresets: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("iTerm2", "com.googlecode.iterm2"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Xcode", "com.apple.dt.Xcode")
    ]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Cài đặt Kodau")
                    .font(.title2.bold())

                // 1. Typing Mode & Brain Strategy
                settingsCard(title: "Chế độ gõ & Chiến lược bộ não", icon: "keyboard.badge.ellipsis") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Chế độ gõ hiện tại")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { appState.config.typingMode },
                                set: { appState.setMode($0) }
                            )) {
                                ForEach(TypingMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 280)
                        }

                        Divider()

                        // Conversion Trigger Mode ("Cách kích hoạt thêm dấu")
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("Cách kích hoạt thêm dấu")
                                    .font(.subheadline.weight(.medium))
                                Text("⌥Space · Smart + VNI")
                                    .font(.caption2.monospaced().bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .foregroundStyle(Color.accentColor)

                                Spacer()

                                Picker("", selection: Binding(
                                    get: { appState.config.triggerMode },
                                    set: { appState.setTriggerMode($0) }
                                )) {
                                    ForEach(ConversionTriggerMode.allCases) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 280)
                            }

                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: appState.config.triggerMode == .manual ? "hand.tap.fill" : "bolt.fill")
                                    .foregroundStyle(appState.config.triggerMode == .manual ? .orange : Color.accentColor)
                                    .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(appState.config.triggerMode.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("Mẹo: Dù ở chế độ Tự động hay Thủ công, bạn luôn có thể bấm phím tắt Option + Space (⌥Space) để ép chuyển dấu ngay lập tức cho dòng hiện tại.")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("⌥Space cũng chạy trong chế độ VNI: nó thêm dấu cho đúng từ đang gõ dở (chữ đã gõ xong trước đó giữ nguyên). Chế độ Tiếng Anh không bị ảnh hưởng.")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Divider()

                        // Popup shown after diacritics are added (word alternatives bar at the bottom of the screen)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "Hiện popup gợi ý từ sau khi thêm dấu",
                                isOn: Binding(
                                    get: { appState.config.showCandidateHUD },
                                    set: {
                                        appState.config.showCandidateHUD = $0
                                        appState.saveConfig()
                                    }
                                )
                            )
                            .font(.subheadline.weight(.medium))
                            Text("Thanh nhỏ ở giữa đáy màn hình để chọn từ khác (bán / bạn / bàn…). Tắt nếu thấy phiền — phím ⌥1…5 vẫn đổi từ được và ⌥Esc vẫn hoàn tác như bình thường.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Chiến lược xử lý AI & Offline")
                                .font(.subheadline.weight(.medium))

                            ForEach(BrainStrategy.allCases) { strategy in
                                let isSelected = appState.config.brainStrategy == strategy
                                Button {
                                    appState.setStrategy(strategy)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                            .padding(.top, 2)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(strategy.displayName)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text(strategy.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(
                                        isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.02),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // 2. Gemini API Configuration
                settingsCard(title: "Google Gemini API", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(appState.config.hasAPIKey ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(appState.config.hasAPIKey ? "Đã kết nối API Key" : "Chưa nhập API Key")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Text("Key: \(appState.maskedAPIKeyDisplay)  •  Model: \(appState.config.geminiModel)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                appState.showAPIKeyDialog = true
                            } label: {
                                Label("Nhập / Kiểm tra Gemini API Key", systemImage: "key.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Text("Mô hình Gemini")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Picker("", selection: Binding(
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
                                    Text(model == defaultGeminiModel ? "\(model) (Mặc định)" : model)
                                        .tag(model)
                                }
                                Divider()
                                Text("Tùy chỉnh tên model...").tag("__custom__")
                            }
                            .labelsHidden()
                            .frame(width: 280)
                        }

                        if isUsingCustomModel || !AppConfig.availableGeminiModels.contains(appState.config.geminiModel) {
                            HStack(spacing: 8) {
                                TextField("Nhập tên model tùy chỉnh (vd: gemini-3.5-flash-lite)", text: $customGeminiModelInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                Button("Áp dụng") {
                                    let trimmed = customGeminiModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    appState.config.geminiModel = trimmed.isEmpty ? defaultGeminiModel : trimmed
                                    appState.saveConfig()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .onAppear {
                        if !AppConfig.availableGeminiModels.contains(appState.config.geminiModel) {
                            isUsingCustomModel = true
                            customGeminiModelInput = appState.config.geminiModel
                        }
                    }
                }

                // 3. Smart Tuning Sliders & Toggles
                settingsCard(title: "Tinh chỉnh Bộ gõ Thông minh & VNI", icon: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 14) {
                        // Confidence Threshold
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Ngưỡng tự tin Offline (bỏ qua Gemini khi đạt ngưỡng)")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(Int((appState.config.localConfidenceThreshold * 100).rounded()))%")
                                    .font(.subheadline.monospaced().bold())
                                    .foregroundStyle(Color.accentColor)
                            }
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
                            Text("Thấp hơn = xử lý offline nhiều hơn (<1ms). Cao hơn = nhờ Gemini kiểm tra kỹ hơn để học nhanh hơn.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        // Opt-in typo fixing (Gemini). Off = Kodau only ever adds diacritics to the user's words.
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(
                                "Sửa lỗi chính tả (Anh / Việt) bằng Gemini",
                                isOn: Binding(
                                    get: { appState.config.fixTyposEnabled },
                                    set: {
                                        appState.config.fixTyposEnabled = $0
                                        appState.saveConfig()
                                    }
                                )
                            )
                            .font(.subheadline.weight(.medium))
                            Text(appState.config.fixTyposEnabled
                                 ? "Đang bật: Gemini được sửa từ gõ sai rõ ràng (dnag → đang, teh → the), từng từ một, tối đa 1–2 ký tự. Không mở rộng viết tắt (ko, dc giữ nguyên), không viết lại câu. Chỉ áp dụng cho câu được gửi Gemini."
                                 : "Đang tắt: Kodau chỉ thêm dấu — mọi chữ cái bạn gõ được giữ nguyên tuyệt đối, kể cả từ gõ sai.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // When to call Gemini (per sentence vs realtime)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Thời điểm gọi Gemini (chế độ Tự động)")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Picker("", selection: Binding(
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
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 300)
                            }
                            Text(appState.config.geminiTiming.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if appState.config.geminiTiming == .perSentence {
                                HStack {
                                    Text("Gửi câu đang gõ dở khi bạn dừng gõ")
                                        .font(.caption.weight(.medium))
                                    Spacer()
                                    Text(String(format: "%.1f giây", Double(appState.config.sentencePauseMilliseconds) / 1000.0))
                                        .font(.caption.monospaced().bold())
                                        .foregroundStyle(Color.accentColor)
                                }
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

                        Divider()

                        // Daily limits & spacing between calls
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Giới hạn gọi Gemini mỗi ngày")
                                .font(.subheadline.weight(.medium))

                            HStack(spacing: 10) {
                                Text("Tối đa")
                                    .font(.caption)
                                TextField("500", value: Binding(
                                    get: { appState.config.dailyGeminiCallLimit },
                                    set: {
                                        appState.config.dailyGeminiCallLimit = max(0, $0)
                                        appState.saveConfig()
                                    }
                                ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                Text("lượt/ngày")
                                    .font(.caption)

                                Spacer().frame(width: 16)

                                Text("Ngân sách")
                                    .font(.caption)
                                TextField("5000", value: Binding(
                                    get: { Int(appState.config.dailyGeminiBudgetVND.rounded()) },
                                    set: {
                                        appState.config.dailyGeminiBudgetVND = Double(max(0, $0))
                                        appState.saveConfig()
                                    }
                                ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                Text("₫/ngày")
                                    .font(.caption)
                                Spacer()
                            }

                            HStack {
                                Text("Khoảng cách tối thiểu giữa 2 lần gọi")
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(appState.config.minGeminiIntervalSeconds <= 0
                                     ? "Không giới hạn"
                                     : String(format: "%.1f giây", appState.config.minGeminiIntervalSeconds))
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(Color.accentColor)
                            }
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
                            Text("Nhập 0 để bỏ giới hạn. Khi chạm hạn mức, Kodau tự chạy 100% offline đến hết ngày (vẫn thêm dấu bình thường) và báo trong tab Token & Chi phí.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                        // Debounce delay
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Độ trễ chờ ngừng gõ trước khi gọi Gemini (chế độ Thời gian thực)")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("\(appState.config.debounceMilliseconds) ms")
                                    .font(.subheadline.monospaced().bold())
                                    .foregroundStyle(Color.accentColor)
                            }
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

                        Divider()

                        Toggle(
                            "Cho phép gõ số VNI nhanh ngay trong chế độ Thông minh (vd: ban5 → bạn)",
                            isOn: Binding(
                                get: { appState.config.inlineVNIOverrideEnabled },
                                set: {
                                    appState.config.inlineVNIOverrideEnabled = $0
                                    appState.saveConfig()
                                }
                            )
                        )

                        Toggle(
                            "Học từ khi bạn sửa lại chữ đã có dấu (hiện thông báo xác nhận giữa đáy màn hình, ⌥↩ để học)",
                            isOn: Binding(
                                get: { appState.config.learnFromEditsEnabled },
                                set: {
                                    appState.config.learnFromEditsEnabled = $0
                                    appState.saveConfig()
                                }
                            )
                        )

                        Toggle(
                            "Tự động học từ vựng khi bạn gõ ở chế độ VNI",
                            isOn: Binding(
                                get: { appState.config.learnFromVNIMode },
                                set: {
                                    appState.config.learnFromVNIMode = $0
                                    appState.saveConfig()
                                }
                            )
                        )

                        Toggle(
                            "Đặt dấu kiểu òa, óe, úy (hòa, tòa, khỏe, thủy — thay vì hoà, khoẻ)",
                            isOn: Binding(
                                get: { appState.config.modernTonePlacement },
                                set: {
                                    appState.config.modernTonePlacement = $0
                                    appState.saveConfig()
                                }
                            )
                        )

                        Toggle(
                            "Tự động gợi ý chuyển sang 100% Offline khi đạt Giai đoạn 4",
                            isOn: Binding(
                                get: { appState.config.autoSuggestOfflineMode },
                                set: {
                                    appState.config.autoSuggestOfflineMode = $0
                                    appState.saveConfig()
                                }
                            )
                        )
                    }
                }

                // 4. Typing path: KodauIM (default) vs legacy CGEventTap
                settingsCard(title: "Đường gõ", icon: "keyboard") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Image(systemName: appState.kodauIMStatus == .active ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(appState.kodauIMStatus == .active ? .green : .orange)
                            Text(kodauIMStatusTitle)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if appState.kodauIMStatus == .installedNotEnabled {
                                Button("Mở Input Sources") {
                                    appState.openInputSourcesSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else if appState.kodauIMStatus == .enabledNotSelected {
                                Button("Chọn Kodau ngay") {
                                    appState.selectKodauIM()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        Text(kodauIMStatusCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(
                                "Chế độ cũ: chặn phím toàn hệ thống (cần quyền Trợ năng)",
                                isOn: Binding(
                                    get: { appState.config.legacyEventTapEnabled },
                                    set: {
                                        appState.config.legacyEventTapEnabled = $0
                                        appState.saveConfig()
                                    }
                                )
                            )
                            .font(.subheadline.weight(.medium))

                            Text("Chỉ dùng khi bộ gõ Kodau bị lỗi trong một ứng dụng cụ thể (ví dụ app cũ không nhận diện được nguồn nhập). Chế độ này chặn mọi phím bằng CGEventTap và sửa chữ bằng phím xóa giả lập nên kém ổn định hơn — Kodau khuyến nghị dùng KodauIM.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if appState.config.legacyEventTapEnabled {
                                HStack(spacing: 8) {
                                    Image(systemName: appState.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(appState.accessibilityGranted ? .green : .orange)
                                    Text(appState.accessibilityGranted
                                         ? (appState.isInterceptorRunning ? "Chế độ cũ đang hoạt động." : "Đã có quyền Trợ năng.")
                                         : "Chế độ cũ cần quyền Trợ năng để chặn phím.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if !appState.accessibilityGranted {
                                        Button("Cấp quyền Trợ năng") {
                                            appState.openAccessibilitySettings()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(10)
                                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }

                // 5. macOS Secure Input Protection
                settingsCard(title: "Bảo mật Mật khẩu macOS", icon: "lock.shield.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Ở chế độ mặc định, macOS tự tắt KodauIM trong ô mật khẩu")
                                    .font(.subheadline.weight(.semibold))
                                Text("Bộ gõ KodauIM là nguồn nhập chuẩn của macOS nên hệ thống tự chuyển về bàn phím gốc khi bạn gõ vào ô mật khẩu, khóa hoặc hộp thoại bảo mật — Kodau không thể đọc hay sửa nội dung. Nếu bạn bật chế độ cũ (CGEventTap), Kodau còn kiểm tra thêm `IsSecureEventInputEnabled()` và `AXSecureTextField` trên từng phím nhấn rồi xóa trắng bộ đệm.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        if appState.config.legacyEventTapEnabled {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Chế độ cũ vẫn bảo vệ mật khẩu")
                                        .font(.subheadline.weight(.bold))
                                    Text("Khi chặn phím toàn hệ thống, Kodau kiểm tra đồng thời cờ `IsSecureEventInputEnabled()` và thuộc tính `AXSecureTextField` trên từng phím nhấn. Ngay khi bạn chạm vào ô nhập mật khẩu, khóa hệ thống hoặc ứng dụng quản lý mật khẩu (1Password, Bitwarden, Keychain), Kodau xóa trắng bộ đệm RAM, hiện biểu tượng 🔒 trên thanh menu và cho phím đi thẳng qua macOS.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.green.opacity(0.24), lineWidth: 1)
                            )
                        }
                    }
                }

                // 6. Excluded Applications
                settingsCard(title: "Ứng dụng ngoại lệ (Tự động tắt dấu / Pass-through)", icon: "app.badge.checkmark") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("Thêm Bundle ID (vd: com.apple.Terminal)", text: $newBundleID)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Thêm") {
                                addExcludedBundleID(newBundleID)
                                newBundleID = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        // Quick presets
                        HStack(spacing: 6) {
                            Text("Thêm nhanh:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                        VStack(spacing: 6) {
                            ForEach(appState.config.excludedBundleIDs, id: \.self) { bundleID in
                                HStack {
                                    Text(bundleID)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Button(role: .destructive) {
                                        appState.config.excludedBundleIDs.removeAll { $0 == bundleID }
                                        appState.saveConfig()
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }

                // 7. Data Management
                settingsCard(title: "Quản lý dữ liệu học cục bộ", icon: "externaldrive.fill") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Xóa toàn bộ bộ nhớ đã học")
                                .font(.subheadline.weight(.semibold))
                            Text("Đưa từ điển cá nhân và thống kê lộ trình về trạng thái ban đầu (không xóa API Key).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label("Xóa dữ liệu học", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
            .padding(24)
        }
        .alert("Xác nhận xóa bộ nhớ đã học?", isPresented: $showResetConfirm) {
            Button("Hủy", role: .cancel) {}
            Button("Xóa toàn bộ", role: .destructive) {
                appState.store.resetAllData()
                appState.refreshStats()
            }
        } message: {
            Text("Toàn bộ từ vựng, cụm từ và số lượt chuyển đổi đã học trong SQLite sẽ bị xóa vĩnh viễn. Hành động này không thể hoàn tác.")
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

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
