import SwiftUI
import KodauCore

/// Main Dashboard window using macOS native `NavigationSplitView`.
public struct DashboardView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            VStack(spacing: 0) {
                topStatusBanner
                Divider()
                detailTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
        .sheet(isPresented: $appState.showAPIKeyDialog) {
            APIKeyDialogView()
                .environmentObject(appState)
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // App Branding Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                    Text("KD")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Kodau")
                        .font(.headline)
                    Text("Bộ gõ Việt không dấu AI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            List(DashboardTab.allCases, selection: $appState.selectedTab) { tab in
                Label(tab.title, systemImage: tab.iconName)
                    .tag(tab)
            }
            .listStyle(.sidebar)

            Divider()

            // Quick Mode Switcher Footer
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Chế độ gõ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("⌃⇧Space")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 4) {
                    ForEach(TypingMode.allCases) { mode in
                        let active = appState.config.typingMode == mode
                        Button {
                            appState.setMode(mode)
                        } label: {
                            Text(mode.shortBadge)
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    active ? Color.accentColor : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .foregroundStyle(active ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(mode.displayName)
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.config.brainStrategy == .offlineOnly ? Color.green : Color.blue)
                        .frame(width: 7, height: 7)
                    Text(appState.config.brainStrategy.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if appState.config.typingMode == .smart {
                    HStack(spacing: 6) {
                        Image(systemName: appState.config.triggerMode == .manual ? "hand.tap.fill" : "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(appState.config.triggerMode == .manual ? Color.orange : Color.accentColor)
                        Text(appState.config.triggerMode == .manual ? "Thủ công (⌥Space)" : "Tự động thêm dấu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Top Status Banner

    private var topStatusBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                kodauIMStatusPill

                // Legacy CGEventTap state (optional fallback only)
                if appState.config.legacyEventTapEnabled {
                    legacyAccessibilityPill
                }

                // Secure Input Protection Badge
                HStack(spacing: 6) {
                    Image(systemName: appState.isSecureInputActive ? "lock.fill" : "lock.shield.fill")
                        .foregroundStyle(appState.isSecureInputActive ? .orange : .green)
                    Text(
                        appState.isSecureInputActive
                            ? "🔒 Đang tạm dừng: \(appState.secureInputReason ?? "Ô mật khẩu")"
                            : "An toàn mật khẩu: Đang bảo vệ"
                    )
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (appState.isSecureInputActive ? Color.orange : Color.green).opacity(0.10),
                    in: Capsule()
                )

                Spacer()

                // Quick Gemini API Key Button
                Button {
                    appState.showAPIKeyDialog = true
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.config.hasAPIKey ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Image(systemName: "key.fill")
                            .font(.caption)
                        Text(appState.config.hasAPIKey ? "Gemini API Key (\(appState.config.geminiModel))" : "Nhập Gemini API Key")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            inputSourceOnboarding
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            appState.refreshInputSourceStatus()
        }
    }

    @ViewBuilder
    private var kodauIMStatusPill: some View {
        switch appState.kodauIMStatus {
        case .active:
            statusPill(
                icon: "checkmark.circle.fill",
                tint: .green,
                text: "Bộ gõ Kodau đang hoạt động"
            )
        case .enabledNotSelected:
            Button {
                appState.selectKodauIM()
            } label: {
                statusPill(
                    icon: "keyboard.badge.ellipsis",
                    tint: .orange,
                    text: "Kodau chưa được chọn"
                )
            }
            .buttonStyle(.plain)
            .help("Chuyển ngay sang bộ gõ Kodau")
        case .installedNotEnabled:
            Button {
                appState.openInputSourcesSettings()
            } label: {
                statusPill(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Cần thêm Kodau vào Input Sources"
                )
            }
            .buttonStyle(.plain)
            .help("Mở Cài đặt Hệ thống → Bàn phím → Nguồn nhập")
        case .notInstalled:
            statusPill(
                icon: "arrow.down.circle.fill",
                tint: .red,
                text: "Chưa cài bộ gõ KodauIM"
            )
        }
    }

    @ViewBuilder
    private var inputSourceOnboarding: some View {
        switch appState.kodauIMStatus {
        case .notInstalled:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Chạy `make install` trong thư mục dự án để cài KodauIM, sau đó thêm vào Input Sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .installedNotEnabled:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thêm Kodau vào nguồn nhập (chỉ một lần)")
                        .font(.caption.weight(.semibold))
                    Text("Cài đặt Hệ thống → Bàn phím → Nguồn nhập: Sửa… → + → Tiếng Việt → Kodau (Smart Vi/En) → Thêm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Mở Input Sources") {
                    appState.openInputSourcesSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.24), lineWidth: 1)
            )

        case .enabledNotSelected:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Kodau đã nằm trong danh sách nguồn nhập. Chuyển sang Kodau bằng nút bên trên (hoặc tổ hợp chuyển nguồn nhập trong Cài đặt Hệ thống) để bắt đầu gõ tiếng Việt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Chọn Kodau ngay") {
                        appState.selectKodauIM()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let error = appState.inputSourceErrorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .active:
            EmptyView()
        }
    }

    @ViewBuilder
    private var legacyAccessibilityPill: some View {
        if appState.accessibilityGranted {
            Button {
                appState.openAccessibilitySettings()
            } label: {
                statusPill(
                    icon: "checkmark.circle.fill",
                    tint: .green,
                    text: appState.isInterceptorRunning ? "Chế độ cũ: Đang bật" : "Chế độ cũ: Có quyền Trợ năng"
                )
            }
            .buttonStyle(.plain)
            .help("Chế độ cũ (CGEventTap) đang bật — chỉ dùng khi bộ gõ Kodau gặp sự cố.")
        } else {
            Button {
                appState.openAccessibilitySettings()
            } label: {
                statusPill(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Chế độ cũ: Cần Quyền Trợ năng"
                )
            }
            .buttonStyle(.plain)
            .help("Mở Cài đặt Hệ thống → Quyền riêng tư & Bảo mật → Trợ năng")
        }
    }

    private func statusPill(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailTabContent: some View {
        switch appState.selectedTab {
        case .roadmap:
            RoadmapView()
        case .playground:
            PlaygroundView()
        case .dictionary:
            DictionaryView()
        case .usage:
            UsageCostView()
        case .settings:
            SettingsView()
        }
    }
}
