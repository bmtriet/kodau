import Foundation
import AppKit
import SwiftUI
import KodauCore

@main
@MainActor
public final class KodauApplicationMain {
    private static var delegate: KodauAppDelegate?

    public static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let appDelegate = KodauAppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}

@MainActor
public final class KodauAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var appState: AppState!
    private var statusItem: NSStatusItem?
    private var dashboardWindow: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        appState = AppState()
        appState.onMenuBarStateChanged = { [weak self] in
            self?.refreshStatusItem()
        }

        setupStatusItem()
        showDashboardWindow(openAPIKeyDialog: appState.showAPIKeyDialog)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep Kodau running persistently in the macOS Menu Bar
        return false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showDashboardWindow(openAPIKeyDialog: false)
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appState?.interceptor.stop()
        appState?.candidatePanel.hide()
    }

    // MARK: - Window Management

    public func showDashboardWindow(openAPIKeyDialog: Bool) {
        if dashboardWindow == nil {
            let rootView = DashboardView()
                .environmentObject(appState)
            let hostingController = NSHostingController(rootView: rootView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Kodau — Bộ gõ Tiếng Việt Không Dấu Thông Minh"
            window.minSize = NSSize(width: 900, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.dashboardWindow = window
        }

        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if openAPIKeyDialog {
            appState.showAPIKeyDialog = true
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide window instead of destroying it so Menu Bar stays active
        sender.orderOut(nil)
        return false
    }

    // MARK: - Menu Bar (NSStatusItem)

    private func setupStatusItem() {
        refreshStatusItem()
    }

    /// Kodau.app's own icon is only needed while it has something to say that macOS's input menu cannot:
    /// KodauIM still needs setting up, or the legacy event tap is doing the typing. Once Kodau is an enabled
    /// input source, its own input menu (modes, Gemini, dashboard) takes over and this icon would be a duplicate.
    /// Deliberately independent of which source is *selected*, so the icon doesn't flicker on every ⌃Space.
    private var shouldShowStatusItem: Bool {
        if appState.config.alwaysShowMenuBarIcon || appState.config.legacyEventTapEnabled { return true }
        switch appState.kodauIMStatus {
        case .notInstalled, .installedNotEnabled: return true
        case .enabledNotSelected, .active: return false
        }
    }

    private func refreshStatusItem() {
        guard shouldShowStatusItem else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }
        let statusItem = self.statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.title = appState.menuBarTitle
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            if appState.isSecureInputActive {
                button.toolTip = "Kodau đang tạm dừng để bảo vệ mật khẩu (\(appState.secureInputReason ?? "Secure Input"))"
            } else {
                button.toolTip = "Kodau — \(appState.config.typingMode.displayName)"
            }
        }

        statusItem.menu = buildStatusMenu()
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        // Status header
        let headerTitle: String
        if appState.isSecureInputActive {
            headerTitle = "🔒 Bảo vệ mật khẩu đang bật"
        } else {
            headerTitle = "Kodau • \(appState.config.typingMode.shortBadge) (\(appState.config.brainStrategy.displayName))"
        }
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        addInputSourceItems(to: menu)

        if appState.config.legacyEventTapEnabled {
            let accessTitle = appState.accessibilityGranted
                ? (appState.isInterceptorRunning
                    ? "✓ Chế độ cũ (CGEventTap): Đang hoạt động"
                    : "✓ Quyền Trợ năng: Đã bật")
                : "⚠️ Chế độ cũ cần Quyền Trợ năng..."
            let accessItem = NSMenuItem(
                title: accessTitle,
                action: appState.accessibilityGranted ? nil : #selector(handleOpenAccessibility),
                keyEquivalent: ""
            )
            accessItem.target = self
            accessItem.isEnabled = !appState.accessibilityGranted
            menu.addItem(accessItem)
        }

        menu.addItem(.separator())

        // Mode Switcher
        let modeHeader = NSMenuItem(title: "Chế độ gõ (⌃⇧Space)", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        for mode in TypingMode.allCases {
            let item = NSMenuItem(
                title: "\(mode.shortBadge) — \(mode.displayName)",
                action: #selector(handleSelectMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (appState.config.typingMode == mode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Trigger Mode Switcher (Automatic vs Manual Option+Space)
        let triggerHeader = NSMenuItem(title: "Cách thêm dấu (Thông minh)", action: nil, keyEquivalent: "")
        triggerHeader.isEnabled = false
        menu.addItem(triggerHeader)

        for triggerMode in ConversionTriggerMode.allCases {
            let title = triggerMode == .automatic ? "Tự động thêm dấu" : "Thủ công (⌥Space)"
            let item = NSMenuItem(
                title: title,
                action: #selector(handleSelectTriggerMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = triggerMode.rawValue
            item.state = (appState.config.triggerMode == triggerMode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Strategy Switcher
        let strategyHeader = NSMenuItem(title: "Chiến lược AI / Offline", action: nil, keyEquivalent: "")
        strategyHeader.isEnabled = false
        menu.addItem(strategyHeader)

        for strategy in BrainStrategy.allCases {
            let item = NSMenuItem(
                title: strategy.displayName,
                action: #selector(handleSelectStrategy(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = strategy.rawValue
            item.state = (appState.config.brainStrategy == strategy) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Quick toggle for the post-conversion popup (word alternatives bar)
        let popupItem = NSMenuItem(
            title: "Hiện popup gợi ý từ sau khi thêm dấu",
            action: #selector(handleToggleCandidatePopup),
            keyEquivalent: ""
        )
        popupItem.target = self
        popupItem.state = appState.config.showCandidateHUD ? .on : .off
        menu.addItem(popupItem)

        menu.addItem(.separator())

        // Gemini API Key Action
        let apiKeyTitle = appState.config.hasAPIKey
            ? "Nhập / Đổi Gemini API Key..."
            : "Nhập Gemini API Key... (Chưa cài)"
        let apiKeyItem = NSMenuItem(
            title: apiKeyTitle,
            action: #selector(handleOpenAPIKeyDialog),
            keyEquivalent: "k"
        )
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        // Open Dashboard Action
        let openDashboardItem = NSMenuItem(
            title: "Mở bảng điều khiển Kodau",
            action: #selector(handleOpenDashboard),
            keyEquivalent: "o"
        )
        openDashboardItem.target = self
        menu.addItem(openDashboardItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Thoát Kodau",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Menu Bar Actions

    /// KodauIM status line + its one-click fix, replacing the old Accessibility-first header.
    private func addInputSourceItems(to menu: NSMenu) {
        switch appState.kodauIMStatus {
        case .active:
            let item = NSMenuItem(
                title: "✓ Bộ gõ Kodau: Đang hoạt động",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        case .enabledNotSelected:
            let selectItem = NSMenuItem(
                title: "Chọn Kodau ngay",
                action: #selector(handleSelectKodauIM),
                keyEquivalent: ""
            )
            selectItem.target = self
            menu.addItem(selectItem)
        case .installedNotEnabled:
            let openItem = NSMenuItem(
                title: "⚠️ Hãy thêm Kodau vào Input Sources...",
                action: #selector(handleOpenInputSources),
                keyEquivalent: ""
            )
            openItem.target = self
            menu.addItem(openItem)
        case .notInstalled:
            let item = NSMenuItem(
                title: "⚠️ Chưa cài bộ gõ KodauIM (chạy make install)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    @objc private func handleSelectKodauIM() {
        appState.selectKodauIM()
    }

    @objc private func handleOpenInputSources() {
        appState.openInputSourcesSettings()
    }

    @objc private func handleSelectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TypingMode(rawValue: raw) else { return }
        appState.setMode(mode)
    }

    @objc private func handleSelectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ConversionTriggerMode(rawValue: raw) else { return }
        appState.setTriggerMode(mode)
    }

    @objc private func handleSelectStrategy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let strategy = BrainStrategy(rawValue: raw) else { return }
        appState.setStrategy(strategy)
    }

    @objc private func handleToggleCandidatePopup() {
        appState.config.showCandidateHUD.toggle()
        appState.saveConfig()
    }

    @objc private func handleOpenAPIKeyDialog() {
        showDashboardWindow(openAPIKeyDialog: true)
    }

    @objc private func handleOpenDashboard() {
        showDashboardWindow(openAPIKeyDialog: false)
    }

    @objc private func handleOpenAccessibility() {
        appState.openAccessibilitySettings()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Standard macOS Main Menu (enables Cmd+C/V/X/A/Z in TextFields & SecureFields)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Mở bảng điều khiển Kodau", action: #selector(handleOpenDashboard), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Nhập Gemini API Key...", action: #selector(handleOpenAPIKeyDialog), keyEquivalent: "k")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ẩn Kodau", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Thoát Kodau", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu (essential for Cmd+V pasting API keys!)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Sửa")
        editMenu.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Cửa sổ")
        windowMenu.addItem(withTitle: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Thu nhỏ", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
