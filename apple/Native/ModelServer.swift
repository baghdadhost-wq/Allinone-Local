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
                Task.detached { await ServerCore.serve(connection, token: token) }
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

/// HTTP handling off the main thread.
enum ServerCore {
    struct Request { let method: String; let path: String; let headers: [String:String]; let body: Data }

    static func serve(_ connection: NWConnection, token: String) async {
        connection.start(queue: .global(qos: .userInitiated))
        defer { connection.cancel() }
        guard let request = try? await read(connection) else { return }
        let auth = request.headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 } ?? request.headers["x-api-key"]
        if request.method == "GET" && request.path == "/" { try? await respond(connection, 200, json: ["ok": true, "name": "Allinone-Local"]); return }
        guard auth == token else {
            try? await respond(connection, 401, json: ["type": "error", "error": ["type": "authentication_error", "message": "Invalid token"]])
            return
        }
        let model = await MainActor.run { ModelServer.shared.model }
        await MainActor.run { ModelServer.shared.countRequest() }
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/models"):
                let now = Int(Date().timeIntervalSince1970)
                try await respond(connection, 200, json: ["object": "list", "data": [["id": model, "object": "model", "created": now, "owned_by": "allinone-local",
                                                                                      "type": "model", "display_name": model] as [String:Any]]])
            case ("POST", "/v1/messages/count_tokens"):
                try await respond(connection, 200, json: ["input_tokens": max(1, request.body.count / 4)])
            case ("POST", "/v1/messages"):
                try await anthropic(connection, request.body, model: model)
            case ("POST", "/v1/chat/completions"):
                try await openAI(connection, request.body, model: model)
            default:
                try await respond(connection, 404, json: ["type": "error", "error": ["type": "not_found_error", "message": "Unknown endpoint " + request.path]])
            }
        } catch {
            try? await respond(connection, 500, json: ["type": "error", "error": ["type": "api_error", "message": error.localizedDescription]])
        }
    }

    // MARK: Anthropic Messages

    static func anthropic(_ connection: NWConnection, _ body: Data, model: String) async throws {
        guard let request = try JSONSerialization.jsonObject(with: body) as? [String:Any] else { throw LinkError.message("Invalid JSON") }
        var system = text(of: request["system"])
        if let tools = request["tools"] as? [[String:Any]], !tools.isEmpty { system += toolPrompt(tools) }
        var turns = [Turn]()
        for message in request["messages"] as? [[String:Any]] ?? [] {
            let role = message["role"] as? String == "assistant" ? "assistant" : "user"
            append(&turns, role, content(message["content"]))
        }
        let provider = Provider(name: "server", base: "local://" + model, model: model, style: .localModel, free: true)
        let stream = request["stream"] as? Bool ?? false
        let id = "msg_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))
        let generation = LocalEngine.shared.stream(provider, system: system, turns: turns)
        if !stream {
            var answer = ""
            for try await text in generation { answer = text }
            let (lead, calls) = toolCalls(answer)
            var blocks: [[String:Any]] = lead.isEmpty ? [] : [["type": "text", "text": lead]]
            blocks += calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] }
            if blocks.isEmpty { blocks = [["type": "text", "text": ""]] }
            try await respond(connection, 200, json: ["id": id, "type": "message", "role": "assistant", "model": model, "content": blocks,
                                                      "stop_reason": calls.isEmpty ? "end_turn" : "tool_use", "stop_sequence": NSNull(),
                                                      "usage": ["input_tokens": body.count / 4, "output_tokens": answer.count / 4]])
            return
        }
        try await send(connection, Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
        func event(_ name: String, _ payload: [String:Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await send(connection, Data("event: \(name)\ndata: ".utf8) + data + Data("\n\n".utf8))
        }
        try await event("message_start", ["type": "message_start", "message": ["id": id, "type": "message", "role": "assistant", "model": model, "content": [] as [Any],
                                                                               "stop_reason": NSNull(), "stop_sequence": NSNull(), "usage": ["input_tokens": body.count / 4, "output_tokens": 1]] as [String:Any]])
        try await event("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
        var sent = 0
        var answer = ""
        do {
            for try await text in generation {
                answer = text
                // Hold back a possible tool call; it is sent as a tool_use block at the end.
                var visible = text
                if let r = visible.range(of: "<tool_call") { visible = String(visible[..<r.lowerBound]) }
                else if visible.count > 11 { visible = String(visible.dropLast(11)) } else { visible = "" }
                if visible.count > sent {
                    let delta = String(visible.dropFirst(sent))
                    sent = visible.count
                    try await event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": delta]])
                }
            }
        } catch {
            try await event("error", ["type": "error", "error": ["type": "api_error", "message": error.localizedDescription]])
            return
        }
        let (lead, calls) = toolCalls(answer)
        if lead.count > sent {
            try await event("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": String(lead.dropFirst(sent))]])
        }
        try await event("content_block_stop", ["type": "content_block_stop", "index": 0])
        for (offset, call) in calls.enumerated() {
            let index = offset + 1
            try await event("content_block_start", ["type": "content_block_start", "index": index,
                                                    "content_block": ["type": "tool_use", "id": call.id, "name": call.name, "input": [String:Any]()] as [String:Any]])
            let input = String(decoding: try JSONSerialization.data(withJSONObject: call.input), as: UTF8.self)
            try await event("content_block_delta", ["type": "content_block_delta", "index": index, "delta": ["type": "input_json_delta", "partial_json": input]])
            try await event("content_block_stop", ["type": "content_block_stop", "index": index])
        }
        try await event("message_delta", ["type": "message_delta", "delta": ["stop_reason": calls.isEmpty ? "end_turn" : "tool_use", "stop_sequence": NSNull()] as [String:Any],
                                          "usage": ["output_tokens": max(1, answer.count / 4)]])
        try await event("message_stop", ["type": "message_stop"])
    }

    /// Tool definitions in the Hermes format that Qwen and many open models are trained on.
    static func toolPrompt(_ tools: [[String:Any]]) -> String {
        let lines = tools.compactMap { tool -> String? in
            guard let name = tool["name"] as? String else { return nil }
            let description = String((tool["description"] as? String ?? "").prefix(600))
            let parameters: Any = tool["input_schema"] ?? ["type": "object"]
            let function: [String:Any] = ["type": "function", "function": ["name": name, "description": description, "parameters": parameters] as [String:Any]]
            return (try? JSONSerialization.data(withJSONObject: function)).map { String(decoding: $0, as: UTF8.self) }
        }
        return """


        # Tools

        You may call one or more functions to assist with the user query.

        You are provided with function signatures within <tools></tools> XML tags:
        <tools>
        \(lines.joined(separator: "\n"))
        </tools>

        For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
        <tool_call>
        {"name": <function-name>, "arguments": <args-json-object>}
        </tool_call>
        """
    }

    struct ToolCall { let id: String; let name: String; let input: [String:Any] }
    /// Splits a reply into its text and the <tool_call> blocks it contains.
    static func toolCalls(_ text: String) -> (String, [ToolCall]) {
        var calls = [ToolCall]()
        var rest = text
        var lead = ""
        while let open = rest.range(of: "<tool_call>") {
            if calls.isEmpty { lead = String(rest[..<open.lowerBound]) }
            let after = rest[open.upperBound...]
            let close = after.range(of: "</tool_call>")
            let body = String(close.map { after[..<$0.lowerBound] } ?? after).trimmingCharacters(in: .whitespacesAndNewlines)
            if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String:Any], let name = object["name"] as? String {
                var input = object["arguments"] as? [String:Any] ?? object["input"] as? [String:Any] ?? [:]
                if input.isEmpty, let raw = object["arguments"] as? String,
                   let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String:Any] { input = decoded }
                calls.append(ToolCall(id: "toolu_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(22)), name: name, input: input))
            }
            guard let close else { break }
            rest = String(after[close.upperBound...])
        }
        return (calls.isEmpty ? text : lead.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }

    static func text(of value: Any?) -> String {
        if let s = value as? String { return s }
        return (value as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Flattens Anthropic/OpenAI content blocks (text, tool_use, tool_result, images) into text.
    static func content(_ value: Any?) -> String {
        if let s = value as? String { return s }
        return (value as? [[String:Any]] ?? []).map { block -> String in
            switch block["type"] as? String {
            case "text": return block["text"] as? String ?? ""
            case "tool_use":
                let call: [String:Any] = ["name": block["name"] as? String ?? "", "arguments": block["input"] ?? [String:Any]()]
                let json = (try? JSONSerialization.data(withJSONObject: call)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return "<tool_call>\n" + json + "\n</tool_call>"
            case "tool_result":
                let result = text(of: block["content"])
                return "<tool_response>\n" + String(result.prefix(12000)) + "\n</tool_response>"
            case "image", "image_url": return "[image omitted: the local model reads text only]"
            default: return ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Chat templates expect alternating roles: merge consecutive turns of the same role.
    static func append(_ turns: inout [Turn], _ role: String, _ text: String) {
        guard !text.isEmpty else { return }
        if let last = turns.last, last.role == role {
            turns[turns.count - 1] = Turn(role: role, content: last.content + "\n\n" + text)
        } else { turns.append(Turn(role: role, content: text)) }
    }

    // MARK: OpenAI chat completions

    static func openAI(_ connection: NWConnection, _ body: Data, model: String) async throws {
        guard let request = try JSONSerialization.jsonObject(with: body) as? [String:Any] else { throw LinkError.message("Invalid JSON") }
        var system = ""
        var turns = [Turn]()
        for message in request["messages"] as? [[String:Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            let text = content(message["content"])
            if role == "system" || role == "developer" { system += (system.isEmpty ? "" : "\n\n") + text }
            else { append(&turns, role == "assistant" ? "assistant" : "user", role == "tool" ? "<tool_response>\n" + text + "\n</tool_response>" : text) }
        }
        let provider = Provider(name: "server", base: "local://" + model, model: model, style: .localModel, free: true)
        let generation = LocalEngine.shared.stream(provider, system: system, turns: turns)
        let id = "chatcmpl-" + String(UUID().uuidString.prefix(12))
        let created = Int(Date().timeIntervalSince1970)
        guard request["stream"] as? Bool == true else {
            var answer = ""
            for try await text in generation { answer = text }
            try await respond(connection, 200, json: ["id": id, "object": "chat.completion", "created": created, "model": model,
                                                      "choices": [["index": 0, "message": ["role": "assistant", "content": answer], "finish_reason": "stop"] as [String:Any]],
                                                      "usage": ["prompt_tokens": body.count / 4, "completion_tokens": answer.count / 4, "total_tokens": (body.count + answer.count) / 4]])
            return
        }
        try await send(connection, Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
        func chunk(_ delta: [String:Any], _ finish: Any) async throws {
            let payload: [String:Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": model,
                                         "choices": [["index": 0, "delta": delta, "finish_reason": finish] as [String:Any]]]
            try await send(connection, Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: payload)) + Data("\n\n".utf8))
        }
        try await chunk(["role": "assistant", "content": ""], NSNull())
        var sent = 0
        do {
            for try await text in generation where text.count > sent {
                try await chunk(["content": String(text.dropFirst(sent))], NSNull())
                sent = text.count
            }
        } catch {
            try await send(connection, Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: ["error": ["message": error.localizedDescription]])) + Data("\n\n".utf8))
        }
        try await chunk([:], "stop")
        try await send(connection, Data("data: [DONE]\n\n".utf8))
    }

    // MARK: HTTP/1.1

    static func read(_ connection: NWConnection) async throws -> Request {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let chunk = try await receive(connection), !chunk.isEmpty else { throw LinkError.message("closed") }
            buffer.append(chunk)
            if buffer.count > 65536 { throw LinkError.message("headers too large") }
        }
        let split = buffer.range(of: separator)!
        let head = String(decoding: buffer[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (head.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { throw LinkError.message("bad request") }
        var headers = [String:String]()
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(buffer[split.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= 16 << 20 else { throw LinkError.message("body too large") }
        while body.count < length {
            guard let chunk = try await receive(connection), !chunk.isEmpty else { break }
            body.append(chunk)
        }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return Request(method: String(parts[0]), path: path, headers: headers, body: body)
    }

    static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if complete && (data?.isEmpty ?? true) { continuation.resume(returning: nil) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    static func respond(_ connection: NWConnection, _ status: Int, json: [String:Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: json)
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try await send(connection, Data(head.utf8) + body)
    }
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
