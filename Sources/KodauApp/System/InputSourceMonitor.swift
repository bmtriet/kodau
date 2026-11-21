import Foundation
import AppKit
import Carbon
import Combine

/// Installation / selection state of the native `KodauIM` input source.
public enum KodauIMStatus: String, Equatable, Sendable {
    /// No input source registered with the KodauIM bundle ID (bundle not installed).
    case notInstalled
    /// Bundle is registered but the user has not added it to the enabled Input Sources list.
    case installedNotEnabled
    /// Enabled in Input Sources, but another input source is currently selected.
    case enabledNotSelected
    /// KodauIM is the current keyboard input source.
    case active

    public var isActive: Bool { self == .active }
}

/// Watches the macOS Text Input Source (TIS) database for the KodauIM input method.
///
/// Detection notes (verified live against an installed KodauIM bundle):
/// - macOS registers the input *mode* under a doubled identifier
///   (`com.kodau.inputmethod.KodauIM.KodauIM.smart`), so Kodau sources are matched by bundle-ID
///   prefix, never by the `…KodauIM.smart` string declared in `Info.plist`.
/// - `TISCreateInputSourceList(filter, false)` is NOT a reliable "is enabled" test: once any call
///   passes `includeAllInstalled: true`, the process-wide TIS cache keeps returning
///   installed-but-disabled sources. `kTISPropertyInputSourceIsEnabled` is equally misleading (it
///   reports `true` for a mode absent from the user's enabled list). The authoritative signal is
///   the persisted `AppleEnabledInputSources` preference, read through CFPreferences.
@MainActor
public final class InputSourceMonitor: ObservableObject {

    public static let bundleID = "com.kodau.inputmethod.KodauIM"

    /// HIToolbox keys the enabled Input Sources list lives under.
    private static let hitoolboxDomain = "com.apple.HIToolbox"
    private static let enabledSourcesKey = "AppleEnabledInputSources"

    @Published public private(set) var status: KodauIMStatus

    /// Invoked on the main actor whenever `status` changes.
    public var onStatusChanged: ((KodauIMStatus) -> Void)?

    private var distributedObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval

    public init(refreshInterval: TimeInterval = 3) {
        self.refreshInterval = refreshInterval
        self.status = Self.currentStatus()
    }

    deinit {
        refreshTimer?.invalidate()
        let center = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            center.removeObserver(observer)
        }
    }

    public func start() {
        guard refreshTimer == nil else { return }

        let center = DistributedNotificationCenter.default()
        let names = [
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            distributedObservers.append(observer)
        }

        // Fallback poll: the enabled-sources notification is not always delivered.
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        refresh()
    }

    public func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let center = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            center.removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    @discardableResult
    public func refresh() -> KodauIMStatus {
        let newStatus = Self.currentStatus()
        if newStatus != status {
            status = newStatus
            onStatusChanged?(newStatus)
        }
        return newStatus
    }

    // MARK: - Detection

    public static func currentStatus() -> KodauIMStatus {
        resolveStatus(
            isInstalled: isInstalled(),
            isEnabled: isEnabledInPreferences(),
            isSelected: isKodauIMSelected()
        )
    }

    /// Pure decision table so the state machine stays testable.
    public static func resolveStatus(
        isInstalled: Bool,
        isEnabled: Bool,
        isSelected: Bool
    ) -> KodauIMStatus {
        // Being the current input source implies installed + enabled, whatever the other probes say.
        if isSelected { return .active }
        guard isInstalled else { return .notInstalled }
        guard isEnabled else { return .installedNotEnabled }
        return .enabledNotSelected
    }

    /// Any input source (method or mode) registered under the KodauIM bundle ID.
    public static func isInstalled() -> Bool {
        !kodauSources(includeAllInstalled: true).isEmpty
    }

    /// `true` only when Kodau appears in the user's enabled Input Sources list.
    public static func isEnabledInPreferences() -> Bool {
        for domain in [hitoolboxDomain, "-currentHost." + hitoolboxDomain] {
            guard let raw = CFPreferencesCopyAppValue(
                enabledSourcesKey as CFString,
                domain as CFString
            ), let entries = raw as? [[String: Any]] else {
                continue
            }
            let matches = entries.contains { entry in
                guard let entryBundle = entry["Bundle ID"] as? String else { return false }
                return entryBundle == bundleID || entryBundle.hasPrefix(bundleID + ".")
            }
            if matches { return true }
        }
        return false
    }

    public static func isKodauIMSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = inputSourceID(source) else {
            return false
        }
        return id.hasPrefix(bundleID)
    }

    // MARK: - Actions

    /// Opens System Settings → Keyboard → Text Input → Input Sources.
    @discardableResult
    public static func openInputSourcesSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    /// Selects the KodauIM input mode. macOS returns a non-zero `OSStatus` when the source is not
    /// enabled or while a secure field owns the input context; callers surface that failure.
    @discardableResult
    public func selectKodauIM() -> Bool {
        defer { refresh() }

        guard let target = Self.selectableKodauMode() else { return false }
        return TISSelectInputSource(target) == noErr
    }

    private static func selectableKodauMode() -> TISInputSource? {
        let sources = kodauSources(includeAllInstalled: true)
        let modes = sources.filter { sourceType($0) == (kTISTypeKeyboardInputMode as String) }
        return modes.first(where: isSelectable) ?? sources.first(where: isSelectable)
    }

    // MARK: - TIS helpers

    private static func kodauSources(includeAllInstalled: Bool) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue()
                as? [TISInputSource] else {
            return []
        }
        return list
    }

    private static func inputSourceID(_ source: TISInputSource) -> String? {
        guard let rawPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(rawPtr).takeUnretainedValue() as String
    }

    private static func sourceType(_ source: TISInputSource) -> String? {
        guard let rawPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(rawPtr).takeUnretainedValue() as String
    }

    private static func isSelectable(_ source: TISInputSource) -> Bool {
        guard let rawPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else {
            return false
        }
        return CFBooleanGetValue(
            Unmanaged<CFBoolean>.fromOpaque(rawPtr).takeUnretainedValue()
        )
    }
}
