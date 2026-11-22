import SwiftUI
import AppKit
import KodauCore

/// Dedicated welcoming modal dialog for configuring & testing the user's Google Gemini API Key.
public struct APIKeyDialogView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput: String = ""
    @State private var revealKey: Bool = false
    @State private var selectedPresetModel: String = AppConfig.availableGeminiModels.first ?? "gemini-3.5-flash-lite"
    @State private var useCustomModel: Bool = false
    @State private var customModelName: String = ""

    @State private var isTesting: Bool = false
    @State private var testResult: GeminiTestResult? = nil
    @State private var validationWarning: String? = nil

    private var defaultModel: String {
        AppConfig.availableGeminiModels.first ?? "gemini-3.5-flash-lite"
    }

    private var effectiveModel: String {
        if useCustomModel {
            let trimmed = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultModel : trimmed
        }
        return selectedPresetModel
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "key.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kết nối Google Gemini API")
                            .font(Typography.pageTitle)
                        Text("Gemini giúp học nhanh hơn ở giai đoạn đầu.")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(Space.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Body Form
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // API Key Field
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Google Gemini API Key")
                                .font(.headline)
                            Spacer()
                            Button {
                                if let clip = NSPasteboard.general.string(forType: .string) {
                                    apiKeyInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                    validationWarning = nil
                                }
                            } label: {
                                Label("Dán từ Clipboard", systemImage: "doc.on.clipboard")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        HStack(spacing: 8) {
                            Group {
                                if revealKey {
                                    TextField("Dán API Key (bắt đầu bằng AIza...)", text: $apiKeyInput)
                                } else {
                                    SecureField("Dán API Key (bắt đầu bằng AIza...)", text: $apiKeyInput)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: apiKeyInput) { _, _ in
                                validationWarning = nil
                            }

                            Button {
                                revealKey.toggle()
                            } label: {
                                Image(systemName: revealKey ? "eye.slash" : "eye")
                                    .frame(width: 28, height: 24)
                            }
                            .buttonStyle(.bordered)
                            .help(revealKey ? "Ẩn API Key" : "Hiện API Key")
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                            Text("Chưa có key? Lấy miễn phí tại")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("aistudio.google.com/apikey") {
                                if let url = URL(string: "https://aistudio.google.com/apikey") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption.weight(.medium))
                        }
                    }

                    // Model Picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chọn mô hình Gemini")
                            .font(.headline)

                        HStack(spacing: 10) {
                            Picker("Model", selection: Binding(
                                get: { useCustomModel ? "__custom__" : selectedPresetModel },
                                set: { newValue in
                                    if newValue == "__custom__" {
                                        useCustomModel = true
                                    } else {
                                        useCustomModel = false
                                        selectedPresetModel = newValue
                                    }
                                }
                            )) {
                                ForEach(AppConfig.availableGeminiModels, id: \.self) { model in
                                    Text(model == defaultModel ? "\(model) (Khuyên dùng)" : model)
                                        .tag(model)
                                }
                                Divider()
                                Text("Tùy chỉnh tên model...").tag("__custom__")
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)

                            Spacer()
                        }

                        if useCustomModel {
                            TextField("Nhập tên model, vd: gemini-3.5-flash-lite", text: $customModelName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    // Live Connection Test
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Button {
                                runConnectionTest()
                            } label: {
                                HStack(spacing: 6) {
                                    if isTesting {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "bolt.horizontal.circle.fill")
                                    }
                                    Text(isTesting ? "Đang kiểm tra kết nối..." : "Kiểm tra kết nối (Test Gemini)")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTesting || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if let result = testResult, result.success {
                                Label(String(format: "%.0f ms", result.latencyMs), systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }

                        if let warning = validationWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let result = testResult {
                            testResultCard(result)
                        }
                    }

                    // Privacy note
                    HStack(alignment: .top, spacing: Space.xs) {
                        Image(systemName: "lock.shield")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        Text("API Key lưu cục bộ với quyền 0600. Kodau tự dừng khi gặp ô mật khẩu.")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .padding(22)
            }

            Divider()

            // Footer Buttons
            HStack(spacing: 12) {
                Button("Dùng 100% Offline trước") {
                    appState.config.brainStrategy = .offlineOnly
                    appState.saveConfig()
                    appState.showAPIKeyDialog = false
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                if appState.config.hasAPIKey {
                    Button("Đóng") {
                        appState.showAPIKeyDialog = false
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Button {
                    saveAndContinueWithGemini()
                } label: {
                    Label("Lưu & Bắt đầu dùng Gemini", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 580, height: 540)
        .onAppear {
            loadInitialState()
        }
    }

    @ViewBuilder
    private func testResultCard(_ result: GeminiTestResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.success ? .green : .red)
                Text(result.success ? "Kết nối Gemini thành công!" : "Kết nối thất bại")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(result.success ? .green : .red)
                Spacer()
                Text("Model: \(result.modelUsed) • \(Int(result.latencyMs)) ms")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if result.success && !result.sampleOutput.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kết quả phục hồi mẫu:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.sampleOutput)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            } else if let err = result.errorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            (result.success ? Color.green : Color.red).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((result.success ? Color.green : Color.red).opacity(0.25), lineWidth: 1)
        )
    }

    private func loadInitialState() {
        apiKeyInput = appState.config.geminiAPIKey
        let currentModel = appState.config.geminiModel
        if AppConfig.availableGeminiModels.contains(currentModel) {
            selectedPresetModel = currentModel
            useCustomModel = false
            customModelName = ""
        } else if !currentModel.isEmpty {
            selectedPresetModel = defaultModel
            useCustomModel = true
            customModelName = currentModel
        } else {
            selectedPresetModel = defaultModel
            useCustomModel = false
        }
    }

    private func runConnectionTest() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationWarning = "Vui lòng nhập hoặc dán Gemini API Key trước khi kiểm tra."
            return
        }
        isTesting = true
        testResult = nil
        validationWarning = nil
        let model = effectiveModel

        Task {
            let result = await appState.testGeminiAPI(apiKey: key, model: model)
            await MainActor.run {
                self.testResult = result
                self.isTesting = false
            }
        }
    }

    private func saveAndContinueWithGemini() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationWarning = "Vui lòng nhập API Key hoặc chọn \"Dùng 100% Offline trước\"."
            return
        }

        appState.config.geminiAPIKey = key
        appState.config.geminiModel = effectiveModel
        if appState.config.brainStrategy == .offlineOnly {
            appState.config.brainStrategy = .hybrid
        }
        appState.saveConfig()
        appState.showAPIKeyDialog = false
        dismiss()
    }
}
