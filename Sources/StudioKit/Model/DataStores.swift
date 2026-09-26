import Foundation

/// Where DataStoreService keeps what scripts save: a folder per place (by its
/// `placeID`), a JSON file per data store and scope, holding each key's value as the
/// Luau library encodes it (see `datastore.*` in ScriptRuntime+DataStore). Only the host
/// — whoever runs the scene's scripts — reads and writes it, so in a network game it is
/// the host's machine that remembers everyone's progress.
///
/// Values are kept in memory once read and written through to disk at once, so a quit
/// or a crash loses nothing that was set.
final class DataStoreFiles {
    static let shared = DataStoreFiles()

    /// The folder every place's is in. The self-tests point it somewhere of their own.
    var directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Studio/DataStores", isDirectory: true)
    } () {
        didSet { cache = [:] }
    }

    private var cache: [URL: [String: ScriptValue]] = [:]

    private func file(place: UUID, store: String, scope: String) -> URL {
        // Names made safe for a file name, and never clashing with each other.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        func safe(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "store" }
        return directory.appendingPathComponent(place.uuidString, isDirectory: true)
            .appendingPathComponent("\(safe(store))@\(safe(scope)).json")
    }

    private func contents(of url: URL) -> [String: ScriptValue] {
        if let kept = cache[url] { return kept }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: ScriptValue].self, from: $0) }
        cache[url] = read ?? [:]
        return read ?? [:]
    }

    private func write(_ values: [String: ScriptValue], to url: URL) {
        cache[url] = values
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if values.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func value(place: UUID, store: String, scope: String, key: String) -> ScriptValue? {
        contents(of: file(place: place, store: store, scope: scope))[key]
    }

    func set(_ value: ScriptValue, place: UUID, store: String, scope: String, key: String) {
        let url = file(place: place, store: store, scope: scope)
        var values = contents(of: url)
        values[key] = value
        write(values, to: url)
    }

    /// Takes a key out, handing back what it held.
    @discardableResult
    func remove(place: UUID, store: String, scope: String, key: String) -> ScriptValue? {
        let url = file(place: place, store: store, scope: scope)
        var values = contents(of: url)
        let old = values.removeValue(forKey: key)
        write(values, to: url)
        return old
    }

    /// Every key and value in a store, for an OrderedDataStore's pages.
    func entries(place: UUID, store: String, scope: String) -> [String: ScriptValue] {
        contents(of: file(place: place, store: store, scope: scope))
    }

    /// Whether anything is saved for a place.
    func hasData(place: UUID) -> Bool {
        let folder = directory.appendingPathComponent(place.uuidString, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasSuffix(".json") }
    }

    /// Forgets everything a place's scripts saved (Studio's File › Clear Saved Data).
    func clear(place: UUID) {
        let folder = directory.appendingPathComponent(place.uuidString, isDirectory: true)
        cache = cache.filter { !$0.key.path.hasPrefix(folder.path) }
        try? FileManager.default.removeItem(at: folder)
    }
}

extension UUID {
    /// The same UUID every time for the same text: a place from a file saved before
    /// places had ids gets one from its path, so it keeps its data without being edited.
    init(stableFrom text: String) {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325, second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100_0000_01b3
            second = (second ^ UInt64(byte)) &* 0x100_0000_01b3 &+ 7
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: first >> (index * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: second >> (index * 8))
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50   // a name-based UUID
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

extension SceneModel {
    /// A place opened from a file saved before places had ids gets one from the file's
    /// path — the same every time, and without marking the place edited.
    func ensurePlaceID(from url: URL) {
        if placeID == nil { placeID = UUID(stableFrom: url.standardizedFileURL.path) }
    }
}
