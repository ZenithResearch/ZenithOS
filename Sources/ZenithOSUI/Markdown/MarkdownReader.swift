import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

enum MarkdownViewerContext: String, Codable {
    case process
    case fileBrowser
    case playground
    case generic
}

enum MarkdownReaderPresentationMode: String, Codable {
    case inline
    case processModal
}

struct MarkdownDocumentSource: Identifiable, Equatable {
    let id: UUID
    let title: String
    let markdown: String
    let sourceURL: URL?
    let context: MarkdownViewerContext
    let focusFragment: String?

    init(
        id: UUID = UUID(),
        title: String,
        markdown: String,
        sourceURL: URL? = nil,
        context: MarkdownViewerContext = .generic,
        focusFragment: String? = nil
    ) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.sourceURL = sourceURL
        self.context = context
        self.focusFragment = focusFragment
    }

    static func fromFileURL(
        _ url: URL,
        context: MarkdownViewerContext,
        titleOverride: String? = nil,
        focusFragment: String? = nil
    ) throws -> MarkdownDocumentSource {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return MarkdownDocumentSource(
            title: titleOverride ?? url.deletingPathExtension().lastPathComponent,
            markdown: markdown,
            sourceURL: url,
            context: context,
            focusFragment: focusFragment
        )
    }
}

enum MarkdownLinkResolution {
    case document(MarkdownDocumentSource)
    case external(URL)
    case none
}

typealias MarkdownLinkResolver = @MainActor (MarkdownDocumentSource, String) async -> MarkdownLinkResolution
typealias MarkdownPageLayoutHandler = @MainActor (CGRect) -> Void

@MainActor
final class MarkdownReaderSession: ObservableObject {
    @Published private(set) var currentDocument: MarkdownDocumentSource
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    var linkResolver: MarkdownLinkResolver?

    private var backStack: [MarkdownDocumentSource] = []
    private var forwardStack: [MarkdownDocumentSource] = []

    init(initialDocument: MarkdownDocumentSource, linkResolver: MarkdownLinkResolver? = nil) {
        self.currentDocument = initialDocument
        self.linkResolver = linkResolver
        updateNavigationFlags()
    }

    func setDocument(_ document: MarkdownDocumentSource, resetHistory: Bool = false) {
        if resetHistory {
            backStack.removeAll()
            forwardStack.removeAll()
        }
        currentDocument = document
        updateNavigationFlags()
    }

    func open(_ document: MarkdownDocumentSource) {
        backStack.append(currentDocument)
        currentDocument = document
        forwardStack.removeAll()
        updateNavigationFlags()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentDocument)
        currentDocument = previous
        updateNavigationFlags()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentDocument)
        currentDocument = next
        updateNavigationFlags()
    }

    func handleLink(_ href: String) {
        guard let linkResolver else { return }
        let source = currentDocument
        Task { @MainActor in
            switch await linkResolver(source, href) {
            case .document(let document):
                open(document)
            case .external(let url):
                NSWorkspace.shared.open(url)
            case .none:
                break
            }
        }
    }

    private func updateNavigationFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }
}

@MainActor
enum MarkdownLinkNavigator {
    static func makeResolver(
        context: MarkdownViewerContext,
        onSelectInFileTree: ((URL) -> Void)? = nil
    ) -> MarkdownLinkResolver {
        { current, href in
            await resolve(href: href, from: current, context: context, onSelectInFileTree: onSelectInFileTree)
        }
    }

    private static func resolve(
        href: String,
        from current: MarkdownDocumentSource,
        context: MarkdownViewerContext,
        onSelectInFileTree: ((URL) -> Void)?
    ) async -> MarkdownLinkResolution {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if trimmed.hasPrefix("#") {
            return .none
        }
        if trimmed.hasPrefix("zenith-wiki:") {
            return await resolveWikiTarget(
                String(trimmed.dropFirst("zenith-wiki:".count)),
                from: current,
                context: context,
                onSelectInFileTree: onSelectInFileTree
            )
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https", "mailto", "tel":
                return .external(url)
            case "file":
                return loadResolvedFile(
                    URL(fileURLWithPath: url.path),
                    from: current,
                    context: context,
                    onSelectInFileTree: onSelectInFileTree
                )
            case "zenith-file":
                guard let fileURL = decodeZenithFileURL(trimmed) else { return .none }
                return loadResolvedFile(
                    fileURL,
                    from: current,
                    context: context,
                    onSelectInFileTree: onSelectInFileTree
                )
            default:
                return .none
            }
        }
        if trimmed.hasPrefix("/") {
            return loadResolvedFile(
                URL(fileURLWithPath: trimmed),
                from: current,
                context: context,
                onSelectInFileTree: onSelectInFileTree
            )
        }

        if let relativeURL = resolveRelativeMarkdownURL(trimmed, from: current.sourceURL) {
            return loadResolvedFile(
                relativeURL,
                from: current,
                context: context,
                onSelectInFileTree: onSelectInFileTree
            )
        }

        return await resolveWikiTarget(
            trimmed,
            from: current,
            context: context,
            onSelectInFileTree: onSelectInFileTree
        )
    }

    private static func resolveWikiTarget(
        _ rawTarget: String,
        from current: MarkdownDocumentSource,
        context: MarkdownViewerContext,
        onSelectInFileTree: ((URL) -> Void)?
    ) async -> MarkdownLinkResolution {
        let decoded = rawTarget.removingPercentEncoding ?? rawTarget
        let (target, fragment) = splitTargetAndFragment(decoded)
        let searchRoot = FileStore.hubRoot
        guard let resolvedURL = await searchWikiMarkdownURL(target: target, root: searchRoot) else {
            return .none
        }
        if resolvedURL.pathExtension.lowercased() == "md" {
            onSelectInFileTree?(resolvedURL)
        }
        return loadResolvedFile(
            resolvedURL,
            from: current,
            context: context,
            onSelectInFileTree: onSelectInFileTree,
            focusFragment: fragment
        )
    }

    private static func loadResolvedFile(
        _ url: URL,
        from current: MarkdownDocumentSource,
        context: MarkdownViewerContext,
        onSelectInFileTree: ((URL) -> Void)?,
        focusFragment: String? = nil
    ) -> MarkdownLinkResolution {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let fragment = focusFragment
        if resolvedURL.pathExtension.lowercased() == "md" || resolvedURL.pathExtension.lowercased() == "markdown" {
            do {
                var document = try MarkdownDocumentSource.fromFileURL(
                    resolvedURL,
                    context: context,
                    focusFragment: fragment
                )
                if document.title.isEmpty {
                    document = MarkdownDocumentSource(
                        title: resolvedURL.deletingPathExtension().lastPathComponent,
                        markdown: document.markdown,
                        sourceURL: document.sourceURL,
                        context: document.context,
                        focusFragment: document.focusFragment
                    )
                }
                onSelectInFileTree?(resolvedURL)
                return .document(document)
            } catch {
                return .none
            }
        }
        return .external(resolvedURL)
    }

    private static func decodeZenithFileURL(_ href: String) -> URL? {
        guard let url = URL(string: href) else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    private static func resolveRelativeMarkdownURL(_ href: String, from sourceURL: URL?) -> URL? {
        let decoded = href.removingPercentEncoding ?? href
        let (pathPart, fragment) = splitTargetAndFragment(decoded)
        guard let baseURL = sourceURL?.deletingLastPathComponent(),
              !pathPart.isEmpty else { return nil }

        let initialURL = URL(fileURLWithPath: pathPart, relativeTo: baseURL).standardizedFileURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: initialURL.path) {
            return withFragment(initialURL, fragment: fragment)
        }
        if initialURL.pathExtension.isEmpty {
            let markdownURL = initialURL.deletingPathExtension().appendingPathExtension("md")
            if fileManager.fileExists(atPath: markdownURL.path) {
                return withFragment(markdownURL, fragment: fragment)
            }
        }
        return nil
    }

    private static func searchWikiMarkdownURL(target: String, root: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let searchTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !searchTarget.isEmpty else { return nil as URL? }

            let exactFilename = searchTarget.hasSuffix(".md") ? searchTarget : "\(searchTarget).md"
            let exactStem = URL(fileURLWithPath: searchTarget).deletingPathExtension().lastPathComponent
            let lowerStem = exactStem.lowercased()

            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }

            var exactFilenameMatch: URL?
            var exactStemMatch: URL?
            var caseInsensitiveStemMatches: [URL] = []

            while let next = enumerator.nextObject() as? URL {
                let last = next.lastPathComponent
                if ["node_modules", ".git", ".build", ".obsidian", ".claude"].contains(last) {
                    enumerator.skipDescendants()
                    continue
                }
                guard next.pathExtension.lowercased() == "md" else { continue }

                if next.lastPathComponent == exactFilename {
                    exactFilenameMatch = next
                    break
                }

                let stem = next.deletingPathExtension().lastPathComponent
                if stem == exactStem, exactStemMatch == nil {
                    exactStemMatch = next
                }
                if stem.lowercased() == lowerStem {
                    caseInsensitiveStemMatches.append(next)
                }
            }

            if let exactFilenameMatch { return exactFilenameMatch }
            if let exactStemMatch { return exactStemMatch }
            if caseInsensitiveStemMatches.count == 1 {
                return caseInsensitiveStemMatches[0]
            }
            return nil
        }.value
    }

    private static func splitTargetAndFragment(_ target: String) -> (String, String?) {
        guard let hashIndex = target.firstIndex(of: "#") else {
            return (target, nil)
        }
        let path = String(target[..<hashIndex])
        let fragment = String(target[target.index(after: hashIndex)...])
        return (path, fragment.isEmpty ? nil : fragment)
    }

    private static func withFragment(_ url: URL, fragment: String?) -> URL {
        guard let fragment else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? url
    }
}

@MainActor
struct MarkdownReaderView: View {
    @ObservedObject var session: MarkdownReaderSession
    let presentationMode: MarkdownReaderPresentationMode
    let onPageLayout: MarkdownPageLayoutHandler?
    @StateObject private var holder = MarkdownWebViewHolder()

    init(
        session: MarkdownReaderSession,
        presentationMode: MarkdownReaderPresentationMode = .inline,
        onPageLayout: MarkdownPageLayoutHandler? = nil
    ) {
        self._session = ObservedObject(wrappedValue: session)
        self.presentationMode = presentationMode
        self.onPageLayout = onPageLayout
    }

    var body: some View {
        MarkdownWebViewRepresentable(
            webView: holder.webView,
            session: session,
            presentationMode: presentationMode,
            onPageLayout: onPageLayout
        )
    }
}

final class MarkdownWebViewHolder: ObservableObject {
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ZenithFileSchemeHandler(), forURLScheme: "zenith-file")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground") // legacy suppress
        webView.underPageBackgroundColor = .clear          // suppress pre-paint flash on current WebKit
        webView.allowsBackForwardNavigationGestures = false
        self.webView = webView
    }
}

private struct MarkdownWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    @ObservedObject var session: MarkdownReaderSession
    let presentationMode: MarkdownReaderPresentationMode
    let onPageLayout: MarkdownPageLayoutHandler?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            presentationMode: presentationMode,
            onPageLayout: onPageLayout
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "markdownReady")
        controller.removeScriptMessageHandler(forName: "markdownLink")
        controller.removeScriptMessageHandler(forName: "markdownLayout")
        controller.add(context.coordinator, name: "markdownReady")
        controller.add(context.coordinator, name: "markdownLink")
        controller.add(context.coordinator, name: "markdownLayout")

        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView: webView)
        context.coordinator.loadViewerIfNeeded()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.session = session
        context.coordinator.presentationMode = presentationMode
        context.coordinator.onPageLayout = onPageLayout
        context.coordinator.render(document: session.currentDocument)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        let controller = nsView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "markdownReady")
        controller.removeScriptMessageHandler(forName: "markdownLink")
        controller.removeScriptMessageHandler(forName: "markdownLayout")
        nsView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var session: MarkdownReaderSession
        var presentationMode: MarkdownReaderPresentationMode
        var onPageLayout: MarkdownPageLayoutHandler?
        private weak var webView: WKWebView?
        private var viewerReady = false
        private var pendingDocument: MarkdownDocumentSource?
        private var lastRenderedDocumentID: UUID?
        private var lastRenderedPresentationMode: MarkdownReaderPresentationMode?

        init(
            session: MarkdownReaderSession,
            presentationMode: MarkdownReaderPresentationMode,
            onPageLayout: MarkdownPageLayoutHandler?
        ) {
            self.session = session
            self.presentationMode = presentationMode
            self.onPageLayout = onPageLayout
        }

        func attach(webView: WKWebView) {
            self.webView = webView
        }

        func loadViewerIfNeeded() {
            guard let webView else { return }
            guard webView.url == nil else { return }
            guard let viewerURL = Bundle.module.resourceURL?
                .appendingPathComponent("MarkdownResources/viewer.html") else {
                return
            }
            viewerReady = false
            webView.loadFileURL(
                viewerURL,
                allowingReadAccessTo: viewerURL.deletingLastPathComponent()
            )
        }

        func render(document: MarkdownDocumentSource) {
            guard let webView else {
                pendingDocument = document
                return
            }
            guard viewerReady else {
                pendingDocument = document
                return
            }
            guard lastRenderedDocumentID != document.id || lastRenderedPresentationMode != presentationMode else { return }

            do {
                let payload = try JSONEncoder().encode(
                    DocumentPayload(
                        document: document,
                        presentationMode: presentationMode
                    )
                )
                guard let json = String(data: payload, encoding: .utf8) else { return }
                let script = "window.ZenithMarkdownViewer.renderDocument(\(json));"
                webView.evaluateJavaScript(script)
                lastRenderedDocumentID = document.id
                lastRenderedPresentationMode = presentationMode
            } catch {}
        }

        @MainActor
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            viewerReady = true
            render(document: pendingDocument ?? session.currentDocument)
            pendingDocument = nil
        }

        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow)
                return
            }

            if ["http", "https", "mailto", "tel"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        @MainActor
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "markdownReady":
                viewerReady = true
                render(document: pendingDocument ?? session.currentDocument)
                pendingDocument = nil
            case "markdownLink":
                if let href = message.body as? String {
                    session.handleLink(href)
                }
            case "markdownLayout":
                if let rect = Self.decodeRect(from: message.body) {
                    onPageLayout?(rect)
                }
            default:
                break
            }
        }

        private static func decodeRect(from body: Any) -> CGRect? {
            guard let payload = body as? [String: Any],
                  let x = payload["x"] as? Double,
                  let y = payload["y"] as? Double,
                  let width = payload["width"] as? Double,
                  let height = payload["height"] as? Double else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

private struct DocumentPayload: Encodable {
    let title: String
    let markdown: String
    let sourceURL: String?
    let context: String
    let focusFragment: String?
    let presentationMode: String

    init(
        document: MarkdownDocumentSource,
        presentationMode: MarkdownReaderPresentationMode
    ) {
        title = document.title
        markdown = document.markdown
        sourceURL = document.sourceURL?.absoluteString
        context = document.context.rawValue
        focusFragment = document.focusFragment
        self.presentationMode = presentationMode.rawValue
    }
}
