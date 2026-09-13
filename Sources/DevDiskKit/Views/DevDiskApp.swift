import SwiftUI

public struct DevDiskApp: App {
    @ObservedObject private var language = LanguageStore.shared
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
        .commands {
            CommandGroup(after: .windowArrangement) {
                if Bundle.main.object(forInfoDictionaryKey: "DevDiskDemoScenario") != nil {
                    Button(L("devdiskapp.demo.open.menu.bar.panel")) { appDelegate.statusBar.showPanel() }
                }
            }
        }

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
        let demo = Bundle.main.object(forInfoDictionaryKey: "DevDiskDemoScenario") as? String
        let store = demo.map { DemoFixture.makeStore(scenario: $0) } ?? DiskStore()
        let updateDefaults = demo == nil ? UserDefaults.standard : UserDefaults(suiteName: "devdisk.demo.updates")!
        if demo != nil { updateDefaults.set(false, forKey: "updateCheckEnabled") }
        let updates = UpdateChecker(defaults: updateDefaults)
        self.store = store
        self.updates = updates
        self.statusBar = StatusBarController(store: store, updates: updates)
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.operation.locksTarget else { return .terminateNow }
        // A menu/keyboard quit must not bypass the operation lock. Before commit,
        // stop subsequent work first; after commit, wait for the system result.
        store.cancelEject()
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = Bundle.main.object(forInfoDictionaryKey: "DevDiskDemoAppearance") as? String {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        statusBar.install()
    }
}
