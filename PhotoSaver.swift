import Foundation
import Photos

/// Zapis odebranych plików w aplikacji Zdjęcia.
/// - data utworzenia = data wykonania przesłana z komputera (oś czasu w Zdjęciach jest poprawna),
/// - para zdjęcie + film o tej samej nazwie = Live Photo (gdy się nie da – zapis osobno),
/// - opcjonalnie dodanie do albumu,
/// - kilka plików naraz w jednej operacji (szybciej); przy błędzie – po jednym.
final class PhotoSaver {
    struct Item {
        let id: Int
        let url: URL
        let name: String
        let kind: String        // "photo" | "video"
        let date: Date?
        let group: String?
        let last: Bool
    }

    struct Result {
        let id: Int
        let ok: Bool
        let err: String
    }

    typealias Done = ([Result]) -> Void

    static let incomingDir: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: url)          // resztki po przerwanym odbiorze
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let model: AppModel
    private let q = DispatchQueue(label: "pl.stec.saver", qos: .userInitiated)
    private var groups: [String: [Item]] = [:]
    private var waiting: [([Item], Done)] = []
    private var scheduled = false
    private var albumName = ""
    private var album: PHAssetCollection?
    private var albumTried = false

    init(model: AppModel) {
        self.model = model
        _ = PhotoSaver.incomingDir
    }

    static func statusString() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .notDetermined: return "notDetermined"
        case .denied, .restricted:
            return PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized ? "addOnly" : "denied"
        @unknown default: return "denied"
        }
    }

    func setAlbum(_ name: String) {
        q.async {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != self.albumName {
                self.albumName = trimmed
                self.album = nil
                self.albumTried = false
            }
        }
    }

    func add(_ item: Item, done: @escaping Done) {
        q.async {
            var unit: [Item] = [item]
            if let g = item.group {
                self.groups[g, default: []].append(item)
                if !item.last { return }          // czekamy na drugą część pary Live Photo
                unit = self.groups.removeValue(forKey: g) ?? [item]
            }
            self.waiting.append((unit, done))
            if !self.scheduled {
                self.scheduled = true
                self.q.async { self.pump() }
            }
        }
    }

    // MARK: - zapis

    private func pump() {
        scheduled = false
        guard !waiting.isEmpty else { return }
        let batch = Array(waiting.prefix(12))
        waiting.removeFirst(batch.count)
        let results = save(batch.map { $0.0 })
        for (i, entry) in batch.enumerated() {
            entry.1(results[i])
        }
        for (unit, _) in batch {
            for it in unit { try? FileManager.default.removeItem(at: it.url) }
        }
        let ok = results.flatMap { $0 }.filter { $0.ok }.count
        let bad = results.flatMap { $0 }.filter { !$0.ok }
        model.post { m in
            m.saved += ok
            m.failed += bad.count
            if let e = bad.last { m.lastError = e.err }
        }
        if !waiting.isEmpty && !scheduled {
            scheduled = true
            q.async { self.pump() }
        }
    }

    private func save(_ units: [[Item]]) -> [[Result]] {
        ensureAlbum()
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                var placeholders: [PHObjectPlaceholder] = []
                for unit in units {
                    if let ph = self.request(for: unit, live: unit.count > 1) { placeholders.append(ph) }
                }
                self.addToAlbum(placeholders)
            }
            return units.map { unit in unit.map { Result(id: $0.id, ok: true, err: "") } }
        } catch {
            // coś w paczce się nie udało – po jednym, żeby wiedzieć który
            return units.map { saveSingle($0) }
        }
    }

    private func saveSingle(_ unit: [Item]) -> [Result] {
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let ph = self.request(for: unit, live: unit.count > 1)
                self.addToAlbum(ph.map { [$0] } ?? [])
            }
            return unit.map { Result(id: $0.id, ok: true, err: "") }
        } catch {
            if unit.count > 1 {
                // Live Photo się nie udało – zdjęcie i film osobno
                return unit.flatMap { saveSingle([$0]) }
            }
            return unit.map { Result(id: $0.id, ok: false, err: error.localizedDescription) }
        }
    }

    private func request(for unit: [Item], live: Bool) -> PHObjectPlaceholder? {
        let req = PHAssetCreationRequest.forAsset()
        for it in unit {
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = it.name
            opts.shouldMoveFile = false
            let type: PHAssetResourceType
            if it.kind == "video" {
                type = live ? .pairedVideo : .video
            } else {
                type = .photo
            }
            req.addResource(with: type, fileURL: it.url, options: opts)
        }
        if let date = unit.first(where: { $0.kind == "photo" })?.date ?? unit.first?.date {
            req.creationDate = date
        }
        return req.placeholderForCreatedAsset
    }

    // MARK: - album

    private func addToAlbum(_ placeholders: [PHObjectPlaceholder]) {
        guard let album = album, !placeholders.isEmpty,
              let change = PHAssetCollectionChangeRequest(for: album) else { return }
        change.addAssets(placeholders as NSArray)
    }

    private func ensureAlbum() {
        guard !albumName.isEmpty, album == nil, !albumTried else { return }
        albumTried = true
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", albumName)
        if let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject {
            album = found
            return
        }
        var newID: String?
        let name = albumName
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                newID = req.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            return
        }
        if let id = newID {
            album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        }
    }
}
