import Foundation

struct DeployEntry {
    let key: String
    let value: String
    let firstLine: Int
    let lastLine: Int
    let movable: Bool
    let reason: String?
    let looksSecret: Bool
    /// Set when several settings share one line: this setting's own text.
    var inline: String? = nil
}

private let keyPattern = try! NSRegularExpression(pattern: "^\\s*(?:export\\s+)?([A-Za-z_][A-Za-z0-9_]{0,63})=(.*)$")
private let secretNamePattern = try! NSRegularExpression(
    pattern: "(PASS|PASSWD|PASSWORD|SECRET|TOKEN|API_?KEY|PRIVATE_?KEY|CREDENTIAL)", options: [.caseInsensitive])

private enum Parsed {
    case value(String)
    case rejected(String)
    case unclosed
}

private func parseValue(_ raw: String) -> Parsed {
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard let first = text.first else { return .rejected("empty") }
    if first == "'" {
        let body = text.dropFirst()
        guard let end = body.firstIndex(of: "'") else { return .unclosed }
        let rest = body[body.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.isEmpty || rest.hasPrefix("#") else { return .rejected("too complex to move safely") }
        return .value(String(body[..<end]))
    }
    if first == "\"" {
        var out = ""
        var index = text.index(after: text.startIndex)
        var closed = false
        while index < text.endIndex {
            let c = text[index]
            if c == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                out.append(text[next])
                index = text.index(after: next)
                continue
            }
            if c == "$" || c == "`" { return .rejected("uses shell expansion") }
            if c == "\"" {
                closed = true
                index = text.index(after: index)
                break
            }
            out.append(c)
            index = text.index(after: index)
        }
        guard closed else { return .unclosed }
        let rest = text[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard rest.isEmpty || rest.hasPrefix("#") else { return .rejected("too complex to move safely") }
        return .value(out)
    }
    if first == "#" { return .rejected("empty") }
    var value = text
    if let comment = text.range(of: #"\s#"#, options: .regularExpression) { value = String(text[..<comment.lowerBound]) }
    value = value.trimmingCharacters(in: .whitespaces)
    if value.contains("$") || value.contains("`") { return .rejected("uses shell expansion") }
    if value.contains(" ") || value.contains("\\") || value.contains(";") { return .rejected("too complex to move safely") }
    return .value(value)
}

/// Splits `A=1  B='two'  C=3` into its settings. Returns nil unless the whole
/// line is nothing but settings, so a line that runs a command is left alone.
private func splitAssignments(_ line: String) -> [(key: String, value: String, text: String)]? {
    var rest = Substring(line.trimmingCharacters(in: .whitespaces))
    if rest.hasPrefix("export ") { rest = rest.dropFirst("export ".count) }
    var out: [(key: String, value: String, text: String)] = []
    while true {
        rest = rest.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { break }
        if first == "#" { break }
        guard let equals = rest.firstIndex(of: "=") else { return nil }
        let key = String(rest[..<equals])
        guard isValidVariableName(key) else { return nil }
        var cursor = rest.index(after: equals)
        if let quote = rest[cursor...].first, quote == "'" || quote == "\"" {
            cursor = rest.index(after: cursor)
            var closed = false
            while cursor < rest.endIndex {
                let c = rest[cursor]
                if c == "\\" && quote == "\"" {
                    cursor = rest.index(after: cursor)
                    if cursor < rest.endIndex { cursor = rest.index(after: cursor) }
                    continue
                }
                cursor = rest.index(after: cursor)
                if c == quote {
                    closed = true
                    break
                }
            }
            guard closed else { return nil }
        } else {
            while cursor < rest.endIndex, rest[cursor] != " ", rest[cursor] != "\t" { cursor = rest.index(after: cursor) }
        }
        let raw = String(rest[rest.index(after: equals)..<cursor])
        guard case .value(let value) = parseValue(raw) else {
            if raw.isEmpty {
                out.append((key, "", key + "="))
                rest = rest[cursor...]
                continue
            }
            return nil
        }
        out.append((key, value, String(rest[..<cursor])))
        rest = rest[cursor...]
    }
    return out.count >= 2 ? out : nil
}

private func isSecretEntry(key: String, value: String) -> Bool {
    let named = secretNamePattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    let isPath = value.hasPrefix("/") || value.hasPrefix("~")
    return value.contains("PRIVATE KEY-----") || (named && !isPath)
}

/// Handles values that span lines, so the body of a pasted private key is never
/// mistaken for settings. A key's base64 lines can look just like `NAME=`.
func parseDeploy(_ text: String) -> [DeployEntry] {
    let lines = text.components(separatedBy: "\n")
    var entries: [DeployEntry] = []
    var number = 0
    while number < lines.count {
        let line = lines[number]
        let start = number
        number += 1
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard let match = keyPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line)
        else { continue }
        let key = String(line[keyRange])
        var raw = String(line[valueRange])

        // An unquoted key: skip its body, but do not try to move it.
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("-----BEGIN") {
            while number < lines.count, !lines[number - 1].contains("-----END") { number += 1 }
            entries.append(DeployEntry(key: key, value: "", firstLine: start, lastLine: number - 1, movable: false, reason: "needs quotes around it", looksSecret: true))
            continue
        }

        var parsed = parseValue(raw)
        if case .rejected = parsed, let parts = splitAssignments(line) {
            for part in parts {
                entries.append(
                    DeployEntry(
                        key: part.key, value: part.value, firstLine: start, lastLine: start, movable: !part.value.isEmpty,
                        reason: part.value.isEmpty ? "empty" : nil, looksSecret: isSecretEntry(key: part.key, value: part.value), inline: part.text))
            }
            continue
        }
        while case .unclosed = parsed, number < lines.count {
            raw += "\n" + lines[number]
            number += 1
            parsed = parseValue(raw)
        }

        var value = ""
        var reason: String?
        switch parsed {
        case .value(let found): value = found
        case .rejected(let why): reason = why
        case .unclosed: reason = "unclosed quote"
        }
        // The tail of a key body pasted without quotes can still look like `NAME=`.
        if value.isEmpty && (key != key.uppercased() || key.count > 40) { continue }
        if value.allSatisfy({ $0 == "=" }) && !value.isEmpty && key != key.uppercased() { continue }

        entries.append(
            DeployEntry(
                key: key, value: value, firstLine: start, lastLine: number - 1, movable: reason == nil && !value.isEmpty,
                reason: reason, looksSecret: isSecretEntry(key: key, value: value)))
    }
    return entries
}

// MARK: Finding servers

struct FoundLink {
    let label: String
    let path: String
    let env: [String: String]
}

struct FoundServer {
    let prefix: String
    let host: String
    let user: String?
    let port: Int?
    /// password | key | system
    let auth: String
    let secret: String?
    /// Every .deploy name that moves into the vault with this server.
    let names: [String]
    let links: [FoundLink]

    var target: String { (user.map { $0 + "@" } ?? "") + host }
}

/// Groups `DEPLOY_SSH`, `DEPLOY_PATH`, `WEB_HOST` and friends into servers.
func detectServers(_ entries: [DeployEntry]) -> [FoundServer] {
    let filled = entries.filter { $0.movable && !$0.value.isEmpty }
    func entry(_ name: String) -> DeployEntry? { filled.first { $0.key == name } }

    var prefixes: [String] = []
    for item in filled {
        for suffix in ["_SSH", "_HOST"] where item.key.hasSuffix(suffix) {
            let prefix = String(item.key.dropLast(suffix.count))
            if !prefix.isEmpty && !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
    }

    var servers: [FoundServer] = []
    for prefix in prefixes {
        var names: [String] = []
        var env: [String: String] = [:]
        var host = ""
        var user: String?
        if let ssh = entry(prefix + "_SSH") {
            names.append(ssh.key)
            env["target"] = ssh.key
            if let at = ssh.value.firstIndex(of: "@") {
                user = String(ssh.value[..<at])
                host = String(ssh.value[ssh.value.index(after: at)...])
            } else {
                host = ssh.value
            }
        }
        if let plain = entry(prefix + "_HOST") {
            names.append(plain.key)
            env["host"] = plain.key
            if host.isEmpty { host = plain.value }
        }
        guard !host.isEmpty else { continue }
        if let entryUser = entry(prefix + "_USER") {
            names.append(entryUser.key)
            env["user"] = entryUser.key
            if user == nil { user = entryUser.value }
        }
        var port: Int?
        for name in [prefix + "_SSH_PORT", prefix + "_PORT"] {
            guard let found = entry(name), let parsed = Int(found.value) else { continue }
            names.append(found.key)
            env["port"] = found.key
            port = parsed
            break
        }
        var auth = "system"
        var secret: String?
        for name in [prefix + "_SSH_PASSWORD", prefix + "_PASSWORD", prefix + "_PASS"] {
            guard let found = entry(name) else { continue }
            names.append(found.key)
            env["password"] = found.key
            auth = "password"
            secret = found.value
            break
        }
        // A pasted key moves. A path to a key file stays, because the file is what ssh uses.
        for name in [prefix + "_SSH_KEY", prefix + "_KEY"] {
            guard auth == "system", let found = entry(name), found.value.contains("PRIVATE KEY-----") else { continue }
            names.append(found.key)
            env["key"] = found.key
            auth = "key"
            secret = found.value
            break
        }
        var path = ""
        if let found = entry(prefix + "_PATH") {
            names.append(found.key)
            env["path"] = found.key
            path = found.value
        }
        let label = prefix == "DEPLOY" ? "main" : prefix.lowercased()
        var links = [FoundLink(label: label, path: path, env: env)]

        // e.g. DEPLOY_WEB_PATH: a second folder on the same server.
        for item in filled where item.key.hasPrefix(prefix + "_") && item.key.hasSuffix("_PATH") && item.key != prefix + "_PATH" {
            let middle = item.key.dropFirst(prefix.count + 1).dropLast("_PATH".count)
            guard !middle.isEmpty, !prefixes.contains(prefix + "_" + middle) else { continue }
            names.append(item.key)
            links.append(FoundLink(label: middle.lowercased(), path: item.value, env: ["path": item.key]))
        }
        servers.append(FoundServer(prefix: prefix, host: host, user: user, port: port, auth: auth, secret: secret, names: names, links: links))
    }
    return servers
}

/// Names a script sets to a fixed value. Moving one out of .deploy would not
/// work, because the script's own value replaces what the vault supplies.
func namesScriptOverrides(script: String, names: [String]) -> [String] {
    guard let text = try? String(contentsOfFile: script, encoding: .utf8) else { return [] }
    var out: [String] = []
    for name in names {
        let pattern = "(^|[\\s;])\(NSRegularExpression.escapedPattern(for: name))=(''|\"\"|[^$\"'\\s]|\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            let string = String(line)
            if regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
                out.append(name)
                break
            }
        }
    }
    return out
}

/// Variable names this project's deploy files mention. Strict on purpose:
/// uppercase and short, so a line of a pasted key can never count as one.
func deployVariableNames(projectPath: String) -> Set<String> {
    let pattern = try! NSRegularExpression(pattern: "^[#\\s]*(?:export\\s+)?([A-Z_][A-Z0-9_]{0,39})(?:=| moved to the vault)")
    var names = Set<String>()
    for file in [".deploy", ".deploy.example"] {
        guard let text = try? String(contentsOfFile: projectPath + "/" + file, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            let string = String(line)
            guard let match = pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
                let range = Range(match.range(at: 1), in: string)
            else { continue }
            names.insert(String(string[range]))
        }
    }
    return names
}

/// Which script variables to fill for a mapping, preferring names already in use.
func suggestedLinkEnv(prefix: String, names: Set<String>) -> [String: String] {
    let options: [(String, [String])] = [
        ("target", [prefix + "_SSH"]),
        ("host", [prefix + "_HOST"]),
        ("user", [prefix + "_USER"]),
        ("port", [prefix + "_SSH_PORT", prefix + "_PORT"]),
        ("path", [prefix + "_PATH"]),
        ("password", [prefix + "_SSH_PASSWORD", prefix + "_PASSWORD", prefix + "_PASS"]),
        ("key", [prefix + "_SSH_KEY", prefix + "_KEY"]),
    ]
    var env: [String: String] = [:]
    for (field, candidates) in options {
        if let used = candidates.first(where: { names.contains($0) }) { env[field] = used }
    }
    if !env.isEmpty { return env }
    return [
        "target": prefix + "_SSH", "host": prefix + "_HOST", "user": prefix + "_USER", "port": prefix + "_PORT",
        "path": prefix + "_PATH", "password": prefix + "_PASSWORD",
    ]
}

/// The script a project most likely deploys with, if any.
func findDeployScript(in projectPath: String) -> String? {
    ["deploy.sh", "scripts/deploy.sh", "deploy/deploy.sh", "bin/deploy"].first {
        FileManager.default.fileExists(atPath: projectPath + "/" + $0)
    }
}

func makeAction(name: String, script: String, projectPath: String, path: String?) throws -> Action {
    var pinned = [script]
    if script != ".deploy", FileManager.default.fileExists(atPath: projectPath + "/.deploy") { pinned.append(".deploy") }
    let pins = try pinned.map { file -> Pin in
        guard let hash = sha256Hex(ofFile: projectPath + "/" + file) else { throw VaultError("Could not read \(file).") }
        return Pin(path: file, sha256: hash)
    }
    return Action(name: name, script: script, args: [], pins: pins, path: path)
}

/// Moves the chosen servers and secrets out of a project's .deploy file.
/// The vault is saved and read back before the file is touched.
func importDeploy(projectID: String, servers chosenPrefixes: [String], keys: [String], loginPath: String?) throws -> (servers: Int, keys: Int) {
    var data = try Store.load()
    guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { throw VaultError("Unknown project.") }
    let root = data.projects[index].path
    let file = root + "/.deploy"
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { throw VaultError("Could not read .deploy.") }
    let entries = parseDeploy(text)
    let found = detectServers(entries).filter { chosenPrefixes.contains($0.prefix) }
    let serverNames = Set(found.flatMap(\.names))
    let chosenKeys = entries.filter { keys.contains($0.key) && $0.movable && !$0.value.isEmpty && !serverNames.contains($0.key) }
    guard !found.isEmpty || !chosenKeys.isEmpty else { throw VaultError("Nothing to move.") }

    for server in found {
        // The same login on the same machine is one server shared by several projects.
        let existing = data.servers.first {
            $0.host == server.host && $0.user == server.user && ($0.port ?? 22) == (server.port ?? 22) && $0.auth == server.auth && $0.secret == server.secret
        }
        var serverID = existing?.id
        if serverID == nil {
            var name = server.host
            if data.servers.contains(where: { $0.name == name }) { name = server.target }
            if data.servers.contains(where: { $0.name == name }) { name = "\(server.target) (\(data.projects[index].name))" }
            let created = Server(
                id: newID(), name: name, host: server.host, user: server.user, port: server.port, auth: server.auth,
                secret: server.secret, updatedAt: Date())
            data.servers.append(created)
            serverID = created.id
        }
        for link in server.links {
            var label = link.label
            if data.projects[index].links.contains(where: { $0.label == label }) { label = "\(label)-\(server.prefix.lowercased())" }
            guard !data.projects[index].links.contains(where: { $0.label == label }) else { continue }
            data.projects[index].links.append(ServerLink(id: newID(), serverID: serverID ?? "", label: label, path: link.path, env: link.env))
        }
    }

    for entry in chosenKeys {
        if let existing = data.secrets.first(where: { $0.env == entry.key && $0.value == entry.value }) {
            if !data.projects[index].secretIDs.contains(existing.id) { data.projects[index].secretIDs.append(existing.id) }
            continue
        }
        var name = entry.key
        if data.secrets.contains(where: { $0.name == name }) { name = "\(entry.key) (\(data.projects[index].name))" }
        let secret = Secret(
            id: newID(), name: name, env: entry.key, kind: "password", value: entry.value, host: nil, user: nil, port: nil,
            allowedHosts: nil, headerName: nil, headerPrefix: nil, updatedAt: Date())
        data.secrets.append(secret)
        data.projects[index].secretIDs.append(secret.id)
    }
    try Store.save(data)

    let check = try Store.load()
    for entry in chosenKeys where !check.secrets.contains(where: { $0.env == entry.key && $0.value == entry.value }) {
        throw VaultError("Could not confirm \(entry.key) was saved, so .deploy was left unchanged.")
    }
    for server in found where !check.servers.contains(where: { $0.host == server.host && $0.secret == server.secret }) {
        throw VaultError("Could not confirm \(server.host) was saved, so .deploy was left unchanged.")
    }

    var lines = text.components(separatedBy: "\n")
    let moved = entries.filter { serverNames.contains($0.key) || chosenKeys.map(\.key).contains($0.key) }
    for start in Set(moved.map(\.firstLine)).sorted(by: >) {
        let leaving = moved.filter { $0.firstLine == start }
        var replacement = leaving.map { "# \($0.key) moved to the vault" }
        // Settings sharing the line with a moved one stay behind on their own line.
        let leavingKeys = Set(leaving.map(\.key))
        let staying = entries.filter { $0.firstLine == start && $0.inline != nil && !leavingKeys.contains($0.key) }.compactMap(\.inline)
        if !staying.isEmpty {
            let exported = lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("export ")
            replacement.append((exported ? "export " : "") + staying.joined(separator: "  "))
        }
        lines.replaceSubrange(start...leaving[0].lastLine, with: replacement)
    }
    let mode = (try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    let tmp = file + ".tmp-\(getpid())"
    guard FileManager.default.createFile(atPath: tmp, contents: Data(lines.joined(separator: "\n").utf8), attributes: [.posixPermissions: mode]),
        rename(tmp, file) == 0
    else {
        unlink(tmp)
        throw VaultError("The vault was saved but .deploy could not be rewritten.")
    }

    var after = check
    if let script = findDeployScript(in: root), !after.projects[index].actions.contains(where: { $0.name == "deploy" }) {
        after.projects[index].actions.append(try makeAction(name: "deploy", script: script, projectPath: root, path: loginPath))
    } else {
        // .deploy just changed, so re-approve the actions that pin it.
        for i in after.projects[index].actions.indices {
            for p in after.projects[index].actions[i].pins.indices where after.projects[index].actions[i].pins[p].path == ".deploy" {
                if let hash = sha256Hex(ofFile: file) { after.projects[index].actions[i].pins[p].sha256 = hash }
            }
        }
    }
    try Store.save(after)
    return (found.count, chosenKeys.count)
}
