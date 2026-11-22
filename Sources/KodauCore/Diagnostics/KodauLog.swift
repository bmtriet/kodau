import Foundation
import os

/// Central `os_log` handles for Kodau. Text the user typed is logged as `privacy: .private` unless
/// `AppConfig.debugLogging` is on, in which case it is public so `log stream` shows it in clear.
///
/// Cheap by construction: composing logs only fire on events (a commit, a Gemini decision), never per keystroke,
/// and a debug-only keystroke line is emitted only when `debugLogging` is enabled.
public enum KodauLog {
    public static let subsystem = "com.kodau.im"

    /// Key handling → marked text / commit summaries.
    public static let compose = Logger(subsystem: subsystem, category: "compose")
    /// Gemini request lifecycle: scheduled, sent, applied, discarded.
    public static let gemini = Logger(subsystem: subsystem, category: "gemini")
    /// Locally recorded corrections / learning events.
    public static let learning = Logger(subsystem: subsystem, category: "learning")

    /// The `log stream` command users can paste to watch Kodau live.
    public static let streamCommand = #"log stream --predicate 'subsystem == "com.kodau.im"' --level debug"#

    /// Composing event (commit, revert, mode). `detail` may hold user text, so it is redacted unless debugging.
    public static func composeEvent(_ summary: String, detail: String = "", debug: Bool) {
        if debug {
            compose.notice("\(summary, privacy: .public) \(detail, privacy: .public)")
        } else if detail.isEmpty {
            compose.notice("\(summary, privacy: .public)")
        } else {
            compose.notice("\(summary, privacy: .public) \(detail, privacy: .private)")
        }
    }

    /// Gemini lifecycle event (scheduled, sent, applied, discarded). Never contains user text.
    public static func geminiEvent(_ summary: String) {
        gemini.debug("\(summary, privacy: .public)")
    }

    /// Local correction/learning event. `detail` may hold words, so it follows `debugLogging`.
    public static func learningEvent(_ summary: String, detail: String = "", debug: Bool) {
        if debug {
            learning.notice("\(summary, privacy: .public) \(detail, privacy: .public)")
        } else if detail.isEmpty {
            learning.notice("\(summary, privacy: .public)")
        } else {
            learning.notice("\(summary, privacy: .public) \(detail, privacy: .private)")
        }
    }
}
