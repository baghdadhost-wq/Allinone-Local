import SwiftUI
import UniformTypeIdentifiers

/// A suggested model; the exact file is looked up in the Hugging Face repo at download time.
struct CatalogModel: Identifiable {
    let title: String
    let repo: String
    let quant: String
    let approx: Int64
    let note: String
    var id: String { repo }
    static let all: [CatalogModel] = [
        .init(title: "Qwen2.5 Coder 1.5B", repo: "bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF", quant: "Q4_K_M", approx: 1_000_000_000, note: "برمجة · سريع على كل الأجهزة"),
        .init(title: "Qwen2.5 Coder 3B", repo: "bartowski/Qwen2.5-Coder-3B-Instruct-GGUF", quant: "Q4_K_M", approx: 1_950_000_000, note: "برمجة · أفضل توازن للآيفون"),
        .init(title: "Qwen2.5 Coder 7B", repo: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF", quant: "Q4_K_M", approx: 4_700_000_000, note: "برمجة · يحتاج 8 GB أو زيادة الذاكرة"),
        .init(title: "Qwen2.5 Coder 14B", repo: "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF", quant: "Q4_K_M", approx: 9_000_000_000, note: "برمجة · آيباد بذاكرة 16 GB"),
        .init(title: "Qwen3 4B", repo: "Qwen/Qwen3-4B-GGUF", quant: "Q4_K_M", approx: 2_500_000_000, note: "عام وبرمجة · يدعم العربية جيدا"),
        .init(title: "Qwen3 8B", repo: "Qwen/Qwen3-8B-GGUF", quant: "Q4_K_M", approx: 5_000_000_000, note: "عام وبرمجة · يحتاج 8 GB أو أكثر"),
        .init(title: "Llama 3.2 3B", repo: "bartowski/Llama-3.2-3B-Instruct-GGUF", quant: "Q4_K_M", approx: 2_000_000_000, note: "عام · خفيف"),
        .init(title: "Gemma 3 4B", repo: "ggml-org/gemma-3-4b-it-GGUF", quant: "Q4_K_M", approx: 2_500_000_000, note: "عام · لغات متعددة"),
        .init(title: "Phi-4 mini", repo: "bartowski/microsoft_Phi-4-mini-instruct-GGUF", quant: "Q4_K_M", approx: 2_500_000_000, note: "منطق ورياضيات"),
        .init(title: "DeepSeek R1 Distill 7B", repo: "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF", quant: "Q4_K_M", approx: 4_700_000_000, note: "تفكير متسلسل · أبطأ في الرد"),
    ]
}

/// Minimal Hugging Face Hub client (public repos only, no account needed).
enum HuggingFace {
    struct Repo: Decodable, Identifiable { let id: String; let downloads: Int? }
    struct File: Identifiable, Hashable {
        let name: String
        let size: Int64
        let sha256: String?
        var id: String { name }
        var split: Bool { name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) != nil }
    }
    private struct Info: Decodable {
        struct Sibling: Decodable { struct LFS: Decodable { let sha256: String?; let size: Int64? }; let rfilename: String; let size: Int64?; let lfs: LFS? }
        let siblings: [Sibling]?
    }
    static func search(_ text: String) async throws -> [Repo] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [.init(name: "search", value: text), .init(name: "filter", value: "gguf"),
                        .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "40")]
        let (data, response) = try await URLSession.shared.data(from: c.url!)
        try check(response)
        return try JSONDecoder().decode([Repo].self, from: data)
    }
    static func files(_ repo: String) async throws -> [File] {
        guard let url = URL(string: "https://huggingface.co/api/models/" + repo + "?blobs=true") else { throw LinkError.message("اسم مستودع غير صالح") }
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response)
        let info = try JSONDecoder().decode(Info.self, from: data)
        return (info.siblings ?? []).filter { $0.rfilename.lowercased().hasSuffix(".gguf") && !$0.rfilename.lowercased().contains("mmproj") }
            .map { File(name: $0.rfilename, size: $0.lfs?.size ?? $0.size ?? 0, sha256: $0.lfs?.sha256) }
            .sorted { $0.size < $1.size }
    }
    static func downloadURL(_ repo: String, _ file: String) -> URL? {
        let path = file.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://huggingface.co/" + repo + "/resolve/main/" + path + "?download=true")
    }
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LinkError.message("تعذر الاتصال بـ Hugging Face (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
    }
}

@MainActor final class ModelLibrary: ObservableObject {
    static let shared = ModelLibrary()
    @Published private(set) var installed = ModelStore.installed
    @Published var message = ""
    func reload() { installed = ModelStore.installed }

    func download(repo: String, file: HuggingFace.File) {
        guard !file.split else { message = "الملفات المقسمة إلى أجزاء غير مدعومة بعد. اختر ملفا واحدا."; return }
        guard let url = HuggingFace.downloadURL(repo, file.name) else { return }
        let target = ModelStore.url(for: file.name)
        Downloads.shared.start(ModelStore.downloadID(repo, file.name), url: url, to: target, size: file.size > 0 ? file.size : nil,
                               sha256: file.sha256, magic: ModelStore.magic) { [weak self] in self?.reload() }
    }
    /// Looks up the suggested quantization in the repo, then downloads it.
    func download(_ model: CatalogModel) async {
        do {
            let files = try await HuggingFace.files(model.repo).filter { !$0.split }
            guard let file = files.first(where: { $0.name.localizedCaseInsensitiveContains(model.quant) }) ?? files.first else {
                throw LinkError.message("لم أجد ملف GGUF في " + model.repo)
            }
            download(repo: model.repo, file: file)
        } catch { message = error.localizedDescription }
    }
    func delete(_ file: String) {
        if EngineState.shared.loadedFile == file { LocalEngine.shared.unload() }
        try? FileManager.default.removeItem(at: ModelStore.url(for: file))
        reload()
    }
    /// Copies a GGUF picked from the Files app into the model folder.
    func importFile(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        message = "جار نسخ " + source.lastPathComponent + "…"
        let target = ModelStore.url(for: source.lastPathComponent)
        Task.detached {
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let handle = try FileHandle(forReadingFrom: source)
                let head = try handle.read(upToCount: 4); try handle.close()
                guard head == ModelStore.magic else { throw LinkError.message("الملف ليس بصيغة GGUF") }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
                await MainActor.run { self.message = "تم استيراد " + target.lastPathComponent; self.reload() }
            } catch { await MainActor.run { self.message = error.localizedDescription } }
        }
    }
    func use(_ file: String, studio: Studio) {
        let base = "local://" + file
        var provider = studio.providers.first { $0.base == base } ??
            Provider(name: "محلي: " + (file as NSString).deletingPathExtension, base: base, model: file, style: .localModel, free: true)
        provider.enabled = true
        do {
            if let index = studio.providers.firstIndex(where: { $0.id == provider.id }) { studio.providers.remove(at: index) }
            try studio.storeProvider(provider, key: "")
            message = "أصبح " + file + " أول مزود في قائمة التوجيه، ويظهر في قائمة البوابات بالشاشة الرئيسية."
        } catch { message = error.localizedDescription }
    }
}

private struct FitLabel: View {
    let bytes: Int64
    var body: some View {
        switch ModelStore.fit(bytes) {
        case .good: Label("يناسب جهازك", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .tight: Label("قريب من حد الذاكرة", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .tooBig: Label("أكبر من ذاكرة التطبيق", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
}

private struct DownloadRow: View {
    let id: String
    @ObservedObject var downloads = Downloads.shared
    var body: some View {
        if let job = downloads.active[id] {
            ProgressView(value: job.fraction) {
                Text(job.verifying ? "التحقق من الملف…" : "جار التنزيل")
            } currentValueLabel: {
                Text(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: job.total, countStyle: .file))
            }
            Button("إيقاف مؤقت") { downloads.pause(id) }
        }
        if let error = downloads.errors[id] { Text(error).font(.footnote).foregroundStyle(.red) }
    }
}

struct ModelLibraryPanel: View {
    @ObservedObject var studio: Studio
    @ObservedObject private var library = ModelLibrary.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var gateways = MobileGateways.shared
    @ObservedObject private var engine = EngineState.shared
    @State private var query = ""
    @State private var results: [HuggingFace.Repo] = []
    @State private var searching = false
    @State private var importing = false
    @State private var context = ModelStore.contextSetting
    var body: some View {
        Form {
            Section {
                LabeledContent("ذاكرة التطبيق", value: DeviceMemory.format(DeviceMemory.limit))
                if !engine.status.isEmpty {
                    LabeledContent("محمّل الآن", value: engine.status)
                    Button("تفريغ النموذج من الذاكرة") { LocalEngine.shared.unload() }
                }
                Picker("طول السياق", selection: $context) {
                    Text("تلقائي").tag(0)
                    ForEach([4096, 8192, 16384, 32768], id: \.self) { Text("\($0)").tag($0) }
                }.onChange(of: context) { value in ModelStore.contextSetting = value; LocalEngine.shared.unload() }
                Toggle("هذا المشروع لا يغادر الجهاز", isOn: $studio.localOnly)
                if gateways.desired.values.contains(true) {
                    Button("إيقاف البوابات لتوفير الذاكرة") { for name in ["omni", "free"] { gateways.set(name, enabled: false) } }
                }
            } footer: { Text("النموذج والمحادثات تبقى على الجهاز ولا تحتاج إنترنت بعد التنزيل. الملفات مستثناة من نسخ iCloud الاحتياطي. عند تفعيل «لا يغادر الجهاز» يرفض المشروع الحالي أي مزود سحابي أو بوابة.") }

            Section("على الجهاز") {
                if library.installed.isEmpty { Text("لا توجد نماذج بعد. نزّل واحدا من القائمة أو استورد ملف GGUF.") }
                ForEach(library.installed, id: \.file) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.file).font(.subheadline)
                        HStack { Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)); FitLabel(bytes: item.size) }.font(.caption)
                        HStack {
                            Button("استخدام في المحادثة") { library.use(item.file, studio: studio) }.buttonStyle(.borderless)
                            Spacer()
                            Button("حذف", role: .destructive) { library.delete(item.file) }.buttonStyle(.borderless)
                        }
                    }
                }
                Button("استيراد ملف GGUF من الملفات") { importing = true }
            }

            Section("نماذج مقترحة") {
                ForEach(CatalogModel.all) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(model.title).font(.headline); Spacer(); Text("~" + ByteCountFormatter.string(fromByteCount: model.approx, countStyle: .file)).font(.caption) }
                        Text(model.note).font(.caption)
                        FitLabel(bytes: model.approx).font(.caption)
                        let active = downloads.active.keys.contains { $0.hasPrefix(ModelStore.downloadID(model.repo, "")) }
                        if active || downloads.errors.keys.contains(where: { $0.hasPrefix(ModelStore.downloadID(model.repo, "")) }) {
                            ForEach(Array(downloads.active.keys.filter { $0.hasPrefix(ModelStore.downloadID(model.repo, "")) }) + Array(downloads.errors.keys.filter { $0.hasPrefix(ModelStore.downloadID(model.repo, "")) && downloads.active[$0] == nil }), id: \.self) { DownloadRow(id: $0) }
                        }
                        if !active {
                            HStack {
                                Button("تنزيل") { Task { await library.download(model) } }.buttonStyle(.borderless)
                                Spacer()
                                NavigationLink("كل الأحجام") { RepoFiles(repo: model.repo) }
                            }
                        }
                    }
                }
            }

            Section("بحث في Hugging Face") {
                HStack {
                    TextField("مثال: qwen coder", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { Task { await search() } }
                    Button("بحث") { Task { await search() } }.disabled(query.isEmpty || searching)
                }
                if searching { ProgressView() }
                ForEach(results) { repo in
                    NavigationLink { RepoFiles(repo: repo.id) } label: {
                        VStack(alignment: .leading) { Text(repo.id).font(.subheadline); Text("تنزيلات: \(repo.downloads ?? 0)").font(.caption) }
                    }
                }
            }
            if !library.message.isEmpty { Section { Text(library.message).font(.footnote).textSelection(.enabled) } }
        }
        .navigationTitle("النماذج المحلية")
        .onAppear { library.reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .data]) { result in
            if case .success(let url) = result { library.importFile(url) }
        }
    }
    private func search() async {
        searching = true; defer { searching = false }
        do { results = try await HuggingFace.search(query) } catch { library.message = error.localizedDescription }
    }
}

private struct RepoFiles: View {
    let repo: String
    @ObservedObject private var library = ModelLibrary.shared
    @ObservedObject private var downloads = Downloads.shared
    @State private var files: [HuggingFace.File] = []
    @State private var error = ""
    var body: some View {
        List {
            if files.isEmpty && error.isEmpty { ProgressView() }
            if !error.isEmpty { Text(error) }
            ForEach(files) { file in
                let id = ModelStore.downloadID(repo, file.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.subheadline)
                    HStack { Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)); FitLabel(bytes: file.size) }.font(.caption)
                    DownloadRow(id: id)
                    if library.installed.contains(where: { $0.file == (file.name as NSString).lastPathComponent }) {
                        Text("موجود على الجهاز").font(.caption)
                    } else if file.split {
                        Text("ملف مقسم إلى أجزاء (غير مدعوم بعد)").font(.caption)
                    } else if downloads.active[id] == nil {
                        Button("تنزيل") { library.download(repo: repo, file: file) }.buttonStyle(.borderless)
                    }
                }
            }
            if !library.message.isEmpty { Text(library.message).font(.footnote) }
        }
        .navigationTitle(repo.split(separator: "/").last.map(String.init) ?? repo)
        .task {
            do { files = try await HuggingFace.files(repo); if files.isEmpty { error = "لا توجد ملفات GGUF في هذا المستودع" } }
            catch { self.error = error.localizedDescription }
        }
    }
}
