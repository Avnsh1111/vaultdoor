import CommonCrypto
import CryptoKit
import Foundation
import Security

struct VaultError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Secret: Codable {
    var id: String
    var name: String
    var env: String
    /// password | token | ssh-password | ssh-key
    var kind: String
    var value: String
    var host: String?
    var user: String?
    var port: Int?
    var allowedHosts: [String]?
    var headerName: String?
    var headerPrefix: String?
    var updatedAt: Date
}

struct Pin: Codable {
    var path: String
    var sha256: String
}

struct Action: Codable {
    var name: String
    var script: String
    var args: [String]
    var pins: [Pin]
    /// PATH captured from the user's login shell when the action was approved.
    var path: String?
}

/// A machine the AI can reach, and the login for it.
struct Server: Codable {
    var id: String
    var name: String
    var host: String
    var user: String?
    var port: Int?
    /// password | key | system (this Mac's own SSH setup, nothing stored)
    var auth: String
    var secret: String?
    var updatedAt: Date

    var target: String { (user.map { $0 + "@" } ?? "") + host }
}

/// Maps a server and a folder on it to a project.
struct ServerLink: Codable {
    var id: String
    var serverID: String
    /// What the project calls this mapping: `vaultdoor ssh <label> -- ...`
    var label: String
    var path: String
    /// Which script variable receives each field: target, host, user, port, path, password, key.
    var env: [String: String]
}

struct Project: Codable {
    var id: String
    var name: String
    var path: String
    var secretIDs: [String]
    var disabledApps: [String]
    var actions: [Action]
    var links: [ServerLink] = []
}

struct VaultData: Codable {
    var version = 1
    var secrets: [Secret] = []
    var servers: [Server] = []
    var projects: [Project] = []
}

// Written by hand so vaults saved before servers existed still open.
extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        secretIDs = try c.decode([String].self, forKey: .secretIDs)
        disabledApps = try c.decode([String].self, forKey: .disabledApps)
        actions = try c.decode([Action].self, forKey: .actions)
        links = try c.decodeIfPresent([ServerLink].self, forKey: .links) ?? []
    }
}

extension VaultData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        secrets = try c.decodeIfPresent([Secret].self, forKey: .secrets) ?? []
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
    }
}

/// SSH logins used to be stored as keys. They become servers, keeping their
/// variable name so scripts that read it still work.
func migrateLogins(_ data: inout VaultData) {
    for secret in data.secrets where secret.kind.hasPrefix("ssh-") {
        guard let host = secret.host, !host.isEmpty else { continue }
        let isPassword = secret.kind == "ssh-password"
        data.servers.append(
            Server(
                id: secret.id, name: secret.name, host: host, user: secret.user, port: secret.port,
                auth: isPassword ? "password" : "key", secret: secret.value, updatedAt: secret.updatedAt))
        for index in data.projects.indices where data.projects[index].secretIDs.contains(secret.id) {
            data.projects[index].secretIDs.removeAll { $0 == secret.id }
            data.projects[index].links.append(
                ServerLink(id: secret.id + "-" + data.projects[index].id, serverID: secret.id, label: secret.name, path: "", env: isPassword ? ["password": secret.env] : [:]))
        }
    }
    data.secrets.removeAll { secret in secret.kind.hasPrefix("ssh-") && data.servers.contains { $0.id == secret.id } }
}

/// The account's real home directory. Ignores $HOME so a caller cannot redirect it.
func realHome() -> String {
    guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
    return String(cString: dir)
}

enum Paths {
    static var home: String {
        #if VAULT_TEST
        return ProcessInfo.processInfo.environment["VAULT_TEST_HOME"] ?? "/nonexistent"
        #else
        return realHome() + "/Library/Application Support/VaultDoor"
        #endif
    }
    static var vaultFile: String { home + "/vault.enc" }
    static var activityFile: String { home + "/activity.log" }
    static var appsFile: String { home + "/apps.json" }

    static func ensureHome() throws {
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

enum MasterKey {
    #if VAULT_KEYCHAIN_TEST
    static let service = "local.vault.selftest"
    #else
    static let service = "local.vault.master"
    #endif
    static let account = "default"
    private static var cached: SymmetricKey?
    private static let lock = NSLock()

    /// Reads the Keychain once per run, so a prompt can only appear the first time.
    /// That read can wait on the user, so the dashboard makes it off the main thread.
    static func load(createIfMissing: Bool) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let key = try fetch(createIfMissing: createIfMissing)
        cached = key
        return key
    }

    private static func fetch(createIfMissing: Bool) throws -> SymmetricKey {
        #if VAULT_TEST
        let environment = ProcessInfo.processInfo.environment
        if let delay = environment["VAULT_TEST_KEY_DELAY"].flatMap({ Double($0) }) { Thread.sleep(forTimeInterval: delay) }
        if environment["VAULT_TEST_KEY_FAIL_ONCE"] != nil && !testFailureUsed {
            testFailureUsed = true
            throw VaultError("Access to the vault's key was denied in the Keychain.")
        }
        #endif
        #if VAULT_TEST && !VAULT_KEYCHAIN_TEST
        let path = Paths.home + "/test-master.key"
        if let data = FileManager.default.contents(atPath: path) { return SymmetricKey(data: data) }
        guard createIfMissing else { throw VaultError("No test master key.") }
        try Paths.ensureHome()
        let data = randomBytes(32)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        return SymmetricKey(data: data)
        #else
        if let data = try readKeychain() { return SymmetricKey(data: data) }
        guard createIfMissing else { throw VaultError("The vault's key is missing from the Keychain.") }
        if FileManager.default.fileExists(atPath: Paths.vaultFile) {
            throw VaultError("The vault exists but its key is missing from the Keychain. Restore from an export.")
        }
        let data = randomBytes(32)
        try writeKeychain(data)
        return SymmetricKey(data: data)
        #endif
    }

    #if VAULT_TEST
    private static var testFailureUsed = false
    #endif

    private static func readKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw VaultError("Access to the vault's key was denied in the Keychain.")
        default: throw VaultError("Keychain error \(status).")
        }
    }

    /// No access list is passed, so macOS trusts only this exact signed binary.
    /// Any other program, `security` included, gets a prompt the user can refuse.
    private static func writeKeychain(_ data: Data) throws {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Vault master key",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError("Could not store the vault's key (\(status)).") }
    }
}

func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        fatalError("Secure random generator failed.")
    }
    return Data(bytes)
}

func newID() -> String { UUID().uuidString.lowercased() }

enum Store {
    private static let aad = Data("vault-v1".utf8)

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func load() throws -> VaultData {
        guard FileManager.default.fileExists(atPath: Paths.vaultFile) else { return VaultData() }
        let key = try MasterKey.load(createIfMissing: false)
        let blob = try Data(contentsOf: URL(fileURLWithPath: Paths.vaultFile))
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key, authenticating: aad)
        } catch {
            throw VaultError("The vault file failed its integrity check, so nothing was used.")
        }
        var data = try decoder.decode(VaultData.self, from: plain)
        migrateLogins(&data)
        return data
    }

    static func save(_ data: VaultData) throws {
        try Paths.ensureHome()
        let key = try MasterKey.load(createIfMissing: true)
        let plain = try encoder.encode(data)
        guard let blob = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else {
            throw VaultError("Could not encrypt the vault.")
        }
        try writePrivate(blob, to: Paths.vaultFile)
    }

    static func exportBlob(_ data: VaultData, passphrase: String) throws -> Data {
        let salt = randomBytes(16)
        let rounds = 600_000
        let key = try derive(passphrase: passphrase, salt: salt, rounds: rounds)
        guard let box = try AES.GCM.seal(try encoder.encode(data), using: key, authenticating: aad).combined else {
            throw VaultError("Could not encrypt the export.")
        }
        let file: [String: Any] = [
            "format": "vault-export-1",
            "salt": salt.base64EncodedString(),
            "rounds": rounds,
            "box": box.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
    }

    static func importBlob(_ blob: Data, passphrase: String) throws -> VaultData {
        guard let file = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
            file["format"] as? String == "vault-export-1",
            let saltText = file["salt"] as? String, let salt = Data(base64Encoded: saltText),
            let rounds = file["rounds"] as? Int, (100_000...10_000_000).contains(rounds),
            let boxText = file["box"] as? String, let box = Data(base64Encoded: boxText)
        else { throw VaultError("That is not a vault export file.") }
        let key = try derive(passphrase: passphrase, salt: salt, rounds: rounds)
        do {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key, authenticating: aad)
            var data = try decoder.decode(VaultData.self, from: plain)
            migrateLogins(&data)
            return data
        } catch {
            throw VaultError("Wrong passphrase, or the export file was changed.")
        }
    }

    private static func derive(passphrase: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        }
        guard status == 0 else { throw VaultError("Could not derive a key from the passphrase.") }
        return SymmetricKey(data: Data(out))
    }
}

/// Atomic write, owner read/write only.
func writePrivate(_ data: Data, to path: String) throws {
    let tmp = path + ".tmp-\(getpid())"
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw VaultError("Could not write \(path).")
    }
    guard rename(tmp, path) == 0 else {
        unlink(tmp)
        throw VaultError("Could not replace \(path).")
    }
}

func sha256Hex(ofFile path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

func projectFor(path: String, in data: VaultData) -> Project? {
    let target = canonicalPath(path)
    return data.projects
        .filter { let root = canonicalPath($0.path); return target == root || target.hasPrefix(root + "/") }
        .max { canonicalPath($0.path).count < canonicalPath($1.path).count }
}

/// Files whose contents no longer match what the user approved.
func changedPins(_ action: Action, projectPath: String) -> [String] {
    action.pins.filter { sha256Hex(ofFile: projectPath + "/" + $0.path) != $0.sha256 }.map(\.path)
}

struct ActivityEntry: Codable {
    var time: Date
    var project: String
    var kind: String
    var item: String
    var itemName: String
    var detail: String
    var exit: Int32?
}

enum Activity {
    /// Never receives secret values or remote command text.
    static func log(_ entry: ActivityEntry) {
        guard (try? Paths.ensureHome()) != nil else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let path = Paths.activityFile
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    static func recent(_ count: Int) -> [ActivityEntry] {
        guard let text = try? String(contentsOfFile: Paths.activityFile, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(count).compactMap {
            try? decoder.decode(ActivityEntry.self, from: Data($0.utf8))
        }
    }
}
