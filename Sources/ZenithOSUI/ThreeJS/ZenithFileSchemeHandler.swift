import Foundation
import WebKit

/// Serves local files to WKWebView under the `zenith-file://` custom scheme.
/// URL format: `zenith-file:///absolute/path/to/file.glb`
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

        // The path is encoded in the URL's path component
        let filePath = url.path   // e.g. /Users/.../scene.glb

        let fileURL = URL(fileURLWithPath: filePath)
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
            NSLog("FormsFileServeDiagnostics error=%@ url=%@ path=%@", String(describing: error), url.absoluteString, fileURL.path)
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView,
                 stop urlSchemeTask: any WKURLSchemeTask) {
        // Nothing to cancel for synchronous file reads
    }

    private func logFormsFileServe(fileURL: URL, requestURL: URL, byteCount: Int) {
        guard Self.formsDiagnosticFileNames.contains(fileURL.lastPathComponent),
              fileURL.path.contains("/claude-hub/repos/workspace/Forms/") else {
            return
        }

        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)
            .map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"

        NSLog(
            "FormsFileServeDiagnostics path=%@ bytes=%d modified=%@ url=%@",
            fileURL.path,
            byteCount,
            modified,
            requestURL.absoluteString
        )
    }
}
