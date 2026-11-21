import Foundation
import AppKit
import Carbon
import ApplicationServices

/// Monitors macOS Secure Event Input, password fields (`AXSecureTextField`),
/// Accessibility trust status, and user-excluded applications so Kodau NEVER
/// intercepts or logs sensitive input.
public enum SecureInputMonitor {

    /// Returns `true` when the user has selected our native macOS Input Method (`KodauIM`)
    /// in System Settings -> Keyboard -> Input Sources, so the legacy CGEventTap passes keys through
    /// without double-processing.
    public static func isNativeKodauIMActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        let sourceID = Unmanaged<CFString>.fromOpaque(rawPtr).takeUnretainedValue() as String
        return sourceID.hasPrefix("com.kodau.inputmethod.KodauIM")
    }

    /// Checks whether this process has macOS Accessibility permission.
    /// When `prompt` is `true`, macOS displays the system Accessibility prompt.
    public static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Returns `(true, reason)` whenever Kodau MUST pass all keystrokes through untouched
    /// and clear its in-memory buffers.
    public static func isPasswordFieldOrSecureInputActive(
        excludedBundleIDs: [String]
    ) -> (isSecure: Bool, reason: String?) {
        // 1. OS-level Secure Event Input (active in macOS login/sudo/password prompts & secure fields)
        if IsSecureEventInputEnabled() {
            return (true, "macOS Secure Event Input đang bật")
        }

        // 2. Excluded applications (e.g., password managers or terminals chosen by user)
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleID = frontApp.bundleIdentifier {
            if excludedBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                let appName = frontApp.localizedName ?? bundleID
                return (true, "Ứng dụng ngoại lệ: \(appName)")
            }
        }

        // 3. Accessibility API focused UI element check for AXSecureTextField
        if isFocusedElementSecureTextField() {
            return (true, "Ô nhập mật khẩu (AXSecureTextField)")
        }

        return (false, nil)
    }

    /// Inspects the currently focused UI element via Accessibility APIs to detect password fields
    /// even in apps that do not enable Carbon Secure Event Input.
    private static func isFocusedElementSecureTextField() -> Bool {
        guard isAccessibilityTrusted(prompt: false) else {
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        // This runs inside the CGEventTap callback on every keystroke. The default AX messaging timeout
        // is ~6s, so a hung target app could stall typing and get the tap disabled by macOS. Cap it at 50ms.
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusStatus == .success, let focusedElement = focusedRef else {
            return false
        }

        // swiftlint:disable:next force_cast
        let axElement = focusedElement as! AXUIElement

        if let role = copyStringAttribute(axElement, attribute: kAXRoleAttribute as CFString),
           role == "AXSecureTextField" {
            return true
        }

        if let subrole = copyStringAttribute(axElement, attribute: kAXSubroleAttribute as CFString),
           subrole == "AXSecureTextField" {
            return true
        }

        return false
    }

    private static func copyStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success, let str = value as? String else {
            return nil
        }
        return str
    }
}
