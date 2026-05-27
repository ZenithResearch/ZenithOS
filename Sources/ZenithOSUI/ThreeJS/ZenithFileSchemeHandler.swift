import Foundation
import WebKit

/// Serves local files to WKWebView under the `zenith-file://` custom scheme.
/// URL format: `zenith-file:///absolute/path/to/file.glb`.
/// Requests are bounded to the app-opened file sandbox or the user's home directory.
final class ZenithFileSchemeHandler: NSObject, WKURLSchemeHandler {

    private static let formsDiagnosticFileNames: Set<String> = [
        "index.html",
        "main.js",
        "forms_renderer.js",
        "forms_renderer_bg.wasm",
        "forms_export.js",
        "forms_export_bg.wasm",
    ]

    private static let mimeTypes: [String: String] = [
        "glb":  "model/gltf-binary",
        "gltf": "model/gltf+json",
        "obj":  "text/plain",
        "mtl":  "text/plain",
        "stl":  "model/stl",
        "fbx":  "application/octet-stream",
        "dae":  "model/vnd.collada+xml",
        "ply":  "application/octet-stream",
        "json": "application/json",
        "bin":  "application/octet-stream",
        "png":  "image/png",
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "wasm": "application/wasm",
        "js":   "text/javascript",
        "mjs":  "text/javascript",
        "html": "text/html",
        "css":  "text/css",
    ]

    func webView(_ webView: WKWebView,
                 start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "zenith-file" else {
            urlSchemeTask.didFailWithError(
                NSError(domain: "ZenithFileSchemeHandler",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid scheme"]))
            return
        }

        let filePath = url.path
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        guard Self.isAllowedFileURL(fileURL) else {
            urlSchemeTask.didFailWithError(
                NSError(domain: "ZenithFileSchemeHandler",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Requested file is outside allowed local roots"]))
            return
        }
        let ext = fileURL.pathExtension.lowercased()
        let mime = Self.mimeTypes[ext] ?? "application/octet-stream"

        do {
            let data = try Data(contentsOf: fileURL)
            logFormsFileServe(fileURL: fileURL, requestURL: url, byteCount: data.count)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(data.count)",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                    "Pragma": "no-cache",
                    "Expires": "0",
                ]
            ) ?? URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            NSLog("FormsFileServeDiagnostics error=%@ file=%@", String(describing: error), fileURL.lastPathComponent)
            urlSchemeTask.didFailWithError(error)
        }
    }

    private static func isAllowedFileURL(_ fileURL: URL) -> Bool {
        let path = fileURL.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return path == home || path.hasPrefix(home + "/") || path.hasPrefix(temporary)
    }

    func webView(_ webView: WKWebView,
                 stop urlSchemeTask: any WKURLSchemeTask) {
        // Nothing to cancel for synchronous file reads
    }

    private func logFormsFileServe(fileURL: URL, requestURL: URL, byteCount: Int) {
        guard Self.formsDiagnosticFileNames.contains(fileURL.lastPathComponent),
              fileURL.path.contains("/repos/workspace/Forms/") else {
            return
        }

        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)
            .map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"

        NSLog(
            "FormsFileServeDiagnostics file=%@ bytes=%d modified=%@",
            fileURL.lastPathComponent,
            byteCount,
            modified
        )
    }
}
