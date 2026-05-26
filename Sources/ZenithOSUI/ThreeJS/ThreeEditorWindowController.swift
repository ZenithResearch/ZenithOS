import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Forms repo root

let formsRepoRoot = URL(fileURLWithPath:
    NSString("~/claude-hub/repos/workspace/Forms").expandingTildeInPath
)

/// The single viewer HTML — all catalog items render through this.
let viewerHTML = formsRepoRoot
    .appendingPathComponent("crates/forms-renderer/viewer/index.html")

func formsViewerRequest(for item: CatalogItem) -> URLRequest {
    let fragment = item.id.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? item.id
    let cacheBuster = UUID().uuidString
    let zenithURL = URL(string: "zenith-file://\(viewerHTML.path)?v=\(cacheBuster)#\(fragment)")!
    var request = URLRequest(
        url: zenithURL,
        cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
        timeoutInterval: 30
    )
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    return request
}

// MARK: - Catalog item model

struct CatalogItem: Identifiable, Hashable {
    let id: String          // e.g. "geometry/unit_box"
    let name: String        // e.g. "unit_box"
    let section: CatalogSection
}

enum CatalogSection: String, CaseIterable {
    case geometry = "Geometry"
    case material = "Material"
    case light    = "Light"
    case camera   = "Camera"
    case mesh     = "Mesh"
    case scene    = "Scene"

    var icon: String {
        switch self {
        case .geometry: return "cube"
        case .material: return "paintpalette"
        case .light:    return "light.max"
        case .mesh:     return "cube.fill"
        case .camera:   return "camera"
        case .scene:    return "cube.transparent"
        }
    }

    var level: String {
        switch self {
        case .geometry, .material, .light, .camera: return "Atoms"
        case .mesh: return "Molecules"
        case .scene: return "Organisms"
        }
    }
}

// MARK: - Catalog store

@MainActor
final class FormsCatalogStore: ObservableObject {
    @Published var items: [CatalogItem] = []
    @Published var selected: CatalogItem? = nil

    init() {
        // Mirror the Rust catalog entries exactly
        let entries: [(CatalogSection, [String])] = [
            (.geometry, ["unit_box", "unit_sphere", "ground_plane", "slab", "pillar", "hires_sphere", "dot"]),
            (.material, ["brushed_metal", "gold", "dark_iron", "matte_red", "matte_white", "frosted_glass", "clay", "neon_aqua", "ember"]),
            (.light,    ["studio_key", "warm_key", "cool_fill", "rim_back", "ambient_neutral", "ambient_warm", "overhead_point"]),
            (.camera,   ["product_shot", "closeup", "wide_overhead", "top_down_ortho"]),
            (.mesh,     ["metal_cube", "gold_sphere", "iron_pillar", "showcase_sphere", "default_box", "clay_slab", "neon_orb", "ember_dot", "glass_sphere"]),
            (.scene,    ["default_scene", "material_showcase", "hero_display", "pillar_row"]),
        ]

        items = entries.flatMap { section, names in
            names.map { name in
                CatalogItem(
                    id: "\(section.rawValue.lowercased())/\(name)",
                    name: name,
                    section: section
                )
            }
        }
    }

    /// Group items by section for display.
    func grouped() -> [(CatalogSection, [CatalogItem])] {
        let grouped = Dictionary(grouping: items, by: \.section)
        return CatalogSection.allCases
            .compactMap { section in
                guard let entries = grouped[section], !entries.isEmpty else { return nil }
                return (section, entries)
            }
    }
}

// MARK: - Catalog browser view

struct FormsCatalogView: View {
    @ObservedObject var store: FormsCatalogStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Forms")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            List(selection: Binding(
                get: { store.selected },
                set: { store.selected = $0 }
            )) {
                ForEach(store.grouped(), id: \.0) { section, entries in
                    Section(header: Text(section.rawValue).font(.caption2)) {
                        ForEach(entries) { item in
                            Label {
                                Text(item.name.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: section.icon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Window controller

final class ThreeEditorWindowController: NSWindowController {

    static let shared = ThreeEditorWindowController()

    private let webView:      WKWebView
    private let store:        FormsCatalogStore
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ZenithFileSchemeHandler(), forURLScheme: "zenith-file")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let wv    = WKWebView(frame: .zero, configuration: config)
        let store = FormsCatalogStore()

        let browserHost = NSHostingView(
            rootView: FormsCatalogView(store: store)
        )
        browserHost.frame.size = CGSize(width: 220, height: 600)

        let split = NSSplitView()
        split.isVertical   = true
        split.dividerStyle = .thin
        split.addArrangedSubview(browserHost)
        split.addArrangedSubview(wv)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 820),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        win.title              = "3D Editor"
        win.contentView        = split
        win.minSize            = NSSize(width: 700, height: 480)
        win.isReleasedWhenClosed = false
        win.center()
        split.setPosition(220, ofDividerAt: 0)

        self.webView = wv
        self.store   = store
        super.init(window: win)

        // Observe catalog selection — load renderer with item hash
        store.$selected
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] item in self?.loadItem(item) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        // Default: load the default box
        if webView.url == nil {
            if let defaultItem = store.items.first(where: { $0.id == "mesh/default_box" }) {
                store.selected = defaultItem
            }
        }
    }

    // MARK: Private

    private func loadItem(_ item: CatalogItem) {
        // Load the single renderer viewer via zenith-file:// with the catalog item as hash
        webView.stopLoading()
        webView.load(formsViewerRequest(for: item))
    }
}
