import HAPKit
import SwiftUI

/// What the editor opens with: an existing automatic playlist (its id) or a new one (nil).
struct RuleEditorRequest: Identifiable {
    let id = UUID()
    let playlistID: UUID?
    var name: String
    var rules: PlaylistRules
}

/// The automatic-playlist editor: name, match all/any, rules, limit, order, live count.
struct RuleEditorSheet: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    let request: RuleEditorRequest
    let save: (String, PlaylistRules) -> Void
    @State private var name = ""
    @State private var rules = PlaylistRules(match: .all, rules: [], limit: nil, order: .shuffled)
    /// The rule rows, each with its own identity, so removing one never mixes up the others.
    @State private var rows = EditableRules([])

    private var current: PlaylistRules {
        var made = rules
        made.rules = rows.rules
        return made
    }

    var body: some View {
        let count = RuleEngine.tracks(for: current, in: player.library?.tracks ?? [], artists: player.artistIndex).count
        VStack(alignment: .leading, spacing: 14) {
            Text(request.playlistID == nil ? "New Automatic Playlist" : "Edit Rules").font(.title3.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text("Match")
                Picker("", selection: $rules.match) {
                    Text("all").tag(MatchMode.all)
                    Text("any").tag(MatchMode.any)
                }
                .labelsHidden().fixedSize()
                Text("of these rules:")
            }
            ForEach($rows.items) { $item in
                HStack(alignment: .center) {
                    RuleRow(rule: $item.rule)
                    Spacer()
                    Button { rows.remove(item.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this rule")
                }
            }
            Button { rows.append(.genres([])) } label: { Label("Add Rule", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
            Divider()
            HStack {
                Toggle("Limit to", isOn: Binding(get: { rules.limit != nil }, set: { rules.limit = $0 ? 50 : nil }))
                if rules.limit != nil {
                    NumberField(value: rules.limit ?? 50) { rules.limit = max(1, $0) }
                    Text("songs")
                }
            }
            Picker("Order", selection: $rules.order) {
                ForEach(PlaylistOrder.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Text(count == 0 ? "No songs match yet" : "\(countText(count, "song")) match")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(request.playlistID == nil ? "Create" : "Save") {
                    save(name.trimmingCharacters(in: .whitespaces).isEmpty ? "Automatic Playlist" : name, current)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            name = request.name
            rules = request.rules
            rows = EditableRules(request.rules.rules)
        }
    }
}

/// The editor's rule rows, each with a stable id.
struct EditableRules {
    struct Item: Identifiable {
        let id = UUID()
        var rule: PlaylistRule
    }

    var items: [Item]
    init(_ rules: [PlaylistRule]) { items = rules.map { Item(rule: $0) } }
    var rules: [PlaylistRule] { items.map(\.rule) }
    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    mutating func append(_ rule: PlaylistRule) { items.append(Item(rule: rule)) }
}

/// A number box that takes what's typed at once (a value-formatted field only updates on
/// Return or leaving it, so clicking Save could lose the last change).
struct NumberField: View {
    let value: Int
    let set: (Int) -> Void
    @State private var text = ""

    static func parse(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        TextField("", text: $text)
            .frame(width: 64)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = String(value) }
            .onChange(of: text) { if let number = Self.parse(text), number != value { set(number) } }
            .onChange(of: value) { if Self.parse(text) != value { text = String(value) } }
    }
}

extension PlaylistOrder {
    var label: String {
        switch self {
        case .shuffled: "Shuffled"
        case .newest: "Newest first"
        case .mostPlayed: "Most played"
        case .artistAlbum: "By artist and album"
        case .year: "By year"
        }
    }
}

extension Quality {
    var label: String {
        switch self {
        case .hiRes: "Hi-res"
        case .cd: "CD quality"
        case .dsd: "DSD"
        }
    }
}

/// One rule: its kind, then the value(s) it needs.
private struct RuleRow: View {
    @Environment(PlayerModel.self) private var player
    @Binding var rule: PlaylistRule

    enum Kind: String, CaseIterable {
        case year = "Year", quality = "Quality", neverPlayed = "Never played", playedAtLeast = "Played at least",
             newest = "Newest additions", genres = "Genre is one of", artists = "Artist is one of"

        init(_ rule: PlaylistRule) {
            switch rule {
            case .year: self = .year
            case .quality: self = .quality
            case .neverPlayed: self = .neverPlayed
            case .playedAtLeast: self = .playedAtLeast
            case .newest: self = .newest
            case .genres: self = .genres
            case .artists: self = .artists
            }
        }

        var startingRule: PlaylistRule {
            switch self {
            case .year: .year(from: 1970, to: 1979)
            case .quality: .quality(.hiRes)
            case .neverPlayed: .neverPlayed
            case .playedAtLeast: .playedAtLeast(3)
            case .newest: .newest(50)
            case .genres: .genres([])
            case .artists: .artists([])
            }
        }
    }

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { Kind(rule) }, set: { rule = $0.startingRule })) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()
            switch rule {
            case .year(let from, let to):
                number(from) { rule = .year(from: $0, to: to) }
                Text("to")
                number(to) { rule = .year(from: from, to: $0) }
            case .quality(let quality):
                Picker("", selection: Binding(get: { quality }, set: { rule = .quality($0) })) {
                    ForEach(Quality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            case .neverPlayed:
                EmptyView()
            case .playedAtLeast(let count):
                number(count) { rule = .playedAtLeast(max(1, $0)) }
                Text("times")
            case .newest(let count):
                Text("last")
                number(count) { rule = .newest(max(1, $0)) }
                Text("songs")
            case .genres(let chosen):
                ChooserButton(title: "genres", all: (player.library?.genres ?? []).map(\.name).filter { !$0.isEmpty }.sorted(),
                              chosen: chosen) { rule = .genres($0) }  // chosen ones stay listed (see ChooserButton)
            case .artists(let chosen):
                ChooserButton(title: "artists", all: player.artistIndex.entries.map(\.name), chosen: chosen) { rule = .artists($0) }
            }
        }
    }

    private func number(_ value: Int, set: @escaping (Int) -> Void) -> some View {
        NumberField(value: value, set: set)
    }
}

/// Pick several genres or artists from a searchable list.
private struct ChooserButton: View {
    let title: String
    let all: [String]
    let chosen: [String]
    let change: ([String]) -> Void
    @State private var open = false
    @State private var filter = ""

    var body: some View {
        Button(chosen.isEmpty ? "Choose \(title)…" : chosen.joined(separator: ", ")) { open = true }
            .lineLimit(1)
            .frame(maxWidth: 260, alignment: .leading)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search \(title)", text: $filter).textFieldStyle(.roundedBorder)
                    // Chosen names stay in the list even if they've left the library, so they can be unticked.
                    let names = chosen.filter { !all.contains($0) } + all
                    List(names.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { chosen.contains(name) }, set: { on in
                            change(on ? chosen + [name] : chosen.filter { $0 != name })
                        }))
                    }
                    .frame(width: 280, height: 300)
                }
                .padding(12)
            }
    }
}
