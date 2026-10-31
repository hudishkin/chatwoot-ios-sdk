import SwiftUI

struct OwnTextCell: View {
    let item: ChatItem.Mine
    let time: String
    let maxWidth: CGFloat
    let onCopy: (String) -> Void
    let onRetry: (String) -> Void

    @Environment(\.chatColors) private var colors

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Group {
                    if item.deleted {
                        Text(ChatStrings.messageDeleted)
                            .italic()
                    } else {
                        Text(linkified(item.text ?? "", linkColor: colors.outgoingLink))
                    }
                }
                .font(.body)
                if item.showMeta {
                    MessageMeta(
                        time: time,
                        color: colors.outgoingMeta,
                        status: item.deleted ? nil : item.status
                    )
                }
            }
            .padding(.horizontal, Spacing.bubbleHorizontal)
            .padding(.vertical, Spacing.bubbleVertical)
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .background(colors.outgoingBubble)
            .foregroundColor(colors.onOutgoingBubble)
            .clipShape(BubbleShape(mine: true, run: item.run))
            .contentShape(BubbleShape(mine: true, run: item.run))
            .onTapGesture {
                if item.status == .failed, let echoId = item.echoId { onRetry(echoId) }
            }
            .onLongPressGesture {
                if let text = item.text { onCopy(text) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ownDescription(item, time: time))
        }
        .padding(.bottom, runGap(item.run))
    }
}

func ownDescription(_ item: ChatItem.Mine, time: String) -> String {
    let status: String
    switch item.status {
    case .sending: status = ChatStrings.sendingStatus
    case .sent: status = ChatStrings.sentStatus
    case .failed: status = ChatStrings.failed
    }
    let body = item.deleted ? ChatStrings.messageDeleted : item.text ?? ""
    return "\(ChatStrings.you), \(time), \(status): \(body)"
}

struct AgentTextCell: View {
    let item: ChatItem.Theirs
    let time: String
    let maxWidth: CGFloat
    let onCopy: (String) -> Void

    @Environment(\.chatColors) private var colors

    var body: some View {
        AgentRow(item: item) {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if item.deleted {
                        Text(ChatStrings.messageDeleted)
                            .italic()
                    } else {
                        Text(linkified(item.text ?? "", linkColor: colors.incomingLink))
                    }
                }
                .font(.body)
                if item.showMeta {
                    HStack {
                        Spacer(minLength: 0)
                        MessageMeta(time: time, color: colors.incomingMeta, status: nil)
                    }
                }
            }
            .padding(.horizontal, Spacing.bubbleHorizontal)
            .padding(.vertical, Spacing.bubbleVertical)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(colors.incomingBubble)
            .foregroundColor(colors.onIncomingBubble)
            .clipShape(BubbleShape(mine: false, run: item.run))
            .contentShape(BubbleShape(mine: false, run: item.run))
            .onLongPressGesture {
                if let text = item.text { onCopy(text) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(agentDescription(item, time: time))
        }
    }
}

struct AgentRow<Bubble: View>: View {
    let item: ChatItem.Theirs
    @ViewBuilder let bubble: () -> Bubble

    @Environment(\.chatColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.showName, let senderName = item.senderName, !senderName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(senderName)
                    .font(.caption)
                    .foregroundColor(colors.incomingMeta)
                    .lineLimit(1)
                    .padding(.leading, Spacing.avatar + Spacing.avatarGap + Spacing.bubbleHorizontal)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .bottom, spacing: Spacing.avatarGap) {
                if item.showAvatar {
                    Avatar(name: item.senderName)
                } else {
                    Spacer().frame(width: Spacing.avatar)
                }
                bubble()
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, runGap(item.run))
    }
}

struct Avatar: View {
    let name: String?

    @Environment(\.chatColors) private var colors

    var body: some View {
        Text(initials(name))
            .font(.caption)
            .foregroundColor(colors.onAvatarPlaceholder)
            .lineLimit(1)
            .frame(width: Spacing.avatar, height: Spacing.avatar)
            .background(colors.avatarPlaceholder)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

func agentDescription(_ item: ChatItem.Theirs, time: String) -> String {
    let who: String
    if let name = item.senderName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
        who = ChatStrings.agent(name)
    } else {
        who = ChatStrings.agentUnnamed
    }
    let body = item.deleted ? ChatStrings.messageDeleted : item.text ?? ""
    return "\(who), \(time): \(body)"
}
