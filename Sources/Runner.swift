import Foundation

private var childPID: pid_t = 0

private func forwardSignal(_ signalNumber: Int32) {
    if childPID > 0 { kill(childPID, signalNumber) }
}

struct Launch {
    var path: String
    var args: [String]
    var env: [String: String]
    var cwd: String?
    /// Delivered on file descriptor 3, so it never shows in arguments or the environment.
    var fd3: Data?
    var stdinData: Data?
}

func exitCode(fromWaitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

private func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
    values.map { strdup($0) } + [nil]
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, base + offset, bytes.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
}

private func pump(from fd: Int32, to target: Int32, secrets: [(name: String, value: String)], group: DispatchGroup) {
    group.enter()
    Thread.detachNewThread {
        let redactor = Redactor(secrets: secrets) { writeAll(target, $0) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&descriptor, 1, 250)
            if ready == 0 { redactor.flushIdle(); continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            redactor.write(Data(buffer[0..<count]))
        }
        redactor.finish()
        close(fd)
        group.leave()
    }
}

/// Runs a program and passes its output through the redactor.
func launchRedacted(_ launch: Launch, secrets: [(name: String, value: String)]) throws -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    signal(SIGINT, forwardSignal)
    signal(SIGTERM, forwardSignal)

    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    var fd3Pipe: [Int32] = [-1, -1]
    var inPipe: [Int32] = [-1, -1]
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw VaultError("Could not create pipes.") }
    if launch.fd3 != nil, pipe(&fd3Pipe) != 0 { throw VaultError("Could not create a pipe.") }
    if launch.stdinData != nil, pipe(&inPipe) != 0 { throw VaultError("Could not create a pipe.") }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if launch.stdinData != nil {
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
    } else {
        posix_spawn_file_actions_addinherit_np(&actions, 0)
    }
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    if launch.fd3 != nil { posix_spawn_file_actions_adddup2(&actions, fd3Pipe[0], 3) }
    if let cwd = launch.cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Only the descriptors set up above reach the child.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    let argv = cStrings([launch.path] + launch.args)
    let envp = cStrings(launch.env.map { "\($0.key)=\($0.value)" })
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, launch.path, &actions, &attributes, argv, envp)
    close(outPipe[1])
    close(errPipe[1])
    if launch.fd3 != nil { close(fd3Pipe[0]) }
    if launch.stdinData != nil { close(inPipe[0]) }
    guard spawned == 0 else {
        close(outPipe[0])
        close(errPipe[0])
        throw VaultError("Could not start \(launch.path): \(String(cString: strerror(spawned))).")
    }
    childPID = pid

    if let data = launch.fd3 {
        writeAll(fd3Pipe[1], data)
        close(fd3Pipe[1])
    }
    if let data = launch.stdinData {
        writeAll(inPipe[1], data)
        close(inPipe[1])
    }

    let group = DispatchGroup()
    pump(from: outPipe[0], to: 1, secrets: secrets, group: group)
    pump(from: errPipe[0], to: 2, secrets: secrets, group: group)

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    childPID = 0
    // A background grandchild may keep the pipes open; do not wait on it forever.
    _ = group.wait(timeout: .now() + 3)
    return exitCode(fromWaitStatus: status)
}

/// Starts from an empty environment, so settings such as BASH_ENV, PS4 or a
/// doctored PATH cannot run code inside a process that holds secrets.
func cleanEnvironment(path: String?) -> [String: String] {
    let current = ProcessInfo.processInfo.environment
    var env: [String: String] = [:]
    for name in ["LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "SSH_AUTH_SOCK"] {
        if let value = current[name] { env[name] = value }
    }
    let home = realHome()
    env["HOME"] = home
    // From the system, not the caller: tools look up their sign-in by account name.
    if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name {
        env["USER"] = String(cString: name)
        env["LOGNAME"] = String(cString: name)
    }
    env["SHELL"] = "/bin/bash"
    env["VAULT_RUN"] = "1"
    env["PATH"] = path ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin"
    return env
}

func redactionList(for project: Project, in data: VaultData) -> [(name: String, value: String)] {
    var out: [(name: String, value: String)] = project.secretIDs.compactMap { id in
        data.secrets.first { $0.id == id }.map { (name: $0.name, value: $0.value) }
    }
    for link in project.links {
        guard let server = data.servers.first(where: { $0.id == link.serverID }), let secret = server.secret, !secret.isEmpty else { continue }
        out.append((name: server.name, value: secret))
    }
    return out
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private let variableName = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")

func isValidVariableName(_ name: String) -> Bool {
    variableName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
}

/// What a script receives: values, plus private keys that need a file on disk.
struct RunPlan {
    var values: [String: String] = [:]
    var keyFiles: [(variable: String, material: String)] = []
    var agentKeys: [String] = []
}

func planVariables(project: Project, data: VaultData) throws -> RunPlan {
    var plan = RunPlan()
    var owner: [String: String] = [:]
    func assign(_ name: String, _ value: String, from who: String) throws {
        guard isValidVariableName(name) else { throw VaultError("Refused: \(name) is not a valid variable name.") }
        if let current = plan.values[name], current != value {
            throw VaultError("Refused: \(owner[name] ?? "another item") and \(who) both set \(name) to different values. Change one in the dashboard.")
        }
        plan.values[name] = value
        owner[name] = who
    }
    for id in project.secretIDs {
        guard let secret = data.secrets.first(where: { $0.id == id }) else { continue }
        try assign(secret.env, secret.value, from: secret.name)
    }
    for link in project.links {
        guard let server = data.servers.first(where: { $0.id == link.serverID }) else { continue }
        let fields: [String: String?] = [
            "target": server.target, "host": server.host, "user": server.user, "port": server.port.map(String.init),
            "path": link.path.isEmpty ? nil : link.path, "password": server.auth == "password" ? server.secret : nil,
        ]
        for (field, value) in fields {
            guard let name = link.env[field], !name.isEmpty, let value else { continue }
            try assign(name, value, from: link.label)
        }
        if server.auth == "key", let material = server.secret {
            if !plan.agentKeys.contains(material) { plan.agentKeys.append(material) }
            if let name = link.env["key"], !name.isEmpty {
                guard isValidVariableName(name) else { throw VaultError("Refused: \(name) is not a valid variable name.") }
                plan.keyFiles.append((variable: name, material: material))
            }
        }
    }
    return plan
}

private func makePrivateDirectory() throws -> String {
    var template = Array("/tmp/vault.XXXXXXXX".utf8CString)
    guard mkdtemp(&template) != nil else { throw VaultError("Could not create a private folder.") }
    return String(cString: template)
}

/// A short-lived private agent: it can sign with a key but cannot hand it back.
private func withPrivateAgent(
    keys: [String], env: [String: String], hide: [(name: String, value: String)], _ body: (String?) throws -> Int32
) throws -> Int32 {
    guard !keys.isEmpty else { return try body(nil) }
    let dir = try makePrivateDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let socket = dir + "/a"
    var agent: pid_t = 0
    let agentArgv = cStrings(["/usr/bin/ssh-agent", "-D", "-a", socket])
    let agentEnvp = cStrings([])
    defer {
        agentArgv.forEach { free($0) }
        agentEnvp.forEach { free($0) }
    }
    var quiet: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&quiet)
    defer { posix_spawn_file_actions_destroy(&quiet) }
    posix_spawn_file_actions_addopen(&quiet, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&quiet, 2, "/dev/null", O_WRONLY, 0)
    guard posix_spawn(&agent, "/usr/bin/ssh-agent", &quiet, nil, agentArgv, agentEnvp) == 0 else {
        throw VaultError("Could not start ssh-agent.")
    }
    defer {
        kill(agent, SIGTERM)
        var ignored: Int32 = 0
        waitpid(agent, &ignored, 0)
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { usleep(20_000) }
    var agentEnv = env
    agentEnv["SSH_AUTH_SOCK"] = socket
    for key in keys {
        var material = key
        if !material.hasSuffix("\n") { material += "\n" }
        let added = try launchRedacted(
            Launch(path: "/usr/bin/ssh-add", args: ["-q", "-"], env: agentEnv, stdinData: Data(material.utf8)), secrets: hide)
        guard added == 0 else { throw VaultError("A key was not accepted. Passphrase-protected keys are not supported.") }
    }
    return try body(socket)
}

/// The shell named on a script's first line, if it is a shell script.
private func shellInterpreter(for script: String, path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: script) else { return nil }
    defer { try? handle.close() }
    let head = String(decoding: (try? handle.read(upToCount: 256)) ?? Data(), as: UTF8.self)
    let shells = ["bash", "sh", "zsh", "dash", "ksh"]
    guard head.hasPrefix("#!"), let line = head.split(separator: "\n").first else { return script.hasSuffix(".sh") ? "/bin/bash" : nil }
    var words = line.dropFirst(2).split(separator: " ").map(String.init)
    guard var program = words.first else { return nil }
    if (program as NSString).lastPathComponent == "env" {
        words.removeFirst()
        guard let named = words.first(where: { !$0.hasPrefix("-") }) else { return nil }
        guard shells.contains(named) else { return nil }
        for dir in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: dir + "/" + named) {
            return dir + "/" + named
        }
        return nil
    }
    program = program.trimmingCharacters(in: .whitespaces)
    return shells.contains((program as NSString).lastPathComponent) ? program : nil
}

func runAction(_ action: Action, project: Project, data: VaultData, extraArgs: [String]) throws -> Int32 {
    let changed = changedPins(action, projectPath: project.path)
    guard changed.isEmpty else {
        throw VaultError(
            "Refused: \(changed.joined(separator: ", ")) changed since it was approved. "
                + "Ask the user to review the change and approve it in the dashboard.")
    }
    let script = canonicalPath(project.path + "/" + action.script)
    guard script.hasPrefix(canonicalPath(project.path) + "/") else {
        throw VaultError("Refused: the script is outside the project.")
    }
    let plan = try planVariables(project: project, data: data)
    let hide = redactionList(for: project, in: data)
    var values = plan.values

    let dir = try makePrivateDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for (index, item) in plan.keyFiles.enumerated() {
        let file = "\(dir)/key\(index)"
        var material = item.material
        if !material.hasSuffix("\n") { material += "\n" }
        guard FileManager.default.createFile(atPath: file, contents: Data(material.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw VaultError("Could not prepare a key for the script.")
        }
        values[item.variable] = file
    }

    var env = cleanEnvironment(path: action.path)
    return try withPrivateAgent(keys: plan.agentKeys, env: env, hide: hide) { socket in
        if let socket { env["SSH_AUTH_SOCK"] = socket }
        if let shell = shellInterpreter(for: script, path: env["PATH"] ?? "") {
            // Plain shell variables, delivered on a private pipe. They stay out of the
            // environment, so `ps` cannot show them and child processes do not inherit them.
            let prelude = values.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))\n" }.joined()
            let wrapper = "eval \"$(/bin/cat <&3)\"; exec 3<&-; . \"$0\""
            return try launchRedacted(
                Launch(path: shell, args: ["-c", wrapper, script] + action.args + extraArgs, env: env, cwd: project.path, fd3: Data(prelude.utf8)),
                secrets: hide)
        }
        // Not a shell script: the environment is the only way to hand values over.
        for (name, value) in values { env[name] = value }
        return try launchRedacted(Launch(path: script, args: action.args + extraArgs, env: env, cwd: project.path), secrets: hide)
    }
}

private func toolPath(_ name: String, candidates: [String]) -> String? {
    #if VAULT_TEST
    if let override = ProcessInfo.processInfo.environment["VAULT_TEST_" + name.uppercased()] { return override }
    #endif
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Starts the remote command in the mapped folder.
func remoteCommand(path: String, command: [String], enter: Bool) -> [String] {
    guard enter, !path.isEmpty else { return command }
    let folder: String
    if path == "~" {
        folder = "~"
    } else if path.hasPrefix("~/") {
        folder = "~/" + shellQuote(String(path.dropFirst(2)))
    } else {
        folder = shellQuote(path)
    }
    return ["cd -- \(folder) && " + command.joined(separator: " ")]
}

func runSSH(_ server: Server, link: ServerLink, project: Project, data: VaultData, command: [String], enterFolder: Bool) throws -> Int32 {
    guard !server.host.isEmpty else {
        throw VaultError("Refused: \(server.name) has no host. Ask the user to set it in the dashboard.")
    }
    guard !command.isEmpty else { throw VaultError("Give the remote command after --. Interactive sessions are not supported.") }
    guard let ssh = toolPath("ssh", candidates: ["/usr/bin/ssh"]) else { throw VaultError("ssh was not found.") }
    var sshArgs = ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15", "-p", String(server.port ?? 22)]
    let remote = remoteCommand(path: link.path, command: command, enter: enterFolder)
    var env = cleanEnvironment(path: nil)
    let hide = redactionList(for: project, in: data)

    switch server.auth {
    case "password":
        guard let secret = server.secret else { throw VaultError("Refused: \(server.name) has no password stored.") }
        guard let sshpass = toolPath("sshpass", candidates: ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]) else {
            throw VaultError("sshpass is not installed. Ask the user to run: brew install sshpass")
        }
        env["SSH_AUTH_SOCK"] = nil
        sshArgs += ["-o", "PubkeyAuthentication=no", server.target] + remote
        return try launchRedacted(
            Launch(path: sshpass, args: ["-d", "3", ssh] + sshArgs, env: env, fd3: Data((secret + "\n").utf8)), secrets: hide)
    case "key":
        guard let secret = server.secret else { throw VaultError("Refused: \(server.name) has no key stored.") }
        env["SSH_AUTH_SOCK"] = nil
        return try withPrivateAgent(keys: [secret], env: env, hide: hide) { socket in
            sshArgs += ["-o", "IdentityAgent=" + (socket ?? ""), "-o", "PasswordAuthentication=no", server.target] + remote
            return try launchRedacted(Launch(path: ssh, args: sshArgs, env: env), secrets: hide)
        }
    default:
        // This Mac's own SSH setup. BatchMode so it fails instead of waiting on a prompt.
        sshArgs += ["-o", "BatchMode=yes", server.target] + remote
        return try launchRedacted(Launch(path: ssh, args: sshArgs, env: env), secrets: hide)
    }
}

func hostAllowed(_ host: String, _ allowed: [String]) -> Bool {
    let lower = host.lowercased()
    return allowed.contains { let entry = $0.lowercased(); return lower == entry || lower.hasSuffix("." + entry) }
}

private final class HTTPGuard: NSObject, URLSessionTaskDelegate {
    let allowed: [String]
    init(allowed: [String]) { self.allowed = allowed }

    /// A redirect to a host the user did not allow would carry the key with it.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, let host = url.host, url.scheme == "https", hostAllowed(host, allowed) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

func runHTTP(_ secret: Secret, project: Project, data: VaultData, args: [String]) throws -> Int32 {
    guard secret.kind == "token" else { throw VaultError("Refused: \(secret.name) is not an API token.") }
    guard args.count >= 2 else { throw VaultError("Usage: vaultdoor http <key> <METHOD> <URL> [-H 'Name: value'] [-d body] [--data-file path]") }
    let allowed = secret.allowedHosts ?? []
    guard !allowed.isEmpty else {
        throw VaultError("Refused: \(secret.name) has no allowed hosts. Ask the user to set them in the dashboard.")
    }
    guard let url = URL(string: args[1]), let host = url.host else { throw VaultError("That URL is not valid.") }
    guard hostAllowed(host, allowed) else {
        throw VaultError("Refused: \(secret.name) may only be sent to \(allowed.joined(separator: ", ")).")
    }
    let local = host == "localhost" || host == "127.0.0.1"
    guard url.scheme == "https" || (url.scheme == "http" && local) else { throw VaultError("Refused: the URL must use https.") }

    let headerName = secret.headerName ?? "Authorization"
    var request = URLRequest(url: url, timeoutInterval: 120)
    request.httpMethod = args[0].uppercased()
    var index = 2
    while index < args.count {
        let flag = args[index]
        guard index + 1 < args.count else { throw VaultError("\(flag) needs a value.") }
        let value = args[index + 1]
        switch flag {
        case "-H", "--header":
            let parts = value.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw VaultError("A header must look like 'Name: value'.") }
            if parts[0].caseInsensitiveCompare(headerName) != .orderedSame { request.setValue(parts[1], forHTTPHeaderField: parts[0]) }
        case "-d", "--data":
            request.httpBody = Data(value.utf8)
        case "--data-file":
            guard let body = FileManager.default.contents(atPath: value) else { throw VaultError("Could not read \(value).") }
            request.httpBody = body
        default:
            throw VaultError("Unknown option \(flag).")
        }
        index += 2
    }
    request.setValue((secret.headerPrefix ?? "Bearer ") + secret.value, forHTTPHeaderField: headerName)

    let session = URLSession(configuration: .ephemeral, delegate: HTTPGuard(allowed: allowed), delegateQueue: nil)
    let done = DispatchSemaphore(value: 0)
    var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    session.dataTask(with: request) { body, response, error in
        result = (body, response, error)
        done.signal()
    }.resume()
    done.wait()
    if result.2 != nil { throw VaultError("The request failed: could not reach \(host).") }

    let hide = redactionList(for: project, in: data)
    let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
    let out = Redactor(secrets: hide) { FileHandle.standardOutput.write($0) }
    out.write(result.0 ?? Data())
    out.finish()
    FileHandle.standardError.write(Data("HTTP \(code)\n".utf8))
    return (200..<300).contains(code) ? 0 : 1
}
