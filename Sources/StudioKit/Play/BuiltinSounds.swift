import AVFoundation

/// Sounds Studio makes rather than plays from a file: "builtin://Name" as any Sound's
/// SoundId. Effects — a sword's swing, a hit, a coin, a checkpoint, a zombie's groan —
/// and music that loops, synthesized the first time they're wanted and kept. A place
/// using them carries no audio, and a network game sends only their names.
///
/// Everything is made from a few oscillators, noise and envelopes (`Synth`), the music
/// from a little sequencer (`Song`), so the same name always sounds the same.
enum BuiltinSounds {
    static let prefix = "builtin://"
    static let sampleRate = 22_050.0

    enum Kind: String { case effect, music }

    struct Entry {
        let name: String
        let kind: Kind
        let summary: String
        fileprivate let make: () -> [Float]
    }

    /// Every built-in sound, effects then music.
    static let catalog: [Entry] = [
        Entry(name: "Swing", kind: .effect, summary: "a sword's whoosh", make: Effects.swing),
        Entry(name: "Hit", kind: .effect, summary: "a solid thump", make: Effects.hit),
        Entry(name: "Shoot", kind: .effect, summary: "a blaster's zap", make: Effects.shoot),
        Entry(name: "Groan", kind: .effect, summary: "a zombie's moan", make: Effects.groan),
        Entry(name: "ZombieDown", kind: .effect, summary: "a zombie falling", make: Effects.zombieDown),
        Entry(name: "Hurt", kind: .effect, summary: "taking damage", make: Effects.hurt),
        Entry(name: "Oof", kind: .effect, summary: "knocked out", make: Effects.oof),
        Entry(name: "Pickup", kind: .effect, summary: "a coin or orb, two quick notes", make: Effects.pickup),
        Entry(name: "Sparkle", kind: .effect, summary: "something special found", make: Effects.sparkle),
        Entry(name: "PowerUp", kind: .effect, summary: "a rising arpeggio", make: Effects.powerUp),
        Entry(name: "Click", kind: .effect, summary: "a button", make: Effects.click),
        Entry(name: "Checkpoint", kind: .effect, summary: "two bright bells", make: Effects.checkpoint),
        Entry(name: "Boing", kind: .effect, summary: "a jump pad", make: Effects.boing),
        Entry(name: "Jump", kind: .effect, summary: "a little hop", make: Effects.jump),
        Entry(name: "Crack", kind: .effect, summary: "something giving way", make: Effects.crack),
        Entry(name: "Chime", kind: .effect, summary: "a soft bell: morning", make: Effects.chime),
        Entry(name: "Gong", kind: .effect, summary: "a deep gong: night falls", make: Effects.gong),
        Entry(name: "Rumble", kind: .effect, summary: "heavy stone moving", make: Effects.rumble),
        Entry(name: "Victory", kind: .effect, summary: "a short fanfare", make: Effects.victory),
        Entry(name: "Defeat", kind: .effect, summary: "falling notes", make: Effects.defeat),
        Entry(name: "CalmDay", kind: .music, summary: "gentle plucked chords, looping", make: Music.calmDay),
        Entry(name: "NightHunt", kind: .music, summary: "a tense, driving minor loop", make: Music.nightHunt),
        Entry(name: "ObbyRun", kind: .music, summary: "bright, bouncy chiptune, looping", make: Music.obbyRun),
    ]

    static func entry(named name: String) -> Entry? { catalog.first { $0.name == name } }

    /// The name in "builtin://Name", if it is one of these.
    static func name(of soundId: String) -> String? {
        guard soundId.hasPrefix(prefix) else { return nil }
        let name = String(soundId.dropFirst(prefix.count))
        return entry(named: name) == nil ? nil : name
    }

    private static var made: [String: AVAudioPCMBuffer] = [:]
    private static let lock = NSLock()

    /// The sound for "builtin://Name", made once. (Made outside the lock, so a long
    /// one being made elsewhere never holds up a short one wanted now.)
    static func buffer(for soundId: String) -> AVAudioPCMBuffer? {
        guard let name = name(of: soundId) else { return nil }
        lock.lock()
        let known = made[name]
        lock.unlock()
        if let known { return known }
        guard let samples = samples(named: name),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        lock.lock()
        defer { lock.unlock() }
        if let first = made[name] { return first }
        made[name] = buffer
        return buffer
    }

    /// Makes, off the main thread, what a place about to be played will want: the
    /// built-in sounds its Sounds name, and — if it uses any, or its scripts mention them —
    /// every effect, since scripts make Sounds as they go.
    static func prepare(for model: SceneModel) {
        let named = Set(model.sounds.map(\.soundId).filter { name(of: $0) != nil })
        let scripted = model.scripts.contains { $0.source.contains(prefix) }
        guard !named.isEmpty || scripted else { return }
        let effects = catalog.filter { $0.kind == .effect }.map { prefix + $0.name }
        DispatchQueue.global(qos: .userInitiated).async {
            for soundId in effects + named.sorted() { _ = buffer(for: soundId) }
        }
    }

    /// Every one as a WAV file in `folder` (`--write-sounds`), to listen to.
    static func writeAll(to folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in catalog {
            let started = Date()
            guard let buffer = buffer(for: prefix + entry.name),
                  let file = try? AVAudioFile(forWriting: folder.appendingPathComponent("\(entry.name).wav"),
                                              settings: buffer.format.settings),
                  (try? file.write(from: buffer)) != nil else {
                print("Could not write \(entry.name)")
                return false
            }
            let seconds = Double(buffer.frameLength) / sampleRate
            print(String(format: "%@  %.2fs  (made in %.2fs)", entry.name, seconds, Date().timeIntervalSince(started)))
        }
        return true
    }

    /// The samples themselves, made fresh.
    static func samples(named name: String) -> [Float]? {
        entry(named: name)?.make()
    }
}

// MARK: - Synthesis

private enum Wave { case sine, square(Double), saw, triangle }

/// A mono buffer being written: notes and noise added in, then levelled.
private struct Synth {
    var samples: [Float]
    private var seed: UInt32 = 0x2545_F491

    init(seconds: Double) {
        samples = Array(repeating: 0, count: Int(seconds * BuiltinSounds.sampleRate))
    }

    static func frequency(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    private static func sample(_ wave: Wave, _ phase: Double) -> Double {
        let p = phase - phase.rounded(.down)
        switch wave {
        case .sine: return sin(2 * .pi * p)
        case .square(let duty): return p < duty ? 1 : -1
        case .saw: return 2 * p - 1
        case .triangle: return p < 0.5 ? 4 * p - 1 : 3 - 4 * p
        }
    }

    /// How loud a note is `t` seconds in: up over `attack`, falling away with time
    /// constant `decay` (nil: held), and down to nothing over the last `release`.
    private static func envelope(_ t: Double, length: Double, attack: Double, decay: Double?, release: Double) -> Double {
        var level = attack > 0 ? min(t / attack, 1) : 1
        if let decay { level *= exp(-max(t - attack, 0) / decay) }
        let left = length - t
        if left < release { level *= max(left / release, 0) }
        return level
    }

    /// A note from `from` Hz sliding (by ratio) to `to`, with an optional wobble and a
    /// one-pole low-pass at `lowpass` Hz.
    mutating func tone(_ wave: Wave, at start: Double, length: Double, from: Double, to: Double? = nil,
                       volume: Double, attack: Double = 0.004, decay: Double? = nil, release: Double = 0.02,
                       vibrato: (rate: Double, depth: Double)? = nil, lowpass: Double? = nil) {
        let rate = BuiltinSounds.sampleRate
        let first = Int(start * rate), count = Int(length * rate)
        var phase = 0.0, filtered = 0.0
        let smoothing = lowpass.map { 1 - exp(-2 * .pi * $0 / rate) }
        for index in 0..<count where first + index < samples.count {
            let t = Double(index) / rate
            var frequency = from
            if let to { frequency = from * pow(to / from, t / length) }
            if let vibrato { frequency *= 1 + vibrato.depth * sin(2 * .pi * vibrato.rate * t) }
            phase += frequency / rate
            var value = Self.sample(wave, phase)
            if let smoothing {
                filtered += smoothing * (value - filtered)
                value = filtered
            }
            let level = Self.envelope(t, length: length, attack: attack, decay: decay, release: release)
            samples[first + index] += Float(value * level * volume)
        }
    }

    private mutating func random() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Double(seed) / Double(UInt32.max) * 2 - 1
    }

    /// Noise through a low-pass sweeping from `from` to `to` Hz, and a high-pass above
    /// `highpass` if given.
    mutating func noise(at start: Double, length: Double, volume: Double, attack: Double = 0.002,
                        decay: Double? = nil, release: Double = 0.02, lowpass from: Double = 8000, to: Double? = nil,
                        highpass: Double? = nil) {
        let rate = BuiltinSounds.sampleRate
        let first = Int(start * rate), count = Int(length * rate)
        var low = 0.0, floor = 0.0
        let high = highpass.map { 1 - exp(-2 * .pi * $0 / rate) }
        for index in 0..<count where first + index < samples.count {
            let t = Double(index) / rate
            var cutoff = from
            if let to { cutoff = from * pow(to / from, t / length) }
            low += (1 - exp(-2 * .pi * cutoff / rate)) * (random() - low)
            var value = low
            if let high {
                floor += high * (value - floor)
                value -= floor
            }
            let level = Self.envelope(t, length: length, attack: attack, decay: decay, release: release)
            samples[first + index] += Float(value * level * volume)
        }
    }

    /// Scaled so the loudest moment is `peak`.
    func levelled(to peak: Float) -> [Float] {
        let loudest = samples.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return samples }
        let gain = peak / loudest
        return samples.map { $0 * gain }
    }
}

// MARK: - Effects

private enum Effects {
    static func swing() -> [Float] {
        var s = Synth(seconds: 0.32)
        s.noise(at: 0, length: 0.3, volume: 1, attack: 0.09, decay: 0.07, lowpass: 700, to: 4200, highpass: 350)
        s.tone(.sine, at: 0, length: 0.25, from: 320, to: 140, volume: 0.15, attack: 0.08, decay: 0.08)
        return s.levelled(to: 0.8)
    }

    static func hit() -> [Float] {
        var s = Synth(seconds: 0.3)
        s.tone(.sine, at: 0, length: 0.25, from: 190, to: 55, volume: 1, decay: 0.07)
        s.noise(at: 0, length: 0.08, volume: 0.6, decay: 0.02, lowpass: 2600)
        return s.levelled(to: 0.9)
    }

    static func shoot() -> [Float] {
        var s = Synth(seconds: 0.26)
        s.tone(.square(0.3), at: 0, length: 0.22, from: 1500, to: 210, volume: 0.6, decay: 0.08, lowpass: 5000)
        s.tone(.sine, at: 0, length: 0.2, from: 900, to: 160, volume: 0.4, decay: 0.07)
        s.noise(at: 0, length: 0.03, volume: 0.3, decay: 0.01, lowpass: 6000)
        return s.levelled(to: 0.75)
    }

    static func groan() -> [Float] {
        var s = Synth(seconds: 1.3)
        s.tone(.saw, at: 0, length: 1.25, from: 98, to: 72, volume: 0.7, attack: 0.18, decay: 0.9, release: 0.2,
               vibrato: (5.5, 0.035), lowpass: 650)
        s.tone(.saw, at: 0.02, length: 1.2, from: 101, to: 74, volume: 0.45, attack: 0.2, decay: 0.8, release: 0.2,
               vibrato: (4.3, 0.04), lowpass: 520)
        s.noise(at: 0, length: 1.1, volume: 0.25, attack: 0.25, decay: 0.6, release: 0.2, lowpass: 480)
        return s.levelled(to: 0.8)
    }

    static func zombieDown() -> [Float] {
        var s = Synth(seconds: 0.8)
        s.tone(.saw, at: 0, length: 0.6, from: 150, to: 48, volume: 0.7, attack: 0.02, decay: 0.3, lowpass: 900)
        s.tone(.sine, at: 0.45, length: 0.3, from: 120, to: 45, volume: 0.9, decay: 0.08)
        s.noise(at: 0.45, length: 0.2, volume: 0.5, decay: 0.05, lowpass: 900)
        return s.levelled(to: 0.85)
    }

    static func hurt() -> [Float] {
        var s = Synth(seconds: 0.24)
        s.tone(.square(0.4), at: 0, length: 0.2, from: 440, to: 170, volume: 0.6, decay: 0.08, lowpass: 2400)
        s.noise(at: 0, length: 0.06, volume: 0.35, decay: 0.02, lowpass: 3000)
        return s.levelled(to: 0.75)
    }

    static func oof() -> [Float] {
        var s = Synth(seconds: 0.36)
        s.tone(.saw, at: 0, length: 0.3, from: 330, to: 140, volume: 0.8, attack: 0.01, decay: 0.12,
               vibrato: (18, 0.02), lowpass: 1300)
        s.tone(.sine, at: 0, length: 0.3, from: 660, to: 280, volume: 0.25, decay: 0.1)
        return s.levelled(to: 0.8)
    }

    static func pickup() -> [Float] {
        var s = Synth(seconds: 0.36)
        s.tone(.square(0.5), at: 0, length: 0.08, from: Synth.frequency(88), volume: 0.4, release: 0.01, lowpass: 7000)
        s.tone(.square(0.5), at: 0.07, length: 0.28, from: Synth.frequency(95), volume: 0.4, decay: 0.1, lowpass: 7000)
        return s.levelled(to: 0.6)
    }

    static func sparkle() -> [Float] {
        var s = Synth(seconds: 0.9)
        for (index, note) in [84.0, 88, 91, 96, 100].enumerated() {
            s.tone(.triangle, at: Double(index) * 0.06, length: 0.6, from: Synth.frequency(note), volume: 0.5, decay: 0.18)
            s.tone(.sine, at: Double(index) * 0.06, length: 0.6, from: Synth.frequency(note + 12), volume: 0.15, decay: 0.1)
        }
        return s.levelled(to: 0.65)
    }

    static func powerUp() -> [Float] {
        var s = Synth(seconds: 0.8)
        for (index, note) in [72.0, 76, 79, 84, 88].enumerated() {
            s.tone(.square(0.25), at: Double(index) * 0.065, length: 0.12, from: Synth.frequency(note), volume: 0.45,
                   decay: 0.08, lowpass: 5000)
        }
        s.tone(.square(0.25), at: 0.33, length: 0.45, from: Synth.frequency(91), volume: 0.4, decay: 0.2,
               vibrato: (7, 0.01), lowpass: 5000)
        return s.levelled(to: 0.65)
    }

    static func click() -> [Float] {
        var s = Synth(seconds: 0.05)
        s.tone(.sine, at: 0, length: 0.04, from: 1900, to: 1200, volume: 1, decay: 0.01, release: 0.005)
        s.noise(at: 0, length: 0.01, volume: 0.2, lowpass: 7000)
        return s.levelled(to: 0.5)
    }

    static func checkpoint() -> [Float] {
        var s = Synth(seconds: 0.9)
        for (index, note) in [81.0, 88].enumerated() {
            let start = Double(index) * 0.12
            s.tone(.sine, at: start, length: 0.7, from: Synth.frequency(note), volume: 0.6, decay: 0.25)
            s.tone(.triangle, at: start, length: 0.5, from: Synth.frequency(note + 12), volume: 0.2, decay: 0.12)
            s.tone(.sine, at: start, length: 0.4, from: Synth.frequency(note) * 2.76, volume: 0.08, decay: 0.08)
        }
        return s.levelled(to: 0.7)
    }

    static func boing() -> [Float] {
        var s = Synth(seconds: 0.45)
        s.tone(.sine, at: 0, length: 0.42, from: 140, to: 720, volume: 0.8, decay: 0.25, vibrato: (22, 0.06))
        s.tone(.triangle, at: 0, length: 0.3, from: 280, to: 1000, volume: 0.25, decay: 0.12)
        return s.levelled(to: 0.75)
    }

    static func jump() -> [Float] {
        var s = Synth(seconds: 0.16)
        s.tone(.square(0.5), at: 0, length: 0.14, from: 300, to: 640, volume: 0.5, decay: 0.08, lowpass: 3500)
        return s.levelled(to: 0.5)
    }

    static func crack() -> [Float] {
        var s = Synth(seconds: 0.4)
        for (index, start) in [0.0, 0.05, 0.13, 0.2].enumerated() {
            s.noise(at: start, length: 0.08, volume: 1 - Double(index) * 0.18, decay: 0.015, lowpass: 5000, highpass: 900)
        }
        s.tone(.sine, at: 0, length: 0.25, from: 240, to: 90, volume: 0.3, decay: 0.07)
        return s.levelled(to: 0.7)
    }

    static func chime() -> [Float] {
        var s = Synth(seconds: 2.4)
        for (start, base) in [(0.0, 880.0), (0.35, 1318.5)] {
            for (ratio, volume) in [(1.0, 0.5), (2.0, 0.2), (3.01, 0.12), (4.2, 0.05)] {
                s.tone(.sine, at: start, length: 2.0, from: base * ratio, volume: volume, attack: 0.003, decay: 0.7 / ratio)
            }
        }
        return s.levelled(to: 0.6)
    }

    static func gong() -> [Float] {
        var s = Synth(seconds: 3.6)
        for (ratio, volume, decay) in [(1.0, 0.8, 1.4), (1.48, 0.4, 1.0), (2.37, 0.25, 0.7), (3.13, 0.12, 0.5)] {
            s.tone(.sine, at: 0, length: 3.5, from: 62 * ratio, volume: volume, attack: 0.01, decay: decay,
                   vibrato: (0.7, 0.004))
        }
        s.noise(at: 0, length: 1.2, volume: 0.25, attack: 0.3, decay: 0.4, lowpass: 300)
        return s.levelled(to: 0.8)
    }

    static func rumble() -> [Float] {
        var s = Synth(seconds: 1.8)
        s.noise(at: 0, length: 1.7, volume: 1, attack: 0.2, release: 0.5, lowpass: 180)
        s.tone(.saw, at: 0, length: 1.7, from: 46, to: 38, volume: 0.35, attack: 0.3, release: 0.5, lowpass: 160)
        for start in stride(from: 0.1, to: 1.3, by: 0.23) {
            s.noise(at: start, length: 0.1, volume: 0.35, decay: 0.03, lowpass: 900, highpass: 200)
        }
        return s.levelled(to: 0.85)
    }

    static func victory() -> [Float] {
        var s = Synth(seconds: 1.6)
        for (index, note) in [72.0, 76, 79].enumerated() {
            s.tone(.square(0.25), at: Double(index) * 0.13, length: 0.13, from: Synth.frequency(note), volume: 0.4,
                   release: 0.02, lowpass: 4500)
        }
        for note in [84.0, 88, 91] {
            s.tone(.square(0.25), at: 0.39, length: 1.1, from: Synth.frequency(note), volume: 0.28, decay: 0.8,
                   release: 0.3, vibrato: (6, 0.006), lowpass: 4000)
        }
        s.tone(.triangle, at: 0.39, length: 1.1, from: Synth.frequency(48), volume: 0.5, decay: 0.6, release: 0.3)
        return s.levelled(to: 0.7)
    }

    static func defeat() -> [Float] {
        var s = Synth(seconds: 1.3)
        for (index, note) in [67.0, 64, 60, 55].enumerated() {
            s.tone(.triangle, at: Double(index) * 0.22, length: index == 3 ? 0.6 : 0.24, from: Synth.frequency(note),
                   volume: 0.6, decay: index == 3 ? 0.35 : nil, release: 0.04, vibrato: index == 3 ? (5, 0.01) : nil)
        }
        return s.levelled(to: 0.65)
    }
}

// MARK: - Music

/// A loop: notes by beat, drawn by instrument, then whatever rings past the end folded
/// back onto the start, so it loops without a seam.
private struct Song {
    let tempo: Double
    let beats: Double
    private var synth: Synth
    private let tail = 2.0

    init(tempo: Double, bars: Int) {
        self.tempo = tempo
        beats = Double(bars * 4)
        synth = Synth(seconds: beats * 60 / tempo + tail)
    }

    var beat: Double { 60 / tempo }

    enum Instrument { case bass, pluck, pad, lead, arp, kick, snare, hat, bell }

    mutating func play(_ instrument: Instrument, _ note: Double, at beat: Double, for length: Double = 1,
                       volume: Double = 1) {
        let start = beat * self.beat, seconds = length * self.beat
        let f = Synth.frequency(note)
        switch instrument {
        case .bass:
            synth.tone(.saw, at: start, length: seconds, from: f, volume: 0.5 * volume, attack: 0.005, decay: 0.35,
                       release: 0.03, lowpass: 520)
        case .pluck:
            synth.tone(.triangle, at: start, length: seconds + 0.6, from: f, volume: 0.35 * volume, decay: 0.28, release: 0.1)
        case .pad:
            for detune in [0.997, 1.003] {
                synth.tone(.saw, at: start, length: seconds, from: f * detune, volume: 0.12 * volume, attack: 0.35,
                           release: 0.4, lowpass: 900)
            }
        case .lead:
            synth.tone(.square(0.25), at: start, length: seconds, from: f, volume: 0.2 * volume, attack: 0.01,
                       decay: 0.6, release: 0.04, vibrato: (5.5, 0.006), lowpass: 3800)
        case .arp:
            synth.tone(.square(0.5), at: start, length: seconds, from: f, volume: 0.12 * volume, decay: 0.07,
                       release: 0.01, lowpass: 3000)
        case .kick:
            synth.tone(.sine, at: start, length: 0.22, from: 150, to: 42, volume: 0.9 * volume, decay: 0.09)
        case .snare:
            synth.noise(at: start, length: 0.18, volume: 0.45 * volume, decay: 0.05, lowpass: 5500, highpass: 400)
            synth.tone(.triangle, at: start, length: 0.1, from: 210, to: 150, volume: 0.25 * volume, decay: 0.04)
        case .hat:
            synth.noise(at: start, length: 0.05, volume: 0.18 * volume, decay: 0.012, lowpass: 9000, highpass: 5000)
        case .bell:
            synth.tone(.sine, at: start, length: seconds + 1, from: f, volume: 0.22 * volume, decay: 0.5, release: 0.2)
            synth.tone(.sine, at: start, length: seconds, from: f * 2.76, volume: 0.05 * volume, decay: 0.2)
        }
    }

    /// The loop, `beats` long, with the tail added back to its start.
    func looped(peak: Float) -> [Float] {
        let length = Int((beats * beat * BuiltinSounds.sampleRate).rounded())
        var loop = Array(synth.levelled(to: peak).prefix(synth.samples.count))
        for index in length..<loop.count { loop[index - length] += loop[index] }
        loop.removeLast(loop.count - length)
        let loudest = loop.reduce(0) { max($0, abs($1)) }
        return loudest > peak ? loop.map { $0 * peak / loudest } : loop
    }
}

private enum Music {
    /// Chord tones: a root and its intervals.
    static func chord(_ root: Double, minor: Bool) -> [Double] { [root, root + (minor ? 3 : 4), root + 7] }

    /// Nightfall by day: A minor, F, C, G, plucked, with a soft pad and bass. No drums.
    static func calmDay() -> [Float] {
        var song = Song(tempo: 84, bars: 8)
        let changes: [(Double, Bool)] = [(57, true), (53, false), (60, false), (55, false)]
        for bar in 0..<8 {
            let (root, minor) = changes[bar % 4]
            let tones = chord(root, minor: minor)
            let at = Double(bar * 4)
            for tone in tones { song.play(.pad, tone, at: at, for: 4, volume: 0.9) }
            song.play(.bass, root - 24, at: at, for: 2, volume: 0.7)
            song.play(.bass, root - 17, at: at + 2, for: 2, volume: 0.6)
            let pattern = [tones[0] + 12, tones[1] + 12, tones[2] + 12, tones[1] + 12,
                           tones[0] + 24, tones[2] + 12, tones[1] + 12, tones[2] + 12]
            for (step, note) in pattern.enumerated() {
                song.play(.pluck, note, at: at + Double(step) * 0.5, for: 0.5, volume: step % 2 == 0 ? 1 : 0.7)
            }
        }
        // A little tune over the second half.
        for (beat, note, length) in [(16.0, 76.0, 2.0), (18, 74, 1), (19, 72, 1), (20, 72, 3), (24, 71, 2),
                                     (26, 72, 1), (27, 74, 1), (28, 71, 4)] {
            song.play(.bell, note, at: beat, for: length, volume: 0.8)
        }
        return song.looped(peak: 0.6)
    }

    /// Nightfall by night: D minor, a driving sixteenth-note bass, four on the floor,
    /// and a lead that won't settle.
    static func nightHunt() -> [Float] {
        var song = Song(tempo: 132, bars: 8)
        let changes: [(Double, Bool)] = [(50, true), (50, true), (46, false), (48, false),
                                         (50, true), (50, true), (55, true), (57, false)]
        for bar in 0..<8 {
            let (root, minor) = changes[bar]
            let at = Double(bar * 4)
            for tone in chord(root, minor: minor) { song.play(.pad, tone - 12, at: at, for: 4, volume: 0.8) }
            for step in 0..<16 {
                let note = root - 24 + (step % 4 == 2 ? 12 : 0)
                song.play(.bass, note, at: at + Double(step) * 0.25, for: 0.25, volume: step % 4 == 0 ? 1 : 0.7)
                song.play(.hat, 0, at: at + Double(step) * 0.25, volume: step % 2 == 0 ? 0.8 : 0.4)
            }
            for beat in 0..<4 { song.play(.kick, 0, at: at + Double(beat), volume: 0.8) }
            song.play(.snare, 0, at: at + 1, volume: 0.7)
            song.play(.snare, 0, at: at + 3, volume: 0.7)
        }
        for (beat, note, length) in [(0.0, 69.0, 3.0), (3, 70, 1), (4, 69, 4), (8, 70, 2), (10, 72, 2), (12, 69, 4),
                                     (16, 74, 2), (18, 72, 1), (19, 70, 1), (20, 69, 4), (24, 67, 2), (26, 70, 2),
                                     (28, 73, 4)] {
            song.play(.lead, note, at: beat, for: length, volume: 0.9)
        }
        return song.looped(peak: 0.62)
    }

    /// Mega Obby: C major, I–V–vi–IV twice, bouncing bass, arpeggios and a happy tune.
    static func obbyRun() -> [Float] {
        var song = Song(tempo: 140, bars: 8)
        let changes: [(Double, Bool)] = [(60, false), (55, false), (57, true), (53, false),
                                         (60, false), (55, false), (53, false), (55, false)]
        for bar in 0..<8 {
            let (root, minor) = changes[bar]
            let tones = chord(root, minor: minor)
            let at = Double(bar * 4)
            for step in 0..<8 {
                song.play(.bass, root - 24 + (step % 2 == 1 ? 12 : 0), at: at + Double(step) * 0.5, for: 0.5,
                          volume: step % 2 == 0 ? 1 : 0.75)
                song.play(.hat, 0, at: at + Double(step) * 0.5, volume: step % 2 == 0 ? 0.7 : 0.45)
            }
            for step in 0..<16 {
                let note = tones[step % 3] + 12 + (step % 6 >= 3 ? 12 : 0)
                song.play(.arp, note, at: at + Double(step) * 0.25, for: 0.25, volume: 0.9)
            }
            song.play(.kick, 0, at: at, volume: 0.9)
            song.play(.kick, 0, at: at + 2, volume: 0.9)
            song.play(.snare, 0, at: at + 1, volume: 0.8)
            song.play(.snare, 0, at: at + 3, volume: 0.8)
        }
        let tune: [[(Double, Double, Double)]] = [
            [(0, 76, 0.5), (0.5, 79, 0.5), (1, 84, 1), (2, 79, 0.5), (2.5, 76, 0.5), (3, 79, 1)],
            [(0, 74, 0.5), (0.5, 79, 0.5), (1, 83, 1), (2, 81, 0.5), (2.5, 79, 0.5), (3, 74, 1)],
            [(0, 72, 0.5), (0.5, 76, 0.5), (1, 81, 1), (2, 79, 0.5), (2.5, 76, 0.5), (3, 72, 1)],
            [(0, 69, 0.5), (0.5, 72, 0.5), (1, 77, 1.5), (2.5, 76, 0.5), (3, 74, 1)],
            [(0, 76, 0.5), (0.5, 79, 0.5), (1, 84, 1), (2, 79, 0.5), (2.5, 76, 0.5), (3, 79, 1)],
            [(0, 74, 0.5), (0.5, 79, 0.5), (1, 83, 1), (2, 81, 0.5), (2.5, 79, 0.5), (3, 74, 1)],
            [(0, 77, 0.5), (0.5, 81, 0.5), (1, 84, 1), (2, 81, 0.5), (2.5, 77, 0.5), (3, 81, 1)],
            [(0, 79, 1), (1, 83, 0.5), (1.5, 86, 0.5), (2, 83, 1), (3, 79, 1)],
        ]
        for (bar, notes) in tune.enumerated() {
            for (beat, note, length) in notes {
                song.play(.lead, note, at: Double(bar * 4) + beat, for: length)
            }
        }
        return song.looped(peak: 0.6)
    }
}
