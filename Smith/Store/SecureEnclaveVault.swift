import Foundation
import CryptoKit
import LocalAuthentication

/// Secrets locked to this device's Secure Enclave.
///
/// The Secure Enclave makes a P-256 key that never leaves the chip; Smith
/// only holds an opaque handle that works on this device's chip and nowhere
/// else. A secret is sealed to it with ECIES (a one-time P-256 key, ECDH,
/// HKDF-SHA256, AES-GCM), and only that sealed copy is saved. Copied to
/// another device, the files open nothing.
///
/// Two locks:
///  - `device`: opens without a prompt (Smith's storage key, sync key, API key)
///  - `presence`: needs Face ID / Touch ID or the device passcode each time
///    (the quick-unlock copy of the Chronicles key)
nonisolated enum SecureEnclaveVault {
    enum Lock: String { case device, presence }

    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The presence key made before biometry-only ("se-presence.handle") allowed the
    /// device passcode; a new key under the stricter rule gets a new name.
    private static func handleURL(_ lock: Lock) -> URL {
        EncryptedFile.folder.appendingPathComponent(lock == .presence ? "se-presence-2.handle" : "se-\(lock.rawValue).handle")
    }

    /// Touch ID / Face ID is set up on this device.
    static var hasBiometry: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }

    private static func accessControl(_ lock: Lock) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        // Presence: the fingerprints or face enrolled now, and nothing else. The device
        // passcode is not enough (someone who knows it would get the Chronicles key),
        // and enrolling a new finger makes the sealed copy unusable.
        let flags: SecAccessControlCreateFlags = lock == .presence ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return ac
    }

    /// The lock's key: loaded from its handle, or made (once) inside the chip.
    private static func key(_ lock: Lock, context: LAContext? = nil) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let handle = try? Data(contentsOf: handleURL(lock)) {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: context)
        }
        let k = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl(lock), authenticationContext: context)
        try write(k.dataRepresentation, to: handleURL(lock))
        return k
    }

    private static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private static let info = Data("smith:se-wrap:v1".utf8)

    /// Seals with the lock's public key (no prompt needed to seal).
    static func seal(_ plaintext: Data, lock: Lock) throws -> Data {
        let recipient = try key(lock).publicKey
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.publicKey.x963Representation, sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.seal(plaintext, using: sym)
        return ephemeral.publicKey.x963Representation + box.combined!
    }

    /// Opens inside the chip. With the presence lock, the system asks for Face ID / Touch ID / passcode.
    static func open(_ sealed: Data, lock: Lock, reason: String? = nil) throws -> Data {
        guard sealed.count > 65 + 28 else { throw CocoaError(.coderReadCorrupt) }
        let context = LAContext()
        if let reason { context.localizedReason = reason }
        let me = try key(lock, context: lock == .presence ? context : nil)
        let ephemeralPub = try P256.KeyAgreement.PublicKey(x963Representation: sealed.prefix(65))
        let shared = try me.sharedSecretFromKeyAgreement(with: ephemeralPub)
        let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPub.x963Representation, sharedInfo: info, outputByteCount: 32)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.dropFirst(65)), using: sym)
    }

    // MARK: sealed files

    static func fileURL(_ name: String) -> URL { EncryptedFile.folder.appendingPathComponent(name) }

    static func store(_ data: Data?, name: String, lock: Lock) throws {
        let url = fileURL(name)
        guard let data else { try? FileManager.default.removeItem(at: url); return }
        try write(try seal(data, lock: lock), to: url)
    }

    static func load(name: String, lock: Lock, reason: String? = nil) throws -> Data? {
        guard let sealed = try? Data(contentsOf: fileURL(name)) else { return nil }
        return try open(sealed, lock: lock, reason: reason)
    }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(name).path) }

    /// A short check that sealing and opening work on this device (no prompt).
    static func selfTest() -> Bool {
        guard isAvailable else { return false }
        let probe = Data("smith".utf8)
        return (try? open(seal(probe, lock: .device), lock: .device)) == probe
    }
}
