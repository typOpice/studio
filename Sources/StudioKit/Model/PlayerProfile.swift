import Foundation

/// Who is playing in the client: the name other players see and the look of their
/// character. Kept between launches; the client lays it over each scene it plays, so the
/// player's own colours replace the scene's StarterPlayer defaults.
struct PlayerProfile: Codable, Equatable {
    var name = "Player"
    var colors = BodyColors()
    /// What they wear, from the built-in catalog only (a place's files stay there).
    var look = AvatarLook()

    init() {}

    private enum CodingKeys: String, CodingKey { case name, colors, look }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Player"
        colors = try c.decodeIfPresent(BodyColors.self, forKey: .colors) ?? BodyColors()
        look = try c.decodeIfPresent(AvatarLook.self, forKey: .look) ?? AvatarLook()
    }

    static let defaultsKey = "StudioPlayerProfile"
    static let longestName = 20

    /// A name as the player typed it, made fit to show: trimmed, not too long, never empty.
    static func tidy(_ name: String) -> String {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(longestName))
        return trimmed.isEmpty ? "Player" : trimmed
    }

    static func load(from defaults: UserDefaults = .standard) -> PlayerProfile {
        guard let data = defaults.data(forKey: defaultsKey),
              var profile = try? JSONDecoder().decode(PlayerProfile.self, from: data) else { return PlayerProfile() }
        profile.name = tidy(profile.name)
        profile.look = profile.look.builtInOnly
        return profile
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Readies a play session for this player: their colours on the character, their name
    /// on `player.Name`. Call before `start()`, which spawns the character.
    func apply(to model: SceneModel, _ session: PlayController) {
        model.starterPlayer.bodyColors = colors
        session.playerName = Self.tidy(name)
        session.playerLook = look.builtInOnly
    }

    /// Colours to choose from: a handful of Roblox's classic BrickColors.
    static let palette: [(name: String, color: Vec3)] = [
        ("White", Vec3(0.95, 0.95, 0.95)), ("Light stone grey", Vec3(0.90, 0.89, 0.87)),
        ("Medium stone grey", Vec3(0.64, 0.64, 0.64)), ("Dark stone grey", Vec3(0.39, 0.37, 0.38)),
        ("Black", Vec3(0.11, 0.11, 0.12)), ("Bright red", Vec3(0.77, 0.16, 0.11)),
        ("Really red", Vec3(1.00, 0.00, 0.00)), ("Bright orange", Vec3(0.85, 0.52, 0.25)),
        ("Bright yellow", Vec3(0.96, 0.80, 0.19)), ("Cool yellow", Vec3(0.99, 0.92, 0.55)),
        ("Bright green", Vec3(0.29, 0.59, 0.29)), ("Lime green", Vec3(0.00, 1.00, 0.00)),
        ("Earth green", Vec3(0.15, 0.27, 0.16)), ("Teal", Vec3(0.07, 0.93, 0.83)),
        ("Bright blue", Vec3(0.05, 0.41, 0.67)), ("Really blue", Vec3(0.00, 0.00, 1.00)),
        ("Pastel blue", Vec3(0.50, 0.73, 0.86)), ("Navy blue", Vec3(0.00, 0.13, 0.38)),
        ("Bright violet", Vec3(0.42, 0.20, 0.49)), ("Magenta", Vec3(0.67, 0.00, 0.47)),
        ("Pink", Vec3(1.00, 0.40, 0.80)), ("Nougat", Vec3(0.80, 0.56, 0.41)),
        ("Brown", Vec3(0.49, 0.36, 0.27)), ("Reddish brown", Vec3(0.41, 0.25, 0.17)),
    ]
}
