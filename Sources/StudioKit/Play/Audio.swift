import Foundation
import AVFoundation
import simd

/// Where sound goes: the speakers, or — in the self-tests — a record of what would have
/// played. Buffers come mono, so a sound in a part can be placed in 3D.
protocol AudioOutput: AnyObject {
    /// Starts a sound `time` seconds in; `position` nil is heard the same everywhere.
    func start(_ id: UUID, buffer: AVAudioPCMBuffer, from time: Double, looped: Bool,
               volume: Float, speed: Float, at position: Vec3?)
    func stop(_ id: UUID)
    func update(_ id: UUID, volume: Float, speed: Float, at position: Vec3?)
    /// Where the ears are: the camera.
    func listen(at position: Vec3, forward: Vec3, up: Vec3)
}

/// The Mac's speakers, through AVAudioEngine: each sound a player node through a
/// varispeed (PlaybackSpeed), into the 3D environment if it's in a part, else straight
/// to the mix. Fading with distance is done by `SoundSystem`, not the environment, so
/// every Sound can have its own reach.
///
/// AVAudioEngine throws — an Objective-C exception, which ends the app — if a player
/// is started without a way to the output. Three things once made that happen, and are
/// guarded against here:
/// - `connect(_:to:format:)` into a mixer takes its input bus 0, knocking off whatever
///   was there: every sound goes to the mixer's *next free* bus instead.
/// - Starting the engine drops the environment's connection while nothing feeds it: it
///   is wired when a 3D sound first needs it, and checked every time.
/// - macOS stops the engine when the audio device changes (headphones, a display
///   waking): it is started again, and looping sounds resume.
/// A player is only ever started once its way to the output is there.
final class SpeakerOutput: AudioOutput {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private struct Voice {
        let player: AVAudioPlayerNode
        let pitch: AVAudioUnitVarispeed
        let buffer: AVAudioPCMBuffer
        let looped: Bool
        let spatial: Bool
    }
    private var voices: [UUID: Voice] = [:]
    private var changes: NSObjectProtocol?
    /// Rendering to a buffer instead of the speakers (the self-tests).
    let offline: Bool

    init(offline: Bool = false) {
        self.offline = offline
        engine.attach(environment)
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.reverbParameters.enable = false
        if offline, let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) {
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        changes = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                         queue: .main) { [weak self] _ in
            self?.recover()
        }
    }

    deinit {
        if let changes { NotificationCenter.default.removeObserver(changes) }
        engine.stop()
    }

    /// The engine running, started (again) if it isn't.
    @discardableResult
    private func run() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do { try engine.start() } catch { return false }
        return engine.isRunning
    }

    private var mixFormat: AVAudioFormat {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0
            ? format : AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    /// The environment into the mixer, on a bus of its own, if it isn't already.
    private func wireEnvironment() {
        guard engine.outputConnectionPoints(for: environment, outputBus: 0).isEmpty else { return }
        let mixer = engine.mainMixerNode
        engine.connect(environment, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: mixFormat)
    }

    private func wire(_ pitch: AVAudioUnitVarispeed, format: AVAudioFormat, spatial: Bool) {
        if spatial {
            wireEnvironment()
            engine.connect(pitch, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: format)
        } else {
            let mixer = engine.mainMixerNode
            engine.connect(pitch, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: format)
        }
    }

    /// Whether a voice's sound can reach the output.
    private func reaches(_ pitch: AVAudioUnitVarispeed, spatial: Bool) -> Bool {
        let out = engine.outputConnectionPoints(for: pitch, outputBus: 0)
        guard !out.isEmpty else { return false }
        return !spatial || !engine.outputConnectionPoints(for: environment, outputBus: 0).isEmpty
    }

    /// Whether a sound is playing with a way to the output (the self-tests ask).
    func isHeard(_ id: UUID) -> Bool {
        guard let voice = voices[id] else { return false }
        return voice.player.isPlaying && reaches(voice.pitch, spatial: voice.spatial)
    }

    func start(_ id: UUID, buffer: AVAudioPCMBuffer, from time: Double, looped: Bool,
               volume: Float, speed: Float, at position: Vec3?) {
        stop(id)
        guard buffer.frameLength > 0 else { return }
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitVarispeed()
        let spatial = position != nil
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: buffer.format)
        wire(pitch, format: buffer.format, spatial: spatial)
        if let position {
            player.renderingAlgorithm = .equalPowerPanning
            player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        }
        player.volume = min(max(volume, 0), 1)
        pitch.rate = min(max(speed, 1.0 / 32), 32)
        let skip = AVAudioFramePosition(max(time, 0) * buffer.format.sampleRate)
        if skip > 0, let rest = SoundSystem.slice(buffer, from: skip) {
            player.scheduleBuffer(rest, at: nil, options: [])
            if looped { player.scheduleBuffer(buffer, at: nil, options: .loops) }
        } else {
            player.scheduleBuffer(buffer, at: nil, options: looped ? .loops : [])
        }
        let voice = Voice(player: player, pitch: pitch, buffer: buffer, looped: looped, spatial: spatial)
        voices[id] = voice
        play(voice)
    }

    /// Starts a voice's player — only with the engine running and its way to the output
    /// there (wired again if starting the engine undid it); otherwise it stays silent.
    private func play(_ voice: Voice) {
        guard run() else { return }
        if !reaches(voice.pitch, spatial: voice.spatial) {
            if voice.spatial { wireEnvironment() }
            guard reaches(voice.pitch, spatial: voice.spatial) else { return }
        }
        voice.player.play()
    }

    func stop(_ id: UUID) {
        guard let voice = voices.removeValue(forKey: id) else { return }
        voice.player.stop()
        engine.detach(voice.player)
        engine.detach(voice.pitch)
    }

    /// The engine was stopped by a change of audio device: start it again. Looping
    /// sounds (music, ambience) carry on from their start; the rest were short and are let go.
    func recover() {
        for (id, voice) in voices where !voice.looped { stop(id) }
        guard run() else { return }
        for voice in voices.values {
            voice.player.stop()
            voice.player.scheduleBuffer(voice.buffer, at: nil, options: .loops)
            play(voice)
        }
    }

    /// What comes out, rendered offline: the loudest sample over `frames` (the self-tests).
    func renderOffline(frames: AVAudioFrameCount) -> Float {
        guard offline, run(),
              let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames),
              (try? engine.renderOffline(frames, to: out)) == .success,
              let channels = out.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(out.format.channelCount) {
            for frame in 0..<Int(out.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
        }
        return peak
    }

    func update(_ id: UUID, volume: Float, speed: Float, at position: Vec3?) {
        guard let voice = voices[id] else { return }
        voice.player.volume = min(max(volume, 0), 1)
        voice.pitch.rate = min(max(speed, 1.0 / 32), 32)
        if let position { voice.player.position = AVAudio3DPoint(x: position.x, y: position.y, z: position.z) }
    }

    func listen(at position: Vec3, forward: Vec3, up: Vec3) {
        environment.listenerPosition = AVAudio3DPoint(x: position.x, y: position.y, z: position.z)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
            up: AVAudio3DVector(x: up.x, y: up.y, z: up.z))
    }
}

/// What would have played, for the self-tests: nothing reaches the speakers.
final class RecordingOutput: AudioOutput {
    struct Voice: Equatable {
        var from: Double
        var looped: Bool
        var volume: Float
        var speed: Float
        var position: Vec3?
        var frames: Int
    }

    private(set) var playing: [UUID: Voice] = [:]
    /// Every start, in order.
    private(set) var started: [UUID] = []
    private(set) var listener = Vec3.zero

    func start(_ id: UUID, buffer: AVAudioPCMBuffer, from time: Double, looped: Bool,
               volume: Float, speed: Float, at position: Vec3?) {
        playing[id] = Voice(from: time, looped: looped, volume: volume, speed: speed, position: position,
                            frames: Int(buffer.frameLength))
        started.append(id)
    }

    func stop(_ id: UUID) { playing[id] = nil }

    func update(_ id: UUID, volume: Float, speed: Float, at position: Vec3?) {
        playing[id]?.volume = volume
        playing[id]?.speed = speed
        playing[id]?.position = position
    }

    func listen(at position: Vec3, forward: Vec3, up: Vec3) { listener = position }
}

/// Plays a scene's Sounds while it's played: starts and stops each as its `playing` and
/// `plays` say (a new `plays` starts it again, from `timePosition`), keeps the ones in
/// parts where their part is and the ears at the camera, fades them with distance, and
/// notices when one that doesn't loop runs out.
final class SoundSystem {
    /// What new play sessions hear through; the self-tests swap in a recorder.
    static var makeOutput: () -> AudioOutput = { SpeakerOutput() }

    let output: AudioOutput
    private struct Decoded {
        let size: Int
        let buffer: AVAudioPCMBuffer
    }
    private var decoded: [UUID: Decoded] = [:]
    private struct Voice {
        let plays: Int
        let startedAt: Double
        let from: Double
        let duration: Double
    }
    private var voices: [UUID: Voice] = [:]
    /// How many Sounds are being heard (`--soak` watches it).
    var voiceCount: Int { voices.count }
    /// Sounds that ran out, by the `plays` they ran out at: not started again until played again.
    private var finished: [UUID: Int] = [:]

    init(output: AudioOutput = SoundSystem.makeOutput()) {
        self.output = output
    }

    // MARK: - Files

    /// A sound asset as mono samples, decoded once.
    func buffer(for asset: SceneAsset) -> AVAudioPCMBuffer? {
        if let known = decoded[asset.id], known.size == asset.data.count { return known.buffer }
        guard asset.kind == .sound, let buffer = Self.decode(asset.data, fileExtension: asset.fileExtension) else {
            return nil
        }
        decoded[asset.id] = Decoded(size: asset.data.count, buffer: buffer)
        return buffer
    }

    /// How long a sound asset lasts, in seconds.
    func duration(of asset: SceneAsset) -> Double? {
        buffer(for: asset).map { Double($0.frameLength) / $0.format.sampleRate }
    }

    /// What a SoundId plays: a built-in sound ("builtin://Name") or a sound asset.
    func buffer(forSoundId soundId: String, in model: SceneModel) -> AVAudioPCMBuffer? {
        if soundId.hasPrefix(BuiltinSounds.prefix) { return BuiltinSounds.buffer(for: soundId) }
        return model.asset(named: soundId).flatMap(buffer(for:))
    }

    /// Any audio file AVFoundation reads, mixed down to one channel.
    static func decode(_ data: Data, fileExtension: String) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-sound-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: read)) != nil,
              let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: read.frameLength),
              let source = read.floatChannelData, let target = out.floatChannelData else { return nil }
        let channels = Int(read.format.channelCount)
        for frame in 0..<Int(read.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels { sum += source[channel][frame] }
            target[0][frame] = sum / Float(max(channels, 1))
        }
        out.frameLength = read.frameLength
        return out
    }

    /// The rest of a buffer from a frame on.
    static func slice(_ buffer: AVAudioPCMBuffer, from frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let start = Int(frame), length = Int(buffer.frameLength) - start
        guard length > 0, let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length)),
              let source = buffer.floatChannelData, let target = out.floatChannelData else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + start, count: length)
        }
        out.frameLength = AVAudioFrameCount(length)
        return out
    }

    // MARK: - Playing

    /// How loud a Sound is where the ears are: its Volume (Roblox's 0…10, 1 full), less
    /// the further its part is, to nothing at RollOffMaxDistance.
    static func heardVolume(_ sound: SceneSound, at position: Vec3?, listener: Vec3) -> Float {
        let volume = min(max(sound.volume, 0), 10)
        guard let position else { return volume }
        let distance = simd_distance(position, listener)
        return volume * max(0, 1 - distance / max(sound.rollOffMaxDistance, 0.01))
    }

    /// Brings what is heard up to the Sounds; returns those that ran out just now.
    @discardableResult
    func sync(_ model: SceneModel, clock: Double, listener: Vec3, forward: Vec3, up: Vec3) -> [UUID] {
        output.listen(at: listener, forward: forward, up: up)
        var ended: [UUID] = []
        let live = Dictionary(model.sounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in voices.keys where live[id] == nil { stop(id) }
        for sound in model.sounds {
            let part = sound.parentID.map { model.part(id: $0) }
            // In a part that's gone, or not playing, or nothing to play: silent.
            guard sound.playing, part.map({ $0 != nil }) ?? true, finished[sound.id] != sound.plays,
                  let buffer = buffer(forSoundId: sound.soundId, in: model) else {
                if voices[sound.id] != nil { stop(sound.id) }
                continue
            }
            let position = part??.position
            let volume = Self.heardVolume(sound, at: position, listener: listener)
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            if let voice = voices[sound.id], voice.plays == sound.plays {
                let at = voice.from + (clock - voice.startedAt) * Double(sound.playbackSpeed)
                if !sound.looped && at >= duration {
                    stop(sound.id)
                    finished[sound.id] = sound.plays
                    ended.append(sound.id)
                } else {
                    output.update(sound.id, volume: volume, speed: sound.playbackSpeed, at: position)
                }
            } else {
                output.start(sound.id, buffer: buffer, from: sound.timePosition, looped: sound.looped,
                             volume: volume, speed: sound.playbackSpeed, at: position)
                voices[sound.id] = Voice(plays: sound.plays, startedAt: clock, from: sound.timePosition,
                                         duration: duration)
            }
        }
        return ended
    }

    /// Where a Sound is now, in seconds.
    func timePosition(of sound: SceneSound, clock: Double) -> Double {
        guard sound.playing, let voice = voices[sound.id], voice.plays == sound.plays else { return sound.timePosition }
        let at = voice.from + (clock - voice.startedAt) * Double(sound.playbackSpeed)
        if sound.looped && voice.duration > 0 { return at.truncatingRemainder(dividingBy: voice.duration) }
        return min(at, voice.duration)
    }

    private func stop(_ id: UUID) {
        output.stop(id)
        voices[id] = nil
    }

    func stopAll() {
        for id in Array(voices.keys) { stop(id) }
        finished = [:]
    }
}
