import Foundation
import UIKit
import llama

/// What the engine has loaded, for the settings screen.
@MainActor final class EngineState: ObservableObject {
    static let shared = EngineState()
    @Published var status = ""
    @Published var loadedFile = ""
}

/// Runs GGUF models on the device with llama.cpp (Metal). One model stays loaded;
/// the prompt cache is reused between turns so only new text is processed.
final class LocalEngine {
    static let shared = LocalEngine()
    private let queue = DispatchQueue(label: "app.allinone.local-llm", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedPath = ""
    private var cached: [llama_token] = []
    private var cancelled = false
    private(set) var contextSize = 0

    private init() {
        llama_backend_init()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            // iOS is about to terminate memory-heavy apps: give the model back if it is idle.
            self?.queue.async { self?.unloadLocked() }
        }
    }

    /// Registered as NativeAPI.local at launch.
    func stream(_ provider: Provider, system: String, turns: [Turn]) -> AsyncThrowingStream<String,Error> {
        AsyncThrowingStream { continuation in
            let file = ModelStore.url(for: provider.model)
            cancelled = false
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancelled = true }
            }
            queue.async {
                do {
                    let grammar = system.hasPrefix(CodingAgent.instruction) ? Self.actionGrammar : nil
                    try self.generate(file: file, system: system, turns: turns, grammar: grammar) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    func unload() { queue.async { self.unloadLocked() } }

    // MARK: - Engine (runs on `queue` only)

    private func unloadLocked() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; loadedPath = ""; cached = []; contextSize = 0
        Task { @MainActor in EngineState.shared.status = ""; EngineState.shared.loadedFile = "" }
    }

    private func load(_ file: URL) throws {
        if loadedPath == file.path, ctx != nil { return }
        unloadLocked()
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LinkError.message("ملف النموذج غير موجود. نزّله من «النماذج المحلية».")
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let free = DeviceMemory.available
        guard size + 300_000_000 < free else {
            throw LinkError.message("الذاكرة المتاحة (\(DeviceMemory.format(free))) لا تكفي لهذا النموذج (\(DeviceMemory.format(size))). أوقف البوابات أو اختر نموذجا أصغر، أو فعّل زيادة الذاكرة.")
        }
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 999
        #endif
        guard let loaded = llama_model_load_from_file(file.path, modelParams) else {
            throw LinkError.message("تعذر تحميل النموذج. قد يكون الملف تالفا أو بصيغة لا يدعمها المحرك.")
        }
        model = loaded
        vocab = llama_model_get_vocab(loaded)
        let wanted = ModelStore.contextSetting > 0 ? ModelStore.contextSetting : Self.autoContext(modelBytes: size)
        let train = Int(llama_model_n_ctx_train(loaded))
        let nCtx = UInt32(max(2048, min(wanted, train > 0 ? train : wanted)))
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var params = llama_context_default_params()
        params.n_ctx = nCtx
        params.n_batch = 512
        params.n_ubatch = 512
        params.n_threads = threads
        params.n_threads_batch = threads
        // An 8-bit KV cache doubles the usable context for the same memory.
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        params.type_k = GGML_TYPE_Q8_0
        params.type_v = GGML_TYPE_Q8_0
        var context = llama_init_from_model(loaded, params)
        if context == nil {
            params = llama_context_default_params()
            params.n_ctx = nCtx; params.n_batch = 512; params.n_ubatch = 512
            params.n_threads = threads; params.n_threads_batch = threads
            context = llama_init_from_model(loaded, params)
        }
        guard let context else {
            unloadLocked()
            throw LinkError.message("تعذر تجهيز سياق النموذج. اختر طول سياق أقصر من إعدادات النماذج المحلية.")
        }
        ctx = context
        loadedPath = file.path
        contextSize = Int(llama_n_ctx(context))
        let name = file.deletingPathExtension().lastPathComponent
        let n = contextSize
        let loadedFile = file.lastPathComponent
        Task { @MainActor in EngineState.shared.status = name + " · سياق \(n)"; EngineState.shared.loadedFile = loadedFile }
    }

    static func autoContext(modelBytes: UInt64) -> Int {
        let spare = Int64(DeviceMemory.available) - Int64(modelBytes)
        if spare > 4_000_000_000 { return 32768 }
        if spare > 2_000_000_000 { return 16384 }
        if spare > 1_000_000_000 { return 8192 }
        return 4096
    }

    private func generate(file: URL, system: String, turns: [Turn], grammar: String?, emit: (String) -> Void) throws {
        if ProcessInfo.processInfo.thermalState == .critical {
            throw LinkError.message("الجهاز ساخن جدا. انتظر قليلا قبل تشغيل النموذج المحلي.")
        }
        try load(file)
        guard let ctx, let vocab, let model else { throw LinkError.message("النموذج غير محمّل") }
        // Drop the oldest turns until the prompt leaves room for the answer.
        var history = turns
        var tokens = tokenize(format(model: model, system: system, turns: history))
        let reserve = min(8192, max(1024, contextSize / 3))
        while tokens.count > contextSize - reserve, history.count > 1 {
            history.removeFirst()
            tokens = tokenize(format(model: model, system: system, turns: history))
        }
        guard tokens.count < contextSize - 256 else {
            throw LinkError.message("الطلب أطول من سياق النموذج (\(contextSize) رمز). قسّم المهمة أو زد طول السياق.")
        }
        // Reuse what is already in the KV cache (system prompt, earlier turns).
        var prefix = zip(cached, tokens).prefix { $0 == $1 }.count
        if prefix == tokens.count { prefix -= 1 }
        let memory = llama_get_memory(ctx)
        if !llama_memory_seq_rm(memory, 0, Int32(prefix), -1) {
            llama_memory_clear(memory, true)
            prefix = 0
        }
        cached = Array(tokens.prefix(prefix))
        let batchSize = Int(llama_n_batch(ctx))
        var index = prefix
        while index < tokens.count {
            if cancelled { throw CancellationError() }
            let end = min(index + batchSize, tokens.count)
            var slice = Array(tokens[index..<end])
            let rc = slice.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard rc == 0 else { llama_memory_clear(memory, true); cached = []; throw LinkError.message("تعذرت معالجة الطلب في النموذج (\(rc))") }
            cached.append(contentsOf: slice)
            index = end
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        if let grammar, let rule = llama_sampler_init_grammar(vocab, grammar, "root") {
            llama_sampler_chain_add(sampler, rule)
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(grammar == nil ? 0.6 : 0.2))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        var bytes = [UInt8]()
        var piece = [CChar](repeating: 0, count: 256)
        let limit = contextSize - tokens.count - 8
        for step in 0..<limit {
            if cancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n < 0 { piece = [CChar](repeating: 0, count: Int(-n)); n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false) }
            if n > 0 { bytes.append(contentsOf: piece[0..<Int(n)].map { UInt8(bitPattern: $0) }) }
            // Emit only complete UTF-8 text (Arabic letters span several tokens' bytes).
            if step % 3 == 0, let text = String(bytes: bytes, encoding: .utf8) { emit(text) }
            let rc = llama_decode(ctx, llama_batch_get_one(&token, 1))
            guard rc == 0 else { break }
            cached.append(token)
        }
        emit(String(decoding: bytes, as: UTF8.self))
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 16)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }

    /// Formats the conversation with the model's own chat template (falls back to ChatML).
    private func format(model: OpaquePointer, system: String, turns: [Turn]) -> String {
        let messages = [("system", system)] + turns.map { ($0.role == "assistant" ? "assistant" : "user", $0.content) }
        let roles = messages.map { strdup($0.0) }
        let contents = messages.map { strdup($0.1) }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0!), content: UnsafePointer($1!)) }
        let total = messages.reduce(0) { $0 + $1.1.utf8.count } * 2 + 4096
        let count = chat.count
        func apply(_ template: UnsafePointer<CChar>) -> String? {
            var buffer = [CChar](repeating: 0, count: total)
            var length = Int32(buffer.count)
            var n = llama_chat_apply_template(template, &chat, count, true, &buffer, length)
            if n > length {
                buffer = [CChar](repeating: 0, count: Int(n) + 1)
                length = Int32(buffer.count)
                n = llama_chat_apply_template(template, &chat, count, true, &buffer, length)
            }
            guard n > 0 else { return nil }
            return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if let template = llama_model_chat_template(model, nil), let text = apply(template) { return text }
        if let text = "chatml".withCString({ apply($0) }) { return text }
        return messages.map { "<|im_start|>\($0.0)\n\($0.1)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
    }

    /// Forces the coding agent's reply to be one valid action object. Small models
    /// fail at the format far more often than at the task itself.
    static let actionGrammar = #"""
    root   ::= "{" ws "\"action\"" ws ":" ws action ( ws "," ws field )* ws "}"
    action ::= "\"answer\"" | "\"list\"" | "\"read\"" | "\"search\"" | "\"edit\""
    field  ::= ( "\"path\"" | "\"text\"" | "\"reason\"" ) ws ":" ws string
    string ::= "\"" char* "\""
    char   ::= [^"\\\x7F\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F]{4} )
    ws     ::= [ \t\n]{0,8}
    """#
}
