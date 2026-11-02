import Foundation
import Security

let usage = """
    vaultdoor: use stored credentials without seeing them.

      vaultdoor status [--json]              What this project may use (names only)
      vaultdoor run <action> [args...]       Run an approved action with its keys
      vaultdoor ssh <server> -- <command>    Run a command in the project's folder on a server
      vaultdoor ssh <server> --no-cd -- <command>
                                         Same, starting in the login folder
      vaultdoor http <key> <METHOD> <URL> [-H 'Name: value'] [-d body] [--data-file path]
                                         Call an API using a stored token
      vaultdoor dashboard                    Open the dashboard for the user

    No command prints a stored value. Keys and approvals are managed only in the dashboard.

    """

func stderrLine(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

/// Exit code 3 means "refused by the vault", as opposed to a failing command.
func refuse(_ text: String) -> Never {
    stderrLine(text)
    exit(3)
}

func context() -> (VaultData, Project) {
    do {
        let data = try Store.load()
        let cwd = FileManager.default.currentDirectoryPath
        guard let project = projectFor(path: cwd, in: data) else {
            refuse("This folder is not a project in the vault. Ask the user to add it: vaultdoor dashboard")
        }
        return (data, project)
    } catch {
        refuse("\(error)")
    }
}

func enabledKey(_ reference: String, _ data: VaultData, _ project: Project) -> Secret {
    if let secret = data.secrets.first(where: { project.secretIDs.contains($0.id) && ($0.name == reference || $0.env == reference) }) {
        return secret
    }
    if data.secrets.contains(where: { $0.name == reference || $0.env == reference }) {
        refuse("\(reference) is not turned on for \(project.name). Ask the user to turn it on in the dashboard: vaultdoor dashboard")
    }
    refuse("No key called \(reference). Ask the user to add it in the dashboard: vaultdoor dashboard")
}

func entry(_ project: Project, kind: String, item: String, name: String, detail: String = "", exit code: Int32? = nil) -> ActivityEntry {
    ActivityEntry(time: Date(), project: project.id, kind: kind, item: item, itemName: name, detail: detail, exit: code)
}

func cmdStatus(json: Bool) {
    let (data, project) = context()
    let keys = data.secrets.filter { project.secretIDs.contains($0.id) }
    struct Key: Encodable { let name, env, kind: String; let allowedHosts: [String]? }
    struct ServerInfo: Encodable { let name, server, target, path, login: String; let port: Int? }
    struct ActionInfo: Encodable { let name, script: String; let needsApproval: [String] }
    struct Status: Encodable { let project, path: String; let servers: [ServerInfo]; let keys: [Key]; let actions: [ActionInfo]; let appsOff: [String] }
    let linked: [ServerInfo] = project.links.compactMap { link in
        guard let server = data.servers.first(where: { $0.id == link.serverID }) else { return nil }
        return ServerInfo(name: link.label, server: server.name, target: server.target, path: link.path, login: server.auth, port: server.port)
    }
    let status = Status(
        project: project.name, path: project.path, servers: linked,
        keys: keys.map { Key(name: $0.name, env: $0.env, kind: $0.kind, allowedHosts: $0.allowedHosts) },
        actions: project.actions.map { ActionInfo(name: $0.name, script: $0.script, needsApproval: changedPins($0, projectPath: project.path)) },
        appsOff: project.disabledApps)
    if json {
        print(encodeJSON(status))
        return
    }
    print("Project: \(status.project)  (\(status.path))")
    print("\nServers:")
    if status.servers.isEmpty { print("  none mapped") }
    for server in status.servers {
        var line = "  \(server.name)  \(server.target)"
        if let port = server.port { line += ":\(port)" }
        line += "  folder=\(server.path.isEmpty ? "(login folder)" : server.path)  login=\(server.login)"
        print(line)
    }
    print("\nKeys:")
    if status.keys.isEmpty { print("  none turned on") }
    for key in status.keys {
        var line = "  \(key.name)  [\(key.kind)]  env=\(key.env)"
        if let hosts = key.allowedHosts { line += "  hosts=\(hosts.joined(separator: ","))" }
        print(line)
    }
    print("\nActions:")
    if status.actions.isEmpty { print("  none") }
    for action in status.actions {
        print("  \(action.name)  \(action.script)  " + (action.needsApproval.isEmpty ? "ready" : "NEEDS APPROVAL: \(action.needsApproval.joined(separator: ", ")) changed"))
    }
    if !status.appsOff.isEmpty { print("\nApps turned off here: \(status.appsOff.joined(separator: ", "))") }
}

func cmdRun(_ arguments: [String]) -> Never {
    guard let name = arguments.first else { refuse("Usage: vaultdoor run <action> [args...]") }
    let (data, project) = context()
    guard let action = project.actions.first(where: { $0.name == name }) else {
        refuse("No action called \(name) in \(project.name). Ask the user to add it in the dashboard: vaultdoor dashboard")
    }
    do {
        Activity.log(entry(project, kind: "action", item: name, name: name))
        let code = try runAction(action, project: project, data: data, extraArgs: Array(arguments.dropFirst()))
        Activity.log(entry(project, kind: "action", item: name, name: name, detail: "finished", exit: code))
        exit(code)
    } catch {
        refuse("\(error)")
    }
}

/// A mapping by its name, or by its server's name when the server has only one here.
func mappedServer(_ reference: String, _ data: VaultData, _ project: Project) -> (Server, ServerLink) {
    func server(_ link: ServerLink) -> Server? { data.servers.first { $0.id == link.serverID } }
    if let link = project.links.first(where: { $0.label == reference }), let found = server(link) { return (found, link) }
    let matches = project.links.filter { link in
        guard let found = server(link) else { return false }
        return found.name == reference || found.host == reference || found.target == reference
    }
    if matches.count == 1, let found = server(matches[0]) { return (found, matches[0]) }
    if matches.count > 1 {
        refuse("\(reference) is mapped more than once here. Use one of: \(matches.map(\.label).joined(separator: ", "))")
    }
    if data.servers.contains(where: { $0.name == reference || $0.host == reference || $0.target == reference }) {
        refuse("\(reference) is not mapped to \(project.name). Ask the user to map it in the dashboard: vaultdoor dashboard")
    }
    refuse("No server called \(reference). See vaultdoor status, or ask the user to add it in the dashboard: vaultdoor dashboard")
}

func cmdSSH(_ arguments: [String]) -> Never {
    guard let reference = arguments.first, let split = arguments.firstIndex(of: "--") else {
        refuse("Usage: vaultdoor ssh <server> [--no-cd] -- <command>")
    }
    let enterFolder = !arguments[..<split].contains("--no-cd")
    let (data, project) = context()
    let (server, link) = mappedServer(reference, data, project)
    do {
        Activity.log(entry(project, kind: "ssh", item: server.id, name: server.name))
        let code = try runSSH(server, link: link, project: project, data: data, command: Array(arguments[(split + 1)...]), enterFolder: enterFolder)
        Activity.log(entry(project, kind: "ssh", item: server.id, name: server.name, detail: "finished", exit: code))
        exit(code)
    } catch {
        refuse("\(error)")
    }
}

func cmdHTTP(_ arguments: [String]) -> Never {
    guard let reference = arguments.first else { refuse("Usage: vaultdoor http <key> <METHOD> <URL>") }
    let (data, project) = context()
    let secret = enabledKey(reference, data, project)
    do {
        Activity.log(entry(project, kind: "http", item: secret.id, name: secret.name))
        let code = try runHTTP(secret, project: project, data: data, args: Array(arguments.dropFirst()))
        Activity.log(entry(project, kind: "http", item: secret.id, name: secret.name, detail: "finished", exit: code))
        exit(code)
    } catch {
        refuse("\(error)")
    }
}

/// Pre-tool hook: reads the agent's JSON on stdin, exits 2 to block an app that
/// is switched off for this project. Any problem lets the call through, so a
/// vault fault can never stop an agent from working.
func cmdHook() -> Never {
    // Runs on every app call, so it must never stop to show a Keychain prompt.
    // If the key is not available without one, the call is simply allowed.
    SecKeychainSetUserInteractionAllowed(false)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
        let tool = payload["tool_name"] as? String, tool.hasPrefix("mcp__")
    else { exit(0) }
    let cwd = payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    let parts = tool.components(separatedBy: "__")
    guard parts.count >= 3, let data = try? Store.load(), let project = projectFor(path: cwd, in: data) else { exit(0) }
    let app = parts[1]
    if project.disabledApps.contains(app) {
        stderrLine("\(app) is turned off for \(project.name) in the vaultdoor dashboard. Ask the user to turn it on if it is needed.")
        exit(2)
    }
    exit(0)
}

/// The app this binary belongs to, even when it was started through the `vault` symlink.
func appBundlePath() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    let executable = canonicalPath(String(cString: buffer))
    guard let marker = executable.range(of: ".app/Contents/MacOS/") else { return nil }
    return String(executable[..<marker.lowerBound]) + ".app"
}

func openDashboard() -> Never {
    guard let bundle = appBundlePath() else { refuse("The dashboard needs the installed VaultDoor.app.") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [bundle]
    do {
        try process.run()
        process.waitUntilExit()
        print("Dashboard opened. Ask the user to make the change there.")
        exit(process.terminationStatus)
    } catch {
        refuse("Could not open the dashboard.")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

// Launched from Finder or `open`: the parent is launchd and there are no arguments.
if getppid() == 1 && arguments.filter({ !$0.hasPrefix("-psn") }).isEmpty {
    runDashboard(selfTest: false)
}

#if VAULT_TEST
if let first = arguments.first, first.hasPrefix("__") {
    runTestCommand(first, Array(arguments.dropFirst()))
}
#endif

switch arguments.first {
case "status": cmdStatus(json: arguments.contains("--json"))
case "run": cmdRun(Array(arguments.dropFirst()))
case "ssh": cmdSSH(Array(arguments.dropFirst()))
case "http": cmdHTTP(Array(arguments.dropFirst()))
case "hook": cmdHook()
case "dashboard": openDashboard()
case nil, "help", "--help", "-h": print(usage)
default:
    stderrLine("Unknown command \(arguments[0]).\n")
    print(usage)
    exit(64)
}
