import Foundation

/// A file brought into the scene — a picture or a sound — kept inside it, so it travels
/// with the scene to wherever it's played, joined players included. Scripts name one as
/// "studio://Name".
struct SceneAsset: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case image, sound
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// The file as it was: PNG, JPEG, WAV, MP3, M4A…
    var data: Data
    var fileExtension: String

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic"]
    static let soundExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "aif", "caf", "aac"]
    /// The most one file may be, and all of them together: the scene goes to joined
    /// players in one message.
    static let largest = 8 << 20
    static let largestTotal = 40 << 20

    static func kind(forExtension ext: String) -> Kind? {
        let lower = ext.lowercased()
        if imageExtensions.contains(lower) { return .image }
        if soundExtensions.contains(lower) { return .sound }
        return nil
    }

    /// How a script names it.
    var reference: String { "studio://" + name }
}

/// A Sound: in a part (heard from there) or not (heard everywhere, as SoundService's).
/// Kept in the scene; while playing, whether it plays and from where travel with it, so a
/// host's sounds are heard by joined players.
struct SceneSound: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Sound"
    /// The part it is in; nil for everywhere.
    var parentID: UUID?
    /// "studio://Name" of a sound asset.
    var soundId = ""
    /// Roblox's 0…10; 0.5 by default.
    var volume: Float = 0.5
    var looped = false
    var playbackSpeed: Float = 1
    /// Heard up to this far from its part, in studs.
    var rollOffMaxDistance: Float = 100
    /// In the scene: plays when play starts. In play: whether it is playing now.
    var playing = false
    /// Goes up with every Play or Resume, so a copy elsewhere knows to start again.
    var plays = 0
    /// Where the current playing started from (Play: 0 or where a script put it;
    /// Resume: where Pause left it), in seconds.
    var timePosition: Double = 0
    /// Made by a joined player's own script: theirs alone, never replaced by the host's.
    var local = false

    init(name: String = "Sound", parentID: UUID? = nil) {
        self.name = name
        self.parentID = parentID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parentID, soundId, volume, looped, playbackSpeed, rollOffMaxDistance, playing, plays
        case timePosition, local
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Sound"
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        soundId = try c.decodeIfPresent(String.self, forKey: .soundId) ?? ""
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.5
        looped = try c.decodeIfPresent(Bool.self, forKey: .looped) ?? false
        playbackSpeed = try c.decodeIfPresent(Float.self, forKey: .playbackSpeed) ?? 1
        rollOffMaxDistance = try c.decodeIfPresent(Float.self, forKey: .rollOffMaxDistance) ?? 100
        playing = try c.decodeIfPresent(Bool.self, forKey: .playing) ?? false
        plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
        timePosition = try c.decodeIfPresent(Double.self, forKey: .timePosition) ?? 0
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
    }
}

enum AssetError: Error, LocalizedError, Equatable {
    case unknownKind(String)
    case tooLarge(Int)
    case full

    var errorDescription: String? {
        switch self {
        case .unknownKind(let ext): return "Only pictures and sounds can be imported, not .\(ext) files."
        case .tooLarge(let bytes): return "That file is \(bytes >> 20) MB; the most is \(SceneAsset.largest >> 20) MB."
        case .full: return "The scene's assets would be over \(SceneAsset.largestTotal >> 20) MB."
        }
    }
}

// SceneModel — Assets and Sounds.

extension SceneModel {
    func asset(id: UUID) -> SceneAsset? { assets.first { $0.id == id } }

    /// The asset a reference names: "studio://Name", "studio://<id>", or a bare name.
    func asset(named reference: String) -> SceneAsset? {
        let key = reference.hasPrefix("studio://") ? String(reference.dropFirst("studio://".count)) : reference
        guard !key.isEmpty else { return nil }
        return assets.first { $0.name == key } ?? UUID(uuidString: key).flatMap(asset(id:))
    }

    /// Brings a file in. With undo.
    @discardableResult
    func importAsset(data: Data, name: String, fileExtension: String) throws -> UUID {
        guard let kind = SceneAsset.kind(forExtension: fileExtension) else { throw AssetError.unknownKind(fileExtension) }
        guard data.count <= SceneAsset.largest else { throw AssetError.tooLarge(data.count) }
        guard assets.reduce(data.count, { $0 + $1.data.count }) <= SceneAsset.largestTotal else { throw AssetError.full }
        let asset = SceneAsset(name: Self.unique(name, among: assets.map(\.name)), kind: kind, data: data,
                               fileExtension: fileExtension.lowercased())
        commit("Imported \(asset.name)") {
            assets.append(asset)
            selectedAsset = asset.id
        }
        return asset.id
    }

    @discardableResult
    func importAsset(from url: URL) throws -> UUID {
        let data = try Data(contentsOf: url)
        return try importAsset(data: data, name: url.deletingPathExtension().lastPathComponent,
                               fileExtension: url.pathExtension)
    }

    func renameAsset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = assets.firstIndex(where: { $0.id == id }) else { return }
        commit("Renamed") { assets[index].name = Self.unique(trimmed, among: assets.filter { $0.id != id }.map(\.name)) }
    }

    func deleteAsset(_ id: UUID) {
        commit("Deleted \(asset(id: id)?.name ?? "asset")") {
            assets.removeAll { $0.id == id }
            if selectedAsset == id { selectedAsset = nil }
        }
    }

    // MARK: - Sounds

    func sound(id: UUID) -> SceneSound? { sounds.first { $0.id == id } }

    func sounds(in parent: UUID?) -> [SceneSound] { sounds.filter { $0.parentID == parent } }

    /// A new Sound, in a part or everywhere, selected. With undo.
    @discardableResult
    func addSound(in part: UUID?) -> UUID {
        var sound = SceneSound(name: Self.unique("Sound", among: sounds.map(\.name)), parentID: part)
        sound.soundId = assets.first { $0.kind == .sound }?.reference ?? ""
        commit("Added \(sound.name)") {
            sounds.append(sound)
            selectedSound = sound.id
        }
        return sound.id
    }

    func updateSound(id: UUID, _ body: (inout SceneSound) -> Void) {
        guard let index = sounds.firstIndex(where: { $0.id == id }) else { return }
        body(&sounds[index])
    }

    func deleteSound(_ id: UUID) {
        commit("Deleted \(sound(id: id)?.name ?? "sound")") {
            sounds.removeAll { $0.id == id }
            if selectedSound == id { selectedSound = nil }
        }
    }
}
