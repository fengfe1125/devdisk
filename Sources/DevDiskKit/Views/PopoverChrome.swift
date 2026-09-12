import AppKit
import SwiftUI

private struct PopoverContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

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
/// The system popover host adds a small content inset and owns an opaque background.
/// If left untouched, the result is a band of empty colour above and below the
/// panel and hard 90° corners — the popover reads as content dropped into a box
/// rather than as a card.
///
/// So the panel takes the window over: clear the window's background, draw a
/// rounded one of its own, and cancel the host's vertical inset with matching
/// negative padding so the card fills the panel exactly.
struct PopoverChrome: ViewModifier {
    /// Half of the 20pt the host adds; measured by comparing the popover's window
    /// height against the same content in the standalone window.
    static let hostInset: CGFloat = 10
    static let cornerRadius: CGFloat = 11

    @State private var contentSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    Color.clear.preference(key: PopoverContentSizeKey.self,
                                           value: geometry.size)
                }
            }
            .onPreferenceChange(PopoverContentSizeKey.self) { size in
                guard size != .zero else { return }
                contentSize = size
            }
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
                // The popover host can keep the previous screen's frame when the
                // SwiftUI content becomes shorter. Make the host transparent and
                // explicitly follow the current natural size so a short screen
                // stays attached to the menu bar instead of being vertically
                // centred in a stale tall window.
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = true

                guard contentSize != .zero else { return }
                let target = NSSize(width: contentSize.width,
                                    height: contentSize.height + Self.hostInset * 2)
                let current = window.contentView?.bounds.size ?? .zero
                guard abs(current.width - target.width) > 0.5
                        || abs(current.height - target.height) > 0.5 else { return }
                window.setContentSize(target)
            })
    }
}

extension View {
    /// Applied only to the menu bar popover; the standalone window keeps the
    /// system's own title bar and rounding.
    func popoverChrome() -> some View { modifier(PopoverChrome()) }
}
