import SwiftUI
import AppKit

private enum ZenithWorkspace: String, CaseIterable, Identifiable {
    case mil
    case playground
    case queue
    case cases
    case matrix
    case synapse
    case reviewAccess
    case hubSettings
    case threeEditor
    case threeDevTools

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .mil: return "bolt.circle"
        case .playground: return "sparkles.rectangle.stack"
        case .queue: return "tray.2"
        case .cases: return "list.bullet.clipboard"
        case .matrix: return "bubble.left.and.bubble.right"
        case .synapse: return "tray.full"
        case .reviewAccess: return "key.viewfinder"
        case .hubSettings: return "gearshape"
        case .threeEditor: return "cube"
        case .threeDevTools: return "wrench.and.screwdriver"
        }
    }

    var label: String {
        switch self {
        case .mil: return "MIL"
        case .playground: return "Playground"
        case .queue: return "Queue"
        case .cases: return "Cases"
        case .matrix: return "Matrix"
        case .synapse: return "Synapse"
        case .reviewAccess: return "Review Access"
        case .hubSettings: return "Hub Connection"
        case .threeEditor: return "3D Editor"
        case .threeDevTools: return "3D DevTools"
        }
    }

    var subtitle: String {
        switch self {
        case .mil: return "Inference monitoring and status"
        case .playground: return "Prompting and rapid experiments"
        case .queue: return "Inbound work and dispatch queue"
        case .cases: return "Frank's active and completed cases"
        case .matrix: return "Matrix inbox and conversations"
        case .synapse: return "Synapse inbox and events"
        case .reviewAccess: return "Rolodex-backed reviewer codes"
        case .hubSettings: return "Hub node binding and credentials"
        case .threeEditor: return "Three.js scene editor"
        case .threeDevTools: return "Three.js debugging surface"
        }
    }
}

extension Notification.Name {
    static let zenithShowTabOverview = Notification.Name("ZenithShowTabOverview")
}

struct ContentView: View {
    @EnvironmentObject private var hub: HubStore
    @StateObject private var store = FileStore()
    @StateObject private var tabOverviewGestureMonitor = ThreeFingerSwipeDownMonitor()
    @State private var selected: FileNode?
    @State private var activeWorkspace: ZenithWorkspace?
    @State private var isTabOverviewPresented = false
    @AppStorage(HubArtifactMount.userDefaultsKey) private var hubArtifactMountsJSON: String = "[]"
    @AppStorage(HubRemoteAccess.localRootUserDefaultsKey) private var hubPathRoot: String = ""

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                    .navigationTitle(hub.hubDisplayName)
                    .toolbar {
                        ToolbarItem {
                            Button(action: { store.load() }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .help("Refresh file tree")
                        }
                    }
            } detail: {
                detailView
            }

            if isTabOverviewPresented {
                WorkspaceOverviewOverlay(
                    workspaces: ZenithWorkspace.allCases,
                    activeWorkspace: activeWorkspace,
                    selectedFile: selected,
                    onSelect: { workspace in
                        activateWorkspace(workspace)
                        dismissTabOverview()
                    },
                    onDismiss: dismissTabOverview
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(2)
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: isTabOverviewPresented)
        .onAppear {
            tabOverviewGestureMonitor.start()
            store.useEffectiveHubRoot(from: hubArtifactMountsJSON, rootPath: hubPathRoot)
        }
        .onChange(of: hubArtifactMountsJSON) { newValue in
            selected = nil
            store.useEffectiveHubRoot(from: newValue, rootPath: hubPathRoot)
        }
        .onChange(of: hubPathRoot) { newValue in
            selected = nil
            store.useEffectiveHubRoot(from: hubArtifactMountsJSON, rootPath: newValue)
        }
        .onDisappear {
            tabOverviewGestureMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .zenithShowTabOverview)) { _ in
            showTabOverview()
        }
        .onExitCommand {
            if isTabOverviewPresented {
                dismissTabOverview()
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // ── Hub nav entries ──────────────────────────
            VStack(spacing: 2) {
                ForEach(ZenithWorkspace.allCases) { workspace in
                    SidebarNavButton(
                        icon: workspace.icon,
                        label: workspace.label,
                        isActive: activeWorkspace == workspace
                    ) {
                        activateWorkspace(workspace)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()
                .padding(.bottom, 4)

            // ── File tree ────────────────────────────────
            if store.isLoading && store.rootNodes.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = store.errorMessage, store.rootNodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Could not read directory")
                        .font(.headline)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { store.load() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.rootNodes, children: \.children, selection: $selected) { node in
                    Label(node.name, systemImage: node.systemImage)
                        .tag(node)
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(node.url) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([node.url])
                            }
                        }
                }
                .listStyle(.sidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selected) { newValue in
                    if newValue != nil {
                        activeWorkspace = nil
                        dismissTabOverview()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch activeWorkspace {
        case .queue:
            QueueListView(hub: hub)
        case .cases:
            ProcessListView(hub: hub)
        case .mil:
            MILInferenceView()
        case .playground:
            PlaygroundView()
        case .matrix:
            MatrixInboxView()
        case .synapse:
            SynapseInboxView()
        case .reviewAccess:
            ReviewAccessView()
        case .hubSettings:
            HubConfigView()
        case .threeEditor:
            ThreeEditorDetailView()
        case .threeDevTools:
            ThreeDevToolsDetailView()
        case .none:
            if let node = selected {
                if node.isDirectory {
                    DirectoryDetailView(node: node)
                } else if node.url.pathExtension == "md" {
                    MarkdownDetailView(node: node, store: store, selectedNode: $selected)
                } else {
                    GenericFileDetailView(node: node)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "folder")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a file or folder")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func activateWorkspace(_ workspace: ZenithWorkspace) {
        activeWorkspace = workspace
        selected = nil
    }

    private func showTabOverview() {
        guard !isTabOverviewPresented else { return }
        isTabOverviewPresented = true
    }

    private func dismissTabOverview() {
        guard isTabOverviewPresented else { return }
        isTabOverviewPresented = false
    }
}

// MARK: - Sidebar nav button

struct SidebarNavButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(label)
                    .font(.body)
                Spacer()
            }
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct WorkspaceOverviewOverlay: View {
    let workspaces: [ZenithWorkspace]
    let activeWorkspace: ZenithWorkspace?
    let selectedFile: FileNode?
    let onSelect: (ZenithWorkspace) -> Void
    let onDismiss: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)
    ]

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("All Tabs")
                            .font(.title2.weight(.semibold))
                        Text(statusLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(workspaces) { workspace in
                        WorkspaceOverviewCard(
                            workspace: workspace,
                            isActive: activeWorkspace == workspace,
                            action: { onSelect(workspace) }
                        )
                    }
                }

                Text("Swipe down with three fingers or press Shift-Command-T to open this overview. Press Esc or click outside to close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760)
            .background(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.black.opacity(0.16), radius: 26, y: 14)
            .padding(28)
        }
    }

    private var statusLine: String {
        if let activeWorkspace {
            return "Current tab: \(activeWorkspace.label)"
        }
        if let selectedFile {
            return "Current file: \(selectedFile.name)"
        }
        return "Choose a ZenithOS workspace tab"
    }
}

private struct WorkspaceOverviewCard: View {
    let workspace: ZenithWorkspace
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: workspace.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isActive ? Color.accentColor : .primary)
                    Spacer()
                    if isActive {
                        Text("OPEN")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(workspace.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private final class ThreeFingerSwipeDownMonitor: ObservableObject {
    private var localMonitor: Any?
    private var activeIndirectTouchCount = 0
    private var hasTriggeredForCurrentGesture = false

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.beginGesture, .gesture, .swipe, .endGesture]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        resetGesture()
    }

    deinit {
        stop()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .beginGesture:
            hasTriggeredForCurrentGesture = false
            activeIndirectTouchCount = indirectTouchCount(from: event)
        case .gesture:
            activeIndirectTouchCount = max(activeIndirectTouchCount, indirectTouchCount(from: event))
        case .swipe:
            guard !hasTriggeredForCurrentGesture else { return }
            guard activeIndirectTouchCount == 3 else { return }
            guard event.deltaY < 0 else { return }
            hasTriggeredForCurrentGesture = true
            NotificationCenter.default.post(name: .zenithShowTabOverview, object: nil)
        case .endGesture:
            resetGesture()
        default:
            break
        }
    }

    private func indirectTouchCount(from event: NSEvent) -> Int {
        event.touches(matching: .touching, in: nil)
            .filter { $0.type == .indirect && !$0.isResting }
            .count
    }

    private func resetGesture() {
        activeIndirectTouchCount = 0
        hasTriggeredForCurrentGesture = false
    }
}

// MARK: - Directory detail

struct DirectoryDetailView: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(node.name, systemImage: "folder")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if let children = node.children, !children.isEmpty {
                List(children, id: \.url) { child in
                    HStack {
                        Label(child.name, systemImage: child.systemImage)
                        Spacer()
                        if child.isDirectory, let c = child.children {
                            Text("\(c.count) items")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Text("Empty folder")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(node.name)
    }
}

// MARK: - Markdown detail

struct MarkdownDetailView: View {
    let node: FileNode
    @ObservedObject var store: FileStore
    @Binding var selectedNode: FileNode?
    @StateObject private var session: MarkdownReaderSession

    init(node: FileNode, store: FileStore, selectedNode: Binding<FileNode?>) {
        self.node = node
        self.store = store
        self._selectedNode = selectedNode
        let initialDocument = (try? MarkdownDocumentSource.fromFileURL(node.url, context: .fileBrowser))
            ?? MarkdownDocumentSource(
                title: node.url.deletingPathExtension().lastPathComponent,
                markdown: "(unreadable)",
                sourceURL: node.url,
                context: .fileBrowser
            )
        self._session = StateObject(
            wrappedValue: MarkdownReaderSession(
                initialDocument: initialDocument,
                linkResolver: MarkdownLinkNavigator.makeResolver(
                    context: .fileBrowser,
                    onSelectInFileTree: { resolvedURL in
                        if let matchingNode = store.node(for: resolvedURL) {
                            selectedNode.wrappedValue = matchingNode
                        }
                    }
                )
            )
        )
    }

    var body: some View {
        let activeURL = session.currentDocument.sourceURL ?? node.url
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.currentDocument.title)
                        .font(.title2.weight(.semibold))
                    Text(activeURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    session.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(!session.canGoBack)

                Button {
                    session.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(!session.canGoForward)

                Button("Open in Editor") { NSWorkspace.shared.open(activeURL) }
                    .buttonStyle(.borderedProminent)
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([activeURL]) }) {
                    Label("Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            Divider()
                .padding(.top, 18)
                .padding(.bottom, 20)

            MarkdownReaderView(session: session)
        }
        .padding(24)
        .task(id: node.url) {
            let document = (try? MarkdownDocumentSource.fromFileURL(node.url, context: .fileBrowser))
                ?? MarkdownDocumentSource(
                    title: node.url.deletingPathExtension().lastPathComponent,
                    markdown: "(unreadable)",
                    sourceURL: node.url,
                    context: .fileBrowser
                )
            session.setDocument(document, resetHistory: true)
        }
        .navigationTitle(node.name)
    }
}

// MARK: - Generic file detail

struct GenericFileDetailView: View {
    let node: FileNode

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: node.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                Button("Open") { NSWorkspace.shared.open(node.url) }
                    .buttonStyle(.borderedProminent)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(node.name)
    }
}
