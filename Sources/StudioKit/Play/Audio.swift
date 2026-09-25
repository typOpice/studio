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
final class SpeakerOutput: AudioOutput {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var voices: [UUID: (player: AVAudioPlayerNode, pitch: AVAudioUnitVarispeed)] = [:]
    private var running = false

    init() {
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.reverbParameters.enable = false
    }

    private func run() {
        guard !running else { return }
        engine.prepare()
        running = (try? engine.start()) != nil
    }

    func start(_ id: UUID, buffer: AVAudioPCMBuffer, from time: Double, looped: Bool,
               volume: Float, speed: Float, at position: Vec3?) {
        stop(id)
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitVarispeed()
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: buffer.format)
        engine.connect(pitch, to: position == nil ? engine.mainMixerNode : environment, format: buffer.format)
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
        run()
        guard running else { return }
        player.play()
        voices[id] = (player, pitch)
    }

    func stop(_ id: UUID) {
        guard let voice = voices.removeValue(forKey: id) else { return }
        voice.player.stop()
        engine.detach(voice.player)
        engine.detach(voice.pitch)
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
                  let asset = model.asset(named: sound.soundId), let buffer = buffer(for: asset) else {
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
