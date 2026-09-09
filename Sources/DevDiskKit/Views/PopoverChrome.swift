import AppKit
import SwiftUI

/// Reaches the hosting `NSWindow` so the popover panel can be styled.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window during makeNSView; it gains one on the next turn.
        DispatchQueue.main.async { view.window.map(configure) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window.map(configure) }
    }
}

/// Makes the menu bar popover look like the card the panel is drawn as.
///
/// `MenuBarExtra(.window)` hosts the content in a panel that (measured on this
/// machine) is 20pt taller than the content and paints its own square, opaque
/// background. The result is a band of empty grey above and below the panel and
/// hard 90° corners — the popover reads as content dropped into a box rather than
/// as a card.
///
/// So the panel takes the window over: clear the window's background, draw a
/// rounded one of its own, and cancel the host's vertical inset with matching
/// negative padding so the card fills the panel exactly.
struct PopoverChrome: ViewModifier {
    /// Half of the 20pt the host adds; measured by comparing the popover's window
    /// height against the same content in the standalone window.
    static let hostInset: CGFloat = 10
    static let cornerRadius: CGFloat = 11

    func body(content: Content) -> some View {
        content
            // The card's background grows into the host's inset instead of the
            // content shrinking into it. Shrinking the content worked at the top but
            // pushed the version line past the window's bottom edge, where the window
            // clipped it — the fix must not cost content.
            .background {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .padding(.vertical, -Self.hostInset)
            }
            .background(WindowAccessor { window in
                guard window.backgroundColor != .clear else { return }
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = true
            })
    }
}

extension View {
    /// Applied only to the menu bar popover; the standalone window keeps the
    /// system's own title bar and rounding.
    func popoverChrome() -> some View { modifier(PopoverChrome()) }
}
