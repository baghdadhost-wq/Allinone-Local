import Foundation

/// Marks a folder so iCloud and device backups skip it (models are many gigabytes).
func excludeFolderFromBackup(_ folder: URL) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var url = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}

/// Where GGUF models live on the device and how big a model the device can run.
enum ModelStore {
    static let dir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models")
        excludeFolderFromBackup(url)
        return url
    }()
    static func url(for file: String) -> URL { dir.appendingPathComponent((file as NSString).lastPathComponent) }
    struct Installed: Equatable { let file: String; let size: Int64 }
    static var installed: [Installed] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.filter { $0.pathExtension.lowercased() == "gguf" }
            .map { Installed(file: $0.lastPathComponent, size: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            .sorted { $0.file < $1.file }
    }
    /// 0 = choose automatically from free memory.
    static var contextSetting: Int {
        get { UserDefaults.standard.integer(forKey: "local.context") }
        set { UserDefaults.standard.set(newValue, forKey: "local.context") }
    }
    static let magic = Data("GGUF".utf8)

    enum Fit { case good, tight, tooBig }
    /// Weights plus room for the context cache and the app itself.
    static func fit(_ bytes: Int64) -> Fit {
        let need = Double(bytes) * 1.08 + 600_000_000
        let limit = Double(DeviceMemory.limit)
        return need < limit * 0.8 ? .good : need < limit * 0.97 ? .tight : .tooBig
    }
    static func downloadID(_ repo: String, _ file: String) -> String { "model-" + repo + "/" + file }
}

