import AppKit
import Foundation

/// Launches the standalone client on the current scene by writing it to a temporary
/// file and handing that path to the `StudioClient` executable next to this one.
enum LaunchClient {
    static func launch(with model: SceneModel) {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("studio-scene-\(UUID().uuidString.prefix(8)).json")
            try model.encodeScene().write(to: url)

            guard let executable = clientExecutableURL() else {
                model.statusText = "Client executable not found next to the editor"
                return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = [url.path]
            try process.run()
            model.statusText = "Launched client on a copy of this scene"
        } catch {
            model.statusText = "Could not launch client: \(error.localizedDescription)"
        }
    }

    /// Looks for `StudioClient` beside the running binary, then beside the .app bundle.
    private static func clientExecutableURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        candidates.append(directory.appendingPathComponent("StudioClient"))
        candidates.append(directory.appendingPathComponent("Client"))

        // Inside Studio.app/Contents/MacOS, look for a sibling StudioClient.app too.
        let bundleSibling = directory
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Studio.app
            .deletingLastPathComponent()   // containing folder
            .appendingPathComponent("StudioClient.app/Contents/MacOS/Client")
        candidates.append(bundleSibling)

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
