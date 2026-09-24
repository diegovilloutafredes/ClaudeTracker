// Update-signing key tool. The Ed25519 private key lives only in the login Keychain; the app
// embeds the public half (`updateSigningPublicKey` in UpdateService.swift) and refuses to
// install a release zip whose `.sig` it doesn't verify.
//
//   xcrun --sdk macosx swift scripts/update-signing.swift generate      # once: create the key, print the public key
//   xcrun --sdk macosx swift scripts/update-signing.swift public-key    # print the public key (base64)
//   xcrun --sdk macosx swift scripts/update-signing.swift sign <file>   # write <file>.sig
//
// Back the key up (Keychain Access → "ClaudeTracker update signing key" → Show password).
// If it is lost, installed apps can't verify new releases and their users must update by
// hand once, from a build that embeds a new key.

import CryptoKit
import Foundation
import Security

let service = "com.claudetracker.update-signing"
let account = "ed25519-private-key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        fail("No update-signing key in the Keychain (OSStatus \(status)). Run `generate` once first.")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("The Keychain item is not a raw Ed25519 private key.")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: "ClaudeTracker update signing key",
        kSecValueData as String: key.rawRepresentation,
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    // Never replace an existing key: shipped apps trust its public half.
    if status == errSecDuplicateItem { fail("An update-signing key already exists; refusing to replace it.") }
    guard status == errSecSuccess else { fail("Could not store the key in the Keychain (OSStatus \(status)).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count == 2 else { fail("usage: update-signing.swift sign <file>") }
    let file = URL(fileURLWithPath: arguments[1])
    guard let data = try? Data(contentsOf: file) else { fail("Cannot read \(file.path).") }
    let key = loadKey()
    guard let signature = try? key.signature(for: data), key.publicKey.isValidSignature(signature, for: data) else {
        fail("Signing failed its own verification.")
    }
    do {
        try signature.write(to: file.appendingPathExtension("sig"))
    } catch {
        fail("Cannot write the signature: \(error.localizedDescription)")
    }
    print(file.appendingPathExtension("sig").path)

default:
    fail("usage: update-signing.swift generate | public-key | sign <file>")
}
