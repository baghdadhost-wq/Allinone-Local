import SwiftUI
import WebKit

/// Archives pinned at build time (apple/Vendor/gateways.json, made by prepare.sh).
struct GatewayManifest: Decodable {
    struct Asset: Decodable { let file: String; let size: Int64; let sha256: String; let version: String; let revision: String }
    let tag: String
    let base: String
    let assets: [String:Asset]
    static let bundled: GatewayManifest? = Bundle.main.url(forResource:"gateways",withExtension:"json")
        .flatMap { try? Data(contentsOf:$0) }.flatMap { try? JSONDecoder().decode(GatewayManifest.self,from:$0) }
}

@MainActor final class MobileGateways: ObservableObject {
    static let shared = MobileGateways()
    let dir = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MobileGateways")
    @Published private(set) var desired = [String:Bool]()
    @Published private(set) var state = [String:String]()
    @Published var problem = ""
    private var timer: Timer?
    let manifest = GatewayManifest.bundled
    private init() {
        Downloads.excludeFromBackup(dir)
        // Restore the last choice so gateways that were on keep running after a relaunch.
        if let data = try? Data(contentsOf:dir.appendingPathComponent("desired.json")),
           let saved = try? JSONDecoder().decode([String:Bool].self,from:data) {
            desired = saved
            if saved.values.contains(true) {
                do { try startSupervisor() } catch { problem = error.localizedDescription }
                for (name,on) in saved where on { download(name) }
            }
        }
    }
    static func downloadID(_ name: String) -> String { "gateway-" + name }
    func installed(_ name: String) -> Bool {
        guard let asset = manifest?.assets[name] else { return false }
        return FileManager.default.fileExists(atPath:dir.appendingPathComponent(asset.revision).appendingPathComponent(".ready").path)
    }
    private func archive(_ name: String) -> URL? {
        manifest?.assets[name].map { dir.appendingPathComponent("downloads").appendingPathComponent($0.file) }
    }
    func downloaded(_ name: String) -> Bool { archive(name).map { FileManager.default.fileExists(atPath:$0.path) } ?? false }
    /// True while the gateway still needs its files (downloading or unpacking).
    func preparing(_ name: String) -> Bool {
        !installed(name) || ["missing","installing"].contains(state[name] ?? "")
    }
    /// Fetches the gateway archive from the GitHub release if it is not on the device yet.
    func download(_ name: String) {
        guard let manifest, let asset = manifest.assets[name], let target = archive(name),
              !installed(name), !downloaded(name), let url = URL(string:manifest.base + asset.file) else { return }
        Downloads.shared.start(Self.downloadID(name),url:url,to:target,size:asset.size,sha256:asset.sha256)
    }
    /// Deletes the unpacked gateway to free space. Accounts and keys are kept.
    func remove(_ name: String) {
        set(name,enabled:false)
        Downloads.shared.pause(Self.downloadID(name))
        guard let asset = manifest?.assets[name] else { return }
        DispatchQueue.main.asyncAfter(deadline:.now() + 1.5) { [dir] in
            try? FileManager.default.removeItem(at:dir.appendingPathComponent(asset.revision))
            try? FileManager.default.removeItem(at:dir.appendingPathComponent("downloads").appendingPathComponent(asset.file))
            self.objectWillChange.send()
        }
    }
    func size(_ name: String) -> String {
        ByteCountFormatter.string(fromByteCount:manifest?.assets[name]?.size ?? 0,countStyle:.file)
    }
    private func startSupervisor() throws {
        guard timer == nil else { return }
        let bundle = Bundle.main.bundleURL
        guard manifest != nil else { throw LinkError.message("قائمة ملفات البوابتين مفقودة من التطبيق") }
        try FileManager.default.createDirectory(at:dir.appendingPathComponent("downloads"),withIntermediateDirectories:true)
        try? FileManager.default.removeItem(at:dir.appendingPathComponent("state.json"))
        EmbeddedNode.start(bundle.appendingPathComponent("supervisor.cjs").path,state:dir.path,bundle:bundle.path)
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func set(_ name: String, enabled: Bool) {
        do {
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            var next = desired
            next[name] = enabled
            try JSONEncoder().encode(next).write(to:dir.appendingPathComponent("desired.json"),options:.atomic)
            try startSupervisor()
            desired = next
            problem = ""
            if enabled { download(name) }
        } catch { problem = error.localizedDescription }
    }
    /// Ask the supervisor to restart a stopped or crashed gateway now (also retries unpacking).
    func restart(_ name: String) {
        let name = name == "install" ? (["omni","free"].first { failure($0) != nil } ?? name) : name
        if desired[name] != true { set(name,enabled:true); return }
        Downloads.shared.clearError(Self.downloadID(name))
        download(name)
        try? Data().write(to:dir.appendingPathComponent("restart-" + name))
        state[name] = installed(name) ? "starting" : "installing"
    }
    func failure(_ name: String) -> String? {
        if let error = Downloads.shared.errors[Self.downloadID(name)] { return "error: " + error }
        for key in [name,"install"] { if let value = state[key], value.hasPrefix("error:") { return value } }
        return nil
    }
    func refresh() {
        guard let data = try? Data(contentsOf:dir.appendingPathComponent("state.json")),
              let next = try? JSONDecoder().decode([String:String].self,from:data) else { return }
        if state != next { state = next }
    }
    func password() -> String? { try? String(contentsOf:dir.appendingPathComponent("omni-password"),encoding:.utf8) }
}

private struct GatewayDashboard: UIViewRepresentable {
    let url: URL
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        view.load(URLRequest(url:url))
        return view
    }
    func updateUIView(_ view: WKWebView,context: Context) {}
}

struct GatewayPanel: View {
    @ObservedObject var service = MobileGateways.shared
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var studio: Studio
    var initialPage: URL? = nil
    @State private var openedInitialPage = false
    @State private var web = WKWebView()
    @State private var resultMessage = ""
    @State private var choosing = false

    private func openWhenReady() {
        guard !openedInitialPage, let initialPage else { return }
        let worker = initialPage.port == 3001 ? "free" : "omni"
        guard service.state[worker] == "listening" else { return }
        openedInitialPage = true
        selected = initialPage
    }
    private func selectFastModel() async {
        guard !choosing else { return }
        choosing = true
        defer { choosing = false }
        do {
            let script = """
            if (location.origin !== 'http://127.0.0.1:3001') throw Error('افتح لوحة FreeLLMAPI المحلية');
            const token = localStorage.getItem('freellmapi_dashboard_token');
            async function dashboard(path) {
              const response = await fetch(path, {mode:'same-origin',redirect:'error',
                headers:token ? {Authorization:'Bearer '+token} : {}});
              if (!response.ok) throw Error('افتح لوحة المفاتيح وسجل الدخول (' + response.status + ')');
              return response.json();
            }
            const [catalog, keys] = await Promise.all([dashboard('/api/models'), dashboard('/api/keys/providers')]);
            const active = new Set(keys.providers.filter(p => p.enabledKeyCount > 0).map(p => p.platform));
            const models = (Array.isArray(catalog) ? catalog : catalog.models).filter(m => m.enabled !== false &&
              m.supportsTools && active.has(m.platform) && m.contextWindow >= 32000 && m.modelId);
            models.sort((a,b) => (a.speedRank || 999) - (b.speedRank || 999) ||
              b.contextWindow - a.contextWindow || (a.intelligenceRank || 999) - (b.intelligenceRank || 999));
            return models[0]?.modelId || '';
            """
            let value = try await web.callAsyncJavaScript(script,arguments:[:],in:nil,contentWorld:.defaultClient)
            guard let model = value as? String, !model.isEmpty else {
                throw LinkError.message("لا يوجد نموذج مفعّل يدعم الأدوات وسياق 32000")
            }
            let base = "http://127.0.0.1:3001/v1"
            var provider = studio.providers.first { $0.base == base && $0.style == .gateway } ??
                Provider(name:"FreeLLMAPI",base:base,model:model,style:.gateway,free:true)
            provider.model = model
            try studio.storeProvider(provider,key:Credentials.key(provider.id))
            resultMessage = "تم اختيار " + model
        } catch { resultMessage = error.localizedDescription }
    }
    @State private var selected: URL?
    @State private var copied = false
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    VStack {
                        GatewayDashboard(url:selected,view:web).id(selected)
                        if selected.port == 3001 {
                            Button("اختيار أسرع نموذج متاح يدعم الأدوات") { Task { await selectFastModel() } }.disabled(choosing)
                            if !resultMessage.isEmpty { Text(resultMessage).font(.caption).textSelection(.enabled) }
                        }
                    }
                }
                else {
                    Form {
                        ForEach(["omni","free"],id:\.self) { id in
                            let name = id == "omni" ? "OmniRoute" : "FreeLLMAPI"
                            let endpoint = id == "omni" ? "http://127.0.0.1:20128" : "http://127.0.0.1:3001"
                            Section(name) {
                                let job = downloads.active[MobileGateways.downloadID(id)]
                                if !service.installed(id) {
                                    if let job {
                                        ProgressView(value:job.fraction) {
                                            Text(job.verifying ? "التحقق من الملف…" : "تنزيل " + name)
                                        } currentValueLabel: {
                                            Text(ByteCountFormatter.string(fromByteCount:job.received,countStyle:.file) + " / " + service.size(id))
                                        }
                                        Button("إيقاف التنزيل مؤقتا") { downloads.pause(MobileGateways.downloadID(id)) }
                                    } else if !service.downloaded(id) {
                                        Button("تنزيل " + name + " (" + service.size(id) + ")") { service.set(id,enabled:true) }
                                        Text("تُحمَّل البوابة من إصدار GitHub الخاص بالتطبيق ويُتحقق من بصمتها قبل فكها.").font(.footnote)
                                    }
                                    if let error = downloads.errors[MobileGateways.downloadID(id)] { Text(error).font(.footnote).foregroundStyle(.red) }
                                }
                                Toggle("تشغيل على هذا الجهاز",isOn:Binding(get:{service.desired[id] ?? false},set:{service.set(id,enabled:$0)}))
                                if service.desired[id] == true {
                                    let status = service.state[id] ?? "installing"
                                    Text(["missing":job == nil ? "بانتظار ملفات البوابة" : "جار التنزيل…","installing":"جار تجهيز الملفات لأول تشغيل…","ready":"جار بدء البوابة…","starting":"جار بدء البوابة…","listening":"تعمل محليا","stopped":"متوقفة"][status] ?? status)
                                    if status.hasPrefix("error:") || downloads.errors[MobileGateways.downloadID(id)] != nil {
                                        Button("إعادة المحاولة " + name) { service.restart(id) }
                                    }
                                    Text(endpoint + "/v1").textSelection(.enabled)
                                    Button("فتح لوحة " + name) { selected = URL(string:endpoint) }.disabled(status != "listening")
                                    if id == "free" && status == "listening" {
                                        Button("مفاتيح المزودين") { selected = URL(string:endpoint + "/keys") }
                                    }
                                    if id == "omni" && status == "listening" {
                                        Button(copied ? "تم نسخ كلمة المرور" : "نسخ كلمة مرور اللوحة الأولية") {
                                            if let value = service.password() {
                                                UIPasteboard.general.setItems([["public.utf8-plain-text":value]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(60)])
                                                copied = true
                                            }
                                        }
                                    }
                                }
                                if service.installed(id) {
                                    Button("حذف ملفات " + name + " (تبقى الحسابات)",role:.destructive) { service.remove(id) }
                                }
                            }
                        }
                        Text("بعد إعداد حساب المزود في لوحة البوابة أضف قالب البوابة من قائمة المزودين لاستخدامها في المحادثة. أبق التطبيق مفتوحا أثناء العمل.").font(.footnote)
                        if !service.problem.isEmpty { Text(service.problem) }
                    }
                }
            }.onAppear { openWhenReady() }.onChange(of:service.state) { _ in openWhenReady() }.navigationTitle("البوابات المحلية").navigationBarTitleDisplayMode(.inline)
             .toolbar { Button(selected == nil ? "تم" : "رجوع") { if selected == nil { dismiss() } else { selected = nil } } }
        }
    }
}
