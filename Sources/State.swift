import Foundation

// Everything the dashboard's web view ever receives. None of these types has
// a field for a secret's value, so it cannot reach the page by accident.

struct PublicServer: Encodable {
    let id: String
    let name: String
    let host: String
    let user: String?
    let port: Int?
    let auth: String
    let hasLogin: Bool
    let usedBy: [PublicUse]
    let updatedAt: Date
}

struct PublicUse: Encodable {
    let project: String
    let label: String
    let path: String
}

struct PublicLink: Encodable {
    let id: String
    let serverID: String
    let label: String
    let path: String
    let env: [String: String]
}

struct PublicKey: Encodable {
    let id: String
    let name: String
    let env: String
    let kind: String
    let allowedHosts: [String]?
    let headerName: String?
    let headerPrefix: String?
    let usedBy: [String]
    let updatedAt: Date
}

struct PublicAction: Encodable {
    let name: String
    let script: String
    let changed: [String]
}

struct PublicProject: Encodable {
    let id: String
    let name: String
    let path: String
    let keyIDs: [String]
    let links: [PublicLink]
    let disabledApps: [String]
    let actions: [PublicAction]
    let hasDeploy: Bool
}

struct PublicSuggestion: Encodable {
    let name: String
    let path: String
}

struct PublicState: Encodable {
    let projects: [PublicProject]
    let servers: [PublicServer]
    let keys: [PublicKey]
    let apps: [AppRecord]
    let activity: [ActivityEntry]
    let suggested: [PublicSuggestion]
    let unlocked: Bool
    let appsLoading: Bool
}

/// Project folders that hold a .deploy file and are not in the vault yet.
func suggestedProjects(_ data: VaultData) -> [PublicSuggestion] {
    let manager = FileManager.default
    let known = Set(data.projects.map { canonicalPath($0.path) })
    let home = realHome()
    var roots = ["PhpstormProjects", "WebstormProjects", "IdeaProjects", "Projects", "projects", "Code", "code", "Developer", "Sites", "dev", "src", "work"].map { home + "/" + $0 }
    roots += data.projects.map { ($0.path as NSString).deletingLastPathComponent }
    var out: [PublicSuggestion] = []
    var seen = Set<String>()
    for root in Set(roots) {
        for name in ((try? manager.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
            let path = canonicalPath(root + "/" + name)
            guard !known.contains(path), seen.insert(path).inserted, manager.fileExists(atPath: path + "/.deploy") else { continue }
            out.append(PublicSuggestion(name: name, path: path))
        }
    }
    return out
}

func publicState(_ data: VaultData, unlocked: Bool, appsLoading: Bool) -> PublicState {
    let projects = data.projects.map { project in
        PublicProject(
            id: project.id, name: project.name, path: project.path, keyIDs: project.secretIDs,
            links: project.links.map { PublicLink(id: $0.id, serverID: $0.serverID, label: $0.label, path: $0.path, env: $0.env) },
            disabledApps: project.disabledApps,
            actions: project.actions.map {
                PublicAction(name: $0.name, script: $0.script, changed: changedPins($0, projectPath: project.path))
            },
            hasDeploy: FileManager.default.fileExists(atPath: project.path + "/.deploy"))
    }
    let keys = data.secrets.map { secret in
        PublicKey(
            id: secret.id, name: secret.name, env: secret.env, kind: secret.kind, allowedHosts: secret.allowedHosts,
            headerName: secret.headerName, headerPrefix: secret.headerPrefix,
            usedBy: data.projects.filter { $0.secretIDs.contains(secret.id) }.map(\.name),
            updatedAt: secret.updatedAt)
    }
    let servers = data.servers.map { server in
        PublicServer(
            id: server.id, name: server.name, host: server.host, user: server.user, port: server.port, auth: server.auth,
            hasLogin: server.secret?.isEmpty == false,
            usedBy: data.projects.flatMap { project in
                project.links.filter { $0.serverID == server.id }.map { PublicUse(project: project.name, label: $0.label, path: $0.path) }
            },
            updatedAt: server.updatedAt)
    }
    return PublicState(
        projects: projects, servers: servers, keys: keys, apps: AppCache.load(), activity: Activity.recent(30),
        suggested: suggestedProjects(data), unlocked: unlocked, appsLoading: appsLoading)
}

func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
