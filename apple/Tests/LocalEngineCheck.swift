import Foundation
import Network

// Runs the real on-device engine (llama.cpp, macOS slice of the same release) with a
// tiny GGUF, and drives the Claude Code server end to end over loopback.
enum EngineCheckFailure: Error { case failed(String) }
func expect(_ value: Bool, _ message: String) throws {
    if !value { throw EngineCheckFailure.failed(message) }
    print("✓ " + message)
}

@main struct LocalEngineCheck {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: ModelStore.dir, withIntermediateDirectories: true)
        let file = ModelStore.url(for: source.lastPathComponent)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)
        let name = file.lastPathComponent
        let provider = Provider(name: "test", base: "local://" + name, model: name, style: .localModel, free: true)

        // Plain generation through the same stream the app uses.
        var story = ""
        for try await text in LocalEngine.shared.stream(provider, system: "You tell short stories.", turns: [Turn(role: "user", content: "Once upon a time")]) { story = text }
        print("story: " + String(story.prefix(120)))
        try expect(true, "plain generation ran")

        // Grammar: even a 15M story model must answer the coding agent with a valid action object.
        var reply = ""
        for try await text in LocalEngine.shared.stream(provider, system: CodingAgent.instruction, turns: [Turn(role: "user", content: "List the project files")]) { reply = text }
        print("agent reply: " + String(reply.prefix(200)))
        let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String:Any]
        try expect(["answer","list","read","search","edit","replace","run"].contains(object?["action"] as? String ?? ""), "GBNF forces a valid action JSON")

        // Second request with the same system prompt reuses the cached prefix (must not fail).
        for try await _ in LocalEngine.shared.stream(provider, system: CodingAgent.instruction, turns: [Turn(role: "user", content: "Read main.swift")]) {}
        try expect(true, "prompt cache reuse")

        let speed = try await LocalEngine.shared.benchmark(file)
        print(String(format: "speed: prompt %.0f t/s, generation %.0f t/s", speed.prompt, speed.generation))
        try expect(speed.prompt > 0 && speed.generation > 0, "benchmark")

        LocalEngine.shared.persist()
        try expect(true, "context saved to disk")

        // Tool-call parsing used for Claude Code.
        let (lead, calls) = ServerCore.toolCalls("Let me read it.\n<tool_call>\n{\"name\": \"Read\", \"arguments\": {\"file_path\": \"/a.txt\"}}\n</tool_call>")
        try expect(lead == "Let me read it." && calls.first?.name == "Read" && calls.first?.input["file_path"] as? String == "/a.txt", "tool_call parsing")
        let flattened = ServerCore.content([["type": "tool_result", "tool_use_id": "x", "content": [["type": "text", "text": "file body"]]]])
        try expect(flattened.contains("<tool_response>") && flattened.contains("file body"), "tool_result flattening")

        // Server over loopback, the way Claude Code talks to it.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            Task.detached { await ServerCore.serve(connection, token: "secret", model: { name }) }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var done = false
            listener.stateUpdateHandler = { state in
                guard !done else { return }
                switch state {
                case .ready: done = true; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let base = "http://127.0.0.1:\(port)"
        func call(_ path: String, token: String = "secret", body: [String:Any]? = nil) async throws -> (Int, String) {
            var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 300)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
        }
        let (denied, _) = try await call("/v1/models", token: "wrong")
        try expect(denied == 401, "wrong token is rejected")
        let (listed, models) = try await call("/v1/models")
        try expect(listed == 200 && models.contains(name), "model list")
        let tools: [[String:Any]] = [["name": "Read", "description": "Read a file",
                                      "input_schema": ["type": "object", "properties": ["file_path": ["type": "string"]], "required": ["file_path"]] as [String:Any]]]
        let message: [String:Any] = ["model": "claude-sonnet", "max_tokens": 256, "stream": true, "system": [["type": "text", "text": "You are a helpful assistant."]],
                                     "tools": tools, "messages": [["role": "user", "content": [["type": "text", "text": "Hello"]]]]]
        let (status, events) = try await call("/v1/messages?beta=true", body: message)
        print(String(events.prefix(600)))
        try expect(status == 200 && events.contains("event: message_start") && events.contains("event: content_block_start")
                   && events.contains("event: message_delta") && events.contains("event: message_stop"), "Anthropic streaming events")
        var plain = message; plain["stream"] = false
        let (okPlain, json) = try await call("/v1/messages", body: plain)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String:Any]
        try expect(okPlain == 200 && decoded?["type"] as? String == "message" && decoded?["content"] is [Any], "Anthropic message JSON")
        let (okChat, chat) = try await call("/v1/chat/completions", body: ["model": name, "stream": true, "messages": [["role": "user", "content": "Hi"]]])
        try expect(okChat == 200 && chat.contains("chat.completion.chunk") && chat.contains("[DONE]"), "OpenAI streaming")
        listener.cancel()
        print("All engine and server checks passed.")
    }
}
