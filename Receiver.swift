import Foundation
import Network

/// Nasłuch na porcie 47820. Po kablu połączenie przychodzi przez usługę USB Apple (usbmux)
/// jako połączenie lokalne (127.0.0.1), przez Wi-Fi – z adresu komputera w sieci.
final class Receiver {
    static let port: UInt16 = 47820

    private let model: AppModel
    private let saver: PhotoSaver
    private let queue = DispatchQueue(label: "pl.stec.listener")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var restartScheduled = false

    init(model: AppModel, saver: PhotoSaver) {
        self.model = model
        self.saver = saver
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Zmiana nazwy / trybu / pytania o zgodę – nowe ogłoszenie w sieci (Bonjour).
    func settingsChanged() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.queue.asyncAfter(deadline: .now() + 0.3) { self.startOnQueue() }
        }
    }

    /// Rekord TXT usługi Bonjour (nazwa, model, id) – S-TEC na komputerze pokazuje je na liście.
    private func txtRecord() -> Data {
        let s = model.shared
        let pairs = ["name": s.name, "model": model.device.model, "id": model.device.vendorID,
                     "ask": s.ask ? "1" : "0", "v": "2"]
        var data = Data()
        for (key, value) in pairs {
            var entry = Array("\(key)=\(value)".utf8)
            if entry.count > 255 { entry = Array(entry.prefix(255)) }
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    private func startOnQueue() {
        if let current = listener {
            switch current.state {
            case .ready, .setup, .waiting:
                return
            default:
                current.cancel()
                listener = nil
            }
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: Receiver.port) else { return }
            let l = try NWListener(using: params, on: port)
            if model.shared.mode.allowsWifi {
                // widoczność w sieci domowej (jak AirPrint) – S-TEC znajdzie telefon sam
                l.service = NWListener.Service(name: model.shared.name, type: "_stec._tcp", domain: nil,
                                               txtRecord: txtRecord())
            }
            l.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
        } catch {
            model.post { m in
                m.phase = .error
                m.listenerError = error.localizedDescription
            }
            scheduleRestart()
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            model.post { m in
                m.listenerError = ""
                if m.connections == 0 && m.phase != .finished { m.phase = .waiting }
            }
        case .failed(let error):
            model.post { m in
                m.phase = .error
                m.listenerError = error.localizedDescription
            }
            listener?.cancel()
            listener = nil
            scheduleRestart()
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        queue.asyncAfter(deadline: .now() + 1.5) {
            self.restartScheduled = false
            self.startOnQueue()
        }
    }

    private func accept(_ conn: NWConnection) {
        var usb = false
        var lan = false
        if case let .hostPort(host, _) = conn.endpoint {
            let h = "\(host)".replacingOccurrences(of: "::ffff:", with: "")
            usb = h.hasPrefix("127.") || h == "::1" || h.hasPrefix("::1%")
            lan = !usb && (h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("172.") ||
                           h.hasPrefix("fe80") || h.contains("%en"))
        }
        let mode = model.shared.mode
        // tryb „Kabel” – nie przyjmujemy połączeń z sieci; tryb „Wi-Fi” – nie przyjmujemy z kabla
        if (mode == .cable && lan) || (mode == .wifi && usb) {
            conn.cancel()
            return
        }
        let session = Session(connection: conn, model: model, saver: saver, viaUSB: usb)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onClose = { [weak self] in
            self?.queue.async { self?.sessions.removeValue(forKey: key) }
        }
        session.start()
    }
}

/// Jedno połączenie z komputerem. Protokół STEC1: 4 bajty długości (big-endian) + JSON;
/// po {"t":"file","size":N} przychodzi N bajtów pliku.
final class Session {
    private struct Incoming {
        let id: Int
        let name: String
        let kind: String
        let date: Date?
        let group: String?
        let last: Bool
        let url: URL
        let handle: FileHandle?
        var remaining: Int64
        var failed: Bool
    }

    var onClose: (() -> Void)?

    private let conn: NWConnection
    private let model: AppModel
    private let saver: PhotoSaver
    private let viaUSB: Bool
    private let q = DispatchQueue(label: "pl.stec.session")
    private let sessionID = UUID().uuidString.prefix(8)
    private var buf = Data()
    private var file: Incoming?
    private var closed = false
    private var counted = false
    private var accepted = false
    private var peer = ""
    private var totalBytes: Int64 = 0
    private var reportedBytes: Int64 = 0
    private var lastPost = Date.distantPast
    private var window: [(Date, Int64)] = []

    init(connection: NWConnection, model: AppModel, saver: PhotoSaver, viaUSB: Bool) {
        self.conn = connection
        self.model = model
        self.saver = saver
        self.viaUSB = viaUSB
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        conn.start(queue: q)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buf.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.closed {
                self.receive()
            }
        }
    }

    // MARK: - przetwarzanie strumienia

    private func process() {
        while !closed {
            if var f = file {
                if buf.isEmpty { return }
                let n = Int(min(Int64(buf.count), f.remaining))
                if let h = f.handle, !f.failed {
                    do {
                        try h.write(contentsOf: buf.prefix(n))
                    } catch {
                        f.failed = true
                    }
                }
                if n == buf.count {
                    buf.removeAll(keepingCapacity: true)
                } else {
                    buf = buf.subdata(in: (buf.startIndex + n)..<buf.endIndex)
                }
                f.remaining -= Int64(n)
                addBytes(Int64(n))
                if f.remaining <= 0 {
                    file = nil
                    finishFile(f)
                } else {
                    file = f
                }
                continue
            }
            guard buf.count >= 4 else { return }
            let s = buf.startIndex
            let len = Int(buf[s]) << 24 | Int(buf[s + 1]) << 16 | Int(buf[s + 2]) << 8 | Int(buf[s + 3])
            guard len > 0, len < 16_000_000 else {
                close()
                return
            }
            guard buf.count >= 4 + len else { return }
            let json = buf.subdata(in: (s + 4)..<(s + 4 + len))
            buf = buf.subdata(in: (s + 4 + len)..<buf.endIndex)
            guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  let type = obj["t"] as? String else {
                close()
                return
            }
            handle(type, obj)
        }
    }

    private func handle(_ type: String, _ m: [String: Any]) {
        switch type {
        case "hello":
            let probe = (m["probe"] as? Bool) ?? false
            peer = (m["name"] as? String) ?? "S-TEC"
            if !probe && !counted {
                counted = true
                let usb = viaUSB
                let from = peer
                model.post { mm in
                    mm.connections += 1
                    mm.viaUSB = usb
                    mm.peerName = from
                    if mm.phase == .finished || mm.phase == .waiting { mm.phase = .receiving }
                }
            }
            let settings = model.shared
            send(["t": "hello",
                  "v": 2,
                  "name": settings.name,
                  "ask": settings.ask,
                  "cable": settings.mode.allowsCable,
                  "wifi": settings.mode.allowsWifi,
                  "model": model.device.model,
                  "device": model.device.vendorID,
                  "app": model.device.appVersion,
                  "free": Session.freeSpace(),
                  "photos": PhotoSaver.statusString()])
        case "album":
            saver.setAlbum((m["name"] as? String) ?? "")
        case "ping":
            send(["t": "pong"])
        case "bye":
            send(["t": "bye"])
        case "offer":
            handleOffer(m)
        case "file":
            if !accepted && model.shared.ask {
                close()          // bez zgody nic nie zapisujemy
                return
            }
            startFile(m)
        default:
            break
        }
    }

    private func handleOffer(_ m: [String: Any]) {
        if !model.shared.ask {
            accepted = true
            send(["t": "accepted"])
            return
        }
        let sid = String(sessionID)
        let offer = Offer(session: sid,
                          from: (m["from"] as? String) ?? peer,
                          files: (m["files"] as? NSNumber)?.intValue ?? 0,
                          bytes: (m["bytes"] as? NSNumber)?.int64Value ?? 0,
                          viaUSB: viaUSB) { [weak self] ok in
            guard let self = self else { return }
            self.q.async {
                self.accepted = ok
                self.send(["t": ok ? "accepted" : "rejected"])
            }
        }
        model.post { mm in mm.pendingOffer = offer }
    }

    private func startFile(_ m: [String: Any]) {
        let id = (m["id"] as? NSNumber)?.intValue ?? 0
        let name = (m["name"] as? String) ?? "plik"
        let size = (m["size"] as? NSNumber)?.int64Value ?? 0
        let kind = (m["kind"] as? String) ?? "photo"
        let date = (m["date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let group = (m["group"] as? String).map { "\(sessionID)-\($0)" }
        let last = (m["last"] as? Bool) ?? true
        let ext = (name as NSString).pathExtension.lowercased()
        let url = PhotoSaver.incomingDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: url)
        let f = Incoming(id: id, name: name, kind: kind, date: date, group: group, last: last, url: url,
                         handle: handle, remaining: size, failed: handle == nil)
        model.post { mm in mm.currentFile = name }
        if size <= 0 {
            finishFile(f)
        } else {
            file = f
        }
    }

    private func finishFile(_ f: Incoming) {
        try? f.handle?.close()
        model.post { mm in mm.received += 1 }
        if f.failed {
            try? FileManager.default.removeItem(at: f.url)
            let err = T("Nie udało się zapisać pliku w telefonie (brak miejsca?)",
                        "Could not write the file on the phone (out of space?)")
            send(["t": "ack", "id": f.id, "ok": false, "err": err])
            model.post { mm in
                mm.failed += 1
                mm.lastError = "\(f.name): \(err)"
            }
            return
        }
        let item = PhotoSaver.Item(id: f.id, url: f.url, name: f.name, kind: f.kind, date: f.date,
                                   group: f.group, last: f.last)
        saver.add(item) { [weak self] results in
            guard let self = self else { return }
            self.q.async {
                for r in results {
                    self.send(["t": "ack", "id": r.id, "ok": r.ok, "err": r.err])
                }
            }
        }
    }

    // MARK: - wysyłanie / statystyki

    private func send(_ obj: [String: Any]) {
        guard !closed, let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func addBytes(_ n: Int64) {
        totalBytes += n
        let now = Date()
        guard now.timeIntervalSince(lastPost) > 0.25 else { return }
        lastPost = now
        window.append((now, totalBytes))
        while let firstSample = window.first, now.timeIntervalSince(firstSample.0) > 3, window.count > 2 {
            window.removeFirst()
        }
        var bps: Double = 0
        if let firstSample = window.first {
            let dt = now.timeIntervalSince(firstSample.0)
            if dt > 0.2 { bps = Double(totalBytes - firstSample.1) / dt }
        }
        let delta = totalBytes - reportedBytes
        reportedBytes = totalBytes
        model.post { mm in
            mm.speed = bps
            mm.bytes += delta
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        if let f = file {
            try? f.handle?.close()
            try? FileManager.default.removeItem(at: f.url)
            file = nil
        }
        conn.cancel()
        let sid = String(sessionID)
        let wasCounted = counted
        let delta = totalBytes - reportedBytes
        reportedBytes = totalBytes
        model.post { mm in
            if mm.pendingOffer?.session == sid { mm.pendingOffer = nil }
            mm.bytes += delta
            if wasCounted { mm.connections = max(0, mm.connections - 1) }
            mm.speed = 0
            if mm.connections == 0 {
                mm.phase = mm.received > 0 ? .finished : .waiting
                mm.currentFile = ""
            }
        }
        onClose?()
    }

    static func freeSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage {
            return cap
        }
        return 0
    }
}
