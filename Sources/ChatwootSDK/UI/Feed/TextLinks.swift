import Foundation

func findLinks(_ text: String) -> [Range<String.Index>] {
    let pattern = linkPattern
    let nsRange = NSRange(text.startIndex..., in: text)
    return (pattern?.matches(in: text, range: nsRange) ?? []).compactMap { match in
        guard var range = Range(match.range, in: text) else { return nil }
        while range.lowerBound < range.upperBound,
              let last = text[range].last,
              trailingLinkPunctuation.contains(last) {
            range = range.lowerBound ..< text.index(before: range.upperBound)
        }
        return text[range].count > schemeMinLength ? range : nil
    }
}

func middleEllipsize(_ name: String, maxChars: Int = 32) -> String {
    guard name.count > maxChars else { return name }
    let dot = name.lastIndex(of: ".")
    let extensionPart: String
    if let dot, dot > name.startIndex, name.distance(from: dot, to: name.endIndex) <= maxExtensionLength {
        extensionPart = String(name[dot...])
    } else {
        extensionPart = ""
    }
    let stem = String(name.dropLast(extensionPart.count))
    let keep = max(maxChars - extensionPart.count - 1, 2)
    let head = (keep + 1) / 2
    let tail = keep - head
    return stem.prefix(head) + "…" + stem.suffix(tail) + extensionPart
}

private let linkPattern = try? NSRegularExpression(pattern: #"https?://[^\s<>"]+"#, options: .caseInsensitive)
private let trailingLinkPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\""]
private let schemeMinLength = 8
private let maxExtensionLength = 6

func imageBoxSize(width: Int?, height: Int?, maxWidth: Int) -> (width: Int, height: Int) {
    let boxWidth = min(maxWidth, maxImageWidth)
    let ratio: Double
    if let width, let height, width > 0, height > 0 {
        ratio = Double(width) / Double(height)
    } else {
        ratio = 4.0 / 3.0
    }
    let boxHeight = min(max(Int(Double(boxWidth) / ratio), minImageHeight), maxImageHeight)
    return (boxWidth, boxHeight)
}

let maxImageWidth = 240
let minImageHeight = 120
let maxImageHeight = 320
