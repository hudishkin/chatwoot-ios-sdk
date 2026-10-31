import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CompressResult {
    case done
    case unsupported
    case keepOriginal
}

enum ImageCompressor {
    static func compress(data: Data, to output: URL) -> CompressResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return .unsupported
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AttachmentLimits.maxImageSide
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .unsupported
        }
        let hasAlpha: Bool = {
            switch thumbnail.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast:
                return false
            default:
                return true
            }
        }()
        if hasAlpha && data.count <= AttachmentLimits.maxFileBytes {
            return .keepOriginal
        }
        let flattened = hasAlpha ? flattenOnWhite(thumbnail) : thumbnail
        guard let flattened,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: output)
            return .unsupported
        }
        CGImageDestinationAddImage(destination, flattened, [
            kCGImageDestinationLossyCompressionQuality: AttachmentLimits.jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            return .unsupported
        }
        return .done
    }

    private static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
