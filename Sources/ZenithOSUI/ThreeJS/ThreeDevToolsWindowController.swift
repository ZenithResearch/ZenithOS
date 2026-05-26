import AppKit
import SwiftUI
import WebKit

// MARK: - Scene node model

struct ThreeSceneNode: Identifiable, Hashable {
    let id: String       // Three.js object uuid
    let name: String
    let type: String     // "Mesh", "DirectionalLight", "Group", etc.
    let visible: Bool
    let childIds: [String]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

struct ThreeRendererStats {
    var drawCalls:   Int = 0
    var triangles:   Int = 0
    var geometries:  Int = 0
    var textures:    Int = 0
    var programs:    Int = 0
}

// MARK: - Inspector store

@MainActor
final class ThreeInspectorStore: ObservableObject {
    @Published var nodes:    [ThreeSceneNode]   = []
    @Published var stats:    ThreeRendererStats  = ThreeRendererStats()
    @Published var selected: ThreeSceneNode?     = nil
    @Published var error:    String?             = nil

    weak var webView: WKWebView?

    func refresh() {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(ThreeDevToolsBridge.dumpSceneJS) { [weak self] result, err in
            guard let self else { return }
            Task { @MainActor in
                if let err { self.error = err.localizedDescription; return }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { self.error = "Unexpected inspector response"; return }

                self.error = nil
                self.nodes = ThreeDevToolsBridge.parseNodes(payload)
                self.stats = ThreeDevToolsBridge.parseStats(payload)
            }
        }
    }

    func select(_ node: ThreeSceneNode) {
        selected = node
        guard let wv = webView else { return }
        let js = "window.__zenithDevTools__?.selectObject('\(node.id)')"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - JS bridge helpers

enum ThreeDevToolsBridge {
    /// Injected into the target WKWebView to extract scene data
    static let dumpSceneJS = """
    (function() {
      const renderers = window.__zenithDevTools__?.renderers ?? [];
      if (!renderers.length) {
        // Auto-detect: look for a THREE.WebGLRenderer on window or common variable names
        const candidates = ['renderer', 'webglRenderer', 'threeRenderer'];
        for (const k of candidates) {
          if (window[k]?.isWebGLRenderer) renderers.push(window[k]);
        }
      }

      const renderer = renderers[0];
      const scene    = renderer?.info ? null : window.scene ?? window.threeScene;

      function walkScene(obj) {
        if (!obj) return [];
        return [{
          uuid:    obj.uuid,
          name:    obj.name || obj.type,
          type:    obj.type,
          visible: obj.visible,
          children: (obj.children || []).map(c => c.uuid)
        }, ...(obj.children || []).flatMap(walkScene)];
      }

      const nodes = walkScene(renderer?.scene ?? scene);
      const info  = renderer?.info ?? {};

      return JSON.stringify({
        nodes,
        stats: {
          drawCalls:  info.render?.calls     ?? 0,
          triangles:  info.render?.triangles ?? 0,
          geometries: info.memory?.geometries ?? 0,
          textures:   info.memory?.textures   ?? 0,
          programs:   info.programs?.length   ?? 0,
        }
      });
    })();
    """

    static func parseNodes(_ payload: [String: Any]) -> [ThreeSceneNode] {
        guard let raw = payload["nodes"] as? [[String: Any]] else { return [] }
        return raw.compactMap { obj -> ThreeSceneNode? in
            guard let id   = obj["uuid"]    as? String,
                  let name = obj["name"]    as? String,
                  let type = obj["type"]    as? String else { return nil }
            let visible  = obj["visible"]  as? Bool   ?? true
            let children = obj["children"] as? [String] ?? []
            return ThreeSceneNode(id: id, name: name, type: type, visible: visible, childIds: children)
        }
    }

    static func parseStats(_ payload: [String: Any]) -> ThreeRendererStats {
        guard let s = payload["stats"] as? [String: Any] else { return .init() }
        var stats = ThreeRendererStats()
        stats.drawCalls  = s["drawCalls"]  as? Int ?? 0
        stats.triangles  = s["triangles"]  as? Int ?? 0
        stats.geometries = s["geometries"] as? Int ?? 0
        stats.textures   = s["textures"]   as? Int ?? 0
        stats.programs   = s["programs"]   as? Int ?? 0
        return stats
    }
}

// MARK: - Navigation bar store

@MainActor
final class ThreeNavStore: ObservableObject {
    @Published var addressText: String = ""
    @Published var repos:       [RepoNote] = []
    @Published var showRepos:   Bool = false

    let webView:    WKWebView
    let serverMgr:  DevServerManager

    @AppStorage("vaultPath") private var vaultPath: String = "/Users/bananawalnut/vault"

    init(webView: WKWebView, serverMgr: DevServerManager) {
        self.webView   = webView
        self.serverMgr = serverMgr
    }

    func navigate() {
        var raw = addressText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") { raw = "http://" + raw }
        guard let url = URL(string: raw) else { return }
        webView.load(URLRequest(url: url))
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .init(filenameExtension: "htm")!]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Open a local Three.js HTML file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addressText = url.absoluteString
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func reloadRepos() {
        repos = RepoScanner.repos(at: vaultPath)
    }

    func updateAddress(_ url: URL?) {
        addressText = url?.absoluteString ?? ""
    }

    func launch(_ repo: RepoNote) {
        serverMgr.start(repo) { [weak self] url in
            guard let self else { return }
            self.addressText = url.absoluteString
            self.webView.load(URLRequest(url: url))
            self.showRepos = false
        }
    }

    func stop(_ repo: RepoNote) {
        serverMgr.stop(repo)
    }
}

// MARK: - Repos popover

private struct ReposPopoverView: View {
    @ObservedObject var nav: ThreeNavStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Dev Servers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { nav.reloadRepos() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reload from vault")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if nav.repos.isEmpty {
                Text("No repo notes found in vault.\nAdd notes with type: repo.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(nav.repos) { repo in
                    RepoRowView(repo: repo, nav: nav)
                    Divider()
                }
            }
        }
        .frame(width: 300)
        .onAppear { nav.reloadRepos() }
    }
}

private struct RepoRowView: View {
    let repo: RepoNote
    @ObservedObject var nav: ThreeNavStore

    var state: DevServerState { nav.serverMgr.state(for: repo) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.caption.weight(.medium))
                Text(":\(repo.devPort)  \(repo.devCommand)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            stateButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stateButton: some View {
        switch state {
        case .idle:
            Button { nav.launch(repo) } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.green)
            .help("Start dev server")

        case .starting:
            ProgressView()
                .scaleEffect(0.6)
                .help("Starting…")

        case .running:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Button { nav.stop(repo) } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Stop dev server")
            }

        case .failed(let msg):
            Text("Error")
                .font(.caption2)
                .foregroundStyle(.red)
                .help(msg)
        }
    }
}

// MARK: - Nav bar view

private struct ThreeNavBarView: View {
    @ObservedObject var nav: ThreeNavStore

    var body: some View {
        HStack(spacing: 6) {
            Button { nav.webView.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!nav.webView.canGoBack)

            Button { nav.webView.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!nav.webView.canGoForward)

            TextField("localhost:5173 or https://…", text: $nav.addressText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { nav.navigate() }

            Button { nav.webView.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload page")

            Button { nav.openFile() } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Open local HTML file")

            Button { nav.showRepos.toggle() } label: {
                Image(systemName: "server.rack")
            }
            .buttonStyle(.borderless)
            .help("Dev servers")
            .popover(isPresented: $nav.showRepos, arrowEdge: .bottom) {
                ReposPopoverView(nav: nav)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Inspector SwiftUI view

struct ThreeInspectorView: View {
    @StateObject private var store = ThreeInspectorStore()
    @StateObject private var nav:   ThreeNavStore
    let webView: WKWebView

    init(webView: WKWebView, serverMgr: DevServerManager) {
        self.webView = webView
        _nav = StateObject(wrappedValue: ThreeNavStore(webView: webView, serverMgr: serverMgr))
    }

    var body: some View {
        VStack(spacing: 0) {
            ThreeNavBarView(nav: nav)
            Divider()

            HSplitView {
                // Left: WKWebView (scene)
                WebViewRepresentable(webView: webView, nav: nav)
                    .frame(minWidth: 400)

                // Right: inspector panel
                VStack(spacing: 0) {
                    // Toolbar
                    HStack {
                        Text("Inspector")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button { store.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh scene graph")
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)

                Divider()

                if let err = store.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    // Renderer stats
                    StatsSection(stats: store.stats)
                    Divider()
                    // Scene hierarchy
                    SceneHierarchySection(store: store)
                }

                    Spacer(minLength: 0)
                }
                .frame(minWidth: 240, maxWidth: 360)
            }
        }
        .onAppear {
            store.webView = webView
        }
    }
}

// MARK: - Stats

private struct StatsSection: View {
    let stats: ThreeRendererStats
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Renderer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                stat("Draw calls",  stats.drawCalls)
                stat("Triangles",   stats.triangles)
                stat("Geometries",  stats.geometries)
                stat("Textures",    stats.textures)
                stat("Programs",    stats.programs)
            }
            .font(.caption.monospaced())
        }
        .padding(12)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(value)").foregroundStyle(.primary)
        }
    }
}

// MARK: - Scene hierarchy

private struct SceneHierarchySection: View {
    @ObservedObject var store: ThreeInspectorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scene graph")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if store.nodes.isEmpty {
                Text("No scene detected.\nRefresh after the scene is loaded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                List(store.nodes, id: \.id, selection: $store.selected) { node in
                    HStack(spacing: 6) {
                        Image(systemName: iconFor(node.type))
                            .font(.caption)
                            .foregroundStyle(node.visible ? .secondary : .tertiary)
                            .frame(width: 14)
                        Text(node.name)
                            .font(.caption)
                            .foregroundStyle(node.visible ? .primary : .tertiary)
                        Spacer()
                        Text(node.type)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case "Mesh":              return "cube"
        case "Group", "Scene":   return "square.3.layers.3d"
        case "DirectionalLight",
             "PointLight",
             "SpotLight",
             "AmbientLight":     return "light.max"
        case "PerspectiveCamera",
             "OrthographicCamera": return "camera"
        default:                 return "circle"
        }
    }
}

// MARK: - WKWebView SwiftUI wrapper

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    var nav: ThreeNavStore?
    var onNavigationFinished: (() -> Void)?

    init(webView: WKWebView,
         nav: ThreeNavStore? = nil,
         onNavigationFinished: (() -> Void)? = nil) {
        self.webView              = webView
        self.nav                  = nav
        self.onNavigationFinished = onNavigationFinished
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(nav: nav, onFinished: onNavigationFinished)
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var nav: ThreeNavStore?
        let onFinished: (() -> Void)?

        init(nav: ThreeNavStore?, onFinished: (() -> Void)?) {
            self.nav       = nav
            self.onFinished = onFinished
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in nav?.updateAddress(webView.url) }
            onFinished?()
        }
    }
}

// MARK: - Window controller

final class ThreeDevToolsWindowController: NSWindowController {

    static let shared = ThreeDevToolsWindowController()

    private let inspectorWebView: WKWebView
    let serverMgr = DevServerManager()

    private init() {
        let wv = WKWebView(frame: .zero)
        self.inspectorWebView = wv

        let mgr  = DevServerManager()
        let view = NSHostingView(rootView: ThreeInspectorView(webView: wv, serverMgr: mgr))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        win.title = "Three.js DevTools"
        win.contentView = view
        win.minSize = NSSize(width: 700, height: 400)
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(url: URL? = nil) {
        window?.makeKeyAndOrderFront(nil)
        if let url {
            inspectorWebView.load(URLRequest(url: url))
        }
        // No default URL — user navigates via the address bar
    }
}
