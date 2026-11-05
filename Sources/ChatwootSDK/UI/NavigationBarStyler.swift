import SwiftUI
#if os(iOS)
import UIKit

extension View {
    @ViewBuilder
    func chatNavigationBar(background: Color, foreground: Color) -> some View {
        let styled = self.background {
            NavigationBarStyler(background: UIColor(background), foreground: UIColor(foreground))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        if #available(iOS 16.0, *) {
            styled
                .toolbarBackground(background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(NavigationBarContrast.scheme(foreground: foreground), for: .navigationBar)
        } else {
            styled
        }
    }
}

private enum NavigationBarContrast {
    static func scheme(foreground: Color) -> ColorScheme {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(foreground).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .light
        }
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.6 ? .dark : .light
    }
}

private struct NavigationBarStyler: UIViewRepresentable {
    let background: UIColor
    let foreground: UIColor

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.barBackground = background
        uiView.barForeground = foreground
        uiView.apply()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        uiView.restore()
    }

    final class ProbeView: UIView {
        var barBackground: UIColor = .clear
        var barForeground: UIColor = .label
        private var saved: Saved?
        private var applying = false

        private struct Saved {
            weak var controller: UINavigationController?
            let standard: UINavigationBarAppearance
            let scrollEdge: UINavigationBarAppearance?
            let compact: UINavigationBarAppearance?
            let compactScrollEdge: UINavigationBarAppearance?
            let tint: UIColor?
            let barStyle: UIBarStyle
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        func apply() {
            guard !applying else { return }
            applying = true
            defer { applying = false }
            guard let controller = navigationController else { return }
            let bar = controller.navigationBar
            let wantedStyle: UIBarStyle = NavigationBarContrast.scheme(foreground: Color(barForeground)) == .dark ? .black : .default
            if saved != nil,
               bar.standardAppearance.backgroundColor?.isEqual(barBackground) == true,
               bar.tintColor?.isEqual(barForeground) == true,
               bar.barStyle == wantedStyle {
                return
            }
            if saved == nil {
                saved = Saved(
                    controller: controller,
                    standard: bar.standardAppearance,
                    scrollEdge: bar.scrollEdgeAppearance,
                    compact: bar.compactAppearance,
                    compactScrollEdge: bar.compactScrollEdgeAppearance,
                    tint: bar.tintColor,
                    barStyle: bar.barStyle
                )
            }
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = barBackground
            appearance.shadowColor = barBackground
            appearance.titleTextAttributes = [.foregroundColor: barForeground]
            appearance.largeTitleTextAttributes = [.foregroundColor: barForeground]
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactAppearance = appearance
            bar.compactScrollEdgeAppearance = appearance
            bar.tintColor = barForeground
            bar.barStyle = wantedStyle
        }

        func restore() {
            guard let saved, let bar = saved.controller?.navigationBar else {
                self.saved = nil
                return
            }
            bar.standardAppearance = saved.standard
            bar.scrollEdgeAppearance = saved.scrollEdge
            bar.compactAppearance = saved.compact
            bar.compactScrollEdgeAppearance = saved.compactScrollEdge
            bar.tintColor = saved.tint
            bar.barStyle = saved.barStyle
            self.saved = nil
        }

        private var navigationController: UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UINavigationController { return controller }
                if let controller = current as? UIViewController, let navigation = controller.navigationController {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}
#else
extension View {
    func chatNavigationBar(background: Color, foreground: Color) -> some View { self }
}
#endif
