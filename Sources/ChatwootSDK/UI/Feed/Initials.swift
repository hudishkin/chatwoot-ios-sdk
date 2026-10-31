import Foundation

func initials(_ name: String?) -> String {
    let words = (name ?? "").trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
    let result = words.prefix(2).compactMap { $0.first?.uppercased() }.joined()
    return result.isEmpty ? "?" : result
}
