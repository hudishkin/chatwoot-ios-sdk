import SwiftUI
#if os(iOS)
import PhotosUI
#endif

struct ComposerCell: View {
    @Binding var text: String
    let sending: Bool
    let onSend: () -> Void
    let onAttachmentPicked: (_ url: URL, _ mime: String, _ cleanup: @escaping () -> Void) -> Void

    @Environment(\.chatColors) private var colors
    @FocusState private var focused: Bool
    @State private var fileImporterShown = false

    private static let fieldCorner: CGFloat = 20
    private static let maxLines = 5

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.scheme.outlineVariant)
                .frame(height: 0.5)
            HStack(alignment: .bottom, spacing: 4) {
                attachMenu
                field
                sendButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(colors.composerContainer)
        .fileImporter(isPresented: $fileImporterShown, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let tmp = try ComposerCell.copyToTemp(url, fallbackMime: "application/octet-stream")
                if scoped { url.stopAccessingSecurityScopedResource() }
                onAttachmentPicked(tmp.url, tmp.mime) { try? FileManager.default.removeItem(at: tmp.url) }
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private var attachMenu: some View {
        Menu {
            #if os(iOS)
            if #available(iOS 16, *) {
                PhotoAttachButton { item in
                    Task { await importPhoto(item) }
                }
            }
            #endif
            Button {
                fileImporterShown = true
            } label: {
                Label(ChatStrings.attachFile, systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 18))
                .foregroundColor(colors.scheme.onSurfaceVariant)
                .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(ChatStrings.attach)
    }

    private var field: some View {
        let lineHeight: CGFloat = 22
        let minHeight: CGFloat = lineHeight + 14
        let maxHeight = lineHeight * CGFloat(ComposerCell.maxLines) + 14
        return ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(ChatStrings.composerHint)
                    .font(.body)
                    .foregroundColor(colors.scheme.onSurfaceVariant)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .scrollContentBackgroundHidden()
        }
        .foregroundColor(colors.scheme.onSurface)
        .background(colors.composerField)
        .clipShape(RoundedRectangle(cornerRadius: ComposerCell.fieldCorner))
        .accessibilityLabel(ChatStrings.composerHint)
    }

    private var sendButton: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if !trimmed.isEmpty {
                Button(action: onSend) {
                    ZStack {
                        if sending {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18))
                        }
                    }
                    .foregroundColor(colors.scheme.onPrimary)
                    .frame(width: 40, height: 40)
                    .background(sending ? colors.scheme.primary.opacity(0.6) : colors.scheme.primary)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(ChatStrings.send)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: trimmed.isEmpty)
    }

    #if os(iOS)
    @available(iOS 16, *)
    private struct PhotoAttachButton: View {
        let onPicked: (PhotosPickerItem) -> Void
        @State private var photoItem: PhotosPickerItem?

        var body: some View {
            PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                Label(ChatStrings.attachPhoto, systemImage: "photo")
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                photoItem = nil
                onPicked(item)
            }
        }
    }

    @available(iOS 16, *)
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try data.write(to: url)
            await MainActor.run {
                onAttachmentPicked(url, mime) { try? FileManager.default.removeItem(at: url) }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }
    #endif

    private static func copyToTemp(_ url: URL, fallbackMime: String) throws -> (url: URL, mime: String) {
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: url, to: tmp)
        let mime = ComposerCell.mimeType(for: ext) ?? fallbackMime
        return (tmp, mime)
    }

    static func mimeType(for ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        default: return nil
        }
    }
}

