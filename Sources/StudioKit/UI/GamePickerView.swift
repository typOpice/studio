import SwiftUI
import AppKit

/// The client's first screen: which game to play — a sample game, a place played here
/// before, or a place file. Choosing one goes on to the menu, to play it, host it, or
/// dress the character first. Joining someone else's game needs no choice.
struct GamePickerView: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var games: HomeModel

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    heading("Sample games")
                    // As tall as the tallest, all three.
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(PlaceTemplate.samples) { template in
                            GameCard(template: template, picture: games.pictures[template.id]) {
                                session.choose(template)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    heading("Your places")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        PlaceCard(title: "Open a place…", subtitle: "A place saved from Studio",
                                  picture: nil, symbol: "folder") { games.browse() }
                        PlaceCard(title: PlaceTemplate.starter.title, subtitle: PlaceTemplate.starter.summary,
                                  picture: games.pictures[PlaceTemplate.starter.id],
                                  symbol: PlaceTemplate.starter.symbol) { session.choose(.starter) }
                        ForEach(games.recents) { place in
                            PlaceCard(title: place.name, subtitle: place.folder, picture: games.pictures[place.id],
                                      symbol: "doc.richtext") { games.openFile(place.url) }
                        }
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .background(MenuBackground())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STUDIO").font(.system(size: 34, weight: .heavy)).tracking(4)
                Text("Choose a game").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                if let problem = session.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Color(red: 0.95, green: 0.5, blue: 0.45))
                }
            }
            Spacer()
            MenuButton(title: "Join a game", icon: "person.2.fill", width: 190) { session.screen = .join }
            MenuButton(title: "Character", icon: "person.crop.square", width: 170) { session.screen = .character }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.text)
    }
}

/// A sample game: its picture, name, what it is, and what's in it.
private struct GameCard: View {
    let template: PlaceTemplate
    let picture: CGImage?
    let action: () -> Void

    var body: some View {
        HoverCard(action: action) { hovering in
            VStack(alignment: .leading, spacing: 9) {
                Picture(image: picture, symbol: template.symbol, hovering: hovering)
                Text(template.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(template.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(4, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                FlowTags(tags: template.tags)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tags that wrap onto a second line rather than squeezing.
private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        // Two rows of three: every sample game has six.
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(stride(from: 0, to: tags.count, by: 3)), id: \.self) { start in
                HStack(spacing: 5) {
                    ForEach(tags[start..<min(start + 3, tags.count)], id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(SwiftUI.Capsule().fill(Theme.panelAlt))
                            .foregroundStyle(Theme.text)
                    }
                }
            }
        }
    }
}
