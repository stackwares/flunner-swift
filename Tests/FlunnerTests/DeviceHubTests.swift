import XCTest
import WebKit
@testable import Flunner

@MainActor
final class DeviceHubTests: XCTestCase {
    func testDiscoversOnlyTheLocalServerPort() {
        XCTAssertEqual(DeviceHubService.serverURL(in: "Expo Device Hub ready\n  Local:   http://localhost:57982\n  Network: pass --host 0.0.0.0")?.absoluteString, "http://127.0.0.1:57982/")
        XCTAssertNil(DeviceHubService.serverURL(in: "Network: http://example.com:3400"))
        XCTAssertNil(DeviceHubService.serverURL(in: "Local: http://localhost:0"))
        XCTAssertNil(DeviceHubService.serverURL(in: "Local: http://localhost:99999"))
    }

    func testPreviewDoesNotInheritAnotherHostsRemoteOrRecordingConfiguration() {
        let environment = DeviceHubService.environment(
            node: URL(fileURLWithPath: "/opt/node/bin/node"),
            inherited: ["PATH": "/usr/bin:/bin", "ANDROID_SDK_ROOT": "/custom/android", "EXPO_DEVICE_HUB_BASE_PATH": "/remote", "EXPO_DEVICE_HUB_TRANSPORT": "webrtc", "EXPO_DEVICE_HUB_SCREENSHOT_DIRECTORY": "/private/recordings", "KEEP_ME": "value"],
            home: URL(fileURLWithPath: "/test")
        )
        XCTAssertEqual(environment["ANDROID_HOME"], "/custom/android")
        XCTAssertEqual(environment["ANDROID_SDK_ROOT"], "/custom/android")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/node/bin:/custom/android/platform-tools:/custom/android/emulator:") == true)
        XCTAssertEqual(environment["KEEP_ME"], "value")
        XCTAssertFalse(environment.keys.contains { $0.hasPrefix("EXPO_DEVICE_HUB_") })
    }

    func testWebViewDoesNotNavigateAwayFromItsOwnLocalServer() {
        let origin = URL(string: "http://127.0.0.1:3400/")!
        XCTAssertTrue(DeviceHubWebView.Coordinator.isLocalNavigation(URL(string: "http://127.0.0.1:3400/vendor/serve-sim/")!, origin: origin))
        XCTAssertTrue(DeviceHubWebView.Coordinator.isLocalNavigation(URL(string: "about:blank")!, origin: origin))
        for url in ["http://127.0.0.1:3401/", "http://localhost:3400/", "https://example.com/", "file:///etc/passwd"] {
            XCTAssertFalse(DeviceHubWebView.Coordinator.isLocalNavigation(URL(string: url)!, origin: origin))
        }
    }

    func testExportBridgeDecodesBytesAndCannotChooseAPathFromTheRenderer() {
        let data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let file = DeviceHubWebView.Coordinator.decodeExport(["filename": "../../screenshot.png", "data": "data:image/png;base64,\(data.base64EncodedString())"])
        XCTAssertEqual(file?.filename, "screenshot.png")
        XCTAssertEqual(file?.data, data)
        XCTAssertNil(DeviceHubWebView.Coordinator.decodeExport(["filename": "screenshot.png", "data": "https://example.com/screenshot.png"]))
        XCTAssertNil(DeviceHubWebView.Coordinator.decodeExport(["filename": "screenshot.png", "data": "data:image/png;base64,broken"]))
    }

    func testKeyboardBridgeRejectsInvalidDeviceAndKeyPackets() {
        let device = UUID().uuidString
        XCTAssertEqual(DeviceHubWebView.Coordinator.decodeKey(["device": device, "usage": 225, "phase": "down"])?.usage, 225)
        XCTAssertEqual(DeviceHubWebView.Coordinator.decodeKey(["device": device, "usage": 4, "phase": "up"])?.down, false)
        for packet: [String: Any] in [
            ["device": "not-a-simulator", "usage": 4, "phase": "down"],
            ["device": device, "usage": -1, "phase": "down"],
            ["device": device, "usage": 256, "phase": "down"],
            ["device": device, "usage": 4, "phase": "repeat"]
        ] { XCTAssertNil(DeviceHubWebView.Coordinator.decodeKey(packet)) }
    }

    func testWebKitKeyboardBridgeOrdersKeysAndFallsBackWithoutChangingOtherInput() async throws {
        let loaded = expectation(description: "Keyboard page loaded")
        let keys = expectation(description: "Ordered native keys")
        keys.expectedFulfillmentCount = 4
        let recorder = KeyboardRecorder(loaded: loaded, keys: keys)
        recorder.handled = { $0["usage"] as? Int != 7 }
        let browser = keyboardBrowser(recorder)
        defer { browser.configuration.userContentController.removeScriptMessageHandler(forName: "flunnerKeyboard") }
        browser.loadHTMLString("<div role='application' tabindex='0' id='screen'></div>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let result = try await browser.callAsyncJavaScript("""
        const device = '6D6E0A19-F084-46BF-B47F-45F4BF96454A';
        const ios = new WebSocket('ws://127.0.0.1:3400/vendor/serve-sim/helper/ws?device=' + device);
        const android = new WebSocket('ws://127.0.0.1:3400/serve-emu/ws');
        ios.send(packet(6, {type:'down',usage:27}).buffer);
        ios.send(packet(6, {type:'up',usage:27}));
        ios.send(packet(6, {type:'down',usage:7}));
        ios.send(packet(6, {type:'up',usage:7}));
        ios.send(packet(3, {type:'begin',x:0.5,y:0.5}));
        ios.send(packet(6, {type:'down',usage:999}));
        android.send(packet(6, {type:'down',usage:4}));
        for (let i=0; i<200 && ios.sent.length<4; i++) await new Promise(resolve => setTimeout(resolve,10));
        return {ios:ios.sent.map(decode),android:android.sent.map(decode)};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        await fulfillment(of: [keys], timeout: 10)
        XCTAssertEqual(recorder.events.map { $0["phase"] as? String }, ["down", "up", "down", "up"])
        XCTAssertEqual(recorder.events.map { $0["usage"] as? Int }, [27, 27, 7, 7])
        let sent = result?["ios"] as? [[String: Any]]
        XCTAssertEqual(sent?.count, 4)
        XCTAssertEqual(sent?.first?["header"] as? Int, 3, "Touch packets retain the upstream transport.")
        XCTAssertEqual(sent?.dropFirst().first?["usage"] as? Int, 999)
        XCTAssertEqual(sent?.suffix(2).map { $0["type"] as? String }, ["down", "up"])
        XCTAssertEqual(sent?.suffix(2).map { $0["usage"] as? Int }, [7, 7], "Unavailable native input falls back in order.")
        XCTAssertEqual((result?["android"] as? [[String: Any]])?.count, 1)
    }

    func testWebKitKeyboardBridgeRepairsKeyStateAcrossModifiersAndFocusChanges() async throws {
        let loaded = expectation(description: "Modifier page loaded")
        let keys = expectation(description: "Modifier keys delivered")
        keys.expectedFulfillmentCount = 22
        let recorder = KeyboardRecorder(loaded: loaded, keys: keys)
        let browser = keyboardBrowser(recorder)
        defer { browser.configuration.userContentController.removeScriptMessageHandler(forName: "flunnerKeyboard") }
        browser.loadHTMLString("<div role='application' tabindex='0' id='screen'></div>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await browser.callAsyncJavaScript("""
          const ios = new WebSocket('ws://127.0.0.1:3400/vendor/serve-sim/helper/6D6E0A19-F084-46BF-B47F-45F4BF96454A/ws');
          const screen = document.getElementById('screen');
          for (const phase of ['keydown','keyup']) screen.addEventListener(phase, e => {
            // Native WebKit dispatch can run a microtask checkpoint between
            // the document capture listener and React's root listener.
            queueMicrotask(() => ios.send(packet(6,{type:phase === 'keydown' ? 'down' : 'up',usage:e.code === 'ShiftLeft' ? 225 : 4})));
          });
          const key = async (type,code,shiftKey,metaKey=false) => {
            screen.dispatchEvent(new KeyboardEvent(type,{code,shiftKey,metaKey,bubbles:true}));
            await Promise.resolve();
          };
          await key('keydown','KeyA',true); await key('keyup','KeyA',false);
          await key('keydown','ShiftLeft',true); await key('keyup','ShiftLeft',false);
          await key('keydown','KeyA',true);
          screen.dispatchEvent(new FocusEvent('focusout',{bubbles:true}));
          // A fresh physical press repairs a keyup dropped by the host.
          await key('keydown','KeyA',false); await key('keydown','KeyA',false); await key('keyup','KeyA',false);
          // Command+A may lose its letter keyup before a subsequent Shift+A.
          await key('keydown','KeyA',false,true);
          await key('keydown','KeyA',true); await key('keyup','KeyA',false);
          return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [keys], timeout: 10)
        XCTAssertEqual(recorder.events.map { $0["usage"] as? Int }, [225,4,4,225,225,225,225,4,225,4, 4,4,4,4, 227,4,4,227,225,4,4,225])
        XCTAssertEqual(recorder.events.map { $0["phase"] as? String }, ["down","down","up","up","down","up","down","down","up","up", "down","up","down","up", "down","down","up","up","down","down","up","up"])
    }

    private func keyboardBrowser(_ recorder: KeyboardRecorder) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(recorder, contentWorld: .page, name: "flunnerKeyboard")
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.WebSocket = class extends EventTarget {
          static OPEN = 1;
          constructor(url) { super(); this.url=url; this.readyState=1; this.sent=[]; }
          send(data) { this.sent.push(Array.from(data instanceof ArrayBuffer ? new Uint8Array(data) : data)); }
        };
        window.packet = (header,event) => {
          const json = new TextEncoder().encode(JSON.stringify(event));
          const bytes = new Uint8Array(json.length+1); bytes[0]=header; bytes.set(json,1); return bytes;
        };
        window.decode = bytes => ({header:bytes[0],...JSON.parse(new TextDecoder().decode(new Uint8Array(bytes.slice(1))))});
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: DeviceHubWebView.keyboardBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = recorder
        return browser
    }

    func testScreenshotExportAtomicallyReplacesTheApprovedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flunner-export-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("screenshot.png")
        try Data("original".utf8).write(to: url)
        let replacement = Data("replacement".utf8)
        try DeviceHubWebView.Coordinator.writeExport(replacement, to: url)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["screenshot.png"])
    }

    func testWebKitExportBridgePreservesTheBlobUntilNativeReceivesIt() async throws {
        // Match upstream's click/remove/revoke-on-next-tick download sequence.
        // This exercises the actual injected bridge in WebKit, without a modal
        // Save panel or a simulator being required for the test.
        let loaded = expectation(description: "Page loaded")
        let exported = expectation(description: "Native export received")
        let recorder = ExportRecorder(loaded: loaded, exported: exported)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(recorder, name: "flunnerFileExport")
        configuration.userContentController.addUserScript(WKUserScript(source: DeviceHubWebView.embedStyle(compact: false), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = recorder
        defer {
            browser.stopLoading()
            browser.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "flunnerFileExport")
        }
        browser.loadHTMLString("<html><body><div id='root'></div></body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        _ = try await browser.evaluateJavaScript("""
        (() => {
          const blob = new Blob([new Uint8Array([137,80,78,71,13,10,26,10])], {type:'image/png'});
          const url = URL.createObjectURL(blob), link = document.createElement('a');
          link.href = url; link.download = 'device.png'; document.body.appendChild(link);
          link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 0);
        })();
        """)
        await fulfillment(of: [exported], timeout: 10)
        let file = DeviceHubWebView.Coordinator.decodeExport(recorder.body as Any)
        XCTAssertEqual(file?.filename, "device.png")
        XCTAssertEqual(file?.data, Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testServerStopsAndCanReconnectWithoutShuttingDownDevices() async throws {
        guard ["/opt/homebrew/bin/node", "/usr/local/bin/node"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Node.js is required for the local server lifecycle integration test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flunner-hub-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("node_modules/expo-device-hub/dist/server/cli.mjs")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        import http from 'node:http';
        const server = http.createServer((req, res) => res.end('preview'));
        server.listen(0, '127.0.0.1', () => console.log('Local: http://localhost:' + server.address().port));
        process.on('SIGTERM', () => server.close(() => process.exit(0)));
        """.write(to: cli, atomically: true, encoding: .utf8)
        let service = DeviceHubService(directory: directory)
        defer { service.stop() }
        let firstPane = UUID()
        let secondPane = UUID()
        service.openPane(firstPane)
        let first = try await readyURL(service)
        service.openPane(secondPane)
        service.closePane(firstPane)
        XCTAssertEqual(service.state, .ready(first), "Closing one window must not stop another window's preview.")
        service.closePane(secondPane)
        XCTAssertEqual(service.state, .idle)
        service.openPane(firstPane)
        let second = try await readyURL(service)
        XCTAssertNotEqual(first, second)
        service.closePane(firstPane)
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await URLSession.shared.data(for: URLRequest(url: second, timeoutInterval: 1))
            XCTFail("Closing the pane must stop its server.")
        } catch { /* Connection refused verifies cleanup. */ }
    }

    private func readyURL(_ service: DeviceHubService) async throws -> URL {
        for _ in 0..<150 {
            if case .ready(let url) = service.state { return url }
            if case .failed(let message) = service.state { throw NSError(domain: "DeviceHubTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "DeviceHubTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Server never became ready"])
    }
}

@MainActor
private final class ExportRecorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let loaded: XCTestExpectation
    let exported: XCTestExpectation
    var body: Any?

    init(loaded: XCTestExpectation, exported: XCTestExpectation) {
        self.loaded = loaded
        self.exported = exported
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        body = message.body
        exported.fulfill()
    }
}

@MainActor
private final class KeyboardRecorder: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let loaded: XCTestExpectation
    let keys: XCTestExpectation
    var events: [[String: Any]] = []
    var handled: ([String: Any]) -> Bool = { _ in true }

    init(loaded: XCTestExpectation, keys: XCTestExpectation) { self.loaded = loaded; self.keys = keys }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let event = message.body as? [String: Any] else { replyHandler(false, nil); return }
        events.append(event)
        replyHandler(handled(event), nil)
        keys.fulfill()
    }
}
