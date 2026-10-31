import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct BubbleShape: Shape {
    let mine: Bool
    let run: RunPosition

    static let large: CGFloat = 20
    static let joined: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let senderTop = run.isFirst ? BubbleShape.large : BubbleShape.joined
        let topLeading = mine ? BubbleShape.large : senderTop
        let topTrailing = mine ? senderTop : BubbleShape.large
        let bottomTrailing = mine ? BubbleShape.joined : BubbleShape.large
        let bottomLeading = mine ? BubbleShape.large : BubbleShape.joined
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + topLeading, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - topTrailing, y: rect.minY + topTrailing),
                        radius: topTrailing, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
            path.addArc(center: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY - bottomTrailing),
                        radius: bottomTrailing, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY - bottomLeading),
                        radius: bottomLeading, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))
            path.addArc(center: CGPoint(x: rect.minX + topLeading, y: rect.minY + topLeading),
                        radius: topLeading, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
        }
    }
}

func runGap(_ run: RunPosition) -> CGFloat {
    run.isFirst ? Spacing.betweenRuns : Spacing.inRun
}

func linkified(_ text: String, linkColor: Color) -> AttributedString {
    var attributed = AttributedString(text)
    for range in findLinks(text) {
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
        let slice = lower ..< upper
        attributed[slice].link = URL(string: String(text[range]))
        attributed[slice].foregroundColor = linkColor
        attributed[slice].underlineStyle = .single
    }
    return attributed
}

func linkHost(_ url: String) -> String {
    var host = url
    if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
    for separator: Character in ["/", "?", "#"] {
        if let index = host.firstIndex(of: separator) { host = String(host[..<index]) }
    }
    return host
}

struct MessageMeta: View {
    let time: String
    let color: Color
    let status: SendStatus?

    var body: some View {
        HStack(spacing: 4) {
            Text(time)
                .font(.caption2)
                .foregroundColor(color)
            switch status {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundColor(color)
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
            case .failed, nil:
                EmptyView()
            }
        }
    }
}

enum PlatformClipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
