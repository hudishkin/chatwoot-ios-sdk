import Foundation

enum AttachmentLimits {
    static let maxFileBytes = 40 * 1024 * 1024
    static let maxImageSide = 2048
    static let jpegQuality = 0.85

    private static let compressible: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif"]

    static func isCompressibleImage(_ mime: String?) -> Bool {
        guard let mime else { return false }
        let normalized = mime.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized.map(compressible.contains) ?? false
    }
}
