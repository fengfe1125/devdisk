import Foundation
import Combine

/// Stored values are independent of the language used to label the picker.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    static func resolve(_ value: String?, preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        let selected = value.flatMap(Self.init(rawValue:)) ?? .system
        guard selected == .system else { return selected }
        return preferred.first?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first == "zh" ? .chinese : .english
    }
    var locale: Locale { Locale(identifier: self == .chinese ? "zh_CN" : "en_US") }
}

final class LanguageStore: ObservableObject {
    static let key = "app.language"
    static let shared = LanguageStore()
    private let defaults: UserDefaults
    private let preferred: () -> [String]
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var selection: AppLanguage
    @Published private(set) var resolved: AppLanguage

    init(defaults: UserDefaults = .standard, preferred: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferred = preferred
        selection = defaults.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
        resolved = AppLanguage.resolve(defaults.string(forKey: Self.key), preferred: preferred())
        for name in [UserDefaults.didChangeNotification, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func select(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
        reload()
    }
    private func reload() {
        let next = defaults.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
        let effective = AppLanguage.resolve(next.rawValue, preferred: preferred())
        if selection != next { selection = next }
        if resolved != effective { resolved = effective }
    }
}

/// A value captured by a probe is never translated until it is displayed.
/// Raw arguments are not searched or replaced: paths and command output stay intact.
indirect enum Message: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    case raw(String)
    case number(Double, decimals: Int?)
    case key(String, [Message])
    case joined([Message], separator: Message)

    init(stringLiteral value: String) { self = .raw(value) }
    init(stringInterpolation: StringInterpolation) { self = .joined(stringInterpolation.parts, separator: .raw("")) }
    struct StringInterpolation: StringInterpolationProtocol {
        var parts: [Message] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { parts.append(.raw(literal)) }
        mutating func appendInterpolation<T: MessageArgument>(_ value: T) { parts.append(value.message) }
    }
    func render(_ language: AppLanguage) -> String {
        switch self {
        case .raw(let text): return text
        case .number(let value, let decimals):
            let formatter = NumberFormatter()
            formatter.locale = language.locale
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = decimals ?? 0
            formatter.maximumFractionDigits = decimals ?? 3
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        case .joined(let messages, let separator):
            return messages.map { $0.render(language) }.joined(separator: separator.render(language))
        case .key(let key, let arguments):
            var template = Localization.table(language)[key] ?? Localization.table(.english)[key] ?? key
            if language == .english, arguments.first == .number(1, decimals: nil),
               let singular = Localization.table(language)[key + ".one"] { template = singular }
            // Parse placeholders in the template once, never in substituted user data.
            let regex = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
            let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
            for match in matches.reversed() {
                guard let indexRange = Range(match.range(at: 1), in: template),
                      let index = Int(template[indexRange]), arguments.indices.contains(index),
                      let range = Range(match.range, in: template) else { continue }
                template.replaceSubrange(range, with: arguments[index].render(language))
            }
            return template
        }
    }
    var text: String { render(AppLanguage.resolve(UserDefaults.standard.string(forKey: LanguageStore.key))) }
}

protocol MessageArgument { var message: Message { get } }
extension Message: MessageArgument { var message: Message { self } }
extension String: MessageArgument { var message: Message { .raw(self) } }
extension Int: MessageArgument { var message: Message { .number(Double(self), decimals: nil) } }
extension Int32: MessageArgument { var message: Message { .number(Double(self), decimals: nil) } }
extension Double: MessageArgument { var message: Message { .number(self, decimals: nil) } }
func M(_ key: String, _ arguments: any MessageArgument...) -> Message { .key(key, arguments.map(\.message)) }
func L(_ key: String, _ arguments: any MessageArgument...) -> String { Message.key(key, arguments.map(\.message)).text }
func + (lhs: Message, rhs: Message) -> Message { .joined([lhs, rhs], separator: "") }
func + (lhs: Message, rhs: String) -> Message { lhs + .raw(rhs) }
func + (lhs: String, rhs: Message) -> Message { .raw(lhs) + rhs }
extension Array where Element == Message {
    func joined(separator: Message) -> Message { .joined(self, separator: separator) }
}
extension Error {
    var displayMessage: Message { (self as? ProbeFailure)?.message ?? (self as? CommandError)?.message
        ?? (self as? HealthProbe.Unavailable)?.message ?? .raw(localizedDescription) }
}

enum Localization {
    // A packaged app reads its own resources; it must not fall back to the build machine.
    static func resourceURL(_ language: AppLanguage) -> URL? {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appendingPathComponent(language.rawValue + ".lproj/Localizable.strings")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func table(_ language: AppLanguage) -> [String: String] { language == .chinese ? chinese : english }
    private static let chinese = load(.chinese)
    private static let english = load(.english)
    private static func load(_ language: AppLanguage) -> [String: String] {
        guard let url = resourceURL(language), let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return value
    }
}
