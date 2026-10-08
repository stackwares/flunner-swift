import AppKit
import SwiftUI
import WebKit
import SimulatorKeyboard

/// Keeps the same browser and device selection when the native split changes
/// from horizontal to vertical. Each workspace window owns a separate session.
@MainActor
final class DeviceHubWebSession: ObservableObject {
    @Published private(set) var reloadID = UUID()
    var webView: WKWebView?
    let coordinator = DeviceHubWebView.Coordinator(onError: { _ in })

    func reload() { reloadID = UUID() }

    func reset() {
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "flunnerFileExport")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "flunnerKeyboard")
        Task { await coordinator.keyboard.releaseAll() }
        webView = nil
        coordinator.loadedURL = nil
        coordinator.reloadID = nil
        coordinator.onError = { _ in }
    }
}

/// Uses the upstream input/accessibility implementation rather than recreating
/// simulator gestures. Styling targets semantic elements and stable test IDs
/// in the pinned Device Hub release. iOS keys use a guarded native transport;
/// touch, video, and Android input keep the upstream streaming protocol.
struct DeviceHubWebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var session: DeviceHubWebSession
    var compact = true
    var onError: (String?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { session.coordinator }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = session.webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "flunnerFileExport")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "flunnerKeyboard")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.keyboardBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.embedStyle(compact: compact), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = NSColor(named: "WorkbenchBackground") ?? .windowBackgroundColor
        session.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.allowedOrigin = url
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        webView.appearance = NSAppearance(named: appearance)
        if context.coordinator.loadedURL != url || context.coordinator.reloadID != session.reloadID {
            context.coordinator.loadedURL = url
            context.coordinator.reloadID = session.reloadID
            Task { await context.coordinator.keyboard.releaseAll() }
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The window's session owns cleanup. Removing this representable may
        // just be reparenting the browser into the other split orientation.
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        let keyboard = SimulatorKeyboard()
        var loadedURL: URL?
        var allowedOrigin: URL?
        var reloadID: UUID?
        var onError: (String?) -> Void
        private var downloads: [ObjectIdentifier: WKDownload] = [:]

        init(onError: @escaping (String?) -> Void) { self.onError = onError }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.name == "flunnerKeyboard", message.frameInfo.isMainFrame,
                  let origin = message.frameInfo.request.url,
                  Self.isLocalNavigation(origin, origin: allowedOrigin),
                  let event = Self.decodeKey(message.body) else { replyHandler(false, nil); return }
            Task {
                let handled = await keyboard.send(device: event.device, usage: event.usage, down: event.down)
                replyHandler(handled, nil)
            }
        }

        static func decodeKey(_ body: Any) -> (device: String, usage: UInt32, down: Bool)? {
            guard let body = body as? [String: Any], let device = body["device"] as? String,
                  UUID(uuidString: device) != nil, let usage = body["usage"] as? Int,
                  (0...255).contains(usage), let phase = body["phase"] as? String,
                  phase == "down" || phase == "up" else { return nil }
            return (device, UInt32(usage), phase == "down")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "flunnerFileExport", message.frameInfo.isMainFrame else { return }
            guard let file = Self.decodeExport(message.body) else {
                showExportError("The file could not be exported. Please try again.", window: message.webView?.window)
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.filename
            panel.canCreateDirectories = true
            panel.begin { [weak self] result in
                guard result == .OK, let chosen = panel.url else { return }
                let scoped = chosen.startAccessingSecurityScopedResource()
                defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
                do { try Self.writeExport(file.data, to: chosen) }
                catch { self?.showExportError(error.localizedDescription, window: message.webView?.window) }
            }
        }

        static func decodeExport(_ body: Any) -> (filename: String, data: Data)? {
            guard let body = body as? [String: String], let name = body["filename"],
                  let encoded = body["data"], encoded.utf8.count <= 64 * 1024 * 1024,
                  encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ","),
                  encoded[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])), !data.isEmpty else { return nil }
            let filename = URL(fileURLWithPath: name).lastPathComponent
            guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
            return (filename, data)
        }

        static func writeExport(_ data: Data, to url: URL) throws {
            try data.write(to: url, options: .atomic)
        }

        private func showExportError(_ message: String, window: NSWindow?) {
            let alert = NSAlert()
            alert.messageText = "Could not save the file"
            alert.informativeText = message
            if let window { alert.beginSheetModal(for: window) }
            else { onError(message) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onError(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onError("The device view stopped responding. Reload the preview to reconnect.")
        }

        private func report(_ error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            guard let destination = navigationAction.request.url else { decisionHandler(.cancel); return }
            if Self.isLocalNavigation(destination, origin: allowedOrigin) {
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(destination.scheme) {
                    NSWorkspace.shared.open(destination)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            downloads[ObjectIdentifier(download)] = download
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
            panel.canCreateDirectories = true
            panel.begin { result in completionHandler(result == .OK ? panel.url : nil) }
        }

        func downloadDidFinish(_ download: WKDownload) {
            downloads.removeValue(forKey: ObjectIdentifier(download))
        }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloads.removeValue(forKey: ObjectIdentifier(download))
            report(error)
        }

        static func isLocalNavigation(_ destination: URL, origin: URL?) -> Bool {
            if destination.absoluteString == "about:blank" { return true }
            guard let origin else { return false }
            return destination.scheme == origin.scheme && destination.host == origin.host && destination.port == origin.port
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            guard let window = webView.window else { completionHandler(); return }
            alert.beginSheetModal(for: window) { _ in completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard let window = webView.window else { completionHandler(false); return }
            alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
        }
    }

    // Xcode 27's standard iPhones silently drop legacy Indigo keyboard events.
    // Keep upstream's focus/key mapping, but deliver iOS key packets through
    // CoreDevice. Each socket preserves ordering and falls back when unavailable.
    static let keyboardBridge = #"""
    (() => {
      const send = WebSocket.prototype.send;
      const queues = new WeakMap();
      const sockets = new Map();
      const modifiers = [[224,228,'ctrlKey'], [225,229,'shiftKey'], [226,230,'altKey'], [227,231,'metaKey']];
      let keyboardEvent;
      for (const phase of ['keydown', 'keyup']) document.addEventListener(phase, event => {
        if (!event.target.closest?.('[role="application"]')) return;
        keyboardEvent = event;
        // A native event runs a microtask checkpoint between DOM listeners.
        // Keep its flags through React's handler on the next propagation step.
        setTimeout(() => { if (keyboardEvent === event) keyboardEvent = null; }, 0);
      }, true);
      const packet = event => {
        const json = new TextEncoder().encode(JSON.stringify(event));
        const data = new Uint8Array(json.length + 1);
        data[0] = 6; data.set(json, 1);
        return data;
      };
      const enqueue = (socket, device, event, data = packet(event)) => {
        const state = sockets.get(socket);
        if (state) {
          if (event.type === 'down') state.pressed.add(event.usage);
          else state.pressed.delete(event.usage);
        }
        const fallback = () => { if (socket.readyState === WebSocket.OPEN) send.call(socket, data); };
        const operation = (queues.get(socket) || Promise.resolve()).then(async () => {
          if (socket.readyState !== WebSocket.OPEN && event.type === 'down') return;
          try {
            const handled = await window.webkit.messageHandlers.flunnerKeyboard.postMessage({
              device, usage: event.usage, phase: event.type
            });
            if (!handled) fallback();
          } catch { fallback(); }
        });
        queues.set(socket, operation);
      };
      const releaseKeys = socket => {
        const state = sockets.get(socket);
        if (!state) return;
        for (const usage of state.pressed) enqueue(socket, state.device, {type:'up', usage});
        state.held.clear();
      };
      window.addEventListener('blur', () => { for (const socket of sockets.keys()) releaseKeys(socket); });
      document.addEventListener('focusout', event => {
        if (event.target.closest?.('[role="application"]'))
          for (const socket of sockets.keys()) releaseKeys(socket);
      });
      WebSocket.prototype.send = function(data) {
        let event, device;
        try {
          const url = new URL(this.url);
          if (!url.pathname.includes('/serve-sim/helper/')) return send.call(this, data);
          const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
            : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
          if (!bytes || bytes[0] !== 6) return send.call(this, data);
          event = JSON.parse(new TextDecoder().decode(bytes.subarray(1)));
          device = url.searchParams.get('device') || url.pathname.match(/helper\/([^/]+)\/ws$/)?.[1];
          if (!device || !Number.isInteger(event.usage) || event.usage < 0 || event.usage > 255
              || !['down', 'up'].includes(event.type)) return send.call(this, data);
        } catch { return send.call(this, data); }
        let state = sockets.get(this);
        if (!state) {
          state = {device, held:new Set(), pressed:new Set()}; sockets.set(this, state);
          this.addEventListener('close', () => { releaseKeys(this); sockets.delete(this); }, {once:true});
        }
        const isModifier = event.usage >= 224 && event.usage <= 231;
        const releaseShortcutKeys = () => {
          for (const usage of state.pressed) if (usage < 224)
            enqueue(this, device, {type:'up', usage});
        };
        // macOS command equivalents can omit the letter's keyup. Finish the
        // old shortcut before releasing its modifier or pressing that key again.
        if (event.type === 'down' && keyboardEvent && !keyboardEvent.repeat && state.pressed.has(event.usage))
          enqueue(this, device, {type:'up', usage:event.usage});
        if (isModifier && event.type === 'up' && [224,228,227,231].includes(event.usage)) releaseShortcutKeys();
        const syncModifiers = () => {
          if (!keyboardEvent || isModifier) return;
          // Release the previous chord before pressing its replacement.
          for (const [left, right, flag] of modifiers) {
            const held = [left,right].filter(usage => state.held.has(usage));
            if (!keyboardEvent[flag] && held.length) {
              if (flag === 'metaKey' || flag === 'ctrlKey') releaseShortcutKeys();
              for (const usage of held) {
                state.held.delete(usage); enqueue(this, device, {type:'up', usage});
              }
            }
          }
          for (const [left, right, flag] of modifiers) {
            if (keyboardEvent[flag] && !state.held.has(left) && !state.held.has(right)) {
              state.held.add(left); enqueue(this, device, {type:'down', usage:left});
            }
          }
        };
        // WebKit can report modifiers only on the letter's KeyboardEvent.
        // Reconcile those flags without duplicating actual modifier packets.
        if (event.type === 'down') syncModifiers();
        enqueue(this, device, event, data);
        if (isModifier) {
          if (event.type === 'down') state.held.add(event.usage);
          else state.held.delete(event.usage);
        }
        if (event.type === 'up') syncModifiers();
      };
    })();
    """#

    static func embedStyle(compact: Bool) -> String {
        // The real device is the focal object. Keep the surrounding chrome quiet
        // and match the workbench, without putting a mock window around it.
        let density = compact ? """
        #root > div > section { padding: 12px !important; }
        [data-testid="device-frame-viewport"] { padding-top: 48px !important; padding-bottom: 70px !important; }
        [data-testid="device-frame-anchor"] > div:nth-child(2) { bottom: calc(100% + 16px) !important; }
        [data-testid="device-frame-anchor"] > div:nth-child(3) { top: calc(100% + 16px) !important; }
        """ : ""
        return """
        (() => {
          // Transfer generated files to AppKit instead of asking WebKit to
          // issue a file sandbox extension. Xcode 27 / macOS 27 can block in
          // that path after a Save panel's replacement confirmation.
          const click = HTMLAnchorElement.prototype.click;
          const revoke = URL.revokeObjectURL.bind(URL);
          const exports = new Set();
          URL.revokeObjectURL = url => { if (!exports.has(url)) revoke(url); };
          HTMLAnchorElement.prototype.click = function() {
            if (!this.download || !this.href.startsWith('blob:')) return click.call(this);
            const url = this.href, filename = this.download;
            exports.add(url);
            fetch(url).then(response => response.blob()).then(blob => new Promise((resolve, reject) => {
              const reader = new FileReader();
              reader.onload = () => resolve(reader.result);
              reader.onerror = reject;
              reader.readAsDataURL(blob);
            })).then(data => window.webkit.messageHandlers.flunnerFileExport.postMessage({filename, data}))
              .catch(() => window.webkit.messageHandlers.flunnerFileExport.postMessage({error: 'export_failed'}))
              .finally(() => { exports.delete(url); revoke(url); });
          };
          const style = document.createElement('style');
          style.textContent = `
            :root { --expo-font-sans: -apple-system, BlinkMacSystemFont, sans-serif;
              --expo-theme-background-default: #f3efe7; --expo-theme-background-subtle: #f3efe7;
              --expo-theme-background-element: #fbf9f4; --expo-theme-text-default: #25231f;
              --expo-theme-text-secondary: #706b61; --expo-theme-border-default: #d8d3c9; }
            :root.dark-theme, .dark-theme { --expo-theme-background-default: #171815; --expo-theme-background-subtle: #171815;
              --expo-theme-background-element: #20211d; --expo-theme-text-default: #f4f0e8;
              --expo-theme-text-secondary: #aaa49a; --expo-theme-border-default: #34362f; }
            \(density)
            button { box-shadow: none !important; }
            [data-testid="device-frame-anchor"] > div > button { background: transparent !important; border: none !important; border-radius: 0 !important; }
            [data-testid="device-frame-anchor"] > div > button [aria-hidden] { border: none !important; }
            button:focus-visible, [role="application"]:focus-visible { outline: 2px solid #9d7556 !important; outline-offset: 3px; }
            [role="toolbar"], [role="toolbar"] > div { background: transparent !important; border: none !important; box-shadow: none !important; }
            @media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation: none !important; transition: none !important; } }
          `;
          document.head.appendChild(style);
          // Compact panes start with the screen taking the available space.
          // Collapse only the first automatically docked inspector; its toggle
          // stays functional and subsequent user choices are left alone.
          if (\(compact)) {
            const observer = new MutationObserver(() => {
              const inspector = [...document.querySelectorAll('aside')].find(element => {
                const rect = element.getBoundingClientRect();
                return rect.right >= innerWidth - 2 && rect.width <= innerWidth - 320 && rect.width > 0;
              });
              const toggle = inspector?.querySelector('button[aria-label="Toggle sidebar"]');
              if (toggle) { observer.disconnect(); toggle.click(); }
            });
            observer.observe(document.getElementById('root'), { childList: true, subtree: true });
          }
        })();
        """
    }
}
