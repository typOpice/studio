import SwiftUI
import AppKit

/// A place opened or saved lately, for the home page.
struct RecentPlace: Identifiable, Equatable {
    let url: URL
    var modified: Date?

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// The folder it's in, with the home folder as ~.
    var folder: String {
        let path = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// "Edited 5 minutes ago".
    func edited(relativeTo now: Date = Date()) -> String {
        guard let modified else { return "Saved place" }
        if now.timeIntervalSince(modified) < 60 { return "Edited just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Edited " + formatter.localizedString(for: modified, relativeTo: now)
    }
}

/// What the home page shows, and what its buttons do. The editor's app delegate fills in
/// the actions, since opening a place may first ask about unsaved changes.
final class HomeModel: ObservableObject {
    @Published private(set) var recents: [RecentPlace] = []
    /// Pictures by template id or file path, drawn a little after the page appears.
    @Published private(set) var pictures: [String: CGImage] = [:]
    /// Shown over a place that is open, which Back returns to.
    @Published var canGoBack = false
    @Published var currentName = ""

    var open: (PlaceTemplate) -> Void = { _ in }
    var openFile: (URL) -> Void = { _ in }
    var browse: () -> Void = {}
    var goBack: () -> Void = {}
    var clearRecents: () -> Void = {}
    var reveal: (URL) -> Void = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static let recentLimit = 12
    /// Templates look the same every time, so their pictures are drawn once per run.
    private static var templatePictures: [String: CGImage] = [:]
    private var pending: [String] = []

    /// The recent places that still exist, newest first, without repeats.
    static func places(from urls: [URL]) -> [RecentPlace] {
        var seen = Set<String>()
        var places: [RecentPlace] = []
        for url in urls {
            let file = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path), seen.insert(file.path).inserted else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            places.append(RecentPlace(url: file, modified: modified))
            if places.count == recentLimit { break }
        }
        return places
    }

    func refresh(recentURLs: [URL], drawNow: Bool = false) {
        recents = Self.places(from: recentURLs)
        for (id, image) in Self.templatePictures { pictures[id] = image }
        pending = PlaceTemplate.allCases.map(\.id).filter { pictures[$0] == nil }
            + recents.map(\.id).filter { pictures[$0] == nil }
        if drawNow {
            while !pending.isEmpty { drawNext() }
        } else {
            scheduleNext()
        }
    }

    /// One picture per turn of the run loop, so the page answers clicks while they come.
    private func scheduleNext() {
        guard !pending.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawNext()
            self.scheduleNext()
        }
    }

    private func drawNext() {
        guard !pending.isEmpty else { return }
        let id = pending.removeFirst()
        if let template = PlaceTemplate(rawValue: id) {
            if let image = PlaceThumbnail.shared.image(of: template.state(), camera: template.thumbnailCamera,
                                                       character: template.thumbnailCharacter) {
                Self.templatePictures[id] = image
                pictures[id] = image
            }
        } else if let place = recents.first(where: { $0.id == id }),
                  let image = PlaceThumbnail.shared.image(ofFile: place.url) {
            pictures[id] = image
        }
    }
}

/// Studio's home page: what it shows at launch, and under File › Home. New places from
/// templates, Adventure Island, and the places opened lately.
struct HomeView: View {
    @ObservedObject var home: HomeModel

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                section("New place") {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(PlaceTemplate.starters) { template in
                            PlaceCard(title: template.title, subtitle: template.summary,
                                      picture: home.pictures[template.id], symbol: template.symbol) {
                                home.open(template)
                            }
                        }
                    }
                }
                section("Sample game") { adventure }
                section("Recent", trailing: home.recents.isEmpty ? nil : AnyView(
                    Button("Clear Recents") { home.clearRecents() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim))) {
                    if home.recents.isEmpty {
                        Text("Places you open or save show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .background(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(home.recents) { place in
                                PlaceCard(title: place.name, subtitle: "\(place.edited())\n\(place.folder)",
                                          picture: home.pictures[place.id], symbol: "doc.richtext") {
                                    home.openFile(place.url)
                                }
                                .help(place.url.path)
                                .contextMenu {
                                    Button("Open") { home.openFile(place.url) }
                                    Button("Show in Finder") { home.reveal(place.url) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 1260, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ribbon)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.45, green: 0.35, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "cube.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text("Studio")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Build a place, script it in Luau, and play it — on your own or with friends on your network.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 20)
            Button {
                home.browse()
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .controlSize(.large)
            if home.canGoBack {
                Button {
                    home.goBack()
                } label: {
                    Label("Back to \(home.currentName)", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var adventure: some View {
        HoverCard(action: { home.open(.adventure) }) { hovering in
            AdventureCard(picture: home.pictures[PlaceTemplate.adventure.id], hovering: hovering)
        }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
    }
}

/// Adventure Island's card: its picture beside what's in it.
private struct AdventureCard: View {
    let picture: CGImage?
    let hovering: Bool
    private let template = PlaceTemplate.adventure
    private static let tagNames = ["Explore", "8 NPCs", "Obby tower", "Ray tracing", "Shaders", "Multiplayer"]

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Picture(image: picture, symbol: template.symbol, hovering: hovering)
                .frame(width: 400)
            VStack(alignment: .leading, spacing: 10) {
                title
                Text(template.summary + " Open it to play, or to see how every part of it is made.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                tags
                Spacer(minLength: 0)
                Text("Open \(template.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text(template.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("SAMPLE GAME")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(SwiftUI.Capsule().fill(Theme.accent.opacity(0.25)))
                .foregroundStyle(Theme.accent)
        }
    }

    private var tags: some View {
        HStack(spacing: 6) {
            ForEach(Self.tagNames, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SwiftUI.Capsule().fill(Theme.panelAlt))
                    .foregroundStyle(Theme.text)
            }
        }
    }
}

/// A card that lights up under the pointer and does `action` when clicked.
private struct HoverCard<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content(hovering)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.panelAlt : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovering ? Theme.accent.opacity(0.7) : Theme.stroke))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A place's picture at 16:9, or its symbol until the picture is ready.
private struct Picture: View {
    let image: CGImage?
    let symbol: String
    let hovering: Bool

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Theme.panelAlt, Theme.ribbon], startPoint: .top, endPoint: .bottom)
                        .overlay(Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(Theme.textDim))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(hovering ? 1.01 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A template or a recent place: its picture, name and a line or two about it.
private struct PlaceCard: View {
    let title: String
    let subtitle: String
    let picture: CGImage?
    let symbol: String
    let action: () -> Void

    var body: some View {
        HoverCard(action: action) { hovering in
            VStack(alignment: .leading, spacing: 8) {
                Picture(image: picture, symbol: symbol, hovering: hovering)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
