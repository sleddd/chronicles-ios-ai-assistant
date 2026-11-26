import CryptoKit
import Foundation
import Testing
@testable import SmithCore

/// Known-answer vectors from Chronicles' own TypeScript crypto
/// (chronicles/shared/scripts/emit-vectors.ts).
private enum Vectors {
    static let all: JSONValue = {
        let url = Bundle.module.url(forResource: "chronicles-vectors", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONValue.parse(try! Data(contentsOf: url))
    }()

    static func key(_ name: String) -> SymmetricKey {
        SymmetricKey(data: try! ChroniclesCrypto.base64Decode(all[name]!.string!))
    }
    static var mk: SymmetricKey { key("masterKey") }
    static var oldMK: SymmetricKey { key("oldMasterKey") }
    static var post: JSONValue { all["post"]! }
    static var settings: [JSONValue] { all["settings"]!.array! }
    static var records: [JSONValue] { all["records"]!.array! }
    static var wraps: [JSONValue] { all["wrap"]!.array! }

    static var wire: EncryptedPost {
        let w = post["wire"]!
        return EncryptedPost(contentEncrypted: w["contentEncrypted"]!.string!, contentIv: w["contentIv"]!.string!,
                             metadataEncrypted: w["metadataEncrypted"]!.string!, metadataIv: w["metadataIv"]!.string!)
    }
}

private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
private func b64(_ s: String) -> Data { try! ChroniclesCrypto.base64Decode(s) }

/// Flip one bit of a base64 value's last byte (the end of the GCM tag), or of byte `at`.
private func tampered(_ s: String, at index: Int? = nil) -> String {
    var d = b64(s)
    d[index ?? d.count - 1] ^= 0x01
    return d.base64EncodedString()
}

@Suite struct ChroniclesCryptoVectorTests {
    @Test func authSecretMatchesChronicles() throws {
        for v in Vectors.all["authSecret"]!.array! {
            let secret = try ChroniclesCrypto.authSecret(
                password: v["password"]!.string!, email: v["email"]!.string!,
                iterations: v["iterations"]!.int!, asTyped: v["asTyped"]!.bool!)
            #expect(secret == v["secret"]!.string!)
        }
    }

    @Test func masterKeyUnwrapsFromEveryWrap() throws {
        // Includes the as-typed (pre-normalization) wrap, which only the fallback opens
        for v in Vectors.wraps {
            let key = try ChroniclesCrypto.unwrapMasterKey(
                password: v["password"]!.string!, salt: v["salt"]!.string!, iv: v["iv"]!.string!,
                wrapped: v["wrapped"]!.string!, iterations: v["iterations"]!.int!)
            #expect(raw(key) == raw(Vectors.mk))
        }
    }

    @Test func wrapRefusesWrongPasswordAndBadParameters() throws {
        let v = Vectors.wraps[0]
        let salt = v["salt"]!.string!, iv = v["iv"]!.string!, wrapped = v["wrapped"]!.string!
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.unwrapMasterKey(password: "wrong", salt: salt, iv: iv, wrapped: wrapped, iterations: 600_000)
        }
        #expect(throws: ChroniclesCryptoError.invalidIterations) {
            try ChroniclesCrypto.unwrapMasterKey(password: "x", salt: salt, iv: iv, wrapped: wrapped, iterations: 599_999)
        }
        #expect(throws: ChroniclesCryptoError.invalidIterations) {
            try ChroniclesCrypto.unwrapMasterKey(password: "x", salt: salt, iv: iv, wrapped: wrapped, iterations: 2_000_001)
        }
        #expect(throws: ChroniclesCryptoError.invalidSalt) {
            try ChroniclesCrypto.unwrapMasterKey(password: "x", salt: Data(count: 15).base64EncodedString(), iv: iv, wrapped: wrapped, iterations: 600_000)
        }
    }

    @Test func nfkcComparisonUsesBytes() {
        // Canonically equal to "Café", so Swift's == would call these the same
        #expect(ChroniclesCrypto.legacyPasswordForm("Cafe\u{301}") == "Cafe\u{301}")
        #expect(ChroniclesCrypto.legacyPasswordForm("Caf\u{E9}") == nil)
        #expect(ChroniclesCrypto.legacyPasswordForm("plain ascii") == nil)
    }

    @Test func decryptsPostVector() throws {
        let p = Vectors.post
        let (content, metadata) = try ChroniclesCrypto.decryptPost(Vectors.wire, id: p["id"]!.int!, keys: [Vectors.mk])
        #expect(content == p["content"]!.string!)
        #expect(metadata == p["metadata"]!)
        #expect(metadata["_taxonomyId"] == 7)
        #expect(metadata["_customFields"]?["tags"] == ["walk", "river"])
    }

    @Test func encryptsPostExactlyLikeChronicles() throws {
        let p = Vectors.post, w = Vectors.wire
        let mine = try ChroniclesCrypto.encryptPost(
            content: p["content"]!.string!, metadataPlaintext: Data(p["metadataPlaintext"]!.string!.utf8),
            id: p["id"]!.int!, key: Vectors.mk, contentIV: b64(w.contentIv), metadataIV: b64(w.metadataIv))
        #expect(mine == w)
        // Swift's own JSON (sorted keys) differs in bytes but opens to the same value
        let viaJSONValue = try ChroniclesCrypto.encryptPost(
            content: p["content"]!.string!, metadata: p["metadata"]!, id: p["id"]!.int!, key: Vectors.mk,
            contentIV: b64(w.contentIv), metadataIV: b64(w.metadataIv))
        #expect(viaJSONValue.contentEncrypted == w.contentEncrypted)
        #expect(try ChroniclesCrypto.decryptPost(viaJSONValue, id: p["id"]!.int!, keys: [Vectors.mk]).metadata == p["metadata"]!)
    }

    @Test func decryptsAndSealsEverySetting() throws {
        #expect(Vectors.settings.count == 5)
        for s in Vectors.settings {
            let key = s["key"]!.string!, sealed = s["sealed"]!
            #expect(s["aad"]!.string! == ChroniclesCrypto.settingAAD(key))
            #expect(try ChroniclesCrypto.openSetting(key: key, sealed: sealed, keys: [Vectors.mk]) == s["value"]!)
            let mine = try ChroniclesCrypto.sealSetting(key: key, plaintext: Data(s["plaintext"]!.string!.utf8),
                                                        mk: Vectors.mk, iv: b64(sealed["iv"]!.string!))
            #expect(mine == sealed)
        }
    }

    @Test func decryptsAndSealsEveryRecord() throws {
        for r in Vectors.records {
            let kind = r["kind"]!.string!, id = r["id"]!.string!
            let key = r["key"]!.string! == "oldMasterKey" ? Vectors.oldMK : Vectors.mk
            #expect(r["aad"]!.string! == ChroniclesCrypto.recordAAD(kind: kind, id: id))
            // During a re-key every record is tried with [new, old]
            let opened = try ChroniclesCrypto.openRecord(kind: kind, id: id, payload: r["payload"]!.string!,
                                                         iv: r["iv"]!.string!, keys: [Vectors.mk, Vectors.oldMK])
            #expect(opened == r["record"]!)
            let mine = try ChroniclesCrypto.sealRecord(kind: kind, id: id, plaintext: Data(r["plaintext"]!.string!.utf8),
                                                       key: key, iv: b64(r["iv"]!.string!))
            #expect(mine == SealedRecord(payload: r["payload"]!.string!, iv: r["iv"]!.string!))
        }
    }

    @Test func recordIDsMatchChronicles() throws {
        let kinds = Vectors.records.map { $0["kind"]!.string! }
        #expect(kinds.contains(ChroniclesCrypto.RecordKind.topic))
        #expect(kinds.contains(ChroniclesCrypto.RecordKind.dose))
        #expect(kinds.contains(ChroniclesCrypto.RecordKind.bills))
        #expect(ChroniclesCrypto.topicRecordID(12) == Vectors.records[0]["id"]!.string!)
        #expect(try ChroniclesCrypto.doseRecordID(uuid: "3f2a9c1e-8b4d-4e7f-9a12-5c6d7e8f9a0b", date: "2026-11-25")
                == Vectors.records[1]["id"]!.string!)
        #expect(throws: ChroniclesCryptoError.invalidID) {
            try ChroniclesCrypto.doseRecordID(uuid: "3f2a9c1e-8b4d-4e7f-9a12-5c6d7e8f9a0b|x", date: "2026-11-25")
        }
    }

    @Test func oldKeyRecordNeedsOldKey() throws {
        let r = Vectors.records[3]
        #expect(r["key"]!.string! == "oldMasterKey")
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.openRecord(kind: r["kind"]!.string!, id: r["id"]!.string!, payload: r["payload"]!.string!,
                                            iv: r["iv"]!.string!, keys: [Vectors.mk])
        }
    }
}

@Suite struct ChroniclesCryptoRoundTripTests {
    let key = SymmetricKey(size: .bits256)

    @Test func postRoundTrip() throws {
        let metadata: JSONValue = ["_taxonomyId": 3, "_customFields": ["a": [1, 2.5, "x", nil, true]], "title": "Héllo / there"]
        let a = try ChroniclesCrypto.encryptPost(content: "Body ✓", metadata: metadata, id: 9, key: key)
        let b = try ChroniclesCrypto.encryptPost(content: "Body ✓", metadata: metadata, id: 9, key: key)
        #expect(a.contentIv != b.contentIv && a.contentEncrypted != b.contentEncrypted)
        let back = try ChroniclesCrypto.decryptPost(a, id: 9, keys: [SymmetricKey(size: .bits256), key])
        #expect(back.content == "Body ✓")
        #expect(back.metadata == metadata)
    }

    @Test func nonObjectMetadataOpensAsEmpty() throws {
        let p = try ChroniclesCrypto.encryptPost(content: "c", metadata: ["a", "b"], id: 1, key: key)
        #expect(try ChroniclesCrypto.decryptPost(p, id: 1, keys: [key]).metadata == .object([:]))
    }

    @Test func settingAndRecordRoundTrip() throws {
        let sealed = try ChroniclesCrypto.sealSetting(key: "displayName", value: "Henry", mk: key)
        #expect(sealed["v"] == 2)
        #expect(try ChroniclesCrypto.openSetting(key: "displayName", sealed: sealed, keys: [key]) == "Henry")
        let rec: JSONValue = ["name": "Rent", "amount": 1200, "autopay": false]
        let r = try ChroniclesCrypto.sealRecord(kind: "bills", id: "abc", record: rec, key: key)
        #expect(try ChroniclesCrypto.openRecord(kind: "bills", id: "abc", payload: r.payload, iv: r.iv, keys: [key]) == rec)
    }

    @Test func masterKeyWrapRoundTrip() throws {
        let password = "Cafe\u{301} ﬁle"
        let w = try ChroniclesCrypto.wrapMasterKey(key, password: password, salt: Data(repeating: 9, count: 16))
        let back = try ChroniclesCrypto.unwrapMasterKey(password: password, salt: w.salt, iv: w.iv, wrapped: w.wrapped, iterations: 600_000)
        #expect(raw(back) == raw(key))
    }
}

@Suite struct ChroniclesCryptoRefusalTests {
    let mk = Vectors.mk

    @Test func postBoundToIdAndOtherIV() throws {
        let w = Vectors.wire, id = Vectors.post["id"]!.int!
        #expect(throws: ChroniclesCryptoError.decryptFailed) { try ChroniclesCrypto.decryptPost(w, id: id + 1, keys: [mk]) }
        // Swapping the halves, or pairing with another IV, breaks both AADs
        var swapped = w
        swapped.contentEncrypted = w.metadataEncrypted; swapped.metadataEncrypted = w.contentEncrypted
        swapped.contentIv = w.metadataIv; swapped.metadataIv = w.contentIv
        #expect(throws: ChroniclesCryptoError.decryptFailed) { try ChroniclesCrypto.decryptPost(swapped, id: id, keys: [mk]) }
        // A wrong AAD on one half alone: the content opens only with the metadata IV named in its AAD
        let otherIV = Data(repeating: 1, count: 12).base64EncodedString()
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.open(ciphertext: w.contentEncrypted, iv: w.contentIv,
                                      aad: ChroniclesCrypto.postAAD(part: .content, id: id, otherIV: otherIV), keys: [mk])
        }
        #expect(throws: ChroniclesCryptoError.decryptFailed) { try ChroniclesCrypto.decryptPost(w, id: id, keys: [SymmetricKey(size: .bits256)]) }
        #expect(throws: ChroniclesCryptoError.noKeys) { try ChroniclesCrypto.decryptPost(w, id: id, keys: []) }
        #expect(throws: ChroniclesCryptoError.invalidID) { try ChroniclesCrypto.decryptPost(w, id: 0, keys: [mk]) }
    }

    @Test func settingBoundToKey() throws {
        let s = Vectors.settings[0]
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.openSetting(key: "timezone", sealed: s["sealed"]!, keys: [mk])
        }
        // An unbound (pre-v2) value is refused
        var o = s["sealed"]!.object!
        o["v"] = nil
        #expect(throws: ChroniclesCryptoError.invalidSealedValue) {
            try ChroniclesCrypto.openSetting(key: s["key"]!.string!, sealed: .object(o), keys: [mk])
        }
    }

    @Test func recordBoundToKindAndId() throws {
        let r = Vectors.records[2]
        let payload = r["payload"]!.string!, iv = r["iv"]!.string!
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.openRecord(kind: "budget", id: r["id"]!.string!, payload: payload, iv: iv, keys: [mk])
        }
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.openRecord(kind: "bills", id: "other", payload: payload, iv: iv, keys: [mk])
        }
    }

    @Test func tamperingFails() throws {
        let r = Vectors.records[0], kind = r["kind"]!.string!, id = r["id"]!.string!
        let payload = r["payload"]!.string!, iv = r["iv"]!.string!
        for bad in [tampered(payload), tampered(payload, at: 0)] {
            #expect(throws: ChroniclesCryptoError.decryptFailed) {
                try ChroniclesCrypto.openRecord(kind: kind, id: id, payload: bad, iv: iv, keys: [mk])
            }
        }
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.openRecord(kind: kind, id: id, payload: payload, iv: tampered(iv), keys: [mk])
        }
        var w = Vectors.wire
        w.metadataEncrypted = tampered(w.metadataEncrypted)
        #expect(throws: ChroniclesCryptoError.decryptFailed) {
            try ChroniclesCrypto.decryptPost(w, id: Vectors.post["id"]!.int!, keys: [mk])
        }
    }

    @Test func base64urlRejected() throws {
        #expect(throws: ChroniclesCryptoError.invalidBase64) { try ChroniclesCrypto.base64Decode("ab-_") }
        #expect(throws: ChroniclesCryptoError.invalidBase64) { try ChroniclesCrypto.base64Decode("YQ==\n") }
        // A record whose payload is the same bytes in base64url is refused, not opened
        let r = Vectors.records.first { $0["payload"]!.string!.contains(where: { $0 == "+" || $0 == "/" }) }!
        let url = r["payload"]!.string!.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(throws: ChroniclesCryptoError.invalidBase64) {
            try ChroniclesCrypto.openRecord(kind: r["kind"]!.string!, id: r["id"]!.string!, payload: url,
                                            iv: r["iv"]!.string!, keys: [mk])
        }
    }
}
