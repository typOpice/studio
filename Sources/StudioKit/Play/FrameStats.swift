import Foundation

/// Where a play session's frames go — its scripts, its physics, drawing it — smoothed
/// over the last half second or so, and what the process holds: what the Stats service
/// tells scripts (`stats.get`), and so what the HUD's numbers show.
struct FrameStats {
    /// Milliseconds, each an average that follows the frames with a short lag.
    private(set) var step = 0.0
    private(set) var scripts = 0.0
    private(set) var physics = 0.0
    private(set) var draw = 0.0

    /// Of each new frame, how much counts: about the last 20 frames, mostly.
    private static let weight = 0.1

    mutating func note(step: Double, scripts: Double, physics: Double) {
        self.step += (step * 1000 - self.step) * Self.weight
        self.scripts += (scripts * 1000 - self.scripts) * Self.weight
        self.physics += (physics * 1000 - self.physics) * Self.weight
    }

    mutating func note(draw seconds: Double) {
        draw += (seconds * 1000 - draw) * Self.weight
    }

    /// The whole frame on the CPU: the game's step and drawing it.
    var frame: Double { step + draw }

    /// The process's footprint in megabytes, as Activity Monitor's Memory column counts it.
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
