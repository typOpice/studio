import Foundation
import Combine
import UniformTypeIdentifiers
import simd

/// A saved selection: parts plus their scripts, Sounds and the pictures and sounds they
/// use, positioned relative to a pivot so the creation can be dropped anywhere in another
/// scene.
struct ModelFile: Codable {
    var name: String
    var pivot: Vec3
    var state: SceneState
}

/// Tracks which file the scene belongs to and whether it has unsaved changes.
final class SceneDocument: ObservableObject {
    static let sceneExtension = "studioscene"
    static let modelExtension = "studiomodel"

    static var sceneType: UTType { UTType(filenameExtension: sceneExtension) ?? .json }
    static var modelType: UTType { UTType(filenameExtension: modelExtension) ?? .json }

    @Published private(set) var url: URL?
    @Published private(set) var savedRevision: Int

    private unowned let model: SceneModel

    init(model: SceneModel) {
        self.model = model
        self.savedRevision = model.revision
    }

    var isDirty: Bool { model.revision != savedRevision }

    var displayName: String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var windowTitle: String {
        "Studio — \(displayName)\(isDirty ? " (edited)" : "")"
    }

    // MARK: - Whole scenes

    func save(to destination: URL) throws {
        try model.encodeScene().write(to: destination, options: .atomic)
        url = destination
        savedRevision = model.revision
        NSDocumentControllerNoteRecent(destination)
        model.statusText = "Saved \(destination.lastPathComponent)"
    }

    func open(_ source: URL) throws {
        try model.loadScene(from: Data(contentsOf: source))
        // One from before places had ids: its DataStores go by where the file is.
        model.ensurePlaceID(from: source)
        url = source
        savedRevision = model.revision
        NSDocumentControllerNoteRecent(source)
        model.statusText = "Opened \(source.lastPathComponent)"
    }

    func reset() {
        startNew { model.clearScene() }
    }

    /// A new, untitled place made by `make` — a template, the starter scene: saving it
    /// asks where, rather than writing over the file that was open before.
    func startNew(_ make: () -> Void) {
        make()
        url = nil
        savedRevision = model.revision
    }

    /// A sensible default filename for a save panel.
    var suggestedFileName: String {
        url?.lastPathComponent ?? "Creation.\(Self.sceneExtension)"
    }

    // MARK: - Models (a saved selection)

    func modelData(name: String) throws -> Data? {
        // Every selected subtree: its parts, Models, Folders and scripts. The roots are
        // saved as if they sat in the Workspace.
        let roots = model.selectionRoots
        var ids = Set(roots)
        for root in roots { ids.formUnion(model.descendants(of: root).map(\.id)) }
        var parts = model.parts.filter { ids.contains($0.id) }
        var groups = model.groups.filter { ids.contains($0.id) }
        guard !parts.isEmpty else { return nil }
        for i in parts.indices where roots.contains(parts[i].id) { parts[i].parentID = nil }
        for i in groups.indices where roots.contains(groups[i].id) { groups[i].parentID = nil }
        let scripts = model.scripts.filter { $0.parentID.map(ids.contains) ?? false }
        let attachments = model.attachments.filter { ids.contains($0.parentID) }
        let attachmentIDs = Set(attachments.map(\.id))
        let constraints = model.constraints.filter { c in
            let ends = c.kind == .weld ? [c.part0, c.part1] : [c.attachment0, c.attachment1]
            return ends.allSatisfy { $0.map { ids.contains($0) || attachmentIDs.contains($0) } ?? false }
        }
        let pivot = parts.reduce(Vec3.zero) { $0 + $1.position } / Float(parts.count)
        // Its Sounds, and the files they play or its scripts name, so it sounds the same anywhere.
        let sounds = model.sounds.filter { !$0.local && ($0.parentID.map(ids.contains) ?? false) }
        // …and the 3D models and pictures its MeshParts show.
        let played = Set(sounds.compactMap { model.asset(named: $0.soundId)?.id })
            .union(parts.compactMap { $0.mesh?.asset })
            .union(parts.compactMap { $0.mesh.flatMap { model.asset(named: $0.textureId)?.id } })
        let sources = scripts.map(\.source)
        let assets = model.assets.filter { asset in
            played.contains(asset.id) || sources.contains { $0.contains(asset.reference) }
        }

        let file = ModelFile(name: name, pivot: pivot,
                             state: SceneState(parts: parts, scripts: scripts, groups: groups,
                                               attachments: attachments, constraints: constraints,
                                               assets: assets, sounds: sounds))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Inserts a saved creation, re-identified so it never clashes with what is already there.
    @discardableResult
    func insertModel(from data: Data, at destination: Vec3) throws -> Int {
        model.insert(try JSONDecoder().decode(ModelFile.self, from: data), at: destination)
    }
}

/// Small shim so the model layer does not import AppKit directly.
private func NSDocumentControllerNoteRecent(_ url: URL) {
    RecentDocuments.note?(url)
}

enum RecentDocuments {
    /// Set by the app layer, which owns AppKit.
    static var note: ((URL) -> Void)?
}
