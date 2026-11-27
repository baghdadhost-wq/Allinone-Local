import WebKit

/// Runs JavaScript (and Python through Pyodide) in an off-screen WebKit page so the
/// coding agent can test what it writes. WebKit is the iOS sandbox: no file or shell access.
@MainActor final class CodeRunner {
    static let shared = CodeRunner()
    private var web: WKWebView?
    /// Pyodide is downloaded from jsDelivr the first time Python runs, then cached by WebKit.
    static let pyodide = "https://cdn.jsdelivr.net/pyodide/v0.27.2/full/pyodide.js"

    private func page() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
        view.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'></head><body></body></html>", baseURL: URL(string: "https://allinone.local/"))
        web = view
        return view
    }

    func run(lang: String, code: String, timeout: TimeInterval = 20) async throws -> String {
        let view = page()
        for _ in 0..<50 where view.isLoading { try await Task.sleep(nanoseconds: 100_000_000) }
        let script = lang == "py" ? Self.python : Self.javascript
        let work = Task { @MainActor in
            try await view.callAsyncJavaScript(script, arguments: ["code": code, "src": Self.pyodide], in: nil, contentWorld: .page)
        }
        let limit = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64((lang == "py" ? timeout * 6 : timeout) * 1_000_000_000))
            work.cancel()
        }
        defer { limit.cancel() }
        do {
            let value = try await work.value
            let text = (value as? String) ?? ""
            return text.isEmpty ? "(no output)" : String(text.prefix(8000))
        } catch {
            if work.isCancelled {
                // A runaway loop keeps the page busy: replace it.
                web = nil
                return "Stopped: the code did not finish within \(Int(lang == "py" ? timeout * 6 : timeout)) seconds."
            }
            return "Error: " + error.localizedDescription
        }
    }

    private static let javascript = """
    const out = [];
    const show = v => typeof v === 'string' ? v : (() => { try { return JSON.stringify(v); } catch { return String(v); } })();
    const log = (...a) => out.push(a.map(show).join(' '));
    const consoleProxy = {log, info: log, warn: log, error: log, debug: log};
    const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
    try {
      const result = await new AsyncFunction('console', code)(consoleProxy);
      if (result !== undefined) out.push('=> ' + show(result));
    } catch (e) { out.push((e && e.stack) ? String(e.stack) : String(e)); }
    return out.join('\\n');
    """

    private static let python = """
    if (!window.__pyodide) {
      window.__pyodide = (async () => {
        if (!window.loadPyodide) await new Promise((resolve, reject) => {
          const s = document.createElement('script'); s.src = src; s.onload = resolve;
          s.onerror = () => reject(new Error('تعذر تحميل Pyodide: تشغيل Python يحتاج الإنترنت أول مرة'));
          document.head.appendChild(s);
        });
        return await loadPyodide();
      })();
    }
    let py;
    try { py = await window.__pyodide; } catch (e) { window.__pyodide = null; return String(e.message || e); }
    const out = [];
    py.setStdout({batched: s => out.push(s)});
    py.setStderr({batched: s => out.push(s)});
    try {
      const result = await py.runPythonAsync(code);
      if (result !== undefined && result !== null) out.push('=> ' + String(result));
    } catch (e) { out.push(String(e)); }
    return out.join('\\n');
    """
}
