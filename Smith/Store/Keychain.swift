import Foundation
import Security
import CryptoKit

/// The Anthropic API key, the storage key and the sync pairing key, kept in
/// this device's Keychain only (never synced, never in backups).
nonisolated enum Keychain {
    private static let service = "com.fastandcurious.smith"

    // iPad: the data-protection keychain. Mac: that keychain needs an entitlement a
    // Personal Team build doesn't get (it fails with errSecMissingEntitlement), so
    // the Mac falls back to the login keychain, which sandboxed apps can use as is.

    private static func query(_ account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // Where the Secure Enclave is available (every Apple-silicon Mac and iPad),
    // a secret is saved only as a copy sealed to this device's chip
    // (SecureEnclaveVault, .device lock); the Keychain is the fallback.
    // A secret still in the Keychain from before moves over on first read.

    static func data(_ account: String) -> Data? {
        let file = "secret-\(account).se"
        if SecureEnclaveVault.isAvailable {
            if let sealed = try? SecureEnclaveVault.load(name: file, lock: .device) { return sealed }
            if let legacy = keychainData(account) {
                if (try? SecureEnclaveVault.store(legacy, name: file, lock: .device)) != nil { _ = keychainSet(nil, for: account) }
                return legacy
            }
            return nil
        }
        return keychainData(account)
    }

    @discardableResult
    static func set(_ data: Data?, for account: String) -> Bool {
        if SecureEnclaveVault.isAvailable {
            do {
                try SecureEnclaveVault.store(data, name: "secret-\(account).se", lock: .device)
                _ = keychainSet(nil, for: account)
                return true
            } catch {
                // Fall through to the Keychain
            }
        }
        return keychainSet(data, for: account)
    }

    /// Where the secrets are kept on this device, for Settings.
    static var storageDescription: String {
        SecureEnclaveVault.isAvailable ? "Locked to this device’s Secure Enclave" : "In this device’s Keychain (no Secure Enclave)"
    }

    private static func keychainData(_ account: String) -> Data? {
        for dp in [true, false] {
            var q = query(account, dataProtection: dp)
            q[kSecReturnData as String] = true
            var out: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        }
        return nil
    }

    /// The last Keychain error, shown in Settings if saving fails.
    nonisolated(unsafe) static var lastError: OSStatus = errSecSuccess

    private static func keychainSet(_ data: Data?, for account: String) -> Bool {
        for dp in [true, false] { SecItemDelete(query(account, dataProtection: dp) as CFDictionary) }
        guard let data else { return true }
        for dp in [true, false] {
            var add = query(account, dataProtection: dp)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            let status = SecItemAdd(add as CFDictionary, nil)
            lastError = status
            if status == errSecSuccess { return true }
        }
        return false
    }

    static var apiKey: String? {
        get { data("anthropic-api-key").flatMap { String(data: $0, encoding: .utf8) } }
        set { set(newValue.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: "anthropic-api-key") }
    }

    /// Whether a secret was ever saved under this name, readable right now or not.
    static func exists(_ account: String) -> Bool {
        if SecureEnclaveVault.exists("secret-\(account).se") { return true }
        for dp in [true, false] {
            // Found, or there but not readable now (the device is locked): both mean it exists
            let status = SecItemCopyMatching(query(account, dataProtection: dp) as CFDictionary, nil)
            if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        }
        return false
    }

    /// The key that encrypts Smith's files. Made once per device.
    ///
    /// nil when a key was saved but can't be read right now (Smith started while the
    /// device was locked, say). A new key is only ever made when none was saved:
    /// making one because a read failed would leave every file unreadable for good.
    static var storageKey: SymmetricKey? {
        storageKeyLock.withLock {
            if let k = cachedStorageKey { return k }
            if let d = data("storage-key"), d.count == 32 {
                cachedStorageKey = SymmetricKey(data: d)
                return cachedStorageKey
            }
            guard !exists("storage-key") else { return nil }
            let k = SymmetricKey(size: .bits256)
            // Not saved: not used, or the next launch couldn't open what this one wrote
            guard set(k.withUnsafeBytes { Data($0) }, for: "storage-key") else { return nil }
            cachedStorageKey = k
            return k
        }
    }
    /// "Erase everything": the storage key goes too, so a key that can no longer be
    /// opened (the app's data came from another device, say) doesn't block a fresh start.
    static func resetStorageKey() {
        storageKeyLock.withLock {
            cachedStorageKey = nil
            _ = set(nil, for: "storage-key")
        }
    }
    private static let storageKeyLock = NSLock()
    nonisolated(unsafe) private static var cachedStorageKey: SymmetricKey?

    static var syncKey: SymmetricKey? {
        get { data("sync-key").map { SymmetricKey(data: $0) } }
        set { set(newValue.map { $0.withUnsafeBytes { Data($0) } }, for: "sync-key") }
    }
}

/// Smith's files: JSON, sealed with AES-GCM under the device's storage key,
/// with full file protection, and left out of backups.
nonisolated enum EncryptedFile {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Smith", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        raw(name).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Reads on top of `defaults`, so fields added in an update don't wipe saved data.
    static func read<T: Codable>(_ type: T.Type, _ name: String, defaults: T) -> T? {
        raw(name).flatMap { Tolerant.decode(T.self, from: $0, defaults: defaults) }
    }

    // Two keys.
    //  - Settings (what the unlock screen needs: the account's email, the server, the
    //    lock timer) are sealed under the device's storage key.
    //  - Everything personal (the day's picture, journal summaries, memories, letters,
    //    conversation summaries) is sealed under the vault key, which is made from the
    //    Chronicles master key and exists only while Smith is unlocked. A locked Smith
    //    cannot open these files, and neither can anything else on an unlocked device.

    static let personalFiles: Set<String> = ["chronicles.smith", "journal-vault.smith", "about-you.smith",
                                             "conversations.smith", "letters.smith", "smith-cloud.smith"]
    private static let vaultLock = NSLock()
    nonisolated(unsafe) private static var vault: SymmetricKey?

    /// Set at unlock, cleared at lock.
    static func setVaultKey(_ key: SymmetricKey?) { vaultLock.withLock { vault = key } }
    static var vaultIsOpen: Bool { vaultLock.withLock { vault != nil } }

    private static func key(for name: String) -> SymmetricKey? {
        personalFiles.contains(name) ? vaultLock.withLock { vault } : Keychain.storageKey
    }

    private static func open(_ sealed: Data, _ key: SymmetricKey?) -> Data? {
        guard let key, let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func raw(_ name: String) -> Data? {
        guard let sealed = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        if let plain = open(sealed, key(for: name)) { return plain }
        // A personal file from before the vault key: still under the device key. Read
        // once (only while unlocked) and saved again under the vault key by the caller.
        if personalFiles.contains(name), vaultIsOpen, let plain = open(sealed, Keychain.storageKey) {
            legacyLock.withLock { _ = legacyRead.insert(name) }
            return plain
        }
        return nil
    }

    private static let legacyLock = NSLock()
    nonisolated(unsafe) private static var legacyRead: Set<String> = []
    /// Personal files just read under the old device key (and so due to be saved again).
    static func takeLegacyReads() -> Set<String> { legacyLock.withLock { let r = legacyRead; legacyRead = []; return r } }

    /// False while the storage key can't be read: nothing can be opened, and nothing may be saved.
    static var isAvailable: Bool { Keychain.storageKey != nil }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// The last save that didn't reach the disk, for Settings to show.
    nonisolated(unsafe) static var lastWriteError: String?

    @discardableResult
    static func write<T: Encodable>(_ value: T, _ name: String) -> Bool {
        guard let key = key(for: name) else {
            // Locked: nothing personal is written (there is nothing of it in memory to write)
            if !personalFiles.contains(name) { lastWriteError = "Smith’s storage key can’t be read right now." }
            return false
        }
        do {
            let plain = try JSONEncoder().encode(value)
            guard let sealed = try AES.GCM.seal(plain, using: key).combined else { return false }
            let url = folder.appendingPathComponent(name)
            #if os(iOS)
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try sealed.write(to: url, options: .atomic)
            #endif
            return true
        } catch {
            lastWriteError = "Couldn’t save \(name): \(error.localizedDescription)"
            return false
        }
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}

/// The Anthropic key Smith uses: the account's own key from Chronicles while
/// unlocked (memory only), else the one saved in Smith (Settings → Claude).
nonisolated enum APIKeys {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chronicles: String?
    nonisolated(unsafe) private static var preferChronicles = true

    static func setChroniclesKey(_ key: String?) { lock.withLock { chronicles = key } }
    static func setPreferChronicles(_ on: Bool) { lock.withLock { preferChronicles = on } }

    static var usingChronicles: Bool { lock.withLock { preferChronicles && chronicles != nil } }

    static func current() -> String? {
        if let k = lock.withLock({ preferChronicles ? chronicles : nil }) { return k }
        return Keychain.apiKey
    }
}
