import SwiftUI

struct LanguagePicker: View {
    @ObservedObject private var language = LanguageStore.shared
    var body: some View {
        Picker(L("language.title"), selection: Binding(get: { language.selection }, set: { language.select($0) })) {
            Text(L("language.system")).tag(AppLanguage.system)
            Text(verbatim: "简体中文").tag(AppLanguage.chinese)
            Text(verbatim: "English").tag(AppLanguage.english)
        }
        .accessibilityIdentifier("languagePicker")
    }
}

extension Text {
    init(_ message: Message) { self.init(verbatim: message.text) }
}
