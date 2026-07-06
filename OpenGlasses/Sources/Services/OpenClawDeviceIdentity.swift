import Foundation
import CryptoKit
import Security

/// Stable Ed25519 device identity for OpenClaw gateway protocol v4.
///
/// The gateway requires remote/node clients to present a `device` block in the
/// connect frame: { id, publicKey, signature, signedAt, nonce } where:
/// - id = SHA-256 hex of the raw 32-byte Ed25519 public key
/// - publicKey = raw public key bytes, base64url (unpadded)
/// - signature = Ed25519 over the v3 auth payload string (UTF-8), base64url
/// - nonce = the nonce from the server's `connect.challenge` event
///
/// v3 payload: "v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily"
enum OpenClawDeviceIdentity {
    private static let keychainService = "com.openglasses.openclaw.device-identity"
    private static let keychainAccount = "ed25519-private-key"
    private static var cachedKey: Curve25519.Signing.PrivateKey?

    /// Load (or create on first use) the persistent device signing key.
    static func signingKey() -> Curve25519.Signing.PrivateKey {
        if let cached = cachedKey { return cached }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            cachedKey = key
            return key
        }

        let key = Curve25519.Signing.PrivateKey()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(addQuery as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)
        NSLog("[OpenClawIdentity] Generated new device identity: %@", deviceId(for: key))
        cachedKey = key
        return key
    }

    static func deviceId(for key: Curve25519.Signing.PrivateKey) -> String {
        let digest = SHA256.hash(data: key.publicKey.rawRepresentation)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64Url(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Build the signed `device` block for a connect frame.
    /// - Parameters match the fields the gateway includes in the v3 auth payload.
    static func deviceConnectParams(
        clientId: String,
        clientMode: String,
        role: String,
        scopes: [String],
        token: String?,
        nonce: String,
        platform: String,
        deviceFamily: String = ""
    ) -> [String: Any] {
        let key = signingKey()
        let id = deviceId(for: key)
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = [
            "v3",
            id,
            clientId,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token ?? "",
            nonce,
            platform.lowercased(),
            deviceFamily.lowercased()
        ].joined(separator: "|")

        let signatureData = (try? key.signature(for: Data(payload.utf8))) ?? Data()
        return [
            "id": id,
            "publicKey": base64Url(key.publicKey.rawRepresentation),
            "signature": base64Url(signatureData),
            "signedAt": signedAtMs,
            "nonce": nonce
        ]
    }

    /// Extract the nonce from a `connect.challenge` event JSON string, if present.
    static func challengeNonce(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "event",
              json["event"] as? String == "connect.challenge",
              let payload = json["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String,
              !nonce.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return nonce.trimmingCharacters(in: .whitespaces)
    }

    /// True when a connect error response indicates pairing approval is pending
    /// (device presented identity but the gateway is awaiting operator approval).
    static func isPairingPending(_ responseJSON: [String: Any]) -> Bool {
        guard let error = responseJSON["error"] as? [String: Any] else { return false }
        let code = error["code"] as? String ?? ""
        if code == "NOT_PAIRED" { return true }
        let message = (error["message"] as? String ?? "").lowercased()
        return message.contains("pairing") || message.contains("not paired")
    }
}
