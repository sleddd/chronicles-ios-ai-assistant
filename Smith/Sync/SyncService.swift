import Foundation
import Network
import CryptoKit
import Observation
import SmithCore

/// Mac ↔ iPad sync over the local network (or the cable), with no server (plan, section 12).
///
/// Pairing: the iPad shows a 6-digit code and the Mac types it. That code
/// opens a TLS (pre-shared key) channel just long enough for the iPad to hand
/// over a random 256-bit sync key; from then on every connection uses that key,
/// so only these two devices can talk, and everything is encrypted.
@MainActor @Observable
final class SyncService {
    enum Status: Equatable { case idle, waitingForPair(code: String), syncing, done(String), failed(String) }

    private(set) var status: Status = .idle
    private(set) var peerName: String?
    var isPaired: Bool { Keychain.syncKey != nil }

    private let store: SmithStore
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var pairingCode: String?
    private var lastAutoSync: Date?
    static let serviceType = "_smithsync._tcp"

    init(store: SmithStore) { self.store = store }

    // MARK: start / stop

    func start() {
        startListener()
        startBrowser()
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
    }

    private var psk: SymmetricKey? {
        if let code = pairingCode { return SymmetricKey(data: SHA256.hash(data: Data("smith-pair:\(code)".utf8))) }
        return Keychain.syncKey
    }

    private static func parameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = "smith".data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["exported"] = store.snapshot.map { String(Int($0.exportedAt.timeIntervalSince1970)) } ?? "0"
        txt["name"] = store.deviceName
        return txt
    }

    private func startListener() {
        listener?.cancel()
        guard let key = psk, let l = try? NWListener(using: Self.parameters(key: key)) else { return }
        l.service = NWListener.Service(name: "Smith-\(store.deviceName)", type: Self.serviceType, txtRecord: txtRecord())
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func startBrowser() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.found(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    private var peers: [NWBrowser.Result] = []

    private func found(_ results: Set<NWBrowser.Result>) {
        peers = results.filter {
            if case .service(let name, _, _, _) = $0.endpoint { return name != "Smith-\(store.deviceName)" }
            return false
        }
        guard let peer = peers.first else { peerName = nil; return }
        if case .bonjour(let txt) = peer.metadata {
            peerName = txt["name"]
            let theirs = Double(txt["exported"] ?? "0") ?? 0
            store.peerHasNewer = theirs > (store.snapshot?.exportedAt.timeIntervalSince1970 ?? 0) + 1
        }
        // Automatic: sync whenever both are open on the same network (at most every 5 minutes).
        #if os(macOS)
        if isPaired, (lastAutoSync.map { Date().timeIntervalSince($0) > 300 } ?? true) {
            lastAutoSync = Date()
            Task { await syncNow() }
        }
        #endif
    }

    // MARK: pairing (iPad shows a code, Mac types it)

    func beginPairing() {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        pairingCode = code
        status = .waitingForPair(code: code)
        startListener()
    }

    func cancelPairing() {
        pairingCode = nil
        status = .idle
        startListener()
    }

    func pair(code: String) async {
        guard let peer = peers.first else { status = .failed("I can't see your other device. Open Smith on it, on the same Wi-Fi."); return }
        let key = SymmetricKey(data: SHA256.hash(data: Data("smith-pair:\(code)".utf8)))
        let conn = NWConnection(to: peer.endpoint, using: Self.parameters(key: key))
        status = .syncing
        do {
            try await conn.open()
            try await conn.sendMessage(Data("PAIR".utf8))
            let keyData = try await conn.receiveMessage()
            guard keyData.count == 32 else { throw SyncError.badCode }
            Keychain.syncKey = SymmetricKey(data: keyData)
            conn.cancel()
            status = .done("Paired with \(peerName ?? "your iPad").")
            startListener()
            await syncNow()
        } catch {
            conn.cancel()
            status = .failed(SyncError.badCode.localizedDescription)
        }
    }

    // MARK: syncing

    func syncNow() async {
        guard let key = Keychain.syncKey else { status = .failed(SyncError.notPaired.localizedDescription); return }
        guard let peer = peers.first else { status = .failed("Your other device isn't on this network right now."); return }
        status = .syncing
        let conn = NWConnection(to: peer.endpoint, using: Self.parameters(key: key))
        do {
            try await conn.open()
            try await conn.sendMessage(Data("SYNC".utf8))
            try await conn.sendMessage(try JSONEncoder().encode(store.syncPayload()))
            let theirs = try JSONDecoder().decode(SyncPayload.self, from: try await conn.receiveMessage())
            let (merged, receipt) = SyncMerge.merge(store.syncPayload(), theirs)
            store.apply(merged)
            conn.cancel()
            status = .done(receipt.text)
            startListener() // refresh the advertised export time
        } catch {
            conn.cancel()
            status = .failed("Sync didn't finish: \(error.localizedDescription)")
        }
    }

    private func accept(_ conn: NWConnection) {
        Task {
            do {
                try await conn.open()
                let hello = String(data: try await conn.receiveMessage(), encoding: .utf8)
                if hello == "PAIR", pairingCode != nil {
                    let newKey = SymmetricKey(size: .bits256)
                    try await conn.sendMessage(newKey.withUnsafeBytes { Data($0) })
                    Keychain.syncKey = newKey
                    pairingCode = nil
                    status = .done("Paired.")
                    try? await Task.sleep(for: .milliseconds(300))
                    conn.cancel()
                    startListener()
                } else if hello == "SYNC" {
                    status = .syncing
                    let theirs = try JSONDecoder().decode(SyncPayload.self, from: try await conn.receiveMessage())
                    try await conn.sendMessage(try JSONEncoder().encode(store.syncPayload()))
                    let (merged, receipt) = SyncMerge.merge(store.syncPayload(), theirs)
                    store.apply(merged)
                    status = .done(receipt.text)
                    try? await Task.sleep(for: .milliseconds(300))
                    conn.cancel()
                    startListener()
                } else {
                    conn.cancel()
                }
            } catch {
                conn.cancel()
            }
        }
    }

    func unpair() {
        Keychain.syncKey = nil
        status = .idle
        startListener()
    }
}

// MARK: length-prefixed messages over NWConnection

nonisolated extension NWConnection {
    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { c.resume() }
                case .failed(let e), .waiting(let e): once.run { c.resume(throwing: e) }
                case .cancelled: once.run { c.resume(throwing: SyncError.connection("Connection closed.")) }
                default: break
                }
            }
            start(queue: .main)
        }
    }

    func sendMessage(_ data: Data) async throws {
        var length = UInt32(data.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + data
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            send(content: frame, completion: .contentProcessed { e in e.map { c.resume(throwing: $0) } ?? c.resume() })
        }
    }

    func receiveMessage() async throws -> Data {
        let header = try await receiveExactly(4)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length < 200_000_000 else { throw SyncError.connection("Message too large.") }
        return try await receiveExactly(Int(length))
    }

    private func receiveExactly(_ n: Int) async throws -> Data {
        var out = Data()
        while out.count < n {
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                receive(minimumIncompleteLength: 1, maximumLength: n - out.count) { data, _, done, error in
                    if let error { c.resume(throwing: error) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else if done { c.resume(throwing: SyncError.connection("Connection closed.")) }
                    else { c.resume(returning: Data()) }
                }
            }
            out.append(chunk)
        }
        return out
    }
}

private nonisolated final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

/// AES-GCM for the `.smithdata` backup file.
enum AESGCMBox {
    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw SyncError.connection("Couldn't seal the file.") }
        return Data("SMITH1".utf8) + combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.starts(with: Data("SMITH1".utf8)) else { throw SyncError.connection("That isn't a Smith data file.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(6)), using: key)
    }
}
