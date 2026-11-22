import SwiftUI
import KodauCore

/// Main Dashboard window using macOS native `NavigationSplitView`.
public struct DashboardView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if let attention = attentionCallout {
                    CalloutBanner(
                        icon: attention.icon,
                        title: attention.title,
                        message: attention.message,
                        actionTitle: attention.actionTitle,
                        action: attention.action
                    )
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                    danglingInputSourceError
                }

                detailTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $appState.showAPIKeyDialog) {
            APIKeyDialogView()
                .environmentObject(appState)
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text("K")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )

                Text("Kodau")
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.md)
            .padding(.bottom, Space.xs)

            List(DashboardTab.allCases, selection: $appState.selectedTab) { tab in
                Label(tab.title, systemImage: tab.iconName)
                    .tag(tab)
            }
            .listStyle(.sidebar)

            Divider()

            modeSwitcherFooter
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
        }
    }

    private var modeSwitcherFooter: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xxs) {
                ForEach(TypingMode.allCases) { mode in
                    let active = appState.config.typingMode == mode
                    Button {
                        appState.setMode(mode)
                    } label: {
                        Text(mode.shortBadge)
                            .font(Typography.captionMedium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(
                                active ? Color.accentColor : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            )
                            .foregroundStyle(active ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(mode.displayName)
                }
            }

            Text("⌃⇧Space")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Attention callout (only when something needs action)

    private struct Attention {
        let icon: String
        let title: String
        let message: String?
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private var attentionCallout: Attention? {
        if appState.isSecureInputActive {
            return Attention(
                icon: "lock.fill",
                title: "Đang tạm dừng để bảo vệ mật khẩu",
                message: appState.secureInputReason,
                actionTitle: nil,
                action: nil
            )
        }

        switch appState.kodauIMStatus {
        case .active:
            break
        case .enabledNotSelected:
            return Attention(
                icon: "exclamationmark.circle.fill",
                title: "Kodau chưa được chọn làm nguồn nhập",
                message: "Bạn có thể gõ thử ngay bên dưới mà không cần đổi nguồn nhập.",
                actionTitle: "Chọn Kodau",
                action: { appState.selectKodauIM() }
            )
        case .installedNotEnabled:
            return Attention(
                icon: "exclamationmark.circle.fill",
                title: "Thêm Kodau vào Input Sources",
                message: "Cài đặt Hệ thống → Bàn phím → Nguồn nhập → + → Kodau.",
                actionTitle: "Mở Input Sources",
                action: { appState.openInputSourcesSettings() }
            )
        case .notInstalled:
            return Attention(
                icon: "exclamationmark.circle.fill",
                title: "Chưa cài bộ gõ KodauIM",
                message: "Chạy `make install` rồi thêm Kodau vào Input Sources.",
                actionTitle: nil,
                action: nil
            )
        }

        if appState.config.legacyEventTapEnabled && !appState.accessibilityGranted {
            return Attention(
                icon: "exclamationmark.circle.fill",
                title: "Chế độ cũ cần quyền Trợ năng",
                message: "Bật quyền trong Cài đặt Hệ thống → Quyền riêng tư & Bảo mật → Trợ năng.",
                actionTitle: "Cấp quyền",
                action: { appState.openAccessibilitySettings() }
            )
        }

        return nil
    }

    @ViewBuilder
    private var danglingInputSourceError: some View {
        if let error = appState.inputSourceErrorMessage {
            Text(error)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xxs)
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailTabContent: some View {
        switch appState.selectedTab {
        case .typing:
            PlaygroundView()
        case .dictionary:
            DictionaryView()
        case .stats:
            StatsView()
        case .settings:
            SettingsView()
        }
    }
}
