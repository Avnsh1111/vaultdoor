// Plays the part of another program on this Mac trying to read the vault's key
// from the Keychain. User interaction is off, so it gets a refusal, not a dialog.
import Foundation
import Security

SecKeychainSetUserInteractionAllowed(false)
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: CommandLine.arguments[1],
    kSecAttrAccount as String: "default",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]
var out: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &out)
print(status == errSecSuccess ? "READ-THE-KEY" : "refused \(status)")
