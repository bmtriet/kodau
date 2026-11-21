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
        HStack(spacing: 12) {
            // Accessibility Status Pill
            if appState.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(appState.isInterceptorRunning ? "Bộ gõ toàn hệ thống: Đang bật" : "Quyền Trợ năng: Đã bật")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.10), in: Capsule())
            } else {
                Button {
                    appState.openAccessibilitySettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Cấp Quyền Trợ năng để gõ toàn hệ thống")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Mở Cài đặt Hệ thống → Quyền riêng tư & Bảo mật → Trợ năng")
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
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
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
