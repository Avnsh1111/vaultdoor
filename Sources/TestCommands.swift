#if VAULT_TEST
import Foundation

// Compiled only into the test binary. The installed app has none of these
// commands, so none of them can print or write vault contents there.

func runTestCommand(_ name: String, _ args: [String]) -> Never {
    do {
        switch name {
        case "__seed":
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            try Store.save(try decoder.decode(VaultData.self, from: Data(contentsOf: URL(fileURLWithPath: args[0]))))
        case "__state":
            print(encodeJSON(publicState(try Store.load(), unlocked: false, appsLoading: false)))
        case "__export":
            FileManager.default.createFile(atPath: args[1], contents: try Store.exportBlob(try Store.load(), passphrase: args[0]))
        case "__import":
            try Store.save(try Store.importBlob(Data(contentsOf: URL(fileURLWithPath: args[1])), passphrase: args[0]))
        case "__scan":
            let entries = parseDeploy(try String(contentsOfFile: args[0], encoding: .utf8))
            for row in entries {
                print("\(row.key) secret=\(row.looksSecret) movable=\(row.movable) \(row.reason ?? "")")
            }
            for server in detectServers(entries) {
                let links = server.links.map { "\($0.label):\($0.path)" }.joined(separator: ",")
                print("server \(server.prefix) \(server.target) port=\(server.port ?? 0) auth=\(server.auth) links=\(links)")
            }
        case "__import-deploy":
            // __import-deploy <project> <SERVER,PREFIXES> <KEY,NAMES>
            func list(_ text: String) -> [String] { text.split(separator: ",").map(String.init) }
            let moved = try importDeploy(projectID: args[0], servers: list(args[1]), keys: list(args[2]), loginPath: nil)
            print("servers=\(moved.servers) keys=\(moved.keys)")
        case "__prompt":
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == args[0] }) else { fatalError("no project") }
            print(buildDeployPrompt(project: project, data: data, scriptPath: args[1], notes: args.count > 2 ? args[2] : nil))
        case "__generate":
            let data = try Store.load()
            guard let project = data.projects.first(where: { $0.id == args[0] }) else { fatalError("no project") }
            guard isSafeScriptPath(args[1]) else {
                print("unsafe path")
                exit(4)
            }
            let job = GeneratorJob(project: project, scriptPath: args[1])
            job.run(
                prompt: buildDeployPrompt(project: project, data: data, scriptPath: args[1], notes: args.count > 2 ? args[2] : nil),
                lint: lintContext(project: project, data: data), loginPath: nil, takenActionNames: project.actions.map(\.name))
            print(encodeJSON(job.status()))
            if ProcessInfo.processInfo.environment["VAULT_TEST_DISCARD"] != nil { job.discard() }
        case "__lint":
            let text = try String(contentsOfFile: args[0], encoding: .utf8)
            func list(_ value: String) -> [String] { value.split(separator: ",").map(String.init) }
            for finding in lintDeployScript(text, secretVariables: Set(list(args[1])), knownVariables: Set(list(args[2])), literals: list(args[3])) {
                print("\(finding.line) \(finding.level) \(finding.message)")
            }
        case "__overrides":
            print(namesScriptOverrides(script: args[0], names: Array(args.dropFirst())).joined(separator: ","))
        case "__apps":
            for app in parseAppList(try String(contentsOfFile: args[0], encoding: .utf8)) { print("\(app.id)|\(app.name)|\(app.status)") }
        case "__master-create":
            _ = try MasterKey.load(createIfMissing: true)
            print("created")
        case "__master-read":
            _ = try MasterKey.load(createIfMissing: false)
            print("read-ok")
        case "__gui-selftest":
            runDashboard(selfTest: true)
        default:
            fatalError("unknown test command")
        }
        exit(0)
    } catch {
        stderrLine("\(error)")
        exit(1)
    }
}
#endif
