import SwiftUI

struct SurveyCallbacks {
    let onRate: (Int) -> Void
    let onComment: (String) -> Void
    let onAddComment: () -> Void
    let onSend: () -> Void
}

struct SurveyCell: View {
    let item: ChatItem.Survey
    let draft: SurveyDraft?
    let callbacks: SurveyCallbacks

    @Environment(\.chatColors) private var colors

    var body: some View {
        let sentRating = draft?.phase == .sent ? draft?.rating : nil
        let answered = item.answeredRating ?? sentRating
        if let answered {
            SurveyCard {
                Prompt(text: item.prompt, color: colors.scheme.onSurfaceVariant)
                AnsweredRating(display: item.display, rating: answered)
                Text(ChatStrings.surveyThanks)
                    .font(.footnote)
                    .foregroundColor(colors.scheme.onSurfaceVariant)
            }
        } else if item.closedHint || draft?.phase == .closed {
            SystemCell(text: ChatStrings.surveyClosed)
        } else {
            OpenSurvey(item: item, draft: draft ?? SurveyDraft(), callbacks: callbacks)
        }
    }
}

private struct OpenSurvey: View {
    let item: ChatItem.Survey
    let draft: SurveyDraft
    let callbacks: SurveyCallbacks

    @Environment(\.chatColors) private var colors
    @FocusState private var commentFocused: Bool
    @State private var focusOnOpen: Bool

    init(item: ChatItem.Survey, draft: SurveyDraft, callbacks: SurveyCallbacks) {
        self.item = item
        self.draft = draft
        self.callbacks = callbacks
        _focusOnOpen = State(initialValue: !draft.commentExpanded)
    }

    var body: some View {
        SurveyCard {
            Prompt(text: item.prompt, color: colors.scheme.onSurface)
            RatingPicker(display: item.display, rating: draft.rating, enabled: draft.editable, onRate: callbacks.onRate)
            if let rating = draft.rating {
                if draft.commentExpanded {
                    CommentField(draft: draft, rating: rating, focused: $commentFocused, onComment: callbacks.onComment)
                        .onAppear {
                            if focusOnOpen {
                                focusOnOpen = false
                                commentFocused = true
                            }
                        }
                }
                HStack {
                    if !draft.commentExpanded {
                        Button(ChatStrings.surveyAddComment, action: callbacks.onAddComment)
                            .font(.subheadline)
                            .disabled(!draft.editable)
                    }
                    Spacer(minLength: 0)
                    if draft.phase == .failed {
                        FailedState(onRetry: callbacks.onSend, reason: ChatStrings.surveyFailed)
                    } else {
                        SendButton(sending: draft.phase == .sending, onTap: callbacks.onSend)
                    }
                }
            }
        }
    }
}

private struct SurveyCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.scheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(colors.scheme.outlineVariant, lineWidth: 1)
        )
        .padding(.vertical, 8)
    }
}

private struct Prompt: View {
    let text: String
    let color: Color

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.body)
                .foregroundColor(color)
        }
    }
}

private struct RatingPicker: View {
    let display: SurveyDisplay
    let rating: Int?
    let enabled: Bool
    let onRate: (Int) -> Void

    private static let mark: CGFloat = 32

    var body: some View {
        HStack {
            ForEach(1 ... surveyMaxRating, id: \.self) { value in
                Button {
                    onRate(value)
                } label: {
                    RatingMark(display: display, value: value, rating: rating, size: RatingPicker.mark)
                        .frame(minWidth: Spacing.touchTarget, minHeight: Spacing.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(ChatStrings.surveyRate(value, of: surveyMaxRating))
                .accessibilityAddTraits(value == rating ? [.isButton, .isSelected] : .isButton)
                if value != surveyMaxRating { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AnsweredRating: View {
    let display: SurveyDisplay
    let rating: Int

    private static let mark: CGFloat = 20

    var body: some View {
        HStack(spacing: 4) {
            if display == .emoji {
                RatingMark(display: display, value: rating, rating: rating, size: AnsweredRating.mark)
            } else {
                ForEach(1 ... surveyMaxRating, id: \.self) { value in
                    RatingMark(display: display, value: value, rating: rating, size: AnsweredRating.mark)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatStrings.surveyRated(rating, of: surveyMaxRating))
    }
}

private struct RatingMark: View {
    let display: SurveyDisplay
    let value: Int
    let rating: Int?
    let size: CGFloat

    @Environment(\.chatColors) private var colors

    private static let emoji = ["😞", "😑", "😐", "😀", "😍"]
    private static let emojiHalo: CGFloat = 8
    private static let emojiToIcon = 0.8
    private static let fadedAlpha = 0.45

    var body: some View {
        switch display {
        case .stars:
            let filled = rating != nil && value <= (rating ?? 0)
            Image(systemName: filled ? "star.fill" : "star")
                .font(.system(size: size * 0.8))
                .foregroundColor(filled ? colors.scheme.primary : colors.scheme.outline)
                .frame(width: size, height: size)
        case .emoji:
            let picked = value == rating
            Text(RatingMark.emoji[value - 1])
                .font(.system(size: size * RatingMark.emojiToIcon))
                .frame(width: size + RatingMark.emojiHalo, height: size + RatingMark.emojiHalo)
                .background(picked ? colors.scheme.primaryContainer : Color.clear)
                .clipShape(Circle())
                .opacity(rating == nil || picked ? 1 : RatingMark.fadedAlpha)
        }
    }
}

private struct CommentField: View {
    let draft: SurveyDraft
    let rating: Int
    var focused: FocusState<Bool>.Binding
    let onComment: (String) -> Void

    @Environment(\.chatColors) private var colors

    private static let maxLines = 5

    var body: some View {
        let low = rating <= surveyCommentThreshold
        ZStack(alignment: .topLeading) {
            if draft.comment.isEmpty {
                Text(low ? ChatStrings.surveyCommentHint : ChatStrings.surveyAddComment)
                    .font(.body)
                    .foregroundColor(colors.scheme.onSurfaceVariant)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(
                get: { draft.comment },
                set: { onComment($0) }
            ))
            .font(.body)
            .focused(focused)
            .disabled(!draft.editable)
            .frame(minHeight: 60, maxHeight: 120)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .scrollContentBackgroundHidden()
        }
        .background(colors.scheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colors.scheme.outline, lineWidth: 1)
        )
    }
}

private struct SendButton: View {
    let sending: Bool
    let onTap: () -> Void

    @Environment(\.chatColors) private var colors

    var body: some View {
        Button(action: onTap) {
            Group {
                if sending {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)
                } else {
                    Text(ChatStrings.surveySend)
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundColor(colors.scheme.onPrimaryContainer)
            .background(colors.scheme.primaryContainer)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }
}

extension View {
    @ViewBuilder
    func scrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
