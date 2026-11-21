import Foundation

/// Active keyboard input mode selected by the user.
public enum TypingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Automatically detects Vietnamese (without diacritics) vs English and restores diacritics.
    /// Also supports inline VNI override (e.g., typing `ban5` -> `bạn`) which trains the local brain.
    case smart = "smart"
    /// Standard Vietnamese VNI typing mode (1-5 tones, 6-9 diacritics, 0 remove tone).
    /// Words typed in VNI also train the offline không-dấu brain.
    case vni = "vni"
    /// Raw pass-through English / ASCII mode.
    case english = "english"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smart: return "Thông minh (Không dấu + Anh)"
        case .vni: return "Tiếng Việt (VNI)"
        case .english: return "Tiếng Anh (Tắt dấu)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .smart: return "KD"
        case .vni: return "VNI"
        case .english: return "EN"
        }
    }

    public var next: TypingMode {
        switch self {
        case .smart: return .vni
        case .vni: return .english
        case .english: return .smart
        }
    }
}

/// Controls how the Smart Mode resolves Vietnamese diacritics relative to Gemini API vs Local Brain.
public enum BrainStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Local engine handles high-confidence phrases instantly (<1ms); falls back to Gemini API for ambiguous clauses and learns from them.
    case hybrid = "hybrid"
    /// Always prefer Gemini API when online (and learn everything locally for future offline independence).
    case cloudFirst = "cloud_first"
    /// 100% Offline local engine only — zero network / zero API calls.
    case offlineOnly = "offline_only"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hybrid: return "Tự động (Local + Gemini)"
        case .cloudFirst: return "Ưu tiên Gemini (Học nhanh)"
        case .offlineOnly: return "100% Offline (Không gọi API)"
        }
    }

    public var subtitle: String {
        switch self {
        case .hybrid: return "Xử lý cục bộ <1ms cho cụm quen, chỉ gọi Gemini khi cần và tự lưu học."
        case .cloudFirst: return "Gọi Gemini để tối đa độ chính xác giai đoạn đầu và nạp kiến thức vào bộ nhớ cục bộ."
        case .offlineOnly: return "Hoạt động hoàn toàn trên máy, không gửi bất kỳ dữ liệu nào ra ngoài."
        }
    }
}

/// Controls WHEN diacritic restoration is triggered in Smart Mode.
public enum ConversionTriggerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Automatically restores diacritics on Space, punctuation, Return, and short typing pauses.
    case automatic = "automatic"
    /// Leaves text untouched while typing; ONLY restores diacritics when user presses the manual trigger hotkey (Option+Space).
    case manual = "manual"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Tự động thêm dấu khi gõ"
        case .manual: return "Thủ công (Bấm ⌥Space để thêm dấu)"
        }
    }

    public var subtitle: String {
        switch self {
        case .automatic: return "Tự động bỏ dấu ngay khi bấm Space, dấu câu, xuống dòng hoặc tạm dừng. Bấm ⌥Space để ép thêm dấu ngay."
        case .manual: return "Giữ nguyên chữ không dấu khi gõ; chỉ chuyển có dấu khi bạn bấm phím tắt Option + Space."
        }
    }
}

/// Which engine produced a conversion result.
public enum ConversionSource: String, Codable, Sendable {
    case localExact = "local_exact"
    case localViterbi = "local_viterbi"
    case localEnglish = "local_english"
    case geminiAPI = "gemini_api"
    case vniOverride = "vni_override"
    case passthrough = "passthrough"

    public var label: String {
        switch self {
        case .localExact: return "Bộ nhớ cục bộ"
        case .localViterbi: return "Não Offline (Ngữ cảnh)"
        case .localEnglish: return "Tiếng Anh (Offline)"
        case .geminiAPI: return "Gemini AI"
        case .vniOverride: return "VNI thủ công"
        case .passthrough: return "Giữ nguyên"
        }
    }

    public var isOffline: Bool {
        self != .geminiAPI
    }
}

/// User's learning progress stage toward 100% API independence.
public enum IndependenceStage: Int, Codable, CaseIterable, Sendable {
    case bootstrap = 1
    case learning = 2
    case proficient = 3
    case independent = 4

    public var title: String {
        switch self {
        case .bootstrap: return "Giai đoạn 1: Khởi động"
        case .learning: return "Giai đoạn 2: Học thói quen"
        case .proficient: return "Giai đoạn 3: Thành thạo"
        case .independent: return "Giai đoạn 4: Độc lập 100% Offline"
        }
    }

    public var description: String {
        switch self {
        case .bootstrap: return "Gemini hỗ trợ câu mới trong khi Kodau âm thầm ghi nhớ từ vựng và cách diễn đạt của bạn."
        case .learning: return "Nhiều cụm từ quen thuộc đã được xử lý cục bộ dưới 1ms. Tiếp tục chỉnh sửa để tăng độ chính xác."
        case .proficient: return "Trên 80% văn bản xử lý offline hoàn toàn. Gần như không cần phụ thuộc API."
        case .independent: return "Bộ não cá nhân đã đủ mạnh! Bạn có thể bật chế độ 100% Offline vĩnh viễn."
        }
    }
}
