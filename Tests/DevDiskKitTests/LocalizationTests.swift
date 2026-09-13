import XCTest
@testable import DevDiskKit

final class LocalizationTests: XCTestCase {
    func testLanguageResolution() {
        XCTAssertEqual(AppLanguage.resolve(nil, preferred: ["zh-Hant-TW", "en"]), .chinese)
        XCTAssertEqual(AppLanguage.resolve("system", preferred: ["en", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.resolve(nil, preferred: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(nil, preferred: []), .english)
        XCTAssertEqual(AppLanguage.resolve("invalid", preferred: ["zh-CN"]), .chinese)
        XCTAssertEqual(AppLanguage.resolve("en", preferred: ["zh-CN"]), .english)
        XCTAssertEqual(AppLanguage.resolve("zh-Hans", preferred: ["en"]), .chinese)
    }

    func testSelectionPersistsAndDoesNotOverwriteOtherPreferences() {
        let suite = "devdisk.language.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/Volumes/相机  ", forKey: "targetMountPoint")
        let language = LanguageStore(defaults: defaults, preferred: { ["zh-CN"] })
        XCTAssertEqual(language.selection, .system)
        XCTAssertEqual(language.resolved, .chinese)
        language.select(.english)
        XCTAssertEqual(language.resolved, .english)
        let restarted = LanguageStore(defaults: defaults, preferred: { ["zh-CN"] })
        XCTAssertEqual(restarted.selection, .english)
        XCTAssertEqual(restarted.resolved, .english)
        restarted.select(.system)
        XCTAssertEqual(restarted.resolved, .chinese)
        XCTAssertEqual(defaults.string(forKey: "targetMountPoint"), "/Volumes/相机  ")
    }

    func testBothResourcesHaveMatchingKeysAndPlaceholders() throws {
        let english = Localization.table(.english), chinese = Localization.table(.chinese)
        XCTAssertGreaterThan(english.count, 290)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let pattern = try NSRegularExpression(pattern: #"\{\d+\}|%\.[01]f"#)
        func placeholders(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }.sorted()
        }
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(placeholders(value), placeholders(chinese[key] ?? ""), key)
        }
    }

    func testRawArgumentsAreNotTranslatedOrTreatedAsPlaceholders() {
        let path = "/Volumes/设置 {1} $HOME/文件  "
        let message = M("ejectflow.blocked.by.pid", path, "12167")
        XCTAssertEqual(message.render(.english), "Blocked by \(path) (PID 12167)")
        XCTAssertEqual(message.render(.chinese), "被 \(path)（PID 12167）阻塞")
        XCTAssertEqual(Message.raw(path).render(.english), path)
    }

    func testPluralAndNumericFormatting() {
        XCTAssertEqual(M("scanview.files", 1).render(.english), "1 file")
        XCTAssertEqual(M("scanview.files", 0).render(.english), "0 files")
        XCTAssertEqual(M("scanview.files", 2).render(.english), "2 files")
        XCTAssertEqual(M("scanview.files", 1200).render(.english), "1,200 files")
        XCTAssertEqual(M("scanview.files", 1).render(.chinese), "1 个文件")
        XCTAssertEqual(Message.number(6.2, decimals: 1).render(.english), "6.2")
    }

    func testCapturedErrorsAndSummariesCanRenderAgainWithoutReprobing() {
        let error = ProbeFailure(M("ejectflow.operation.cancelled"))
        let captured = ProbeResult<Int>.capture { throw error }
        let message = captured.issues.joined(separator: M("issue.separator"))
        XCTAssertEqual(message.render(.english), "Operation cancelled")
        XCTAssertEqual(message.render(.chinese), "操作已中止")
        XCTAssertEqual(captured.state, .unavailable)
        let summary = DiskStore.summary(6.2, apps: 1, daemons: 2)
        XCTAssertTrue(summary.render(.english).contains("Apps confirmed quit: 1"))
        XCTAssertTrue(summary.render(.chinese).contains("确认退出 1 个应用"))
        let command = CommandError.notFound("/工具/{0}").displayMessage
        XCTAssertEqual(command.render(.english), "Executable not found: /工具/{0}")
        XCTAssertTrue(command.render(.chinese).hasPrefix("找不到可执行文件"))
        XCTAssertTrue(HealthProbe.Unavailable.notInstalled.displayMessage.render(.english).contains("not installed"))
    }

    func testFlowMessagesDoNotChangeStateOrIssueCommandsWhenTranslated() throws {
        let h = FlowHarness()
        h.add(app: "devdisk.editor")
        h.processes.refuseQuit = true
        let flow = h.flow
        let plan = try flow.prepare()
        let outcome = flow.execute(plan, systemOnly: false)
        guard case .aborted(let message) = outcome else { return XCTFail("Expected blocked quit") }
        let calls = h.calls
        for language in [AppLanguage.english, .chinese, .english] {
            XCTAssertFalse(message.render(language).isEmpty)
            for step in flow.steps {
                XCTAssertFalse(step.title.render(language).isEmpty)
                _ = step.detail?.render(language)
            }
        }
        XCTAssertEqual(h.calls, calls)
        XCTAssertFalse(h.targetInspector.gone)
        XCTAssertTrue(message.render(.english).contains("still running"))
        XCTAssertTrue(message.render(.chinese).contains("仍在运行"))
    }

    func testGeneratedProcessLabelDoesNotChangeProcessIdentity() throws {
        let h = FlowHarness()
        h.add(executable: "/usr/bin/qemu-system-aarch64", args: "qemu-system-aarch64 /Volumes/ReviewDisk/image")
        let plan = try h.flow.prepare()
        let holder = try XCTUnwrap(plan.manual.first)
        let identity = holder.identity, id = holder.id
        XCTAssertEqual(holder.displayLabel?.render(.english), "Android Emulator")
        XCTAssertEqual(holder.displayLabel?.render(.chinese), "Android 模拟器")
        XCTAssertEqual(holder.identity, identity)
        XCTAssertEqual(holder.id, id)
        XCTAssertTrue(h.processes.quits.isEmpty)
    }

    @MainActor
    func testSwitchingLanguagePreservesStoreState() {
        let suite = "devdisk.language.store." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let h = FlowHarness()
        let store = DiskStore(runner: h, defaults: defaults, start: false)
        let languages = LanguageStore(defaults: defaults)
        store.ejectFailure = M("ejectflow.eject.result.unknown.disk.not.verified.offline.do")
        store.ejectSteps = [.init(id: "verify", title: M("ejectflow.verify.eject.result"), state: .running)]
        let original = store.ejectFailure, steps = store.ejectSteps, operation = store.operation
        for language in [AppLanguage.chinese, .english, .system] { languages.select(language) }
        XCTAssertEqual(store.ejectFailure, original)
        XCTAssertEqual(store.ejectSteps, steps)
        XCTAssertEqual(store.operation, operation)
        XCTAssertTrue(h.calls.isEmpty)
    }
}
