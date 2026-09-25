import Foundation
import simd

// PlayController and the mouse: where it points (`pointer`, set by the view), what it
// points at (Player:GetMouse's Hit and Target), and ClickDetectors — hovered and
// clicked. The host decides clicks for everyone; a joined player's game asks it.

extension PlayController {
    /// The ray under the pointer — or through the middle of the view, while the pointer
    /// is captured (first person) or unknown.
    func mouseRay() -> Ray? {
        guard viewSize.x > 0, viewSize.y > 0 else { return nil }
        let point = mouseCaptured ? viewSize / 2 : pointer ?? viewSize / 2
        return renderCamera.ray(atViewPoint: point, viewSize: viewSize)
    }

    /// The part the mouse is over and the point on it. Tools in hands are not targets.
    func mouseTarget() -> (part: Part, point: Vec3)? {
        guard let ray = mouseRay(), let hit = Picking.pick(ray: ray, in: partsOutOfHands) else { return nil }
        return (hit.part, ray.origin + ray.direction * hit.distance)
    }

    /// Whether a player's character is near enough a part to click its ClickDetector.
    func canClick(_ part: Part, from player: Int) -> Bool {
        guard let detector = part.clickDetector else { return false }
        let feet: Vec3
        if player == playerID {
            guard hasPlayer, !humanoid.isDead else { return false }
            feet = character.position
        } else if let remote = remotePlayers.first(where: { $0.id == player }), !remote.dead {
            feet = remote.position
        } else {
            return false
        }
        let reach = simd_distance(feet + Vec3(0, 3, 0), part.position) - simd_length(part.size) / 2
        return reach <= detector.maxActivationDistance
    }

    /// The ClickDetector part under the mouse that this player can click, if any.
    func clickableTarget() -> Part? {
        guard let part = mouseTarget()?.part, part.clickDetector != nil, canClick(part, from: playerID) else { return nil }
        return part
    }

    /// `["Click", partID, player, "MouseClick" | "MouseHoverEnter" | "MouseHoverLeave"]`
    func queueClick(_ part: UUID, by player: Int, _ what: String) {
        pendingEvents.append(.list([.string("Click"), .string(part.uuidString), .number(Double(player)), .string(what)]))
    }

    /// A left click with no tool in hand: the ClickDetector under the mouse, if in reach.
    func clickPart() {
        guard let part = clickableTarget() else { return }
        if worldFromHost {
            sendAction?("click.part", [.string(part.id.uuidString)])
        } else {
            queueClick(part.id, by: playerID, "MouseClick")
        }
    }

    /// Hover in and out of ClickDetectors, as the mouse or the camera moves.
    func updateHover() {
        guard hasPlayer, model.parts.contains(where: { $0.clickDetector != nil }) || hoveredPart != nil else { return }
        let now = clickableTarget()?.id
        guard now != hoveredPart else { return }
        for (part, what) in [(hoveredPart, "MouseHoverLeave"), (now, "MouseHoverEnter")] {
            guard let part else { continue }
            if worldFromHost {
                sendAction?("click.hover", [.string(part.uuidString), .bool(what == "MouseHoverEnter")])
            } else {
                queueClick(part, by: playerID, what)
            }
        }
        hoveredPart = now
    }

    /// A joined player's click or hover, checked here: the part has a detector and they
    /// are near enough.
    func remoteClick(from player: Int, _ name: String, _ arguments: [ScriptValue]) {
        guard let id = arguments.first?.asString.flatMap(UUID.init(uuidString:)), let part = model.part(id: id),
              part.clickDetector != nil else { return }
        if name == "click.part" {
            if canClick(part, from: player) { queueClick(id, by: player, "MouseClick") }
        } else {
            let entering = arguments.count > 1 ? arguments[1].asBool ?? true : true
            queueClick(id, by: player, entering ? "MouseHoverEnter" : "MouseHoverLeave")
        }
    }

    /// `input.mouse`: where the mouse hits, what, and where it is on the screen —
    /// [x, y, z, target or "", screen x, screen y, view width, view height].
    func mouseState() -> ScriptValue {
        let hit: Vec3
        var target = ""
        if let found = mouseTarget() {
            hit = found.point
            target = found.part.id.uuidString
        } else if let ray = mouseRay() {
            hit = ray.origin + ray.direction * 1000
        } else {
            hit = renderCamera.target
        }
        let point = mouseCaptured ? viewSize / 2 : pointer ?? viewSize / 2
        return .list([.number(Double(hit.x)), .number(Double(hit.y)), .number(Double(hit.z)), .string(target),
                      .number(Double(point.x)), .number(Double(point.y)),
                      .number(Double(viewSize.x)), .number(Double(viewSize.y))])
    }
}
