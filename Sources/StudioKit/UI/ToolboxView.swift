import SwiftUI

/// The dock's Toolbox tab, as Roblox Studio's: ready-made models (ToolboxModels.swift),
/// each a card with its picture; click one and it's put in the world in front of the
/// camera, on whatever is there, selected — one step to undo.
struct ToolboxView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var pictures = ToolboxPictures.shared

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 10)], spacing: 10) {
                ForEach(ToolboxModel.allCases) { item in
                    Button {
                        session.showWorld()
                        session.viewport.insert(item)
                    } label: {
                        card(item)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isPlaying)
                    .help(session.isPlaying ? "Stop the game to insert models" : "Insert a \(item.rawValue) in front of the camera")
                }
            }
            .padding(10)
        }
        .onAppear { pictures.load() }
    }

    private func card(_ item: ToolboxModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panelAlt)
                if let picture = pictures.pictures[item] {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .frame(height: 96)
            .clipped()
            Text(item.rawValue)
                .font(.system(size: 11, weight: .semibold))
            // Two lines' room for every summary, so the cards line up.
            Text(item.summary)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
                .frame(height: 28, alignment: .topLeading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
        .foregroundStyle(Theme.text)
        .contentShape(Rectangle())
    }
}

/// The Toolbox's pictures, drawn the first time it opens: one model a turn of the run
/// loop, so the app stays responsive, with one renderer for them all.
final class ToolboxPictures: ObservableObject {
    static let shared = ToolboxPictures()
    static let size = (width: 300, height: 190)

    @Published private(set) var pictures: [ToolboxModel: NSImage] = [:]
    private var painter: AvatarSnapshot.ToolboxPicture?
    private var started = false

    func load() {
        guard !started else { return }
        started = true
        painter = AvatarSnapshot.ToolboxPicture(width: Self.size.width, height: Self.size.height)
        draw(ToolboxModel.allCases[...])
    }

    private func draw(_ remaining: ArraySlice<ToolboxModel>) {
        guard let item = remaining.first else {
            painter = nil
            return
        }
        DispatchQueue.main.async { [self] in
            if let image = painter?.picture(of: item, width: Self.size.width, height: Self.size.height) {
                pictures[item] = NSImage(cgImage: image, size: NSSize(width: Self.size.width / 2, height: Self.size.height / 2))
            }
            draw(remaining.dropFirst())
        }
    }

    /// Every picture at once (for a snapshot of the panel).
    func loadNow() {
        let painter = AvatarSnapshot.ToolboxPicture(width: Self.size.width, height: Self.size.height)
        for item in ToolboxModel.allCases {
            if let image = painter?.picture(of: item, width: Self.size.width, height: Self.size.height) {
                pictures[item] = NSImage(cgImage: image, size: NSSize(width: Self.size.width / 2, height: Self.size.height / 2))
            }
        }
        started = true
    }
}
