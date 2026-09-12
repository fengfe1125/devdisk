import SwiftUI

public struct DevDiskApp: App {
    @NSApplicationDelegateAdaptor(DevDiskAppDelegate.self)
    private var appDelegate

    public init() {
        PanelSetting.registerDefaults()
    }

    public var body: some Scene {
        // A Dock icon with nothing behind it would be dead weight — clicking it has to
        // open something. This window carries the same panel, resizable, so the body
        // is not squeezed into a popover-sized card.
        Window("DevDisk", id: DiskStore.mainWindowID) {
            PanelView(presentation: .window)
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.updates)
                .onAppear {
                    appDelegate.store.refresh()
                    appDelegate.updates.checkIfDue()
                }
        }
        // The window fits its content: each screen has a very different natural
        // height, and a fixed size left the short ones mostly empty.
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.updates)
        }
    }
}

@MainActor
final class DevDiskAppDelegate: NSObject, NSApplicationDelegate {
    let store: DiskStore
    let updates: UpdateChecker
    let statusBar: StatusBarController

    override init() {
        let store = DiskStore()
        let updates = UpdateChecker()
        self.store = store
        self.updates = updates
        self.statusBar = StatusBarController(store: store, updates: updates)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar.install()
    }
}
