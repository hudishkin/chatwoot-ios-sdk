import SwiftUI

struct SystemCell: View {
    let text: String

    @Environment(\.chatColors) private var colors

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(colors.systemText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
    }
}

struct DateHeaderCell: View {
    let item: ChatItem.DateHeader
    let format: ChatFormat

    @Environment(\.chatColors) private var colors

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(format.day(item))
                .font(.caption)
                .foregroundColor(colors.onDateChip)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(colors.dateChip)
                .clipShape(Capsule())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

struct FailedState: View {
    let onRetry: (() -> Void)?
    var reason: String? = nil

    @Environment(\.chatColors) private var colors

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                onRetry?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 14))
                    Text(reason ?? ChatStrings.failedRetry)
                        .font(.footnote)
                }
                .foregroundColor(colors.failed)
                .frame(minHeight: Spacing.touchTarget)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onRetry == nil)
        }
    }
}

struct EmptyState: View {
    @Environment(\.chatColors) private var colors

    var body: some View {
        Text(ChatStrings.empty)
            .font(.subheadline)
            .foregroundColor(colors.systemText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
    }
}

struct TypingIndicator: View {
    @Environment(\.chatColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dots = 3
    private static let pulseSeconds = 1.2
    private static let minAlpha = 0.3

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer().frame(width: Spacing.avatar + Spacing.avatarGap)
            HStack(spacing: 4) {
                if reduceMotion {
                    Text("…")
                        .font(.body)
                        .foregroundColor(colors.incomingMeta)
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 4) {
                            ForEach(0 ..< TypingIndicator.dots, id: \.self) { index in
                                Circle()
                                    .fill(colors.incomingMeta)
                                    .frame(width: 6, height: 6)
                                    .opacity(alpha(at: t, index: index))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(colors.incomingBubble)
            .clipShape(BubbleShape(mine: false, run: .single))
            Spacer(minLength: 0)
        }
        .padding(.bottom, Spacing.betweenRuns)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatStrings.agentTyping)
    }

    private func alpha(at t: TimeInterval, index: Int) -> Double {
        let half = TypingIndicator.pulseSeconds / 2
        let offset = Double(index) * TypingIndicator.pulseSeconds / Double(TypingIndicator.dots * 2)
        let phase = (t + offset).truncatingRemainder(dividingBy: TypingIndicator.pulseSeconds)
        let triangle = phase < half ? phase / half : 2 - phase / half
        return TypingIndicator.minAlpha + (1 - TypingIndicator.minAlpha) * triangle
    }
}

struct ConnectionBannerBar: View {
    let state: ConnectionBanner

    @Environment(\.chatColors) private var colors
    @State private var shown: ConnectionBanner = .none

    var body: some View {
        if state != .none {
            HStack(spacing: 8) {
                switch shown {
                case .offline:
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 14))
                case .liveUpdatesUnavailable:
                    Image(systemName: "clock")
                        .font(.system(size: 14))
                default:
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                Text(text(for: shown))
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .foregroundColor(colors.onBannerContainer)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(colors.bannerContainer)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        Color.clear
            .frame(height: 0)
            .onChange(of: state) { newValue in
                if newValue != .none { shown = newValue }
            }
            .onAppear {
                if state != .none { shown = state }
            }
    }

    private func text(for banner: ConnectionBanner) -> String {
        switch banner {
        case .offline: return ChatStrings.bannerOffline
        case .liveUpdatesUnavailable: return ChatStrings.bannerLiveUnavailable
        default: return ChatStrings.bannerConnecting
        }
    }
}

struct NewMessagesChip: View {
    let count: Int
    let onTap: () -> Void

    @Environment(\.chatColors) private var colors

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                Text(ChatStrings.newMessages(count))
                    .font(.subheadline.weight(.medium))
            }
            .foregroundColor(colors.scheme.onPrimary)
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background(colors.unreadDivider)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ChatStrings.scrollToNewest), \(ChatStrings.newMessages(count))")
    }
}
