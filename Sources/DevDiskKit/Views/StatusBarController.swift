import AppKit
import Combine
import SwiftUI

/// Owns the status item and the popover it anchors to.
///
/// The SwiftUI menu-bar window style leaves sizing and placement to a private host
/// window. That host can retain the previous screen's height, which vertically
/// centres a short card and exposes transparent bands. An AppKit status item gives
/// us the two things this panel needs to be deterministic: the exact anchor view and
/// a popover whose content size follows the hosted SwiftUI view.
@MainActor
final class StatusBarController: NSObject {
    private let store: DiskStore
    private let updates: UpdateChecker
    private let popover = NSPopover()
    private let hostingController: NSHostingController<AnyView>
    private var statusItem: NSStatusItem?
    private var storeObservation: AnyCancellable?

    init(store: DiskStore, updates: UpdateChecker) {
        self.store = store
        self.updates = updates

        let panel = PanelView()
            .environmentObject(store)
            .environmentObject(updates)
            .fixedSize(horizontal: false, vertical: true)
            .popoverChrome()
        hostingController = NSHostingController(rootView: AnyView(panel))

        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
    }

    func install() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyUpOrDown
        item.button?.toolTip = "DevDisk"
        item.button?.setAccessibilityLabel("DevDisk")
        updateIcon()

        // objectWillChange arrives before @Published has stored its new value. The
        // immediate update keeps the icon responsive, and the next main-loop turn
        // picks up the new screen/state for the actual image.
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            self?.updateIcon()
            DispatchQueue.main.async { [weak self] in self?.updateIcon() }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name = MenuBarIcon.name(
            for: store.screen,
            mounted: store.snapshot != nil,
            hasWarnings: (store.snapshot?.warningCount ?? 0) > 0)
        button.image = MenuBarIcon.image(named: name)
            ?? NSImage(systemSymbolName: MenuBarIcon.fallbackSymbol(
                for: store.screen,
                mounted: store.snapshot != nil,
                hasWarnings: (store.snapshot?.warningCount ?? 0) > 0),
                accessibilityDescription: "DevDisk")
        button.image?.size = NSSize(width: 16, height: 16)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        store.refresh()
        updates.checkIfDue()
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        popover.contentSize = NSSize(width: UI.width, height: max(1, fitting.height))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
