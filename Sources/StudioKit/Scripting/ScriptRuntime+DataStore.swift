import Foundation

// The script runtime's host calls for `datastore.*`: DataStoreService's reads and writes,
// kept by DataStoreFiles under the place's id. Only the machine running the scene's
// scripts has them — a joined player's game gets nothing and changes nothing, and the
// Luau library says so to a LocalScript before it gets here.
//
// Values arrive already made storable by the library (numbers, strings, booleans and
// "$t" lists of them), so they are kept as they come.

extension ScriptRuntime {
    func dataStoreCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        func text(_ index: Int) -> String { index < arguments.count ? (arguments[index].asString ?? "") : "" }
        guard runsSceneScripts else { return .nothing }
        // A place from before places had ids (and not opened from a file, as a test's):
        // one for as long as it's open.
        if model.placeID == nil { model.placeID = UUID() }
        guard let place = model.placeID else { return .nothing }
        let files = DataStoreFiles.shared
        let store = text(0), scope = text(1), key = text(2)
        switch name {
        case "datastore.available":
            return .bool(true)

        case "datastore.get":
            return files.value(place: place, store: store, scope: scope, key: key) ?? .nothing

        case "datastore.set":
            guard arguments.count >= 4 else { return .bool(false) }
            if case .nothing = arguments[3] {
                files.remove(place: place, store: store, scope: scope, key: key)
            } else {
                files.set(arguments[3], place: place, store: store, scope: scope, key: key)
            }
            return .bool(true)

        case "datastore.remove":
            return files.remove(place: place, store: store, scope: scope, key: key) ?? .nothing

        case "datastore.entries":
            // Every key with its value, as [key, value] pairs, for an OrderedDataStore.
            let entries = files.entries(place: place, store: store, scope: scope)
            return .list(entries.keys.sorted().map { .list([.string($0), entries[$0]!]) })

        default:
            return .nothing
        }
    }
}
