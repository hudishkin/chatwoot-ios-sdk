import SwiftUI

struct ImageAttachmentCell: View {
    let mine: Bool
    let attachment: AttachmentUi
    let caption: String?
    let run: RunPosition
    let time: String
    let showMeta: Bool
    let status: SendStatus?
    let maxWidth: CGFloat
    let onOpen: () -> Void
    let onCopy: (String) -> Void
    let description: String

    @Environment(\.chatColors) private var colors
    @State private var failed = false
    @State private var attempt = 0

    private static let innerPadding: CGFloat = 4
    private static let scrimAlpha = 0.6

    var body: some View {
        let box = imageBoxSize(
            width: attachment.width,
            height: attachment.height,
            maxWidth: Int(maxWidth - 2 * ImageAttachmentCell.innerPadding)
        )
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if failed {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                        Text(ChatStrings.imageRetry)
                            .font(.footnote)
                    }
                    .foregroundColor(colors.scheme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure:
                            Color.clear
                                .onAppear { failed = true }
                        case .empty:
                            Color.clear
                        @unknown default:
                            Color.clear
                        }
                    }
                    .id(attempt)
                }
                if showMeta && caption == nil {
                    MessageMeta(time: time, color: .white, status: status)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(ImageAttachmentCell.scrimAlpha))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(6)
                }
            }
            .frame(width: CGFloat(box.width), height: CGFloat(box.height))
            .background(colors.scheme.surfaceVariant)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .clipped()

            if let caption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(linkified(caption, linkColor: mine ? colors.outgoingLink : colors.incomingLink))
                        .font(.body)
                    if showMeta {
                        HStack {
                            Spacer(minLength: 0)
                            MessageMeta(
                                time: time,
                                color: mine ? colors.outgoingMeta : colors.incomingMeta,
                                status: status
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.bubbleHorizontal - ImageAttachmentCell.innerPadding)
                .padding(.vertical, 4)
            }
        }
        .padding(ImageAttachmentCell.innerPadding)
        .background(mine ? colors.outgoingBubble : colors.incomingBubble)
        .foregroundColor(mine ? colors.onOutgoingBubble : colors.onIncomingBubble)
        .clipShape(BubbleShape(mine: mine, run: run))
        .contentShape(BubbleShape(mine: mine, run: run))
        .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
        .onTapGesture {
            if failed {
                failed = false
                attempt += 1
            } else {
                onOpen()
            }
        }
        .onLongPressGesture {
            if let caption { onCopy(caption) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(description)
        .accessibilityAddTraits(.isButton)
    }

    private var imageURL: URL? {
        if attachment.isLocal {
            return URL(fileURLWithPath: attachment.source)
        }
        return URL(string: attachment.thumbnail ?? attachment.source)
    }
}

struct FileAttachmentCell: View {
    let mine: Bool
    let attachment: AttachmentUi
    let caption: String?
    let run: RunPosition
    let time: String
    let showMeta: Bool
    let status: SendStatus?
    let maxWidth: CGFloat
    let format: ChatFormat
    let onOpen: () -> Void
    let onCopy: (String) -> Void
    let description: String

    @Environment(\.chatColors) private var colors

    private static let iconBackgroundAlpha = 0.12

    var body: some View {
        let content = mine ? colors.onOutgoingBubble : colors.onIncomingBubble
        let meta = mine ? colors.outgoingMeta : colors.incomingMeta
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .font(.system(size: 18))
                        .foregroundColor(content)
                        .frame(width: 40, height: 40)
                        .background(content.opacity(FileAttachmentCell.iconBackgroundAlpha))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(middleEllipsize(attachment.name))
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        let details = [
                            attachment.sizeBytes.map { format.size($0) },
                            fileType(attachment.name),
                        ].compactMap { $0 }.joined(separator: " · ")
                        if !details.isEmpty {
                            Text(details)
                                .font(.footnote)
                                .foregroundColor(meta)
                        }
                    }
                }
                if let caption {
                    Text(linkified(caption, linkColor: mine ? colors.outgoingLink : colors.incomingLink))
                        .font(.body)
                }
                if showMeta {
                    HStack {
                        Spacer(minLength: 0)
                        MessageMeta(time: time, color: meta, status: status)
                    }
                }
            }
            .padding(.horizontal, Spacing.bubbleHorizontal)
            .padding(.vertical, Spacing.bubbleVertical)
            if status == .sending {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(content)
            }
        }
        .background(mine ? colors.outgoingBubble : colors.incomingBubble)
        .foregroundColor(content)
        .clipShape(BubbleShape(mine: mine, run: run))
        .contentShape(BubbleShape(mine: mine, run: run))
        .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
        .onTapGesture(perform: onOpen)
        .onLongPressGesture {
            if let caption { onCopy(caption) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(description)
        .accessibilityAddTraits(.isButton)
    }
}

func fileType(_ name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot < name.endIndex else { return nil }
    let ext = name[name.index(after: dot)...]
    guard !ext.isEmpty, ext.count <= 5 else { return nil }
    return ext.uppercased()
}
