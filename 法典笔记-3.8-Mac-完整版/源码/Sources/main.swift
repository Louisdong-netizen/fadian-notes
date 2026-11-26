import Cocoa
import WebKit

// MARK: - Constants

private let appDisplayName = "法典笔记"
private let appVersion = "3.8"
private let homeFile = "app-home.html"

private let codexPages: [String: String] = [
    "constitution": "法典笔记.html",
    "cn-constitution": "法典笔记.html",
    "宪法": "法典笔记.html",
    "civil-code": "法典笔记-civil-code.html",
    "cn-civil-code": "法典笔记-civil-code.html",
    "民法典": "法典笔记-civil-code.html",
    "criminal-law": "法典笔记-criminal-law.html",
    "cn-criminal-law": "法典笔记-criminal-law.html",
    "刑法": "法典笔记-criminal-law.html",
    "cyber-law": "法典笔记-cyber-law.html",
    "cn-cyber-law": "法典笔记-cyber-law.html",
    "网络安全法": "法典笔记-cyber-law.html"
]

private let pageTitles: [String: String] = [
    homeFile: "首页",
    "法典笔记.html": "宪法",
    "法典笔记-civil-code.html": "民法典",
    "法典笔记-criminal-law.html": "刑法",
    "法典笔记-cyber-law.html": "网络安全法",
    "使用说明.html": "使用说明",
    "关系说明.html": "关系说明"
]

private let recordLastCodeScript = #"""
try {
  if (typeof DATA !== "undefined" && DATA && DATA.codex && DATA.codex.id) {
    localStorage.setItem("fadian-last-code", DATA.codex.id);
  }
} catch (e) {}
"""#

let bridgeScript = #"""
(function () {
  if (window.FadianShell && window.FadianShell.__native) return;
  var seq = 0;
  var callbacks = {};
  window.__fadianCallbacks = callbacks;
  window.__fadianResolve = function (id, ok, message) {
    var cb = callbacks[id];
    if (!cb) return;
    delete callbacks[id];
    if (ok) cb.resolve(message == null ? "" : message);
    else cb.reject(new Error(message || "操作失败"));
  };
  function call(op, payload) {
    return new Promise(function (resolve, reject) {
      var id = "cb" + (++seq);
      callbacks[id] = { resolve: resolve, reject: reject };
      payload.op = op;
      payload.id = id;
      window.webkit.messageHandlers.fadianShell.postMessage(payload);
    });
  }
  window.FadianShell = {
    __native: true,
    edition: "Mac 版",
    localService: true,
    saveText: function (name, text, type) {
      return call("saveText", { name: String(name), text: String(text), type: String(type || "") });
    },
    saveBytes: function (name, base64) {
      return call("saveBytes", { name: String(name), data: String(base64) });
    },
    copyText: function (text) {
      return call("copyText", { text: String(text) });
    },
    switchCodex: function (name) {
      window.webkit.messageHandlers.fadianShell.postMessage({ op: "switchCodex", name: String(name) });
    }
  };
  window.__fadianErrors = [];
  window.addEventListener("error", function (event) {
    var item = {
      message: String(event.message || "脚本错误"),
      source: String(event.filename || ""),
      line: event.lineno || 0
    };
    window.__fadianErrors.push(item);
    try {
      window.webkit.messageHandlers.fadianShell.postMessage({
        op: "jsError",
        message: item.message,
        source: item.source,
        line: item.line
      });
    } catch (_) {}
  });
  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    var text = reason && reason.message ? reason.message : String(reason);
    window.__fadianErrors.push({ message: "未处理的 Promise 拒绝：" + text, source: "", line: 0 });
  });
})();
"""#

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
                         WKDownloadDelegate {

    private var window: NSWindow!
    private var webView: WKWebView!
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var currentFile = homeFile
    private var webCacheCleared = false
    private var pageErrors: [String] = []

    private let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)

    // Command-line diagnostics (not shown to normal users).
    private var auditDirectory: String?
    private var snapshotPath: String?
    private var crossSnapshotPath: String?
    private var selftestMode: String?
    private var selftestStage = 0
    private var crossSearchTestRunning = false
    private var crossOpenStage = 0
    private var noteFixStage = 0
    private var selftestLog: [String: Any] = [:]
    private var auditPages: [String] = []
    private var auditResults: [[String: Any]] = []
    private var auditBusy = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()
        buildMainMenu()
        buildWindow()
        loadPage(homeFile)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if auditDirectory != nil || snapshotPath != nil {
            // Give the page a moment to settle before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.beginAuditIfNeeded()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Building UI

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        let isTestRun = selftestMode != nil || auditDirectory != nil || snapshotPath != nil
        configuration.websiteDataStore = isTestRun ? .nonPersistent() : .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "fadianShell")
        configuration.userContentController.addUserScript(
            WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: recordLastCodeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = false
        webView.autoresizingMask = [.width, .height]
        webView.pageZoom = CGFloat(UserDefaults.standard.double(forKey: "FadianPageZoom").nonZero ?? 1.0)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(appDisplayName) \(appVersion)"
        window.minSize = NSSize(width: 980, height: 640)
        window.center()
        window.setFrameAutosaveName("FadianNotesMainWindow")
        window.contentView = webView
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)

        let toolbar = NSToolbar(identifier: "FadianNotesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        self.window = window

    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于\(appDisplayName)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏\(appDisplayName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出\(appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "重新载入", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "实际大小", action: #selector(actualSize), keyEquivalent: "0")
        let zoomIn = viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        // Help menu
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        helpItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "使用说明", action: #selector(showGuide), keyEquivalent: "?")
        helpMenu.addItem(withTitle: "条文关系说明", action: #selector(showRelations), keyEquivalent: "")
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: "国家法律法规数据库", action: #selector(openLawDatabase), keyEquivalent: "")
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navReload, .flexibleSpace, .navHelp]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.navReload, .flexibleSpace, .navHelp]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = true
        item.target = self
        switch itemIdentifier {
        case .navReload:
            item.label = "重新载入"; item.paletteLabel = "重新载入"; item.toolTip = "重新载入（⌘R）"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入")
            item.action = #selector(reloadPage)
        case .navHelp:
            item.label = "使用说明"; item.paletteLabel = "使用说明"; item.toolTip = "打开使用说明"
            item.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "使用说明")
            item.action = #selector(showGuide)
        default:
            return nil
        }
        return item
    }

    // MARK: Navigation

    private func loadPage(_ filename: String, fragment: String? = nil) {
        currentFile = filename
        var url = webRoot.appendingPathComponent(filename)
        if let fragment, !fragment.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = fragment
            if let built = components?.url { url = built }
        }
        // WKWebView can serve a previous build's local HTML/CSS from its resource cache even after
        // the app bundle is replaced. Clear only resource caches (never localStorage) on the first
        // load of each process so a rebuilt app shows the current reader layout immediately.
        let load = { [weak self] in
            guard let self else { return }
            self.webView.loadFileURL(url, allowingReadAccessTo: self.webRoot)
            self.window.title = self.titleForCurrentPage()
        }
        if !webCacheCleared {
            webCacheCleared = true
            let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache]
            webView.configuration.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
                DispatchQueue.main.async(execute: load)
            }
        } else {
            load()
        }
    }

    private func titleForCurrentPage() -> String {
        if let name = pageTitles[currentFile], name != "首页" {
            return "\(appDisplayName) \(appVersion) · \(name)"
        }
        return "\(appDisplayName) \(appVersion)"
    }

    private func isInsideWebRoot(_ url: URL) -> Bool {
        let root = webRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if url.isFileURL {
            if isInsideWebRoot(url) {
                decisionHandler(.allow)
            } else {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if ["data", "blob", "about"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, url.isFileURL {
            currentFile = url.lastPathComponent
        }
        window.title = titleForCurrentPage()

        if let auditDirectory, !auditBusy, !auditPages.isEmpty {
            runAuditStep(outputDirectory: auditDirectory)
        } else if let snapshotPath, !auditBusy {
            auditBusy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.captureSnapshot(to: snapshotPath) { _ in
                    NSApp.terminate(nil)
                }
            }
        } else if let selftestMode {
            runSelftest(mode: selftestMode)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageErrors.append("导航失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageErrors.append("载入失败：\(error.localizedDescription)")
        showLoadError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func showLoadError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "页面未能载入"
        alert.informativeText = "\(error.localizedDescription)\n\n请退出后重新打开「\(appDisplayName)」。你的笔记保存在本机，不会被清空。"
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.isFileURL && isInsideWebRoot(url) {
            webView.load(navigationAction.request)
        } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = appDisplayName
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = appDisplayName
        alert.informativeText = message
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确定")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertSecondButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = appDisplayName
        alert.informativeText = prompt
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确定")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertSecondButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: WKDownloadDelegate

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        presentSavePanel(suggestedName: suggestedFilename, data: nil) { url in
            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSSound(named: "Glass")?.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        pageErrors.append("下载失败：\(error.localizedDescription)")
    }

    // MARK: Script bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "fadianShell", let body = message.body as? [String: Any] else { return }
        let op = body["op"] as? String ?? ""

        switch op {
        case "saveText":
            let name = body["name"] as? String ?? "法典笔记.txt"
            let text = body["text"] as? String ?? ""
            let callback = body["id"] as? String
            presentSavePanel(suggestedName: name, data: Data(text.utf8)) { url in
                self.finishSave(callback: callback, url: url, error: nil)
            }

        case "saveBytes":
            let name = body["name"] as? String ?? "法典笔记文件"
            let encoded = body["data"] as? String ?? ""
            let callback = body["id"] as? String
            let payload = encoded.contains(",") ? String(encoded.split(separator: ",", maxSplits: 1).last ?? "") : encoded
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
                resolve(callback: callback, ok: false, message: "文件数据无法解码。")
                return
            }
            presentSavePanel(suggestedName: name, data: data) { url in
                self.finishSave(callback: callback, url: url, error: nil)
            }

        case "copyText":
            let text = body["text"] as? String ?? ""
            let callback = body["id"] as? String
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            resolve(callback: callback, ok: true, message: "已复制")

        case "switchCodex":
            let name = body["name"] as? String ?? ""
            if let page = codexPages[name] {
                loadPage(page)
            }

        case "jsError":
            let text = body["message"] as? String ?? "未知脚本错误"
            let source = body["source"] as? String ?? ""
            let line = body["line"] as? Int ?? 0
            let location = source.isEmpty ? "" : " (\(source):\(line))"
            pageErrors.append(text + location)
            FileHandle.standardError.write(Data("[js] \(text)\(location)\n".utf8))

        default:
            break
        }
    }

    private func presentSavePanel(suggestedName: String, data: Data?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        let cleanName = (suggestedName as NSString).lastPathComponent
        panel.nameFieldStringValue = cleanName.isEmpty ? "法典笔记" : cleanName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let data {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else {
                    completion(nil)
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    completion(url)
                } catch {
                    self.pageErrors.append("写入失败：\(error.localizedDescription)")
                    completion(nil)
                }
            }
        } else {
            // Destination only (used by WKDownload). The download writes the file itself.
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        }
    }

    private func finishSave(callback: String?, url: URL?, error: Error?) {
        if let error {
            resolve(callback: callback, ok: false, message: "保存失败：\(error.localizedDescription)")
        } else if let url {
            resolve(callback: callback, ok: true, message: "已保存到 \(url.path)")
        } else {
            resolve(callback: callback, ok: true, message: "已取消保存")
        }
    }

    private func resolve(callback: String?, ok: Bool, message: String) {
        guard let callback else { return }
        let js = "window.__fadianResolve(\(jsString(callback)), \(ok ? "true" : "false"), \(jsString(message)));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(text.dropFirst().dropLast())
    }

    // MARK: Menu actions

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func actualSize() {
        setZoom(1.0)
    }

    @objc private func zoomIn() {
        setZoom(min(2.0, webView.pageZoom + 0.1))
    }

    @objc private func zoomOut() {
        setZoom(max(0.6, webView.pageZoom - 0.1))
    }

    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
        UserDefaults.standard.set(Double(zoom), forKey: "FadianPageZoom")
    }

    @objc private func showGuide() {
        loadPage("使用说明.html")
    }

    @objc private func showRelations() {
        loadPage("关系说明.html")
    }

    @objc private func openLawDatabase() {
        if let url = URL(string: "https://flk.npc.gov.cn/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "宪法 · 民法典 · 刑法 · 网络安全法\n\n笔记与关联保存在本机，不联网、不上传。\n条文正文取自国家法律法规数据库（flk.npc.gov.cn）。",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appDisplayName,
            .applicationVersion: "\(appVersion)（macOS 独立版）",
            .version: "",
            .credits: credits
        ])
    }

    // MARK: Diagnostics

    private func parseArguments() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--audit"), index + 1 < args.count {
            auditDirectory = args[index + 1]
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            snapshotPath = args[index + 1]
        }
        if let index = args.firstIndex(of: "--cross-snapshot"), index + 1 < args.count {
            crossSnapshotPath = args[index + 1]
        }
        if let index = args.firstIndex(of: "--selftest"), index + 1 < args.count {
            selftestMode = args[index + 1]
        }
    }

    private func beginAuditIfNeeded() {
        guard let directory = auditDirectory else {
            if let snapshotPath {
                captureSnapshot(to: snapshotPath) { _ in NSApp.terminate(nil) }
            }
            return
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        auditPages = [homeFile, "法典笔记.html", "法典笔记-civil-code.html",
                      "法典笔记-criminal-law.html", "法典笔记-cyber-law.html",
                      "使用说明.html", "关系说明.html"]
        loadPage(auditPages[0])
    }

    private func runAuditStep(outputDirectory: String) {
        guard auditBusy == false else { return }
        auditBusy = true
        let page = currentFile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.probePage { result in
                var record = result
                record["page"] = page
                record["errors"] = self.pageErrors
                self.auditResults.append(record)
                let imagePath = (outputDirectory as NSString).appendingPathComponent("\(page).png")
                self.captureSnapshot(to: imagePath) { _ in
                    self.auditBusy = false
                    if let index = self.auditPages.firstIndex(of: page), index + 1 < self.auditPages.count {
                        self.loadPage(self.auditPages[index + 1])
                    } else {
                        self.writeAuditReport(outputDirectory)
                    }
                }
            }
        }
    }

    private func probePage(completion: @escaping ([String: Any]) -> Void) {
        let script = #"""
        (function () {
          var app = document.getElementById('app');
          var result = {
            title: document.title,
            href: location.href,
            protocol: location.protocol,
            secureContext: !!window.isSecureContext,
            hasApp: !!app,
            hasMain: !!(app && app.querySelector('main')),
            appText: (app ? app.innerText : '').replace(/\s+/g, ' ').slice(0, 160),
            dataType: typeof DATA,
            shell: !!(window.FadianShell && window.FadianShell.__native),
            bodyHeight: document.body.scrollHeight,
            localStorageOK: false,
            lastCode: null,
            indexedDBType: typeof indexedDB
          };
          try {
            localStorage.setItem('__fadian_probe__', 'ok');
            result.localStorageOK = localStorage.getItem('__fadian_probe__') === 'ok';
            result.lastCode = localStorage.getItem('fadian-last-code');
          } catch (e) {
            result.localStorageError = String(e);
          }
          return JSON.stringify(result);
        })()
        """#
        webView.evaluateJavaScript(script) { value, error in
            var result: [String: Any] = [:]
            if let text = value as? String, let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = parsed
            }
            if let error {
                result["probeError"] = error.localizedDescription
            }
            result["indexedDB"] = "not-tested"
            self.probeIndexedDB { idb in
                result["indexedDB"] = idb
                completion(result)
            }
        }
    }

    private func probeIndexedDB(completion: @escaping (String) -> Void) {
        let script = #"""
        return await new Promise(function (resolve) {
          try {
            if (!window.indexedDB) { resolve('unavailable'); return; }
            var request = indexedDB.open('__fadian_probe__', 1);
            request.onupgradeneeded = function () {
              try { request.result.createObjectStore('t'); } catch (e) {}
            };
            request.onsuccess = function () { try { request.result.close(); } catch (e) {} resolve('ok'); };
            request.onerror = function () { resolve('error: ' + (request.error && request.error.message || request.error)); };
            request.onblocked = function () { resolve('blocked'); };
            setTimeout(function () { resolve('timeout'); }, 3000);
          } catch (e) { resolve('exception: ' + e); }
        });
        """#
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion(value as? String ?? "unknown")
            case .failure(let error):
                completion("failure: \(error.localizedDescription)")
            }
        }
    }

    private func captureSnapshot(to path: String, completion: @escaping (Bool) -> Void) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: 1400)
        webView.takeSnapshot(with: configuration) { image, error in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("snapshot failed: \(error?.localizedDescription ?? "unknown")\n".utf8))
                completion(false)
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("SNAPSHOT \(path)")
                completion(true)
            } catch {
                FileHandle.standardError.write(Data("snapshot write failed: \(error)\n".utf8))
                completion(false)
            }
        }
    }

    private func writeAuditReport(_ directory: String) {
        let report: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "pages": auditResults
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let path = (directory as NSString).appendingPathComponent("audit.json")
            try? data.write(to: URL(fileURLWithPath: path))
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        }
        NSApp.terminate(nil)
    }

    private func runSelftest(mode: String) {
        if mode == "note" {
            runNoteWorkflowTest()
            return
        }
        if mode == "crosssearch" {
            runCrossSearchTest()
            return
        }
        if mode == "crossopen" {
            runCrossOpenTest()
            return
        }
        if mode == "notefix" {
            runNoteFixTest()
            return
        }
        if mode == "layout" {
            if selftestStage == 0 {
                selftestStage = 1
                loadPage("法典笔记-civil-code.html")
                return
            }
            let script = #"""
            (function () {
              try {
                ui.view = 'reader'; ui.rail = 'mine';
                readUnit('a1', M.years[M.years.length - 1], 'mine');
                var page = document.querySelector('.page.view-reader');
                var secs = [...document.querySelectorAll('.continuous-article')];
                var sec = secs[0], next = secs[1], active = document.querySelector('.continuous-article.active') || sec;
                var cs = getComputedStyle(sec), ns = getComputedStyle(next), ac = getComputedStyle(active);
                var pb = getComputedStyle(page, '::before'), pa = getComputedStyle(page, '::after');
                var toggle = document.querySelector('.sidebar-toggle');
                var tr = toggle && toggle.getBoundingClientRect();
                var util = document.querySelector('.side-utility'), ur = util && util.getBoundingClientRect();
                var side = document.querySelector('.sidebar'), sr = side && side.getBoundingClientRect();
                var pager = document.getElementById('reader-pager');
                return JSON.stringify({
                  url: location.href,
                  view: ui.view,
                  grid: !!document.querySelector('.reader-grid'),
                  sections: secs.length,
                  firstClass: sec.className,
                  nextClass: next.className,
                  sectionMargin: ns.marginTop,
                  sectionPaddingTop: ns.paddingTop,
                  sectionBorderTop: ns.borderTopWidth + ' ' + ns.borderTopColor,
                  sectionBefore: getComputedStyle(next, '::before').content,
                  activeBg: ac.backgroundColor,
                  activeShadow: ac.boxShadow,
                  activeBar: getComputedStyle(active, '::before').content,
                  articleHeadPaddingTop: getComputedStyle(sec.querySelector('.article-head')).paddingTop,
                  pageBefore: { position: pb.position, top: pb.top, height: pb.height, z: pb.zIndex, background: pb.backgroundImage.slice(0, 120), content: pb.content },
                  pageAfter: { position: pa.position, bottom: pa.bottom, height: pa.height, z: pa.zIndex, background: pa.backgroundImage.slice(0, 120), content: pa.content },
                  toggle: toggle ? { display: getComputedStyle(toggle).display, visibility: getComputedStyle(toggle).visibility, width: tr.width, height: tr.height, x: tr.x, right: tr.right, html: toggle.innerHTML.length } : null,
                  utility: util ? { display: getComputedStyle(util).display, width: ur.width, x: ur.x, right: ur.right } : null,
                  sidebar: side ? { width: sr.width, x: sr.x, right: sr.right, overflow: getComputedStyle(side).overflowX } : null,
                  bodyCollapsed: document.body.className,
                  sideWidth: getComputedStyle(document.body).getPropertyValue('--side-w').trim(),
                  pagerPosition: pager ? getComputedStyle(pager).position : null,
                  errors: window.__fadianErrors || []
                });
              } catch (e) { return 'ERR:' + e.stack; }
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                print("SELFTEST_LAYOUT \(value ?? "nil")")
                if let error { print("SELFTEST_LAYOUT_ERROR \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
            return
        }
        if mode == "diag" {
            if selftestStage == 0 {
                selftestStage = 1
                loadPage("法典笔记-civil-code.html")
                return
            }
            let script = #"""
            (function () {
              var out = {};
              try {
                out.stateLen = JSON.stringify(state).length;
                out.storageAvailable = storageAvailable;
                out.storageIssue = typeof storageIssue !== 'undefined' ? storageIssue : null;
                out.unreadable = typeof unreadableBackup !== 'undefined' ? String(unreadableBackup).slice(0, 100) : null;
                try { localStorage.setItem('__diag_small__', 'ok'); out.small = 'ok'; }
                catch (e) { out.small = 'ERR:' + e; }
                try { localStorage.setItem(KEY, JSON.stringify(state)); out.state = 'ok'; }
                catch (e) { out.state = 'ERR:' + e; }
                out.keyLen = (localStorage.getItem(KEY) || '').length;
                localStorage.removeItem('__diag_small__');
              } catch (e) { out.fatal = String(e); }
              return JSON.stringify(out);
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                print("SELFTEST_DIAG \(value ?? "nil")")
                if let error { print("SELFTEST_DIAG_ERROR \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
            return
        }
        guard !auditBusy else { return }
        auditBusy = true
        let write = mode == "write"
        let script = #"""
        (function () {
          var result = { href: location.href, protocol: location.protocol, origin: location.origin,
                         secureContext: !!window.isSecureContext, idb: typeof indexedDB,
                         errors: window.__fadianErrors || [] };
          try {
            if (\#(write)) localStorage.setItem('__fadian_test__', 'persist-ok');
            result.localStorage = localStorage.getItem('__fadian_test__');
          } catch (e) { result.localStorage = 'ERR:' + e; }
          return JSON.stringify(result);
        })()
        """#
        webView.evaluateJavaScript(script) { value, error in
            var result: [String: Any] = [:]
            if let text = value as? String, let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = parsed
            }
            if let error { result["jsError"] = error.localizedDescription }
            self.probeIndexedDB { idb in
                result["indexedDB"] = idb
                result["nativePageErrors"] = self.pageErrors
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print("SELFTEST \(text)")
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Verify that an existing note loads into the editor, can be edited and deleted.
    /// Uses the non-persistent test store, so real notes are never touched.
    private func runNoteFixTest() {
        switch noteFixStage {
        case 0:
            noteFixStage = 1
            loadPage("法典笔记-civil-code.html")
        case 1:
            let script = #"""
            (function () {
              try {
                readUnit('a1', M.years[M.years.length - 1], 'mine');
                var key = draftKey();
                state.drafts[key] = { text: '笔记修复自检-UNIQUE', question: '笔记修复自检问题', anchors: [], year: state.year };
                saveNote();
                var note = state.notes.find(function (n) { return n.text === '笔记修复自检-UNIQUE'; });
                return JSON.stringify({ saved: !!note, id: note && note.id, count: state.notes.length });
              } catch (e) { return 'ERR:' + e; }
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                self.selftestLog["create"] = value ?? "nil"
                if let error { self.selftestLog["createError"] = error.localizedDescription }
                self.noteFixStage = 2
                self.webView.reload()
            }
        case 2:
            let script = #"""
            (function () {
              try {
                function findCard() {
                  return [...document.querySelectorAll('.saved-note')].find(function (card) {
                    return card.textContent.indexOf('笔记修复自检') >= 0;
                  });
                }
                ui.view = 'notes'; ui.notesTab = 'notes'; render();
                var card = findCard();
                if (!card) return JSON.stringify({ error: 'note card not found', count: state.notes.length });
                card.querySelector('[data-action="goto-note"]').click();
                var input = document.getElementById('note-input');
                var loaded = {
                  view: ui.view, rail: ui.rail,
                  title: document.querySelector('.editor-title')?.textContent.trim() || '',
                  value: input?.value || '',
                  question: document.getElementById('note-question')?.value || '',
                  editId: state.drafts[draftKey()]?.editId || '',
                  deleteButton: !!document.querySelector('.note-editor [data-action="delete-note"]')
                };
                input.value = '笔记修复自检-EDITED';
                input.dispatchEvent(new Event('input', { bubbles: true }));
                document.querySelector('.note-editor [data-action="save-note"]').click();
                var afterEdit = {
                  count: state.notes.length,
                  text: state.notes[0]?.text || '',
                  stored: (localStorage.getItem(KEY) || '').indexOf('笔记修复自检-EDITED') >= 0
                };
                ui.view = 'notes'; render();
                var card2 = findCard();
                if (!card2) return JSON.stringify({ loaded: loaded, afterEdit: afterEdit, error: 'edited card not found' });
                card2.querySelector('[data-action="goto-note"]').click();
                document.querySelector('.note-editor [data-action="delete-note"]').click();
                document.querySelector('[data-action="confirm-delete"]').click();
                var afterDelete = {
                  count: state.notes.length,
                  stored: (localStorage.getItem(KEY) || '').indexOf('笔记修复自检') >= 0
                };
                return JSON.stringify({ loaded: loaded, afterEdit: afterEdit, afterDelete: afterDelete });
              } catch (e) { return 'ERR:' + e; }
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                self.selftestLog["ui"] = value ?? "nil"
                if let error { self.selftestLog["uiError"] = error.localizedDescription }
                self.noteFixStage = 3
                self.webView.reload()
            }
        case 3:
            let script = #"""
            JSON.stringify({ count: state.notes.length, stored: (localStorage.getItem(KEY) || '').indexOf('笔记修复自检') >= 0 })
            """#
            webView.evaluateJavaScript(script) { value, error in
                self.selftestLog["reload"] = value ?? "nil"
                if let error { self.selftestLog["reloadError"] = error.localizedDescription }
                self.selftestLog["nativePageErrors"] = self.pageErrors
                if let data = try? JSONSerialization.data(withJSONObject: self.selftestLog, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print("SELFTEST_NOTEFIX \(text)")
                }
                NSApp.terminate(nil)
            }
        default:
            break
        }
    }

    /// Click through from a grouped result into another code and verify the keyword highlight.
    private func runCrossOpenTest() {
        if crossOpenStage == 0 {
            guard currentFile == "法典笔记.html" else {
                loadPage("法典笔记.html")
                return
            }
            crossOpenStage = 1
            let script = #"""
            (function () {
              const input = document.getElementById('global-search');
              input.value = '国家';
              document.getElementById('search-form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
              setTimeout(function () {
                const tab = [...document.querySelectorAll('[data-action="cross-search-code"]')].find((x) => x.dataset.code === 'criminal-law');
                if (tab) tab.click();
                setTimeout(function () {
                  const hit = document.querySelector('#cross-search-results [data-action="rel3-hit-open"]');
                  if (hit) hit.click();
                }, 80);
              }, 450);
              return 'started';
            })()
            """#
            webView.evaluateJavaScript(script, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if self.crossOpenStage == 1 {
                    print("SELFTEST_CROSSOPEN_ERROR no navigation")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        crossOpenStage = 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let script = #"""
            JSON.stringify({
              href: location.href,
              view: ui.view,
              current: state.current,
              marks: document.querySelectorAll('#law-text mark.cross-search-target').length,
              first: document.querySelector('#law-text mark.cross-search-target')?.textContent || '',
              snippet: (document.getElementById('law-text')?.innerText || '').slice(0, 80)
            })
            """#
            self.webView.evaluateJavaScript(script) { value, error in
                print("SELFTEST_CROSSOPEN \(value ?? "nil")")
                if let error { print("SELFTEST_CROSSOPEN_JS_ERROR \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
    }

    /// Exercise the top-bar cross-code search without touching the user's persistent store.
    private func runCrossSearchTest() {
        guard currentFile == "法典笔记.html" else {
            loadPage("法典笔记.html")
            return
        }
        guard !crossSearchTestRunning else { return }
        crossSearchTestRunning = true
        let script = #"""
        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
        const submit = (q) => {
          const input = document.getElementById('global-search');
          input.value = q;
          document.getElementById('search-form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
        };
        const tabList = () => [...document.querySelectorAll('[data-action="cross-search-code"]')].map((tab) => ({
          code: tab.dataset.code,
          name: tab.querySelector('span')?.textContent || '',
          count: tab.querySelector('.cross-search-code-count')?.textContent || '',
          selected: tab.getAttribute('aria-selected') === 'true'
        }));
        const snap = () => ({
          view: ui.view,
          query: ui.crossSearch,
          input: document.getElementById('global-search')?.value || '',
          title: document.querySelector('.page-heading h2')?.textContent || '',
          desc: document.querySelector('.page-heading p')?.textContent || '',
          tabs: tabList(),
          active: document.querySelector('.cross-search-code.active')?.textContent.trim() || '',
          groupTitle: document.querySelector('.cross-search-group-head h3')?.textContent || '',
          groupCount: document.querySelector('.cross-search-group-head p')?.textContent || '',
          results: document.querySelectorAll('#cross-search-results .cross-search-hit').length,
          codes: [...new Set([...document.querySelectorAll('#cross-search-results .cross-search-hit .pill')].map((x) => x.textContent.trim()))],
          empty: document.querySelector('.cross-search-panel .big-empty h3, #cross-search-results .big-empty h3')?.textContent || '',
          loading: !!document.querySelector('.cross-search-loading')
        });
        submit('国家');
        const loading = !!document.querySelector('.cross-search-loading');
        await sleep(400);
        const first = snap();
        const criminalTab = () => document.querySelector('[data-action="cross-search-code"][data-code="criminal-law"]');
        criminalTab()?.click();
        await sleep(100);
        const criminal = snap();
        submit('');
        await sleep(100);
        const empty = snap();
        submit('不存在的词XYZ');
        await sleep(400);
        const none = snap();
        submit('个人信息');
        await sleep(400);
        const again = snap();
        criminalTab()?.click();
        await sleep(100);
        const afterCriminal = snap();
        return JSON.stringify({ loading, first, criminal, empty, none, again, afterCriminal, errors: window.__fadianErrors || [] });
        """#
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                print("SELFTEST_CROSSSEARCH \(value)")
            case .failure(let error):
                print("SELFTEST_CROSSSEARCH_ERROR \(error.localizedDescription)")
            }
            if let path = self.crossSnapshotPath {
                self.captureSnapshot(to: path) { _ in NSApp.terminate(nil) }
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    /// End-to-end check of the actual note workflow: save a note, reload, verify it is in
    /// localStorage, restore the previous value, then switch codes and exercise the copy bridge.
    private func runNoteWorkflowTest() {
        switch selftestStage {
        case 0:
            selftestStage = 1
            loadPage("法典笔记-civil-code.html")

        case 1:
            let script = #"""
            (function () {
              try {
                var original = localStorage.getItem(KEY);
                if (original === null) {
                  localStorage.removeItem('__fadian_note_backup__');
                  localStorage.setItem('__fadian_note_backup_exists__', '0');
                } else {
                  localStorage.setItem('__fadian_note_backup__', original);
                  localStorage.setItem('__fadian_note_backup_exists__', '1');
                }
                readUnit('a1', M.years[M.years.length - 1], 'mine');
                var key = draftKey();
                state.drafts[key] = { text: '应用持久化自检笔记', anchors: [], year: state.year };
                saveNote();
                var stored = (localStorage.getItem(KEY) || '').indexOf('应用持久化自检笔记') >= 0;
                return JSON.stringify({
                  saved: state.notes.some(function (n) { return n.text === '应用持久化自检笔记'; }),
                  stored: stored,
                  count: state.notes.length
                });
              } catch (e) { return 'ERR:' + e; }
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                self.selftestLog["save"] = value ?? "nil"
                if let error { self.selftestLog["saveError"] = error.localizedDescription }
                self.selftestStage = 2
                self.webView.reload()
            }

        case 2:
            let script = #"""
            (function () {
              var out = {};
              try {
                out.persisted = (localStorage.getItem(KEY) || '').indexOf('应用持久化自检笔记') >= 0;
                out.count = state.notes.length;
                out.hasNote = state.notes.some(function (n) { return n.text === '应用持久化自检笔记'; });
                var existed = localStorage.getItem('__fadian_note_backup_exists__') === '1';
                var backup = localStorage.getItem('__fadian_note_backup__');
                if (existed) localStorage.setItem(KEY, backup || '');
                else localStorage.removeItem(KEY);
                out.restored = existed ? (localStorage.getItem(KEY) === backup) : (localStorage.getItem(KEY) === null);
                localStorage.removeItem('__fadian_note_backup__');
                localStorage.removeItem('__fadian_note_backup_exists__');
              } catch (e) { out.error = String(e); }
              return JSON.stringify(out);
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                self.selftestLog["reload"] = value ?? "nil"
                if let error { self.selftestLog["reloadError"] = error.localizedDescription }
                self.selftestStage = 3
                self.webView.evaluateJavaScript("window.FadianShell.switchCodex('criminal-law');", completionHandler: nil)
            }

        case 3:
            selftestStage = 4
            selftestLog["switchedFile"] = currentFile
            selftestLog["switchedTitle"] = webView.title ?? ""
            let script = #"""
            (function () {
              try {
                localStorage.removeItem('__fadian_test__');
                localStorage.removeItem('__fadian_probe__');
              } catch (e) {}
              return JSON.stringify({ title: document.title, codex: CODEX.short, href: location.href });
            })()
            """#
            webView.evaluateJavaScript(script) { value, error in
                self.selftestLog["switchedPage"] = value ?? "nil"
                if let error { self.selftestLog["switchError"] = error.localizedDescription }
                self.webView.evaluateJavaScript(
                    "window.FadianShell.copyText('fadian-copy-test').then(function(){return 'ok';},function(e){return 'ERR:'+e;});"
                ) { copyResult, copyError in
                    self.selftestLog["copyResult"] = copyResult ?? "nil"
                    if let copyError { self.selftestLog["copyError"] = copyError.localizedDescription }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let pasteboard = NSPasteboard.general.string(forType: .string) ?? ""
                        self.selftestLog["pasteboardMatches"] = pasteboard == "fadian-copy-test"
                        self.selftestLog["nativePageErrors"] = self.pageErrors
                        if let data = try? JSONSerialization.data(withJSONObject: self.selftestLog,
                                                                  options: [.prettyPrinted, .sortedKeys]),
                           let text = String(data: data, encoding: .utf8) {
                            print("SELFTEST_NOTE \(text)")
                        }
                        NSApp.terminate(nil)
                    }
                }
            }

        default:
            break
        }
    }
}

// MARK: - Helpers

private extension NSToolbarItem.Identifier {
    static let navReload = NSToolbarItem.Identifier("navReload")
    static let navHelp = NSToolbarItem.Identifier("navHelp")
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

// MARK: - Entry point

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
