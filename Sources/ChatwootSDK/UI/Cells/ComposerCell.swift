import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
import PhotosUI
import UIKit
#endif

struct ComposerCell: View {
    @Binding var text: String
    let sending: Bool
    let onSend: () -> Void
    let attachmentMenu: [ChatAttachmentMenuItem]
    let galleryRepresentation: GalleryRepresentation
    let fileContentTypes: [UTType]
    let onAttachmentPicked: (_ url: URL, _ mime: String, _ cleanup: @escaping () -> Void) -> Void
    let onAttachFailed: () -> Void
    let onCameraUnavailable: () -> Void

    @Environment(\.chatColors) private var colors
    @FocusState private var focused: Bool
    #if os(iOS)
    @State private var pickerSession = AttachmentPickerSession()
    #else
    @State private var fileImporterShown = false
    #endif
    @State private var customBusy = false
    @State private var pendingPresent: Task<Void, Never>?

    private static let fieldCorner: CGFloat = 20
    private static let maxLines = 5

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.composerDivider)
                .frame(height: 0.5)
            HStack(alignment: .center, spacing: 4) {
                if !visibleMenu.isEmpty {
                    attachMenu
                }
                field
                sendButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background {
            colors.composerContainer.ignoresSafeArea(edges: .bottom)
        }
        #if !os(iOS)
        .fileImporter(isPresented: $fileImporterShown, allowedContentTypes: fileContentTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let tmp = try ComposerCell.copyToTemp(url, fallbackMime: "application/octet-stream")
                if scoped { url.stopAccessingSecurityScopedResource() }
                onAttachmentPicked(tmp.url, tmp.mime) { try? FileManager.default.removeItem(at: tmp.url) }
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                onAttachFailed()
            }
        }
        #endif
        .onDisappear { pendingPresent?.cancel() }
    }

    private var visibleMenu: [ChatAttachmentMenuItem] {
        ChatAttachmentMenuItem.visible(attachmentMenu)
    }

    private var attachMenu: some View {
        Menu {
            ForEach(Array(visibleMenu.enumerated()), id: \.offset) { _, item in
                menuRow(item)
            }
        } label: {
            Group {
                if customBusy {
                    ProgressView()
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundColor(colors.composerPlaceholder)
                }
            }
            .frame(width: Spacing.touchTarget, height: Spacing.touchTarget)
            .contentShape(Rectangle())
        }
        .disabled(customBusy)
        .accessibilityLabel(ChatStrings.attach)
    }

    @ViewBuilder
    private func menuRow(_ item: ChatAttachmentMenuItem) -> some View {
        switch item {
        case .camera:
            Button {
                presentAfterMenu(openCamera)
            } label: {
                Label(ChatStrings.attachCamera, systemImage: "camera")
            }
        case .photo:
            Button {
                presentAfterMenu(openPhotoLibrary)
            } label: {
                Label(ChatStrings.attachPhoto, systemImage: "photo")
            }
        case .file:
            Button {
                presentAfterMenu(openFile)
            } label: {
                Label(ChatStrings.attachFile, systemImage: "doc")
            }
        case .custom(let action):
            Button {
                startCustom(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }

    /// A picker opened in the same turn as a menu action is cancelled when the
    /// menu finishes dismissing. Wait that animation out, then present.
    private func presentAfterMenu(_ action: @escaping @MainActor () -> Void) {
        pendingPresent?.cancel()
        pendingPresent = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func openPhotoLibrary() {
        #if os(iOS)
        prepareSession()
        pickerSession.presentPhotoLibrary()
        #endif
    }

    private func openFile() {
        #if os(iOS)
        prepareSession()
        pickerSession.presentFile()
        #else
        fileImporterShown = true
        #endif
    }

    private func openCamera() {
        #if os(iOS)
        prepareSession()
        pickerSession.presentCamera()
        #else
        onCameraUnavailable()
        #endif
    }

    #if os(iOS)
    private func prepareSession() {
        pickerSession.galleryRepresentation = galleryRepresentation
        pickerSession.fileContentTypes = fileContentTypes
        pickerSession.onLoading = { customBusy = true }
        pickerSession.onPicked = { url, mime in
            customBusy = false
            onAttachmentPicked(url, mime) { try? FileManager.default.removeItem(at: url) }
        }
        pickerSession.onFailed = {
            customBusy = false
            onAttachFailed()
        }
        pickerSession.onUnavailable = onCameraUnavailable
    }
    #endif

    private func startCustom(_ action: CustomAttachment) {
        guard !customBusy else { return }
        customBusy = true
        Task {
            defer { customBusy = false }
            guard let file = await action.provide() else { return }
            deliver(file)
        }
    }

    private func deliver(_ file: ChatAttachmentFile) {
        let scoped = file.url.startAccessingSecurityScopedResource()
        defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
        do {
            let tmp = try ComposerCell.copyToTemp(file.url, fallbackMime: file.mimeType ?? "application/octet-stream")
            let mime = file.mimeType ?? tmp.mime
            onAttachmentPicked(tmp.url, mime) { try? FileManager.default.removeItem(at: tmp.url) }
        } catch {
            onAttachFailed()
        }
    }

    private var field: some View {
        let lineHeight: CGFloat = 22
        let minHeight: CGFloat = lineHeight + 14
        let maxHeight = lineHeight * CGFloat(ComposerCell.maxLines) + 14
        return ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(ChatStrings.composerHint)
                    .font(.body)
                    .foregroundColor(colors.composerPlaceholder)
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
        .foregroundColor(colors.composerText)
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
                    .foregroundColor(colors.onComposerSend)
                    .frame(width: 40, height: 40)
                    .background(sending ? colors.composerSend.opacity(0.6) : colors.composerSend)
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

    nonisolated fileprivate static func copyToTemp(_ url: URL, fallbackMime: String) throws -> (url: URL, mime: String) {
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: url, to: tmp)
        let mime = ComposerCell.mimeType(for: ext) ?? fallbackMime
        return (tmp, mime)
    }

    nonisolated static func mimeType(for ext: String) -> String? {
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

#if os(iOS)
/// Presents system pickers with `present`, above the SwiftUI host.
/// Embedding them in a hosting controller makes UIKit insert `_UIReparentingView`
/// into `UIHostingController.view`, which iOS rejects.
@MainActor
private final class AttachmentPickerSession: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    var galleryRepresentation: GalleryRepresentation = .current
    var fileContentTypes: [UTType] = [.item]
    var onLoading: () -> Void = {}
    var onPicked: (URL, String) -> Void = { _, _ in }
    var onFailed: () -> Void = {}
    var onUnavailable: () -> Void = {}
    private weak var host: UIViewController?

    func presentPhotoLibrary() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = galleryRepresentation.pickerMode
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker)
    }

    func presentFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: fileContentTypes, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker)
    }

    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onUnavailable()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.showCamera() } else { self.onUnavailable() }
                }
            }
        default:
            onUnavailable()
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(picker)
        guard let provider = results.first?.itemProvider else { return }
        onLoading()
        load(provider)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(picker)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let outcome = Self.capturedFile(from: info)
        dismiss(picker)
        switch outcome {
        case .success((let url, let mime)):
            onPicked(url, mime)
        case .failure:
            onFailed()
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        dismiss(controller)
        guard let url = urls.first else { return }
        do {
            let copied = try ComposerCell.copyToTemp(url, fallbackMime: "application/octet-stream")
            onPicked(copied.url, copied.mime)
        } catch {
            onFailed()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        dismiss(controller)
    }

    /// A plain controller presents the picker, so UIKit never inserts
    /// `_UIReparentingView` into `UIHostingController.view`.
    private func present(_ picker: UIViewController) {
        guard let presenter = UIViewController.chatTopPresenter else {
            onFailed()
            return
        }
        let host = UIViewController()
        host.modalPresentationStyle = .overFullScreen
        host.view.backgroundColor = .clear
        self.host = host
        presenter.present(host, animated: false) {
            host.present(picker, animated: true)
        }
    }

    private func dismiss(_ picker: UIViewController) {
        let host = self.host
        guard picker.presentingViewController != nil else {
            host?.dismiss(animated: false)
            return
        }
        picker.dismiss(animated: true) {
            host?.dismiss(animated: false)
        }
    }

    private func showCamera() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = UIImagePickerController.availableMediaTypes(for: .camera) ?? [UTType.image.identifier]
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = self
        present(picker)
    }

    private func load(_ provider: NSItemProvider) {
        let type: UTType
        let fallback: String
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            type = .movie
            fallback = "video/quicktime"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
            type = .video
            fallback = "video/mp4"
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            type = .image
            fallback = "image/jpeg"
        } else {
            onFailed()
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            guard let self else { return }
            guard let url else {
                Task { @MainActor in self.onFailed() }
                return
            }
            do {
                let copied = try ComposerCell.copyToTemp(url, fallbackMime: fallback)
                Task { @MainActor in self.onPicked(copied.url, copied.mime) }
            } catch {
                Task { @MainActor in self.onFailed() }
            }
        }
    }

    private static func capturedFile(from info: [UIImagePickerController.InfoKey: Any]) -> Result<(URL, String), Error> {
        let mediaType = info[.mediaType] as? String
        if mediaType == UTType.movie.identifier, let source = info[.mediaURL] as? URL {
            do {
                let copied = try ComposerCell.copyToTemp(source, fallbackMime: "video/quicktime")
                return .success((copied.url, copied.mime))
            } catch {
                return .failure(error)
            }
        }
        guard let image = info[.originalImage] as? UIImage else {
            return .failure(CocoaError(.fileReadUnknown))
        }
        do {
            return .success((try writeJPEG(image), "image/jpeg"))
        } catch {
            return .failure(error)
        }
    }

    private static func writeJPEG(_ image: UIImage) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let upright = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = upright.jpegData(compressionQuality: AttachmentLimits.jpegQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try data.write(to: url)
        return url
    }
}

private extension GalleryRepresentation {
    var pickerMode: PHPickerConfiguration.AssetRepresentationMode {
        switch self {
        case .current: return .current
        case .compatible: return .compatible
        }
    }
}

private extension UIViewController {
    /// The controller that should modally present a system picker.
    /// Stops at the SwiftUI host instead of inserting a view into it.
    static var chatTopPresenter: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        return window?.rootViewController?.chatDeepestPresented
    }

    var chatDeepestPresented: UIViewController {
        if let presented = presentedViewController, !presented.isBeingDismissed {
            return presented.chatDeepestPresented
        }
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.chatDeepestPresented ?? navigation
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.chatDeepestPresented ?? tab
        }
        return self
    }
}
#endif

