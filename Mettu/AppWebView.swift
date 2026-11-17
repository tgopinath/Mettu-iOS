import SwiftUI
import WebKit
import SafariServices
import AVFoundation

/// The live Mettu web app in a WKWebView, set up to behave like a native iPhone app:
/// edge swipe to go back, inline media, sound without a tap first, haptics from the page,
/// JavaScript alerts as iOS alerts, and outside links in Safari's in-app viewer.
/// Generated from the Kolam iOS shell template (kolam-design-system/ios/shell-template).
struct AppWebView: UIViewRepresentable {
    static let home: URL = {
        #if DEBUG
        // Debug builds only: `simctl launch <device> <bundle> -KolamStartURL "<url>"` opens another route (for screenshots).
        if let s = UserDefaults.standard.string(forKey: "KolamStartURL"), let u = URL(string: s) { return u }
        #endif
        return URL(string: "https://mettu.vercel.app/")!
    }()
    /// Hosts that stay inside the app; every other http(s) link opens in Safari's viewer.
    static let appHosts: Set<String> = ["mettu.vercel.app"]

    let url: URL
    @Binding var loading: Bool
    @Binding var failed: Bool
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // "Mettu-iOS" + "Kolam-iOS" let the page's kolam-ios.js turn on the iOS look.
        config.applicationNameForUserAgent = "Mettu-iOS/1.0 Kolam-iOS/1.0 Mobile/15E148"
        config.userContentController.add(context.coordinator, name: "haptic")
        // Mettu: "Export ringtone" (.m4r + share sheet), because iPhone apps cannot set the system ringtone.
        config.userContentController.addScriptMessageHandler(RingtoneExporter(), contentWorld: .page, name: "ringtone")
        config.userContentController.addUserScript(WKUserScript(source: Self.shellScript(),
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true      // swipe from the left edge to go back
        web.allowsLinkPreview = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(named: "LaunchBackground")
        #if DEBUG
        web.isInspectable = true                             // Safari ▸ Develop, for debugging
        #endif
        web.load(URLRequest(url: url))
        context.coordinator.lastToken = reloadToken
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {    // "Try Again" after being offline
            context.coordinator.lastToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }

    /// window.KolamShell tells the kit it runs in this shell, and passes accessibility settings
    /// that have no CSS media query in WebKit yet.
    static func shellScript() -> String {
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled ? "true" : "false"
        let boldText = UIAccessibility.isBoldTextEnabled ? "true" : "false"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return """
        window.KolamShell = { platform: 'ios', app: 'Mettu', version: '\(version)', nativeBack: true,
          reduceTransparency: \(reduceTransparency), boldText: \(boldText) };
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: AppWebView
        var lastToken = 0
        init(_ parent: AppWebView) { self.parent = parent }

        // MARK: Loading state
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.failed = true }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()                                 // iOS reclaimed memory in the background
        }

        // MARK: Links: the app stays in the web view; other sites open in Safari's viewer
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["mailto", "tel", "sms", "facetime", "maps", "itms-apps"].contains(scheme) {
                UIApplication.shared.open(url)
                return decisionHandler(.cancel)
            }
            let isApp = url.host.map { AppWebView.appHosts.contains($0) } ?? true
            if action.navigationType == .linkActivated && !isApp && (scheme == "https" || scheme == "http") {
                openInSafari(url, from: webView)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // target="_blank" links and window.open()
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = action.request.url else { return nil }
            if let host = url.host, AppWebView.appHosts.contains(host) { webView.load(URLRequest(url: url)) }
            else { openInSafari(url, from: webView) }
            return nil
        }

        private func openInSafari(_ url: URL, from view: UIView) {
            guard let root = view.window?.rootViewController else { return }
            let safari = SFSafariViewController(url: url)
            safari.preferredControlTintColor = UIColor(named: "AccentColor")
            (root.presentedViewController ?? root).present(safari, animated: true)
        }

        // MARK: JavaScript alert() / confirm() as iOS alerts (WKWebView shows nothing otherwise)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            present(alert, from: webView, orElse: completionHandler)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            present(alert, from: webView) { completionHandler(false) }
        }
        private func present(_ vc: UIViewController, from view: UIView, orElse fallback: @escaping () -> Void) {
            guard let root = view.window?.rootViewController else { return fallback() }
            (root.presentedViewController ?? root).present(vc, animated: true)
        }

        // Camera and microphone for the app's own pages: iOS asks once; the page then gets it.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(AppWebView.appHosts.contains(origin.host) ? .grant : .prompt)
        }

        // MARK: Haptics requested by the page (KolamIOS.haptic(kind))
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "haptic" else { return }
            switch message.body as? String ?? "light" {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
}

/// Mettu only. iOS does not let any app set the system ringtone, so the page hands over the finished
/// tone (WAV) and this turns it into an .m4r ringtone file (AAC in MPEG-4, at most 40 seconds, which
/// is the iPhone ringtone limit) and opens the share sheet: Save to Files, AirDrop to a Mac for Finder,
/// or GarageBand (`format: "m4a"`, which GarageBand's file browser opens). `format: "file"` shares the given file as it is (WAV/MP3 export).
/// JS: `await webkit.messageHandlers.ringtone.postMessage({ data: base64, ext: "wav", name, format: "m4r" })`
/// resolves to the chosen activity type, or "cancelled".
final class RingtoneExporter: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let b64 = body["data"] as? String,
              let data = Data(base64Encoded: b64) else { return replyHandler(nil, "bad-data") }
        let name = Self.safeName(body["name"] as? String ?? "Mettu tone")
        let ext = (body["ext"] as? String ?? "wav").filter { $0.isLetter || $0.isNumber }
        let format = body["format"] as? String ?? "m4r"
        let toRingtone = format == "m4r" || format == "m4a"   // m4a = the same AAC audio for GarageBand's file browser
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tones", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("source.\(ext)")
        do { try data.write(to: src) } catch { return replyHandler(nil, "write-failed") }
        weak var web = message.webView

        guard toRingtone else {
            let out = dir.appendingPathComponent("\(name).\(ext)")
            try? FileManager.default.moveItem(at: src, to: out)
            return share(out, from: web, reply: replyHandler)
        }
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return replyHandler(nil, "no-encoder")
        }
        let m4a = dir.appendingPathComponent("tone.m4a")
        export.outputURL = m4a
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(asset.duration, CMTime(seconds: 40, preferredTimescale: 600)))
        export.exportAsynchronously {
            DispatchQueue.main.async {
                guard export.status == .completed else {
                    return replyHandler(nil, export.error?.localizedDescription ?? "export-failed")
                }
                let out = dir.appendingPathComponent("\(name).\(format)")   // an .m4r is AAC audio in an MPEG-4 file
                try? FileManager.default.moveItem(at: m4a, to: out)
                self.share(out, from: web, reply: replyHandler)
            }
        }
    }

    private func share(_ url: URL, from web: WKWebView?, reply: @escaping (Any?, String?) -> Void) {
        var top = web?.window?.rootViewController
        while let p = top?.presentedViewController { top = p }
        guard let top, let web else { return reply(nil, "no-window") }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { type, completed, _, _ in
            reply(completed ? (type?.rawValue ?? "done") : "cancelled", nil)
        }
        if let pop = sheet.popoverPresentationController {   // iPad
            pop.sourceView = web
            pop.sourceRect = CGRect(x: web.bounds.midX, y: web.bounds.maxY - 120, width: 1, height: 1)
        }
        top.present(sheet, animated: true)
    }

    private static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let clean = s.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespaces)
        return String((clean.isEmpty ? "Mettu tone" : clean).prefix(40))
    }
}
