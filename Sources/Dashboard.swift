import AppKit
import LocalAuthentication
import WebKit

func runDashboard(selfTest: Bool) -> Never {
    let app = NSApplication.shared
    let controller = Dashboard(selfTest: selfTest)
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}

private let unlockSeconds: TimeInterval = 300
private let minimumPassphrase = 12

final class Dashboard: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private var unlockedUntil = Date.distantPast
    private var appsLoading = false
    private let selfTest: Bool
    private var generator: GeneratorJob?
    #if VAULT_TEST
    private var keepAwake: NSObjectProtocol?
    #endif
    private var pageHTML = ""
    private var keyReady = false
    private var keyLoading = false
    private var keyError: String?
    private var waitingForKey: [() -> Void] = []

    init(selfTest: Bool) { self.selfTest = selfTest }

    typealias Done = (String) -> Void

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "vault")
        #if VAULT_TEST
        if ProcessInfo.processInfo.environment["VAULT_TEST_RECORDING"] != nil {
            // A window behind others normally has its timers and animations slowed.
            for setting in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageCSSAnimationSuspensionEnabled", "pageVisibilityBasedProcessSuppressionEnabled"]
            where config.preferences.responds(to: Selector("_set\(setting.prefix(1).uppercased())\(setting.dropFirst()):")) {
                config.preferences.setValue(false, forKey: setting)
            }
            keepAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording")
        }
        #endif
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VaultDoor"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.043, green: 0.055, blue: 0.102, alpha: 1)
        window.minSize = NSSize(width: 960, height: 640)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("VaultDashboard")
        #if VAULT_TEST
        if ProcessInfo.processInfo.environment["VAULT_TEST_RECORDING"] != nil {
            web.setValue(false, forKey: "windowOcclusionDetectionEnabled")
            window.setContentSize(NSSize(width: 1440, height: 810))
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        #else
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #endif

        pageHTML = String(decoding: Data(base64Encoded: embeddedDashboardBase64) ?? Data(), as: UTF8.self)
        web.loadHTMLString(pageHTML, baseURL: nil)

        if !selfTest && AppCache.load().isEmpty { loadApps(nil) }
        #if VAULT_TEST
        if selfTest { scheduleSelfTest() }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide VaultDoor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit VaultDoor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windows
        return main
    }

    /// The page may never navigate away from the embedded dashboard.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about"
        decisionHandler(allowed ? .allow : .cancel)
    }

    /// A crashed page would otherwise leave an empty window for good.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.loadHTMLString(pageHTML, baseURL: nil)
    }

    // MARK: Bridge

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(errorJSON("Bad request."), nil)
            return
        }
        handle(op, body["args"] as? [String: Any] ?? [:]) { replyHandler($0, nil) }
    }

    private func errorJSON(_ text: String) -> String { encodeJSON(["error": text]) }

    private func stateJSON(message: String? = nil, created: String? = nil) -> String {
        do {
            let state = encodeJSON(publicState(try Store.load(), unlocked: Date() < unlockedUntil, appsLoading: appsLoading))
            return "{\"state\":\(state),\"message\":\(encodeJSON(message)),\"created\":\(encodeJSON(created))}"
        } catch {
            return errorJSON("\(error)")
        }
    }

    /// Touch ID or the Mac's password. One approval covers changes for five minutes.
    private func withAuth(_ reason: String, _ then: @escaping (Bool) -> Void) {
        #if VAULT_TEST
        then(true)
        #else
        if Date() < unlockedUntil {
            then(true)
            return
        }
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            then(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                if ok { self.unlockedUntil = Date().addingTimeInterval(unlockSeconds) }
                then(ok)
            }
        }
        #endif
    }

    /// Runs a change to the vault behind Touch ID, then replies with fresh state.
    private func change(_ reason: String, _ done: @escaping Done, _ body: @escaping (inout VaultData) throws -> String?) {
        withAuth(reason) { ok in
            guard ok else {
                done(encodeJSON(["cancelled": true]))
                return
            }
            do {
                var data = try Store.load()
                let message = try body(&data)
                try Store.save(data)
                done(self.stateJSON(message: message))
            } catch let error as Cancelled {
                _ = error
                done(encodeJSON(["cancelled": true]))
            } catch {
                done(self.errorJSON("\(error)"))
            }
        }
    }

    private struct Cancelled: Error {}

    private func text(_ args: [String: Any], _ key: String) -> String? {
        let value = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Runs work once the vault's key is in memory. Reading it can wait on a Keychain
    /// prompt, and doing that on the main thread froze the window and left it blank.
    private func whenKeyReady(_ work: @escaping () -> Void) {
        if keyReady { return work() }
        waitingForKey.append(work)
        guard !keyLoading else { return }
        keyLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            if FileManager.default.fileExists(atPath: Paths.vaultFile) {
                do {
                    _ = try MasterKey.load(createIfMissing: false)
                } catch {
                    failure = "\(error)"
                }
            }
            DispatchQueue.main.async {
                self.keyError = failure
                self.keyLoading = false
                self.keyReady = failure == nil
                let waiting = self.waitingForKey
                self.waitingForKey = []
                waiting.forEach { $0() }
            }
        }
    }

    private func handle(_ op: String, _ args: [String: Any], _ done: @escaping Done) {
        // These never touch the vault, so they keep working while a prompt is open.
        switch op {
        case "activity": return done(encodeJSON(["activity": Activity.recent(30)]))
        case "generatorStatus": return done(generatorStatusJSON())
        default: break
        }
        if op == "retryKey" { keyError = nil }
        if let keyError, !keyLoading { return done(errorJSON(keyError)) }
        whenKeyReady { [self] in
            if let keyError { return done(errorJSON(keyError)) }
            route(op, args, done)
        }
    }

    private func route(_ op: String, _ args: [String: Any], _ done: @escaping Done) {
        switch op {
        case "state", "retryKey": done(stateJSON())
        case "refreshApps": loadApps(done)
        case "lock":
            unlockedUntil = .distantPast
            done(stateJSON(message: "Locked"))
        case "unlock":
            withAuth("unlock the vault") { ok in done(ok ? self.stateJSON(message: "Unlocked for 5 minutes") : encodeJSON(["cancelled": true])) }
        case "toggle": toggle(args, done)
        case "addProject": addProject(path: text(args, "path"), done)
        case "removeProject": removeProject(args, done)
        case "repath": repath(args, done)
        case "deployPlan": deployPlan(args, done)
        case "copyDeployPrompt": copyDeployPrompt(args, done)
        case "startGenerator": startGenerator(args, done)
        case "cancelGenerator":
            generator?.cancel()
            done(generatorStatusJSON())
        case "discardGenerated":
            generator?.discard()
            generator = nil
            done(generatorStatusJSON())
        case "addServer": addServer(args, done)
        case "updateServer": updateServer(args, done)
        case "replaceLogin": replaceLogin(args, done)
        case "deleteServer": deleteServer(args, done)
        case "testServer": testServer(args, done)
        case "suggestEnv": suggestEnv(args, done)
        case "saveLink": saveLink(args, done)
        case "removeLink": removeLink(args, done)
        case "addKey": addKey(args, done)
        case "updateKey": updateKey(args, done)
        case "replaceKey": replaceKey(args, done)
        case "deleteKey": deleteKey(args, done)
        case "addAction": addAction(args, done)
        case "approveAction": approveAction(args, done)
        case "removeAction": removeAction(args, done)
        case "scanDeploy": scanDeploy(args, done)
        case "importDeploy": runImportDeploy(args, done)
        case "export": exportVault(done)
        case "import": importVault(done)
        default: done(errorJSON("Unknown request."))
        }
    }

    private func loadApps(_ done: Done?) {
        guard !appsLoading else {
            done?(stateJSON())
            return
        }
        appsLoading = true
        done?(stateJSON(message: "Checking connected apps"))
        DispatchQueue.global().async {
            _ = refreshApps()
            DispatchQueue.main.async {
                self.appsLoading = false
                self.web?.evaluateJavaScript("window.vaultRefresh && window.vaultRefresh()", completionHandler: nil)
            }
        }
    }

    // MARK: Mapping

    private func toggle(_ args: [String: Any], _ done: @escaping Done) {
        guard let projectID = text(args, "project"), let item = text(args, "item"), let kind = text(args, "kind") else {
            done(errorJSON("Bad request."))
            return
        }
        change("change what this project can use", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { throw VaultError("Unknown project.") }
            if kind == "app" {
                if let at = data.projects[index].disabledApps.firstIndex(of: item) {
                    data.projects[index].disabledApps.remove(at: at)
                } else {
                    data.projects[index].disabledApps.append(item)
                }
                return nil
            }
            if let at = data.projects[index].secretIDs.firstIndex(of: item) {
                data.projects[index].secretIDs.remove(at: at)
                return nil
            }
            guard let secret = data.secrets.first(where: { $0.id == item }) else { throw VaultError("Unknown key.") }
            let ids = data.projects[index].secretIDs
            if let clash = data.secrets.first(where: { ids.contains($0.id) && $0.env == secret.env }) {
                throw VaultError("\(clash.name) already sets \(secret.env) here. Turn it off first.")
            }
            data.projects[index].secretIDs.append(item)
            return nil
        }
    }

    private func addProject(path suggested: String?, _ done: @escaping Done) {
        var chosen = suggested
        if chosen == nil {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Add Project"
            guard panel.runModal() == .OK, let url = panel.url else {
                done(encodeJSON(["cancelled": true]))
                return
            }
            chosen = url.path
        }
        guard let folder = chosen else { return }
        change("add a project", done) { data in
            let path = canonicalPath(folder)
            if data.projects.contains(where: { canonicalPath($0.path) == path }) { throw VaultError("That project is already added.") }
            data.projects.append(
                Project(id: newID(), name: (path as NSString).lastPathComponent, path: path, secretIDs: [], disabledApps: [], actions: []))
            return "Project added"
        }
    }

    private func removeProject(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        guard confirm("Remove this project from the vault?", "Its keys stay in the vault. Its files are not touched.", "Remove") else {
            return done(encodeJSON(["cancelled": true]))
        }
        change("remove a project", done) { data in
            data.projects.removeAll { $0.id == id }
            return "Project removed"
        }
    }

    private func repath(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return done(encodeJSON(["cancelled": true])) }
        change("change a project's folder", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == id }) else { throw VaultError("Unknown project.") }
            data.projects[index].path = canonicalPath(url.path)
            return "Folder updated"
        }
    }

    // MARK: Keys

    private func applyMeta(_ args: [String: Any], to secret: inout Secret) {
        secret.allowedHosts = text(args, "allowedHosts")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        secret.headerName = text(args, "headerName")
        secret.headerPrefix = args["headerPrefix"] as? String
    }

    private func addKey(_ args: [String: Any], _ done: @escaping Done) {
        guard let name = text(args, "name"), let env = text(args, "env"), let kind = text(args, "kind"), ["password", "token"].contains(kind) else {
            return done(errorJSON("Please fill in the name and variable name."))
        }
        guard isValidVariableName(env) else {
            return done(errorJSON("The variable name may only use letters, numbers and underscores."))
        }
        if kind == "token" && text(args, "allowedHosts") == nil { return done(errorJSON("A token needs at least one allowed host.")) }
        change("add a key", done) { data in
            if data.secrets.contains(where: { $0.name == name }) { throw VaultError("A key called \(name) already exists.") }
            guard let value = self.askSecret("Enter the value for \(name)", "It goes straight into the vault and is never shown again, not even here.") else {
                throw Cancelled()
            }
            var secret = Secret(
                id: newID(), name: name, env: env, kind: kind, value: value, host: nil, user: nil, port: nil,
                allowedHosts: nil, headerName: nil, headerPrefix: nil, updatedAt: Date())
            self.applyMeta(args, to: &secret)
            data.secrets.append(secret)
            if let projectID = self.text(args, "enableFor"), let index = data.projects.firstIndex(where: { $0.id == projectID }) {
                let ids = data.projects[index].secretIDs
                if !data.secrets.contains(where: { ids.contains($0.id) && $0.env == env }) {
                    data.projects[index].secretIDs.append(secret.id)
                }
            }
            return "\(name) saved"
        }
    }

    private func updateKey(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        change("edit a key", done) { data in
            guard let index = data.secrets.firstIndex(where: { $0.id == id }) else { throw VaultError("Unknown key.") }
            self.applyMeta(args, to: &data.secrets[index])
            if let kind = self.text(args, "kind"), ["password", "token"].contains(kind) { data.secrets[index].kind = kind }
            return "Saved"
        }
    }

    // MARK: Servers

    /// The login for a server, asked for in a native box so it never enters the page.
    private func askLogin(auth: String, name: String) throws -> String? {
        if auth == "key" { return try askKeyFile() }
        return askSecret("Enter the password for \(name)", "It goes straight into the vault and is never shown again, not even here.")
    }

    private func addServer(_ args: [String: Any], _ done: @escaping Done) {
        guard let name = text(args, "name"), let host = text(args, "host"), let auth = text(args, "auth"), ["password", "key", "system"].contains(auth) else {
            return done(errorJSON("Please fill in the server's name and address."))
        }
        var createdID: String?
        withAuth("add a server") { ok in
            guard ok else { return done(encodeJSON(["cancelled": true])) }
            do {
                var data = try Store.load()
                if data.servers.contains(where: { $0.name == name }) { throw VaultError("A server called \(name) already exists.") }
                var secret: String?
                if auth != "system" {
                    guard let value = try self.askLogin(auth: auth, name: name) else { return done(encodeJSON(["cancelled": true])) }
                    secret = value
                }
                let server = Server(
                    id: newID(), name: name, host: host, user: self.text(args, "user"), port: self.text(args, "port").flatMap { Int($0) },
                    auth: auth, secret: secret, updatedAt: Date())
                data.servers.append(server)
                createdID = server.id
                try Store.save(data)
                done(self.stateJSON(message: "\(name) saved", created: createdID))
            } catch {
                done(self.errorJSON("\(error)"))
            }
        }
    }

    private func updateServer(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id"), let name = text(args, "name"), let host = text(args, "host") else {
            return done(errorJSON("Please fill in the server's name and address."))
        }
        change("edit a server", done) { data in
            guard let index = data.servers.firstIndex(where: { $0.id == id }) else { throw VaultError("Unknown server.") }
            if data.servers.contains(where: { $0.name == name && $0.id != id }) { throw VaultError("A server called \(name) already exists.") }
            data.servers[index].name = name
            data.servers[index].host = host
            data.servers[index].user = self.text(args, "user")
            data.servers[index].port = self.text(args, "port").flatMap { Int($0) }
            if let auth = self.text(args, "auth"), ["password", "key", "system"].contains(auth), auth != data.servers[index].auth {
                if auth == "system" {
                    data.servers[index].secret = nil
                } else {
                    guard let value = try self.askLogin(auth: auth, name: name) else { throw Cancelled() }
                    data.servers[index].secret = value
                }
                data.servers[index].auth = auth
            }
            data.servers[index].updatedAt = Date()
            return "Saved"
        }
    }

    private func replaceLogin(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        change("replace a server login", done) { data in
            guard let index = data.servers.firstIndex(where: { $0.id == id }) else { throw VaultError("Unknown server.") }
            let server = data.servers[index]
            guard server.auth != "system" else { throw VaultError("This server uses this Mac's own SSH setup, so nothing is stored.") }
            guard let value = try self.askLogin(auth: server.auth, name: server.name) else { throw Cancelled() }
            data.servers[index].secret = value
            data.servers[index].updatedAt = Date()
            return "\(server.name) login replaced"
        }
    }

    private func deleteServer(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        guard confirm("Delete this server?", "Its login cannot be recovered and every project that maps it loses access.", "Delete") else {
            return done(encodeJSON(["cancelled": true]))
        }
        change("delete a server", done) { data in
            data.servers.removeAll { $0.id == id }
            for index in data.projects.indices { data.projects[index].links.removeAll { $0.serverID == id } }
            return "Server deleted"
        }
    }

    /// Logs in once with the stored login. No Touch ID: it changes nothing, and the
    /// AI's own commands use the same login without one. Off the main thread,
    /// because a slow server can take seconds to answer.
    private func testServer(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("No server was given.")) }
        let found: Server?
        do {
            found = try Store.load().servers.first { $0.id == id }
        } catch {
            return done(errorJSON("\(error)"))
        }
        guard let server = found else { return done(errorJSON("That server is no longer in the vault.")) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = checkLogin(server)
            DispatchQueue.main.async { done(encodeJSON(["check": result])) }
        }
    }

    private func suggestEnv(_ args: [String: Any], _ done: @escaping Done) {
        do {
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == text(args, "project") }) else { return done(errorJSON("Unknown project.")) }
            let prefix = text(args, "prefix")?.uppercased() ?? "DEPLOY"
            // One variable cannot hold two servers, so skip names another mapping already fills.
            let linkID = text(args, "id")
            let taken = Set(project.links.filter { $0.id != linkID }.flatMap { $0.env.values })
            let env = suggestedLinkEnv(prefix: prefix, names: deployVariableNames(projectPath: project.path)).filter { !taken.contains($0.value) }
            done(encodeJSON(["env": env]))
        } catch {
            done(errorJSON("\(error)"))
        }
    }

    private func saveLink(_ args: [String: Any], _ done: @escaping Done) {
        guard let projectID = text(args, "project"), let serverID = text(args, "server"), let label = text(args, "label") else {
            return done(errorJSON("Please give this mapping a name."))
        }
        let path = text(args, "path") ?? ""
        guard path.isEmpty || path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            return done(errorJSON("The folder must be a full path, such as /var/www/app."))
        }
        var env: [String: String] = [:]
        for (field, value) in args["env"] as? [String: String] ?? [:] {
            let name = value.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard isValidVariableName(name) else { return done(errorJSON("\(name) is not a valid variable name.")) }
            env[field] = name
        }
        change("map a server to this project", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { throw VaultError("Unknown project.") }
            guard data.servers.contains(where: { $0.id == serverID }) else { throw VaultError("Unknown server.") }
            let linkID = self.text(args, "id")
            if data.projects[index].links.contains(where: { $0.label == label && $0.id != linkID }) {
                throw VaultError("\(label) is already used in this project. Pick another name.")
            }
            let link = ServerLink(id: linkID ?? newID(), serverID: serverID, label: label, path: path, env: env)
            if let at = data.projects[index].links.firstIndex(where: { $0.id == linkID }) {
                data.projects[index].links[at] = link
            } else {
                data.projects[index].links.append(link)
            }
            // Catches two mappings giving one variable different values, before a deploy does.
            _ = try planVariables(project: data.projects[index], data: data)
            return "\(label) mapped"
        }
    }

    private func removeLink(_ args: [String: Any], _ done: @escaping Done) {
        guard let projectID = text(args, "project"), let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        change("remove a server mapping", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { throw VaultError("Unknown project.") }
            data.projects[index].links.removeAll { $0.id == id }
            return "Mapping removed"
        }
    }

    private func replaceKey(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        change("replace a key", done) { data in
            guard let index = data.secrets.firstIndex(where: { $0.id == id }) else { throw VaultError("Unknown key.") }
            let secret = data.secrets[index]
            guard let value = self.askSecret("Replace \(secret.name)", "Enter the new value. The old one is overwritten.") else {
                throw Cancelled()
            }
            data.secrets[index].value = value
            data.secrets[index].updatedAt = Date()
            return "\(secret.name) replaced"
        }
    }

    private func deleteKey(_ args: [String: Any], _ done: @escaping Done) {
        guard let id = text(args, "id") else { return done(errorJSON("Bad request.")) }
        guard confirm("Delete this key?", "It cannot be recovered and every project that uses it loses access.", "Delete") else {
            return done(encodeJSON(["cancelled": true]))
        }
        change("delete a key", done) { data in
            data.secrets.removeAll { $0.id == id }
            for index in data.projects.indices { data.projects[index].secretIDs.removeAll { $0 == id } }
            return "Key deleted"
        }
    }

    private func askSecret(_ title: String, _ detail: String) -> String? {
        #if VAULT_TEST
        return ProcessInfo.processInfo.environment["VAULT_TEST_SECRET"]
        #endif
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    private func askKeyFile() throws -> String? {
        #if VAULT_TEST
        return ProcessInfo.processInfo.environment["VAULT_TEST_SECRET"]
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the private key file to store"
        panel.prompt = "Store Key"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let value = try? String(contentsOf: url, encoding: .utf8), value.contains("-----BEGIN") else {
            throw VaultError("That file is not a private key.")
        }
        if value.contains("ENCRYPTED") || isPassphraseProtectedOpenSSH(value) {
            throw VaultError("That key has a passphrase. Passphrase-protected keys are not supported.")
        }
        return value
    }

    /// New-format keys hide their cipher inside the base64 body.
    private func isPassphraseProtectedOpenSSH(_ value: String) -> Bool {
        let body = value.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let decoded = Data(base64Encoded: body) else { return false }
        return decoded.range(of: Data("aes256".utf8)) != nil || decoded.range(of: Data("bcrypt".utf8)) != nil
    }

    private func confirm(_ title: String, _ detail: String, _ action: String) -> Bool {
        #if VAULT_TEST
        return true
        #endif
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Actions

    private func addAction(_ args: [String: Any], _ done: @escaping Done) {
        guard let projectID = text(args, "project"), let name = text(args, "name"), let script = text(args, "script") else {
            return done(errorJSON("Please fill in the action name and script."))
        }
        let path = loginShellPath()
        change("approve an action", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { throw VaultError("Unknown project.") }
            if data.projects[index].actions.contains(where: { $0.name == name }) { throw VaultError("\(name) already exists here.") }
            let root = data.projects[index].path
            guard canonicalPath(root + "/" + script).hasPrefix(canonicalPath(root) + "/") else { throw VaultError("The script must be inside the project.") }
            data.projects[index].actions.append(try makeAction(name: name, script: script, projectPath: root, path: path))
            if self.generator?.scriptPath == script && self.generator?.projectID == projectID { self.generator = nil }
            return "\(name) approved"
        }
    }

    private func approveAction(_ args: [String: Any], _ done: @escaping Done) {
        guard let projectID = text(args, "project"), let name = text(args, "name") else { return done(errorJSON("Bad request.")) }
        guard confirm("Approve the current version of this script?", "Check what changed first. An approved script runs with this project's keys.", "Approve") else {
            return done(encodeJSON(["cancelled": true]))
        }
        let path = loginShellPath()
        change("approve a changed script", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == projectID }),
                let at = data.projects[index].actions.firstIndex(where: { $0.name == name })
            else { throw VaultError("Unknown action.") }
            let root = data.projects[index].path
            var pins = data.projects[index].actions[at].pins
            for p in pins.indices {
                guard let hash = sha256Hex(ofFile: root + "/" + pins[p].path) else { throw VaultError("Could not read \(pins[p].path).") }
                pins[p].sha256 = hash
            }
            data.projects[index].actions[at].pins = pins
            data.projects[index].actions[at].path = path
            return "\(name) approved"
        }
    }

    private func removeAction(_ args: [String: Any], _ done: @escaping Done) {
        guard let projectID = text(args, "project"), let name = text(args, "name") else { return done(errorJSON("Bad request.")) }
        change("remove an action", done) { data in
            guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { throw VaultError("Unknown project.") }
            data.projects[index].actions.removeAll { $0.name == name }
            return "\(name) removed"
        }
    }

    // MARK: Auto deployment

    private func generatorStatusJSON() -> String {
        guard let generator else { return encodeJSON(["active": false]) }
        return encodeJSON(generator.status())
    }

    private func deployPlan(_ args: [String: Any], _ done: @escaping Done) {
        struct Row: Encodable { let label, target, folder, login: String }
        struct Plan: Encodable { let project, path: String; let exists, agent: Bool; let servers: [Row] }
        do {
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == text(args, "project") }) else { return done(errorJSON("Unknown project.")) }
            let path = defaultGeneratedPath(projectPath: project.path)
            let rows: [Row] = project.links.compactMap { link in
                guard let server = data.servers.first(where: { $0.id == link.serverID }) else { return nil }
                return Row(label: link.label, target: server.target, folder: link.path, login: server.auth)
            }
            done(encodeJSON(Plan(project: project.name, path: path, exists: FileManager.default.fileExists(atPath: project.path + "/" + path), agent: findAgentTool() != nil, servers: rows)))
        } catch {
            done(errorJSON("\(error)"))
        }
    }

    /// The same words the built-in run uses, for pasting into any AI tool.
    private func copyDeployPrompt(_ args: [String: Any], _ done: @escaping Done) {
        do {
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == text(args, "project") }) else { return done(errorJSON("Unknown project.")) }
            let path = text(args, "path") ?? defaultGeneratedPath(projectPath: project.path)
            guard isSafeScriptPath(path) else { return done(errorJSON("The script must be a .sh file inside the project.")) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(buildDeployPrompt(project: project, data: data, scriptPath: path, notes: text(args, "notes")), forType: .string)
            done(encodeJSON(["copied": true]))
        } catch {
            done(errorJSON("\(error)"))
        }
    }

    private func startGenerator(_ args: [String: Any], _ done: @escaping Done) {
        if generator?.status().running == true { return done(errorJSON("A script is already being written.")) }
        do {
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == text(args, "project") }) else { return done(errorJSON("Unknown project.")) }
            guard !project.links.isEmpty else { return done(errorJSON("Map a server to this project first.")) }
            guard let path = text(args, "path"), isSafeScriptPath(path) else {
                return done(errorJSON("The script must be a .sh file inside the project, using only letters, numbers and - _ . /"))
            }
            if FileManager.default.fileExists(atPath: project.path + "/" + path),
                !confirm("Replace \(path)?", "The AI will overwrite this file. If you discard the result, the current version comes back.", "Replace") {
                return done(encodeJSON(["cancelled": true]))
            }
            let job = GeneratorJob(project: project, scriptPath: path)
            generator = job
            let prompt = buildDeployPrompt(project: project, data: data, scriptPath: path, notes: text(args, "notes"))
            let lint = lintContext(project: project, data: data)
            let taken = project.actions.map(\.name)
            DispatchQueue.global().async { job.run(prompt: prompt, lint: lint, loginPath: loginShellPath(), takenActionNames: taken) }
            done(generatorStatusJSON())
        } catch {
            done(errorJSON("\(error)"))
        }
    }

    // MARK: .deploy

    private func scanDeploy(_ args: [String: Any], _ done: @escaping Done) {
        struct ServerRow: Encodable { let prefix, target, auth: String; let port: Int?; let folders: [String]; let warn: [String] }
        struct KeyRow: Encodable { let key: String; let movable: Bool; let reason: String?; let warn: Bool }
        struct Scan: Encodable { let servers: [ServerRow]; let secrets: [KeyRow]; let script: String? }
        do {
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == text(args, "project") }),
                let content = try? String(contentsOfFile: project.path + "/.deploy", encoding: .utf8)
            else { return done(errorJSON("Could not read .deploy.")) }
            // Addresses and folders only: logins and secret values stay in this process.
            let entries = parseDeploy(content)
            let found = detectServers(entries)
            let used = Set(found.flatMap(\.names))
            let script = findDeployScript(in: project.path)
            let scriptPath = script.map { project.path + "/" + $0 }
            func overrides(_ names: [String]) -> [String] { scriptPath.map { namesScriptOverrides(script: $0, names: names) } ?? [] }
            let servers = found.map {
                ServerRow(prefix: $0.prefix, target: $0.target, auth: $0.auth, port: $0.port, folders: $0.links.map { "\($0.label): \($0.path.isEmpty ? "(login folder)" : $0.path)" }, warn: overrides($0.names))
            }
            let secrets = entries.filter { $0.looksSecret && !used.contains($0.key) && ($0.movable || $0.reason != "empty") }.map {
                KeyRow(key: $0.key, movable: $0.movable, reason: $0.reason, warn: !overrides([$0.key]).isEmpty)
            }
            done(encodeJSON(Scan(servers: servers, secrets: secrets, script: script)))
        } catch {
            done(errorJSON("\(error)"))
        }
    }

    private func runImportDeploy(_ args: [String: Any], _ done: @escaping Done) {
        let servers = args["servers"] as? [String] ?? []
        let keys = args["keys"] as? [String] ?? []
        guard let projectID = text(args, "project"), !(servers.isEmpty && keys.isEmpty) else {
            return done(errorJSON("Choose at least one item to move."))
        }
        guard confirm("Move \(servers.count + keys.count) item\(servers.count + keys.count == 1 ? "" : "s") into the vault?", "They are removed from this project's .deploy file. The rest of the file stays as it is.", "Move") else {
            return done(encodeJSON(["cancelled": true]))
        }
        let path = loginShellPath()
        withAuth("move .deploy secrets into the vault") { ok in
            guard ok else { return done(encodeJSON(["cancelled": true])) }
            do {
                let moved = try importDeploy(projectID: projectID, servers: servers, keys: keys, loginPath: path)
                done(self.stateJSON(message: "Moved \(moved.servers) server\(moved.servers == 1 ? "" : "s") and \(moved.keys) key\(moved.keys == 1 ? "" : "s") into the vault"))
            } catch {
                done(self.errorJSON("\(error)"))
            }
        }
    }

    // MARK: Moving to another Mac

    private func exportVault(_ done: @escaping Done) {
        withAuth("export the vault") { ok in
            guard ok else { return done(encodeJSON(["cancelled": true])) }
            guard let first = self.askSecret("Choose a passphrase for this export", "At least \(minimumPassphrase) characters. Without it the file cannot be opened, so keep it somewhere safe."),
                first.count >= minimumPassphrase
            else { return done(self.errorJSON("The passphrase needs at least \(minimumPassphrase) characters.")) }
            guard let second = self.askSecret("Enter the passphrase again", ""), first == second else {
                return done(self.errorJSON("The passphrases did not match."))
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "vault-export.vaultbackup"
            guard panel.runModal() == .OK, let url = panel.url else { return done(encodeJSON(["cancelled": true])) }
            do {
                try writePrivate(try Store.exportBlob(try Store.load(), passphrase: first), to: url.path)
                done(self.stateJSON(message: "Export saved"))
            } catch {
                done(self.errorJSON("\(error)"))
            }
        }
    }

    private func importVault(_ done: @escaping Done) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url, let blob = try? Data(contentsOf: url) else {
            return done(encodeJSON(["cancelled": true]))
        }
        guard let passphrase = askSecret("Enter the export's passphrase", "") else { return done(encodeJSON(["cancelled": true])) }
        guard confirm("Replace this vault with the export?", "Everything currently in this vault is overwritten.", "Replace") else {
            return done(encodeJSON(["cancelled": true]))
        }
        change("import a vault", done) { data in
            data = try Store.importBlob(blob, passphrase: passphrase)
            return "Vault imported"
        }
    }

    #if VAULT_TEST
    private func scheduleSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let canary = ProcessInfo.processInfo.environment["VAULT_TEST_CANARY"] ?? "\u{0}"
            if let file = ProcessInfo.processInfo.environment["VAULT_TEST_GUI_SCRIPT"], let script = try? String(contentsOfFile: file, encoding: .utf8) {
                var recorder: PageRecorder?
                if let path = ProcessInfo.processInfo.environment["VAULT_TEST_RECORD_TO"] {
                    recorder = try? PageRecorder(web: self.web, path: path)
                    recorder?.start()
                }
                self.web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { outcome in
                    switch outcome {
                    case .success(let value): print("BRIDGE \(value)")
                    case .failure(let error): print("BRIDGE-ERROR \(error)")
                    }
                    guard let recorder else { return NSApp.terminate(nil) }
                    recorder.finish { DispatchQueue.main.async { NSApp.terminate(nil) } }
                }
                return
            }
            let js = "JSON.stringify({items:document.querySelectorAll('[data-r],[data-p]').length,leak:document.documentElement.outerHTML.includes(\(encodeJSON(canary)))})"
            self.web.evaluateJavaScript(js) { result, error in
                print("GUI \(result ?? "none") \(error.map { "\($0)" } ?? "")")
                NSApp.terminate(nil)
            }
        }
    }
    #endif
}
