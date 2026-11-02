import Foundation

struct AppRecord: Codable {
    var id: String
    var name: String
    /// connected | needs-auth | failed | unknown
    var status: String
}

/// The tool prefix an agent uses for this connection, e.g. `mcp__<id>__send`.
func normalizedAppID(_ name: String) -> String {
    String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
}

func displayName(forApp raw: String) -> String {
    var name = raw
    if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
    if name.hasPrefix("plugin:") { name = name.split(separator: ":").last.map(String.init) ?? name }
    return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

/// Keeps only the name and health from each line. URLs and arguments can hold tokens.
func parseAppList(_ text: String) -> [AppRecord] {
    var seen = Set<String>()
    var out: [AppRecord] = []
    for line in text.split(separator: "\n") {
        guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards), dash.lowerBound > colon.lowerBound else { continue }
        let raw = String(line[..<colon.lowerBound])
        let health = line[dash.upperBound...]
        let status = health.contains("Connected") ? "connected" : health.contains("Needs") ? "needs-auth" : health.contains("Failed") ? "failed" : "unknown"
        let id = normalizedAppID(raw)
        if seen.insert(id).inserted { out.append(AppRecord(id: id, name: displayName(forApp: raw), status: status)) }
    }
    return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
}

enum AppCache {
    static func load() -> [AppRecord] {
        guard let data = FileManager.default.contents(atPath: Paths.appsFile) else { return [] }
        return (try? JSONDecoder().decode([AppRecord].self, from: data)) ?? []
    }
    static func save(_ apps: [AppRecord]) {
        guard (try? Paths.ensureHome()) != nil, let data = try? JSONEncoder().encode(apps) else { return }
        try? writePrivate(data, to: Paths.appsFile)
    }
}

/// Asks the agent's own CLI which apps are connected. Slow: it health-checks each one.
func refreshApps() -> [AppRecord]? {
    let home = realHome()
    guard let tool = findAgentTool() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = ["mcp", "list"]
    process.currentDirectoryURL = URL(fileURLWithPath: home)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120) { if process.isRunning { process.terminate() } }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let apps = parseAppList(String(decoding: output, as: UTF8.self))
    if !apps.isEmpty { AppCache.save(apps) }
    return apps
}

func loginShellPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", "printf %s \"$PATH\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let value = String(decoding: output, as: UTF8.self)
    // Absolute entries only: a relative one would resolve inside the project.
    let parts = value.split(separator: ":").filter { $0.hasPrefix("/") }
    return parts.isEmpty ? nil : parts.joined(separator: ":")
}
