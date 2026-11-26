import CommonCrypto
import CryptoKit
import Foundation

// A port of the Chronicles client-side crypto (chronicles/shared/src/crypto and
// client/src/services/settingCipher.ts), so Smith can open and write what the
// Chronicles web app seals. Checked against vectors made by Chronicles' own
// code (Tests/SmithCoreTests/Fixtures/chronicles-vectors.json, from
// chronicles/shared/scripts/emit-vectors.ts).
//
// Everything is AES-256-GCM with a 12-byte IV. WebCrypto writes
// ciphertext || 16-byte tag, and the IV travels separately, so boxes are built
// with `AES.GCM.SealedBox(nonce:ciphertext:tag:)` (CryptoKit's `combined` puts
// the nonce first, which isn't the same layout). Binary values are standard
// base64 with padding; base64url is refused, as Chronicles does.
//
// No state: every function takes the keys it needs. The decrypt functions take
// a list of candidate keys, tried in order — during a re-key that's
// [new key, old key] (chronicles client/src/services/rekey.ts `eitherKey`).

public enum ChroniclesCryptoError: Error, Sendable, Equatable {
    case invalidBase64
    case invalidSalt
    case invalidIterations
    case invalidIV
    case invalidKey
    case invalidID
    case invalidSealedValue
    case invalidPlaintext
    case keyDerivationFailed
    case noKeys
    /// No candidate key opened it (wrong key, wrong AAD, or tampered).
    case decryptFailed
}

/// An entry's sealed halves as the server stores them.
public struct EncryptedPost: Codable, Sendable, Equatable {
    public var contentEncrypted: String
    public var contentIv: String
    public var metadataEncrypted: String
    public var metadataIv: String

    public init(contentEncrypted: String, contentIv: String, metadataEncrypted: String, metadataIv: String) {
        self.contentEncrypted = contentEncrypted
        self.contentIv = contentIv
        self.metadataEncrypted = metadataEncrypted
        self.metadataIv = metadataIv
    }
}

/// A sealed record (topic, dose, finance row) as the server stores it.
public struct SealedRecord: Codable, Sendable, Equatable {
    public var payload: String
    public var iv: String

    public init(payload: String, iv: String) {
        self.payload = payload
        self.iv = iv
    }
}

public enum ChroniclesCrypto {
    public static let pbkdf2Iterations = 600_000        // constants.ts PBKDF2_ITERATIONS
    public static let pbkdf2MaxIterations = 2_000_000   // constants.ts PBKDF2_MAX_ITERATIONS
    public static let saltLength = 16
    public static let ivLength = 12
    static let tagLength = 16
    static let keyLength = 32

    // MARK: Record kinds (chronicles client/src/services/api.ts)

    public enum RecordKind {
        public static let topic = "topic"
        public static let dose = "dose"
        public static let bills = "bills"
        public static let budget = "budget"
        public static let expenses = "expenses"
        public static let goals = "goals"
        public static let savings = "savings"
    }

    /// A topic's record id: its numeric id as text.
    public static func topicRecordID(_ topicID: Int) -> String { String(topicID) }

    /// A dose record's id: `<uuid>|<YYYY-MM-DD>`. Both parts are checked, so a
    /// '|' can't be smuggled in through the id.
    public static func doseRecordID(uuid: String, date: String) throws -> String {
        let uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        let datePattern = /^\d{4}-\d{2}-\d{2}$/
        guard uuid.wholeMatch(of: uuidPattern) != nil, date.wholeMatch(of: datePattern) != nil else {
            throw ChroniclesCryptoError.invalidID
        }
        return "\(uuid)|\(date)"
    }

    // MARK: AAD strings

    public enum PostPart: String, Sendable { case content, metadata }

    /// encryptionService.ts postAad
    public static func postAAD(part: PostPart, id: Int, otherIV: String) -> String {
        "chronicles:post:v3:\(part.rawValue):\(id):\(otherIV)"
    }

    /// settingCipher.ts settingAad
    public static func settingAAD(_ key: String) -> String { "chronicles:setting:v2:\(key)" }

    /// encryptionService.ts recordAad
    public static func recordAAD(kind: String, id: String) -> String { "chronicles:finance:v1:\(kind):\(id)" }

    static let kekWrapAAD = "kek-wrap"

    // MARK: Encoding

    /// Standard base64 only (encoding.ts: `^[A-Za-z0-9+/]*={0,2}$`).
    public static func base64Decode(_ text: String) throws -> Data {
        guard text.wholeMatch(of: /[A-Za-z0-9+\/]*={0,2}/) != nil,
              let data = Data(base64Encoded: text) else {
            throw ChroniclesCryptoError.invalidBase64
        }
        return data
    }

    public static func base64Encode(_ data: Data) -> String { data.base64EncodedString() }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: Passwords and email

    /// NFKC, like `password.normalize('NFKC')`.
    public static func normalizePassword(_ password: String) -> String {
        password.precomposedStringWithCompatibilityMapping
    }

    /// The password exactly as typed when normalizing changes it (an account
    /// from before normalization), else nil. Compared as UTF-8 bytes: Swift's
    /// `==` treats canonically equivalent strings as equal, which would hide
    /// a decomposed accent that NFKC composes.
    public static func legacyPasswordForm(_ password: String) -> String? {
        Array(normalizePassword(password).utf8) == Array(password.utf8) ? nil : password
    }

    /// authSecret.ts normalizeEmail: trim, lower-case.
    public static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: PBKDF2

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int = 32) throws -> Data {
        guard iterations > 0, iterations <= Int(UInt32.max) else { throw ChroniclesCryptoError.invalidIterations }
        var out = Data(count: length)
        // A pointer is needed even for an empty password
        let pw = password.isEmpty ? Data([0]) : password
        let status = out.withUnsafeMutableBytes { outBuf in
            pw.withUnsafeBytes { pwBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress!.assumingMemoryBound(to: CChar.self), password.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw ChroniclesCryptoError.keyDerivationFailed }
        return out
    }

    // MARK: Sign-in secret

    /// authSecret.ts deriveAuthSecret: hex(PBKDF2-SHA256(NFKC(password),
    /// "chronicles:auth:v1:" + normalized email, 600k, 32 bytes)). `asTyped`
    /// skips normalizing, for the fallback to an older account's password.
    public static func authSecret(password: String, email: String, iterations: Int = pbkdf2Iterations, asTyped: Bool = false) throws -> String {
        let secret = asTyped ? password : normalizePassword(password)
        let salt = Data("chronicles:auth:v1:\(normalizeEmail(email))".utf8)
        return hex(try pbkdf2SHA256(password: Data(secret.utf8), salt: salt, iterations: iterations))
    }

    // MARK: Master key (password wrap)

    static func checkIterations(_ iterations: Int) throws {
        guard iterations >= pbkdf2Iterations, iterations <= pbkdf2MaxIterations else {
            throw ChroniclesCryptoError.invalidIterations
        }
    }

    static func deriveKEK(password: String, salt: Data, iterations: Int, asTyped: Bool) throws -> SymmetricKey {
        // Every KEK salt is 16 random bytes; anything else is refused (primitives.ts deriveKEK)
        guard salt.count == saltLength else { throw ChroniclesCryptoError.invalidSalt }
        let secret = asTyped ? password : normalizePassword(password)
        return SymmetricKey(data: try pbkdf2SHA256(password: Data(secret.utf8), salt: salt, iterations: iterations))
    }

    /// The master key from the password wrap (all base64): from the normalized
    /// password, then — only when normalizing changed it — from the password
    /// as typed. The first error is the one thrown.
    public static func unwrapMasterKey(password: String, salt: String, iv: String, wrapped: String, iterations: Int) throws -> SymmetricKey {
        try checkIterations(iterations)
        let saltData = try base64Decode(salt)
        let ivData = try base64Decode(iv)
        let wrappedData = try base64Decode(wrapped)
        func attempt(asTyped: Bool) throws -> SymmetricKey {
            let kek = try deriveKEK(password: password, salt: saltData, iterations: iterations, asTyped: asTyped)
            let raw = try openRaw(wrappedData, iv: ivData, aad: Data(kekWrapAAD.utf8), key: kek)
            guard raw.count == keyLength else { throw ChroniclesCryptoError.invalidKey }
            return SymmetricKey(data: raw)
        }
        do {
            return try attempt(asTyped: false)
        } catch {
            guard legacyPasswordForm(password) != nil else { throw error }
            do { return try attempt(asTyped: true) } catch _ { throw error }
        }
    }

    /// Wrap a master key under a password (tests, and any future password change).
    static func wrapMasterKey(_ masterKey: SymmetricKey, password: String, salt: Data, iv: Data? = nil,
                              iterations: Int = pbkdf2Iterations, asTyped: Bool = false) throws -> (salt: String, iv: String, wrapped: String) {
        try checkIterations(iterations)
        let kek = try deriveKEK(password: password, salt: salt, iterations: iterations, asTyped: asTyped)
        let raw = masterKey.withUnsafeBytes { Data($0) }
        let (ct, ivUsed) = try sealRaw(raw, aad: Data(kekWrapAAD.utf8), key: kek, iv: iv)
        return (base64Encode(salt), base64Encode(ivUsed), base64Encode(ct))
    }

    // MARK: AES-GCM core

    static func sealRaw(_ plaintext: Data, aad: Data, key: SymmetricKey, iv: Data? = nil) throws -> (ciphertext: Data, iv: Data) {
        let nonceData = iv ?? Data(AES.GCM.Nonce())
        guard nonceData.count == ivLength else { throw ChroniclesCryptoError.invalidIV }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonceData), authenticating: aad)
        return (box.ciphertext + box.tag, nonceData)
    }

    static func openRaw(_ ciphertextAndTag: Data, iv: Data, aad: Data, key: SymmetricKey) throws -> Data {
        guard iv.count == ivLength else { throw ChroniclesCryptoError.invalidIV }
        guard ciphertextAndTag.count >= tagLength else { throw ChroniclesCryptoError.decryptFailed }
        let split = ciphertextAndTag.count - tagLength
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: iv),
            ciphertext: ciphertextAndTag.prefix(split),
            tag: ciphertextAndTag.suffix(tagLength))
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw ChroniclesCryptoError.decryptFailed
        }
    }

    /// Seal bytes with an AAD string, returning base64 ciphertext||tag and IV
    /// (primitives.ts encrypt). A random IV unless one is given (tests).
    public static func seal(_ plaintext: Data, aad: String, key: SymmetricKey, iv: Data? = nil) throws -> (ciphertext: String, iv: String) {
        let (ct, ivUsed) = try sealRaw(plaintext, aad: Data(aad.utf8), key: key, iv: iv)
        return (base64Encode(ct), base64Encode(ivUsed))
    }

    /// Open base64 ciphertext||tag with the first candidate key that works.
    public static func open(ciphertext: String, iv: String, aad: String, keys: [SymmetricKey]) throws -> Data {
        guard !keys.isEmpty else { throw ChroniclesCryptoError.noKeys }
        let ct = try base64Decode(ciphertext)
        let ivData = try base64Decode(iv)
        for key in keys {
            if let plain = try? openRaw(ct, iv: ivData, aad: Data(aad.utf8), key: key) { return plain }
        }
        throw ChroniclesCryptoError.decryptFailed
    }

    // MARK: JSON

    static func jsonData(_ value: JSONValue) throws -> Data { try value.encoded(sortedKeys: true) }

    static func parseJSON(_ data: Data) throws -> JSONValue {
        do { return try JSONValue.parse(data) } catch { throw ChroniclesCryptoError.invalidPlaintext }
    }

    static func utf8(_ data: Data) throws -> String {
        guard let s = String(data: data, encoding: .utf8) else { throw ChroniclesCryptoError.invalidPlaintext }
        return s
    }

    // MARK: Entries (post v3)

    /// Seal an entry's content and metadata as a pair bound to its id: each
    /// half's AAD names the id and the other half's IV (encryptPost).
    public static func encryptPost(content: String, metadata: JSONValue, id: Int, key: SymmetricKey) throws -> EncryptedPost {
        try encryptPost(content: content, metadata: metadata, id: id, key: key, contentIV: nil, metadataIV: nil)
    }

    static func encryptPost(content: String, metadata: JSONValue, id: Int, key: SymmetricKey,
                            contentIV: Data?, metadataIV: Data?) throws -> EncryptedPost {
        try encryptPost(content: content, metadataPlaintext: jsonData(metadata), id: id, key: key,
                        contentIV: contentIV, metadataIV: metadataIV)
    }

    static func encryptPost(content: String, metadataPlaintext: Data, id: Int, key: SymmetricKey,
                            contentIV: Data?, metadataIV: Data?) throws -> EncryptedPost {
        guard id >= 1 else { throw ChroniclesCryptoError.invalidID }
        let cIV = contentIV ?? Data(AES.GCM.Nonce())
        let mIV = metadataIV ?? Data(AES.GCM.Nonce())
        let cIVText = base64Encode(cIV), mIVText = base64Encode(mIV)
        let c = try seal(Data(content.utf8), aad: postAAD(part: .content, id: id, otherIV: mIVText), key: key, iv: cIV)
        let m = try seal(metadataPlaintext, aad: postAAD(part: .metadata, id: id, otherIV: cIVText), key: key, iv: mIV)
        return EncryptedPost(contentEncrypted: c.ciphertext, contentIv: c.iv, metadataEncrypted: m.ciphertext, metadataIv: m.iv)
    }

    /// Open a v3 entry. Both halves must open under the same key. Metadata
    /// that isn't a JSON object comes back as `{}`, as in decryptPost.
    public static func decryptPost(_ post: EncryptedPost, id: Int, keys: [SymmetricKey]) throws -> (content: String, metadata: JSONValue) {
        guard id >= 1 else { throw ChroniclesCryptoError.invalidID }
        for key in keys {
            guard let contentData = try? open(ciphertext: post.contentEncrypted, iv: post.contentIv,
                                              aad: postAAD(part: .content, id: id, otherIV: post.metadataIv), keys: [key]),
                  let metadataData = try? open(ciphertext: post.metadataEncrypted, iv: post.metadataIv,
                                               aad: postAAD(part: .metadata, id: id, otherIV: post.contentIv), keys: [key])
            else { continue }
            let metadata: JSONValue
            if let parsed = try? JSONValue.parse(metadataData), case .object = parsed { metadata = parsed } else { metadata = .object([:]) }
            return (try utf8(contentData), metadata)
        }
        // Surface malformed input as such rather than as a key failure
        _ = try base64Decode(post.contentEncrypted); _ = try base64Decode(post.contentIv)
        _ = try base64Decode(post.metadataEncrypted); _ = try base64Decode(post.metadataIv)
        throw keys.isEmpty ? ChroniclesCryptoError.noKeys : ChroniclesCryptoError.decryptFailed
    }

    // MARK: Settings (v2)

    /// `{ ciphertext, iv, v: 2 }` for a setting value (settingCipher.ts
    /// sealSetting). Not for the rollback-guarded keys (aiConfig,
    /// imageStorageConfig, googleCalendarId, calendarImportMode), which also
    /// carry a `_rev`; Smith doesn't write those.
    public static func sealSetting(key: String, value: JSONValue, mk: SymmetricKey) throws -> JSONValue {
        try sealSetting(key: key, plaintext: jsonData(value), mk: mk, iv: nil)
    }

    static func sealSetting(key: String, plaintext: Data, mk: SymmetricKey, iv: Data?) throws -> JSONValue {
        let s = try seal(plaintext, aad: settingAAD(key), key: mk, iv: iv)
        return .object(["ciphertext": .string(s.ciphertext), "iv": .string(s.iv), "v": .number(2)])
    }

    /// Open a v2 sealed setting for `key`. Anything not bound to its key
    /// (no `v: 2`) or with extra fields is refused.
    public static func openSetting(key: String, sealed: JSONValue, keys: [SymmetricKey]) throws -> JSONValue {
        guard let o = sealed.object, let ct = o["ciphertext"]?.string, let iv = o["iv"]?.string,
              o["v"]?.double == 2, o.count == 3 else {
            throw ChroniclesCryptoError.invalidSealedValue
        }
        return try parseJSON(try open(ciphertext: ct, iv: iv, aad: settingAAD(key), keys: keys))
    }

    // MARK: Records (topics, doses, finance)

    /// encryptionService.encryptRecord: JSON, AAD bound to kind and id.
    public static func sealRecord(kind: String, id: String, record: JSONValue, key: SymmetricKey) throws -> SealedRecord {
        try sealRecord(kind: kind, id: id, plaintext: jsonData(record), key: key, iv: nil)
    }

    static func sealRecord(kind: String, id: String, plaintext: Data, key: SymmetricKey, iv: Data?) throws -> SealedRecord {
        let s = try seal(plaintext, aad: recordAAD(kind: kind, id: id), key: key, iv: iv)
        return SealedRecord(payload: s.ciphertext, iv: s.iv)
    }

    public static func openRecord(kind: String, id: String, payload: String, iv: String, keys: [SymmetricKey]) throws -> JSONValue {
        try parseJSON(try open(ciphertext: payload, iv: iv, aad: recordAAD(kind: kind, id: id), keys: keys))
    }
}
