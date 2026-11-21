import SwiftUI
import KodauCore

/// Overview & Independence Roadmap tab showing progress from Gemini-assisted learning
/// to a 100% API-free personal offline Vietnamese engine.
public struct RoadmapView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Celebratory Stage 4 Banner
                if appState.showOfflineReadyBanner {
                    offlineReadyBanner
                }

                // Hero Independence Card
                heroIndependenceCard

                // Metrics Grid
                metricsGrid

                // Visual 4-Step Roadmap Timeline
                roadmapTimelineCard

                // Quick Shortcuts & Latest Conversion
                HStack(alignment: .top, spacing: 16) {
                    shortcutsCard
                    latestConversionCard
                }
            }
            .padding(24)
        }
        .onAppear {
            appState.refreshStats()
        }
    }

    // MARK: - Banners & Cards

    private var offlineReadyBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bộ não cá nhân đã sẵn sàng 100% Offline!")
                    .font(.headline)
                Text("Kodau đã đạt Giai đoạn 4 — bạn có thể tắt hoàn toàn gọi Gemini API ngay bây giờ để đạt tốc độ <1ms và bảo mật tuyệt đối.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appState.switchToOfflineOnly()
            } label: {
                Label("Chuyển sang 100% Offline", systemImage: "bolt.shield.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(16)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.30), lineWidth: 1)
        )
    }

    private var heroIndependenceCard: some View {
        let score = appState.stats.independenceScore
        let stage = appState.stats.stage
        let isOffline = appState.config.brainStrategy == .offlineOnly

        return HStack(spacing: 24) {
            // Circular Progress Ring
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: max(0.02, score))
                    .stroke(
                        LinearGradient(
                            colors: isOffline ? [.green, .mint] : [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: score)

                VStack(spacing: 2) {
                    Text("\(Int((score * 100).rounded()))%")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Độc lập")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(stage.title)
                        .font(.title2.bold())

                    if isOffline {
                        Label("Đang chạy 100% Offline", systemImage: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }

                Text(stage.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: score)
                    .tint(isOffline ? .green : .blue)
                    .padding(.top, 2)

                HStack(spacing: 12) {
                    if !isOffline {
                        Button {
                            appState.switchToOfflineOnly()
                        } label: {
                            Label("Chuyển sang 100% Offline (Không gọi API nữa)", systemImage: "airplane.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(stage == .independent ? .green : .blue)
                    } else {
                        Button {
                            appState.setStrategy(.hybrid)
                        } label: {
                            Label("Bật lại Hybrid (Local + Gemini)", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        appState.selectedTab = .playground
                    } label: {
                        Label("Thử gõ & Dạy AI ngay", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var metricsGrid: some View {
        let stats = appState.stats
        let hitRatePct = Int((stats.offlineHitRate * 100).rounded())

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14),
                GridItem(.flexible(), spacing: 14)
            ],
            spacing: 14
        ) {
            metricTile(
                title: "Tỉ lệ xử lý Offline",
                value: "\(hitRatePct)%",
                subtitle: "\(stats.localConversions) cục bộ / \(stats.geminiConversions) Gemini",
                icon: "cpu.fill",
                color: .green
            )

            metricTile(
                title: "Từ vựng đã học",
                value: "\(stats.uniqueWordsLearned)",
                subtitle: "\(stats.uniqueBigramsLearned) ngữ cảnh cặp từ",
                icon: "text.book.closed.fill",
                color: .blue
            )

            metricTile(
                title: "Cụm & Câu ghi nhớ",
                value: "\(stats.uniquePhrasesLearned)",
                subtitle: "Tổng \(stats.totalConversions) lượt chuyển đổi",
                icon: "quote.bubble.fill",
                color: .purple
            )

            metricTile(
                title: "Lượt bạn đã dạy",
                value: "\(stats.userCorrections)",
                subtitle: "Ưu tiên tuyệt đối khi suy đoán",
                icon: "hand.thumbsup.fill",
                color: .orange
            )
        }
    }

    private func metricTile(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
            }

            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var roadmapTimelineCard: some View {
        let currentStage = appState.stats.stage

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Lộ trình 4 giai đoạn tiến tới 100% Offline", systemImage: "map.fill")
                    .font(.headline)
                Spacer()
                Text("Mục tiêu: Tốc độ <1ms • Không cần Internet • Không tốn API")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(IndependenceStage.allCases, id: \.rawValue) { stage in
                    let isCurrent = (stage == currentStage)
                    let isCompleted = (stage.rawValue < currentStage.rawValue)

                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    isCompleted ? Color.green :
                                    isCurrent ? Color.accentColor : Color.primary.opacity(0.10)
                                )
                                .frame(width: 28, height: 28)

                            if isCompleted {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(stage.rawValue)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(isCurrent ? .white : .secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(stage.title)
                                    .font(.subheadline.weight(.semibold))
                                if isCurrent {
                                    Text("Hiện tại")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text(stage.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(
                        isCurrent ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isCurrent ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06),
                                lineWidth: 1
                            )
                    )
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Phím tắt toàn hệ thống", systemImage: "command")
                .font(.headline)

            shortcutRow(keys: "⌃ ⇧ Space", description: "Chuyển nhanh: Thông minh → VNI → Tiếng Anh")
            shortcutRow(keys: "⌥ 1 ... 5", description: "Chọn nhanh từ gợi ý khác trên thanh HUD & dạy AI")
            shortcutRow(keys: "⌥ Esc", description: "Hoàn tác lần thêm dấu vừa rồi (giữ từ gốc / tiếng Anh)")
            shortcutRow(keys: "ban5 / tie6ng1", description: "Gõ trực tiếp số VNI trong chế độ Thông minh để ép dấu")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func shortcutRow(keys: String, description: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(minWidth: 96, alignment: .center)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var latestConversionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Lần chuyển đổi gần nhất", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if let last = appState.lastConversion {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(last.source.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (last.source.isOffline ? Color.green : Color.purple).opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(last.source.isOffline ? .green : .purple)

                        Spacer()

                        Text(String(format: "Tin cậy %d%% • %.1f ms", Int(last.confidence * 100), last.latencyMs))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Text("Gốc: \(last.originalText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    Text(last.convertedText)
                        .font(.body.weight(.medium))
                        .lineLimit(3)
                }
            } else {
                Text("Chưa có lượt gõ nào trong phiên này. Bạn có thể thử ngay ở mục \"Thử nghiệm & Dạy AI\" hoặc gõ trực tiếp ở bất kỳ ứng dụng nào.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
