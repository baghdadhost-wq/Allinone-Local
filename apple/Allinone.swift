import SwiftUI

@main struct AllinoneApp: App {
    init() {
        // On-device GGUF models run through llama.cpp; routing stays independent of it.
        NativeAPI.local = { LocalEngine.shared.stream($0, system: $1, turns: $2) }
    }
    var body: some Scene { WindowGroup { OriginalHome() } }
}
