import Combine
import Foundation
import SwiftUI
import WebKit

// MARK: - Shared WKWebView holder

/// Keeps a WKWebView alive across SwiftUI re-renders.
final class WebViewHolder: ObservableObject {
    let webView: WKWebView

    init(usesPersistentStore: Bool = true, schemeHandler: (WKWebViewConfiguration) -> Void = { _ in }) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = usesPersistentStore ? .default() : .nonPersistent()
        schemeHandler(config)
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        self.webView = WKWebView(frame: .zero, configuration: config)
    }
}

// MARK: - 3D Editor detail view (SwiftUI)

struct ThreeEditorDetailView: View {
    @StateObject private var holder = WebViewHolder(usesPersistentStore: false) {
        $0.setURLSchemeHandler(ZenithFileSchemeHandler(), forURLScheme: "zenith-file")
    }
    @StateObject private var store = FormsCatalogStore()
    @StateObject private var vm    = FormsEditorViewModel()

    var body: some View {
        FormsEditorContentView(webView: holder.webView, store: store, vm: vm)
            .onAppear { vm.attach(webView: holder.webView, store: store) }
    }
}

/// Drives the editor: loads the renderer viewer with catalog item hash when selection changes.
@MainActor
final class FormsEditorViewModel: ObservableObject {
    private var cancellable: AnyCancellable?
    private weak var webView: WKWebView?

    func attach(webView: WKWebView, store: FormsCatalogStore) {
        guard self.webView == nil else { return }
        self.webView = webView

        // Load default item
        if let defaultItem = store.items.first(where: { $0.id == "mesh/default_box" }) {
            loadItem(defaultItem)
        }

        cancellable = store.$selected
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] item in self?.loadItem(item) }
    }

    func captureRuntimeDiagnostics(context: String) {
        guard let wv = webView else {
            NSLog("FormsRuntimeDiagnostics context=%@ error=missing-webview", context)
            return
        }

        let js = """
        (() => {
          const canvas = document.querySelector('#forms-canvas');
          const probe = document.createElement('canvas');
          const result = {
            context: "\(context)",
            href: location.href,
            isSecureContext: window.isSecureContext,
            navigatorGpuType: typeof navigator.gpu,
            formsCurrentCatalogItem: window.Forms?.currentCatalogItem ?? null,
            formsExportObjType: typeof window.Forms?.exportObj,
            statusText: document.querySelector('#status')?.textContent ?? null,
            canvas: canvas ? {
              clientWidth: canvas.clientWidth,
              clientHeight: canvas.clientHeight,
              width: canvas.width,
              height: canvas.height
            } : null,
            offscreenWebGPU: null,
            offscreenWebGPUError: null,
            offscreenWebGL2: null,
            offscreenWebGL2Error: null
          };

          try {
            const gpu = probe.getContext('webgpu');
            result.offscreenWebGPU = gpu ? Object.prototype.toString.call(gpu) : null;
          } catch (error) {
            result.offscreenWebGPUError = String(error?.message || error);
          }

          try {
            const gl = probe.getContext('webgl2');
            result.offscreenWebGL2 = gl ? gl.getParameter(gl.VERSION) : null;
            const loseContext = gl?.getExtension('WEBGL_lose_context');
            if (loseContext) loseContext.loseContext();
          } catch (error) {
            result.offscreenWebGL2Error = String(error?.message || error);
          }

          return JSON.stringify(result);
        })()
        """

        wv.evaluateJavaScript(js) { result, error in
            if let error {
                NSLog("FormsRuntimeDiagnostics context=%@ error=%@", context, String(describing: error))
                return
            }
            NSLog("FormsRuntimeDiagnostics %@", String(describing: result ?? "null"))
        }
    }

    private func loadItem(_ item: CatalogItem) {
        guard let wv = webView else { return }
        wv.stopLoading()
        wv.load(formsViewerRequest(for: item))
    }
}

private struct FormsEditorContentView: View {
    let webView: WKWebView
    @ObservedObject var store: FormsCatalogStore
    @ObservedObject var vm:    FormsEditorViewModel

    var body: some View {
        HSplitView {
            FormsCatalogView(store: store)
                .frame(minWidth: 180, maxWidth: 260)

            WebViewRepresentable(webView: webView) {
                vm.captureRuntimeDiagnostics(context: "ThreeEditorDetailView.didFinish")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    vm.captureRuntimeDiagnostics(context: "ThreeEditorDetailView.didFinish+1s")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    vm.captureRuntimeDiagnostics(context: "ThreeEditorDetailView.didFinish+3s")
                }
            }
        }
    }
}

// MARK: - Three.js DevTools detail view

struct ThreeDevToolsDetailView: View {
    @StateObject private var holder    = WebViewHolder()
    @StateObject private var serverMgr = DevServerManager()

    var body: some View {
        ThreeInspectorView(webView: holder.webView, serverMgr: serverMgr)
    }
}
