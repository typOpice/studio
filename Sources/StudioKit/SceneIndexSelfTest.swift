import Foundation
import simd

/// The scene's index (SceneIndex.swift): after thousands of random changes of every
/// kind — parts and groups made, deleted, moved between parents, sent to storage and
/// back, arrays replaced whole with the same count, undone and redone — every part,
/// group, data object, Sound, parent and child list it answers matches a plain search
/// of the arrays; and finding a part, a Model's pivot, moving a Model and a folder's
/// children cost the same in a scene sixteen times bigger.
enum SceneIndexSelfTest {
    static func run(check: Checker) {
        testMatchesSearch(check)
        testCost(check)
    }

    /// What the index answers against what a search of the arrays finds.
    private static func mismatches(_ model: SceneModel, _ probes: [UUID]) -> [String] {
        var problems: [String] = []
        for id in probes {
            if model.part(id: id)?.id != model.parts.first(where: { $0.id == id })?.id { problems.append("part") }
            if model.group(id: id)?.id != model.groups.first(where: { $0.id == id })?.id { problems.append("group") }
            let parent = model.parts.first { $0.id == id }?.parentID ?? model.groups.first { $0.id == id }?.parentID
            if model.parentID(of: id) != parent { problems.append("parent") }
            if model.dataObject(id: id)?.id != model.dataObjects.first(where: { $0.id == id })?.id { problems.append("data") }
            if model.sound(id: id)?.id != model.sounds.first(where: { $0.id == id })?.id { problems.append("sound") }
        }
        for parent in [nil] + model.groups.map(\.id) + model.parts.prefix(20).map(\.id) as [UUID?] {
            let searched: [TreeNode] = model.groups.filter { $0.parentID == parent && (parent != nil || model.isInWorkspace($0)) }
                .map { .group($0.id) }
                + model.parts.filter { $0.parentID == parent && (parent != nil || $0.storage == nil) }.map { .part($0.id) }
            if model.children(of: parent) != searched { problems.append("children of \(String(describing: parent))") }
        }
        return problems
    }

    private static func testMatchesSearch(_ check: Checker) {
        print("\nScene index: the same answers as a search")
        let model = SceneModel()
        var generator = SystemRandomNumberGenerator()
        var known: [UUID] = [UUID()]
        var problems: [String] = []
        for step in 0..<3000 {
            let roll = Int.random(in: 0..<16, using: &generator)
            let groups = model.groups.map(\.id), parts = model.parts.map(\.id)
            switch roll {
            case 0, 1:
                var part = Part()
                part.parentID = Bool.random(using: &generator) ? groups.randomElement(using: &generator) : nil
                model.parts.append(part)
                known.append(part.id)
            case 2:
                let group = SceneGroup(name: "G", kind: Bool.random(using: &generator) ? .model : .folder)
                var placed = group
                placed.parentID = Bool.random(using: &generator) ? groups.randomElement(using: &generator) : nil
                model.groups.append(placed)
                known.append(group.id)
            case 3:
                if !model.parts.isEmpty { model.parts.remove(at: Int.random(in: 0..<model.parts.count, using: &generator)) }
            case 4:
                if !model.groups.isEmpty { model.groups.remove(at: Int.random(in: 0..<model.groups.count, using: &generator)) }
            case 5:
                // Reparented through the array, and through update(id:).
                if let id = parts.randomElement(using: &generator) {
                    if Bool.random(using: &generator), let slot = model.parts.firstIndex(where: { $0.id == id }) {
                        model.parts[slot].parentID = groups.randomElement(using: &generator)
                    } else {
                        model.update(id: id) { $0.parentID = groups.randomElement(using: &generator) }
                    }
                }
            case 6:
                if let id = parts.randomElement(using: &generator) {
                    model.update(id: id) { $0.position += Vec3(1, 0, 0) }
                }
            case 7:
                if let id = (parts + groups).randomElement(using: &generator) {
                    model.setStorage(id, Bool.random(using: &generator) ? .serverStorage : nil)
                }
            case 8:
                // Replaced whole, the same count, other ids.
                if !model.parts.isEmpty {
                    let count = model.parts.count
                    model.parts = (0..<count).map { _ in
                        var part = Part()
                        part.parentID = groups.randomElement(using: &generator)
                        known.append(part.id)
                        return part
                    }
                }
            case 9:
                model.parts.shuffle(using: &generator)
            case 10:
                var object = DataObject(name: "V", className: .intValue)
                object.parent = .none
                model.dataObjects.append(object)
                known.append(object.id)
            case 11:
                if !model.dataObjects.isEmpty {
                    model.dataObjects.remove(at: Int.random(in: 0..<model.dataObjects.count, using: &generator))
                }
            case 12:
                let sound = SceneSound(name: "S", parentID: parts.randomElement(using: &generator))
                model.sounds.append(sound)
                known.append(sound.id)
            case 13:
                if let id = (parts + groups).randomElement(using: &generator) {
                    model.commit("Moved") { _ = model.setParent(id, groups.randomElement(using: &generator)) }
                }
            case 14:
                model.undo()
            default:
                if let id = groups.randomElement(using: &generator), let slot = model.groups.firstIndex(where: { $0.id == id }) {
                    model.groups[slot].parentID = Bool.random(using: &generator) ? nil : groups.randomElement(using: &generator)
                }
            }
            if step % 25 == 0 {
                let probes = (0..<30).compactMap { _ in known.randomElement(using: &generator) } + [UUID()]
                problems += mismatches(model, probes).map { "step \(step): \($0)" }
            }
        }
        check("3000 random changes: parts, groups, parents, children, data objects and Sounds all found as a search finds them",
              problems.isEmpty, "\(problems.prefix(5))")
    }

    private static func testCost(_ check: Checker) {
        print("\nScene index: as fast in a big scene")
        func costs(parts count: Int) -> [Double] {
            let model = SceneModel()
            model.parts = []
            model.groups = []
            var ids: [UUID] = [], models: [UUID] = []
            for index in 0..<count {
                if index % 10 == 0 {
                    let group = SceneGroup(name: "M", kind: .model)
                    model.groups.append(group)
                    models.append(group.id)
                }
                var part = Part()
                part.parentID = models.last
                model.parts.append(part)
                ids.append(part.id)
            }
            func time(_ runs: Int, _ body: (Int) -> Void) -> Double {
                body(0)
                let started = Date()
                for run in 0..<runs { body(run) }
                return Date().timeIntervalSince(started) / Double(runs)
            }
            var sink = 0
            return [
                time(400) { sink += model.part(id: ids[($0 * 7919) % count]) == nil ? 0 : 1 },
                time(200) { sink += model.pivot(of: models[$0 % models.count]) == nil ? 0 : 1 },
                time(100) { run in
                    let id = models[run % models.count]
                    if let pose = model.pivot(of: id) { model.movePivot(of: id, to: pose) }
                },
                time(200) { sink += model.children(of: models[$0 % models.count]).count },
            ]
        }
        let small = costs(parts: 500), big = costs(parts: 8000)
        let ratios = zip(big, small).map { $0 / max($1, 1e-9) }
        check("finding a part, a Model's pivot, moving a Model, a folder's children: no dearer with 16 times the parts",
              ratios.allSatisfy { $0 < 4 }, "\(ratios.map { String(format: "%.1f", $0) })")
    }
}
