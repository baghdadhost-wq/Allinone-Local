import Foundation
import Network
import SwiftUI

/// Serves the on-device model on the local network so Claude Code (or any
/// Anthropic/OpenAI client) on a computer can use it:
///   ANTHROPIC_BASE_URL=http://<iPad>:8745  ANTHROPIC_AUTH_TOKEN=<token>  claude
/// Endpoints: POST /v1/messages (with streaming and tool calls),
/// POST /v1/chat/completions, GET /v1/models, POST /v1/messages/count_tokens.
@MainActor final class ModelServer: ObservableObject {
    static let shared = ModelServer()
    static let port: UInt16 = 8745
    @Published private(set) var running = false
    @Published private(set) var state = ""
    @Published private(set) var served = 0
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "server.model") } }
    let token: String
    private var listener: NWListener?

    private init() {
        model = UserDefaults.standard.string(forKey: "server.model") ?? ""
        if let saved = UserDefaults.standard.string(forKey: "server.token") { token = saved }
        else {
            token = "allinone-" + (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            UserDefaults.standard.set(token, forKey: "server.token")
        }
    }

    func start() {
        guard listener == nil else { return }
        if model.isEmpty || !ModelStore.installed.contains(where: { $0.file == model }) { model = ModelStore.installed.first?.file ?? "" }
        guard !model.isEmpty else { state = "نزّل نموذجا محليا أولا"; return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let next = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener = next
            let token = token
            next.newConnectionHandler = { connection in
                Task.detached {
                    await ServerCore.serve(connection, token: token,
                                           model: { await MainActor.run { ModelServer.shared.model } },
                                           counted: { await MainActor.run { ModelServer.shared.countRequest() } })
                }
            }
            next.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    switch status {
                    case .ready: self.running = true; self.state = "يعمل"; UIApplication.shared.isIdleTimerDisabled = true
                    case .failed(let error): self.stop(); self.state = error.localizedDescription
                    case .waiting(let error): self.state = error.localizedDescription
                    default: break
                    }
                }
            }
            next.start(queue: .main)
        } catch { state = error.localizedDescription }
    }

    func stop() {
        listener?.cancel(); listener = nil
        running = false; state = "متوقف"
        if Downloads.shared.active.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
    }

    func countRequest() { served += 1 }

    var address: String { wifiAddress().map { "http://\($0):\(Self.port)" } ?? "http://<عنوان-الآيباد>:\(Self.port)" }
}

struct ModelServerPanel: View {
    @ObservedObject private var server = ModelServer.shared
    @ObservedObject private var library = ModelLibrary.shared
    @State private var copied = ""
    private var commands: String {
        """
        export ANTHROPIC_BASE_URL=\(server.address)
        export ANTHROPIC_AUTH_TOKEN=\(server.token)
        export ANTHROPIC_MODEL=\(server.model)
        export ANTHROPIC_SMALL_FAST_MODEL=\(server.model)
        export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
        claude
        """
    }
    var body: some View {
        Form {
            Section {
                Toggle("تشغيل الخادم على شبكة Wi-Fi", isOn: Binding(get: { server.running }, set: { $0 ? server.start() : server.stop() }))
                if !server.state.isEmpty { Text(server.state).font(.footnote) }
                Picker("النموذج", selection: $server.model) {
                    ForEach(library.installed, id: \.file) { Text($0.file).tag($0.file) }
                }
                LabeledContent("العنوان", value: server.address)
                LabeledContent("الطلبات", value: "\(server.served)")
            } footer: {
                Text("أبق التطبيق مفتوحا في المقدمة أثناء الاستخدام؛ iOS يوقف الشبكة للتطبيقات في الخلفية.")
            }
            Section("Claude Code على الحاسوب") {
                Text(commands).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button(copied == "cmd" ? "تم النسخ" : "نسخ الأوامر") { UIPasteboard.general.string = commands; copied = "cmd" }
                Text("يدعم الخادم /v1/messages مع البث واستدعاء الأدوات، و/v1/chat/completions لأدوات OpenAI. Claude Code يرسل تعليمات طويلة، فاختر نموذجا بسياق 32768 من «النماذج المحلية» (يناسب آيباد بذاكرة 8 GB أو أكثر). أول طلب أبطأ، ثم يعيد النموذج استخدام السياق المحفوظ.")
                    .font(.footnote)
            }
            Section("المفتاح") {
                Text(server.token).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button(copied == "token" ? "تم النسخ" : "نسخ المفتاح") { UIPasteboard.general.string = server.token; copied = "token" }
            }
        }
        .navigationTitle("خادم النماذج")
        .onAppear { library.reload() }
    }
}
