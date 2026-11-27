import AppIntents

/// "اسأل Allinone" in Siri and the Shortcuts app: sends a question to the first
/// provider in the routing list (an on-device model works offline) and returns the answer.
@available(iOS 16, *)
struct AskAllinone: AppIntent {
    static var title: LocalizedStringResource = "اسأل Allinone"
    static var description = IntentDescription("يرسل سؤالا إلى المزود الأول في قائمة التوجيه، مثل النموذج المحلي، ويعيد الجواب.")
    @Parameter(title: "السؤال") var question: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        if NativeAPI.local == nil { NativeAPI.local = { LocalEngine.shared.stream($0, system: $1, turns: $2) } }
        let studio = Studio()
        let answer = try await studio.send(question, thread: "siri", assistantMode: .quick)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

@available(iOS 16, *)
struct AllinoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAllinone(), phrases: ["اسأل \(.applicationName)", "Ask \(.applicationName)"])
    }
}
