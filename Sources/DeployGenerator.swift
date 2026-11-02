import Foundation

// Writes a deploy script with an AI tool. The tool gets no secrets and can
// change only one file, and the result runs only after the user approves it.

/// Files the AI may not open while it works, wherever they sit in the project.
let generatorDeniedFiles = [
    ".env", ".env.*", ".deploy", ".deploy.*", "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*", "id_ed25519*", "id_ecdsa*",
    "*credential*", "*secret*", "auth.json", ".npmrc", ".netrc", ".pgpass", "liveserver*",
]

func isSafeScriptPath(_ path: String) -> Bool {
    guard path.hasSuffix(".sh"), !path.hasPrefix("/"), !path.hasPrefix("."), !path.contains("..") else { return false }
    return path.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil
}

/// Tested against a real run in tests/lockdown.sh. Each part closes a route that
/// was proven open without it: settings would bring in the user's approvals, and
/// approving Read, Grep or Glob without a path reaches files outside the project.
func generatorArguments(scriptPath: String, prompt: String, model: String? = nil) -> [String] {
    var args = [
        "-p", prompt,
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--tools", "Read,Glob,Grep,Edit,Write",
        "--permission-mode", "dontAsk",
        "--allowedTools", "Read(./**)", "Edit(./\(scriptPath))", "Write(./\(scriptPath))",
        "--disallowedTools",
    ]
    args += generatorDeniedFiles.map { "Read(./**/\($0))" }
    args += ["--output-format", "stream-json", "--verbose"]
    if let model { args += ["--model", model] }
    return args
}

func findAgentTool() -> String? {
    #if VAULT_TEST
    if let override = ProcessInfo.processInfo.environment["VAULT_TEST_AGENT"] { return override }
    #endif
    let home = realHome()
    let usual = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if let found = usual.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
    // Installed somewhere else, such as a version manager: ask the user's own shell.
    return (loginShellPath() ?? "").split(separator: ":").map { $0 + "/claude" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// A file name that keeps an existing deploy script safe.
func defaultGeneratedPath(projectPath: String) -> String {
    let manager = FileManager.default
    if findDeployScript(in: projectPath) == nil { return "scripts/deploy.sh" }
    if !manager.fileExists(atPath: projectPath + "/scripts/deploy-auto.sh") { return "scripts/deploy-auto.sh" }
    for number in 2...50 where !manager.fileExists(atPath: projectPath + "/scripts/deploy-auto-\(number).sh") {
        return "scripts/deploy-auto-\(number).sh"
    }
    return "scripts/deploy-auto.sh"
}

private let fieldNames: [(String, String)] = [
    ("target", "user@host"), ("host", "host"), ("user", "user"), ("port", "SSH port"), ("path", "folder on the server"),
    ("password", "SSH password (secret)"), ("key", "path to a private key file (secret)"),
]

/// Built only from names, addresses and folders. Never reads a stored login or key value.
func buildDeployPrompt(project: Project, data: VaultData, scriptPath: String, notes: String?) -> String {
    var servers: [String] = []
    for link in project.links {
        guard let server = data.servers.first(where: { $0.id == link.serverID }) else { continue }
        let login: String
        switch server.auth {
        case "password": login = "password"
        case "key": login = "private key, already loaded into a private ssh-agent"
        default: login = "this Mac's own SSH setup"
        }
        var lines = ["- \"\(link.label)\": \(server.target), port \(server.port ?? 22), folder \(link.path.isEmpty ? "not set" : link.path), login by \(login)"]
        for (field, meaning) in fieldNames {
            if let name = link.env[field], !name.isEmpty { lines.append("    $\(name) = \(meaning)") }
        }
        servers.append(lines.joined(separator: "\n"))
    }
    let keys = data.secrets.filter { project.secretIDs.contains($0.id) }.map { "- $\($0.env): \($0.name) (secret)" }
    let mapped = Set(project.links.flatMap { $0.env.values }).union(data.secrets.map(\.env))
    let settings = deployVariableNames(projectPath: project.path).subtracting(mapped)
        .filter { secretLikeName($0) == false }.sorted()
    let wanted = notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? notes! : "Work out the normal deployment for this kind of project."

    return """
        Write an automatic deployment script for the project "\(project.name)" and save it to \(scriptPath). Do your work only by reading the project and writing that one file.

        Study the project first: its framework, package managers, build steps, database migrations, queues and services. Read any existing deploy scripts and docs for reference, but they may be out of date.

        What a deploy should do:
        \(wanted)

        ## Servers

        A vault runs the script and sets these shell variables before it starts. Use them instead of writing their values in the script.

        \(servers.joined(separator: "\n"))

        ## Other secrets available

        \(keys.isEmpty ? "None." : keys.joined(separator: "\n"))

        ## Non-secret settings

        \(settings.isEmpty ? "The project has none." : "The project's .deploy file may set these. The script may source that file if it exists, and must use sensible defaults when a setting is missing: \(settings.joined(separator: ", "))")

        You cannot open .env, .deploy or key files, and you do not need to.

        ## Rules for the script

        - Start with #!/usr/bin/env bash and set -euo pipefail.
        - Keep it safe to run without a person watching: no prompts, and stop at the first error with a clear message.
        - Support --dry-run, which shows each step without changing anything on the server.
        - Check the variables it needs are set, and refuse a folder that is empty or /.
        - Print a short line before each step.
        - Do not delete data, drop tables, or run anything destructive that a normal deploy does not need.
        - Do not commit or push to git.

        ## Handling secrets

        The variables are plain shell variables and are not exported. Keep them that way.

        - Never print a secret: no set -x, no env, printenv or declare -p, and no echo or printf of a secret.
        - Never export a secret, write one to a file, or put one on a command line.
        - With a password login, use a private file descriptor: sshpass -d 3 ssh ... 3<<<"$THE_PASSWORD_VARIABLE". Never use sshpass -p.
        - With a private key login, use plain ssh, because the agent already holds the key.
        - With this Mac's own SSH setup, use plain ssh with -o BatchMode=yes.
        - Always pass -o StrictHostKeyChecking=accept-new and -o ConnectTimeout=15 to ssh, and use the port variable when there is one.

        ## Style

        Write comments the way a member of the team would. Do not mention AI, any AI tool, or how the script was made.

        When you finish, reply in at most five short lines of plain text: what a deploy does, anything you assumed, and anything the user should check. Do not include the script in your reply.
        """
}

private func secretLikeName(_ name: String) -> Bool {
    name.range(of: "(PASS|PASSWD|PASSWORD|SECRET|TOKEN|API_?KEY|PRIVATE_?KEY|CREDENTIAL)", options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: Checking the result

struct ScriptFinding: Encodable {
    /// 0 when it is about the whole script.
    let line: Int
    /// danger | warning
    let level: String
    let message: String
}

private func has(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

/// A second pair of eyes for the user's review, not a replacement for it.
func lintDeployScript(_ text: String, secretVariables: Set<String>, knownVariables: Set<String>, literals: [String]) -> [ScriptFinding] {
    var findings: [ScriptFinding] = []
    func add(_ line: Int, _ level: String, _ message: String) {
        findings.append(ScriptFinding(line: line, level: level, message: message))
    }
    let secretNames = secretVariables.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    let secretRef = secretNames.isEmpty ? "(?!)" : "\\$\\{?(\(secretNames))\\b"
    var usesKnown = knownVariables.isEmpty

    for (index, raw) in text.components(separatedBy: "\n").enumerated() {
        let number = index + 1
        let line = raw.trimmingCharacters(in: .whitespaces)
        if number == 1 && line.hasPrefix("#!") && has(line, "\\s-[a-zA-Z]*x") { add(number, "danger", "Prints every command, which can expose secrets.") }
        if line.isEmpty || line.hasPrefix("#") { continue }
        if knownVariables.contains(where: { has(line, "\\$\\{?\(NSRegularExpression.escapedPattern(for: $0))\\b") }) { usesKnown = true }
        // A here-string to a private descriptor is the safe way to hand over a password.
        let withoutSafeHandoff = line.replacingOccurrences(of: "[0-9]+<<<\\s*\"?\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?\"?", with: "", options: .regularExpression)
        let mentionsSecret = has(withoutSafeHandoff, secretRef)

        if has(line, "\\bset\\s+-[a-zA-Z]*x") || has(line, "set\\s+-o\\s+xtrace") || has(line, "\\bbash\\s+-[a-zA-Z]*x") {
            add(number, "danger", "Prints every command, which can expose secrets.")
        }
        if has(line, "\\b(printenv|compgen\\s+-v)\\b") || has(line, "\\b(declare|typeset|export)\\s+-p\\b") || has(line, "(^|[;|&]\\s*)(env|set)\\s*($|[;|&>])") {
            add(number, "danger", "Prints all variables, which can expose secrets.")
        }
        if mentionsSecret && has(line, "\\b(echo|printf|tee|logger)\\b") { add(number, "danger", "Prints or logs a secret.") }
        if !secretNames.isEmpty && has(line, "\\bexport\\b[^#]*\\b(\(secretNames))\\b") {
            add(number, "danger", "Exports a secret, so every program started afterwards receives it.")
        }
        // Only sshpass's own -p: a later `ssh -p 22` is just the port.
        if has(line, "\\bsshpass\\s+((-e|-v|-d\\s*\\S+|-f\\s*\\S+|-P\\s*\\S+)\\s+)*-p") { add(number, "danger", "Puts a password on the command line, where the process list shows it. Use sshpass -d.") }
        if mentionsSecret && has(line, "\\b(curl|wget|nc|ncat|telnet)\\b") { add(number, "danger", "Sends a secret over the network.") }
        if has(line, "\\b(curl|wget)\\b[^|]*\\|\\s*(sudo\\s+)?(ba|z)?sh\\b") { add(number, "danger", "Downloads code and runs it straight away.") }
        if mentionsSecret && has(withoutSafeHandoff, "[^0-9&<>]>>?\\s*[^&\\s]") { add(number, "danger", "May write a secret to a file.") }
        if has(line, "(?i)\\b[A-Z0-9_]*(PASS|PASSWD|PASSWORD|SECRET|TOKEN)[A-Z0-9_]*=['\"]?[^$'\"\\s(]{4,}") {
            add(number, "danger", "Looks like a secret written into the script.")
        }
        for literal in literals where literal.count >= 4 && line.contains(literal) {
            add(number, "warning", "Hard-codes \(literal) instead of using its variable.")
            break
        }
        if has(line, "\\brm\\s+-[a-zA-Z]*r[a-zA-Z]*f|\\brm\\s+-[a-zA-Z]*f[a-zA-Z]*r") { add(number, "warning", "Deletes files. Check exactly what it removes.") }
    }
    if !usesKnown { add(0, "warning", "Does not use any of the server variables the vault provides.") }
    return findings.sorted { ($0.level == "danger" ? 0 : 1, $0.line) < ($1.level == "danger" ? 0 : 1, $1.line) }
}

struct LintContext {
    let secrets: Set<String>
    let known: Set<String>
    let literals: [String]
}

func lintContext(project: Project, data: VaultData) -> LintContext {
    var secrets = Set(data.secrets.filter { project.secretIDs.contains($0.id) }.map(\.env))
    var known = Set<String>()
    var literals: [String] = []
    for link in project.links {
        for (field, name) in link.env where !name.isEmpty {
            known.insert(name)
            if field == "password" || field == "key" { secrets.insert(name) }
        }
        if !link.path.isEmpty && link.path != "/" { literals.append(link.path) }
        if let server = data.servers.first(where: { $0.id == link.serverID }) { literals.append(server.host) }
    }
    return LintContext(secrets: secrets, known: known, literals: literals)
}

/// Syntax check only: `bash -n` does not run anything in the script.
func checkSyntax(scriptPath: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-n", scriptPath]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "Could not run the syntax check." }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : String(decoding: output, as: UTF8.self)
}

/// File sizes and times, used to notice anything changed besides the script.
private func snapshot(of root: String) -> [String: String] {
    let skipped: Set<String> = [".git", "node_modules", "vendor", "storage", "build", "dist", ".next", "Pods", "worktrees", ".idea"]
    var out: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root) else { return out }
    for case let item as String in walker {
        if skipped.contains((item as NSString).lastPathComponent) {
            walker.skipDescendants()
            continue
        }
        guard let attributes = walker.fileAttributes, attributes[.type] as? FileAttributeType == .typeRegular else { continue }
        out[item] = "\(attributes[.size] ?? 0)-\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    return out
}

struct GeneratorResult: Encodable {
    let script: String
    let notes: String
    let findings: [ScriptFinding]
    let syntaxError: String?
    let otherChanges: [String]
    let actionName: String
}

struct GeneratorStatus: Encodable {
    let active: Bool
    let running: Bool
    let project: String
    let projectName: String
    let scriptPath: String
    let log: [String]
    let error: String?
    let result: GeneratorResult?
    let seconds: Int
}

final class GeneratorJob {
    let projectID: String
    let projectName: String
    let projectPath: String
    let scriptPath: String
    private let lock = NSLock()
    private var log: [String] = []
    private var running = true
    private var failure: String?
    private var result: GeneratorResult?
    private var process: Process?
    private var cancelled = false
    private let started = Date()
    private let previous: Data?

    init(project: Project, scriptPath: String) {
        projectID = project.id
        projectName = project.name
        projectPath = project.path
        self.scriptPath = scriptPath
        previous = FileManager.default.contents(atPath: project.path + "/" + scriptPath)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func addLog(_ line: String) {
        locked {
            if log.last != line { log.append(line) }
            if log.count > 200 { log.removeFirst(log.count - 200) }
        }
    }

    func status() -> GeneratorStatus {
        locked {
            GeneratorStatus(
                active: true, running: running, project: projectID, projectName: projectName, scriptPath: scriptPath, log: log,
                error: failure, result: result, seconds: Int(Date().timeIntervalSince(started)))
        }
    }

    func cancel() {
        locked {
            cancelled = true
            process?.terminate()
        }
    }

    /// Puts things back as they were: restores a replaced file, or removes a new one.
    func discard() {
        cancel()
        let file = projectPath + "/" + scriptPath
        if let previous {
            FileManager.default.createFile(atPath: file, contents: previous)
        } else {
            try? FileManager.default.removeItem(atPath: file)
        }
    }

    private func relative(_ path: String) -> String {
        for root in [projectPath, canonicalPath(projectPath)] where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return (path as NSString).lastPathComponent
    }

    /// One line of the tool's progress stream. Tool input is shown only as a file name or search.
    private func handle(line: Data, notes: inout String, denied: inout Int, isError: inout Bool) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = event["type"] as? String else { return }
        if type == "assistant", let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            for item in content where item["type"] as? String == "tool_use" {
                let input = item["input"] as? [String: Any] ?? [:]
                let file = relative(input["file_path"] as? String ?? "")
                switch item["name"] as? String {
                case "Read": addLog("Reading \(file)")
                case "Grep": addLog("Searching the code")
                case "Glob": addLog("Looking through the project's files")
                case "Write", "Edit": addLog("Writing \(file)")
                default: break
                }
            }
        }
        if type == "result" {
            notes = event["result"] as? String ?? ""
            isError = event["is_error"] as? Bool ?? false
            denied = (event["permission_denials"] as? [Any])?.count ?? 0
        }
    }

    /// Blocks until the tool finishes, so call it off the main thread.
    func run(prompt: String, lint: LintContext, loginPath: String?, takenActionNames: [String]) {
        defer { locked { running = false } }
        guard let tool = findAgentTool() else {
            locked { failure = "No AI tool was found on this Mac." }
            return
        }
        addLog("Starting the AI, with no access to your vault")
        let before = snapshot(of: projectPath)

        var environment = cleanEnvironment(path: loginPath)
        environment["VAULT_RUN"] = nil
        environment["SSH_AUTH_SOCK"] = nil
        var model: String?
        #if VAULT_TEST
        model = ProcessInfo.processInfo.environment["VAULT_TEST_AGENT_MODEL"]
        let transcript = ProcessInfo.processInfo.environment["VAULT_TEST_TRANSCRIPT"]
        var promptToSend = prompt
        if let file = ProcessInfo.processInfo.environment["VAULT_TEST_PROMPT_FILE"], let text = try? String(contentsOfFile: file, encoding: .utf8) {
            promptToSend = text
        }
        #else
        let promptToSend = prompt
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = generatorArguments(scriptPath: scriptPath, prompt: promptToSend, model: model)
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        var errorText = Data()
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorText = err.fileHandleForReading.readDataToEndOfFile()
            errorDone.signal()
        }
        do {
            try process.run()
        } catch {
            locked { failure = "Could not start the AI tool." }
            return
        }
        locked { self.process = process }
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }

        var buffer = Data()
        var notes = ""
        var denied = 0
        var isError = false
        var raw = Data()
        let handleOut = out.fileHandleForReading
        while true {
            let chunk = handleOut.availableData
            if chunk.isEmpty { break }
            raw.append(chunk)
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                handle(line: Data(buffer[buffer.startIndex..<newline]), notes: &notes, denied: &denied, isError: &isError)
                buffer = Data(buffer[(newline + 1)...])
            }
        }
        process.waitUntilExit()
        errorDone.wait()
        #if VAULT_TEST
        if let transcript { FileManager.default.createFile(atPath: transcript, contents: raw) }
        #endif

        if locked({ cancelled }) {
            locked { failure = "Stopped." }
            return
        }
        let file = projectPath + "/" + scriptPath
        let current = FileManager.default.contents(atPath: file)
        guard let current, current != previous else {
            let detail = isError ? notes : String(decoding: errorText.prefix(300), as: UTF8.self)
            locked { failure = "The AI finished without writing the script.\(detail.isEmpty ? "" : " \(detail)")" }
            return
        }
        chmod(file, 0o755)
        addLog("Checking the script")

        var changes = before
        changes[scriptPath] = nil
        let after = snapshot(of: projectPath).filter { $0.key != scriptPath }
        let other = Set(after.keys).union(changes.keys).filter { after[$0] != changes[$0] }.sorted()

        let text = String(decoding: current, as: UTF8.self)
        var name = "deploy"
        var suffix = 2
        while takenActionNames.contains(name) {
            name = suffix == 2 ? "deploy-auto" : "deploy-auto-\(suffix)"
            suffix += 1
        }
        let findings = lintDeployScript(text, secretVariables: lint.secrets, knownVariables: lint.known, literals: lint.literals)
        let review = GeneratorResult(
            script: text, notes: notes, findings: findings, syntaxError: checkSyntax(scriptPath: file), otherChanges: other, actionName: name)
        locked { result = review }
    }
}
