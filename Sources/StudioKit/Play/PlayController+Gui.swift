import Foundation
import AppKit
import simd

// PlayController and the screen: the `gui.*` host calls the Luau GUI objects are built
// on, typing into a TextBox, and `chat.*`. GUI objects are addressed by the number
// `gui.create` returned; 0 is the PlayerGui.

extension PlayController {
    /// A TextBox has the keyboard: keys type instead of reaching the game.
    var isTyping: Bool { gui.focused != nil }

    /// A key while typing. Return finishes (FocusLost with enterPressed), Escape gives up,
    /// Delete takes a character back, the arrows and Home/End move the caret, and
    /// anything else types.
    func typeKey(keyCode: UInt16, characters: String) {
        switch keyCode {
        case 36, 76: gui.releaseFocus(enterPressed: true)
        case 53: gui.releaseFocus(enterPressed: false)
        case 51: gui.backspace()
        case 117: gui.deleteForward()
        case 123: gui.moveCursor(by: -1)
        case 124: gui.moveCursor(by: 1)
        case 115, 126: gui.moveCursor(toEnd: false)
        case 119, 125: gui.moveCursor(toEnd: true)
        default: gui.type(characters)
        }
    }

    /// ⌘A, ⌘C, ⌘X and ⌘V while typing; false for any other command key.
    func typeCommand(_ key: String) -> Bool {
        let board = NSPasteboard.general
        switch key.lowercased() {
        case "a":
            gui.selectAll()
        case "c", "x":
            guard let text = gui.selectedText else { return true }
            board.clearContents()
            board.setString(text, forType: .string)
            if key.lowercased() == "x" { gui.backspace() }
        case "v":
            if let text = board.string(forType: .string) { gui.paste(text) }
        default:
            return false
        }
        return true
    }

    // MARK: - StarterGui

    /// Copies StarterGui's ScreenGuis into this player's PlayerGui — every one, or only
    /// those with ResetOnSpawn for a new character — and returns the LocalScripts in the
    /// copies, each with whether it goes with the character.
    func copyStarterGui(resetting: Bool) -> [(script: ScriptObject, resets: Bool)] {
        var found: [(ScriptObject, Bool)] = []
        for screen in model.guiChildren(of: nil) where screen.kind.isLayer {
            if !hasPlayer && screen.worldParent == nil { continue }
            if resetting && screen.worldParent != nil { continue }
            let resets = screen.worldParent == nil && screen.object().resetOnSpawn
            if resetting && !resets { continue }
            let copies = gui.copy(screen, from: model.starterGui, into: GuiStore.playerGui)
            guiCopies.merge(copies) { _, new in new }
            if hasPlayer {
                for template in copies.keys { found += model.guiScripts(in: template).map { ($0, resets) } }
            }
        }
        return found
    }

    /// Starts StarterGui's LocalScripts: those in a ResetOnSpawn ScreenGui with the
    /// character, the rest for the whole game.
    func runGuiScripts(_ found: [(script: ScriptObject, resets: Bool)]) {
        var remaining = found
        for root in model.starterGui where root.worldParent != nil {
            let family = Set(model.guiSubtree(root.id))
            let inside = remaining.filter { $0.script.parentID.map(family.contains) ?? false }.map(\.script)
            remaining.removeAll { $0.script.parentID.map(family.contains) ?? false }
            guard !inside.isEmpty, let id = guiCopies[root.id], worldGuiScripts[root.id] == nil else { continue }
            let scope = -1_000_000 - id
            worldGuiScripts[root.id] = (scope, inside)
            scripts.runScripts(inside, scope: scope)
        }
        let withCharacter = remaining.filter(\.resets).map(\.script)
        let forGood = remaining.filter { !$0.resets }.map(\.script)
        scripts.runScripts(forGood, scope: 0)
        scripts.runScripts(withCharacter, scope: characterGeneration)
        guiScripts[characterGeneration, default: []] += withCharacter
    }

    /// A character going: its ResetOnSpawn copies go, and the scripts in them stop.
    func takeStarterGui(scope: Int) {
        if let stopping = guiScripts.removeValue(forKey: scope) { scripts.endScope(scope, scripts: stopping) }
        for screen in model.guiChildren(of: nil) where screen.kind.isLayer && screen.worldParent == nil && screen.object().resetOnSpawn {
            guard let copy = guiCopies[screen.id] else { continue }
            for template in model.guiSubtree(screen.id) { guiCopies[template] = nil }
            gui.destroy(copy)
        }
    }

    // MARK: - BillboardGuis

    /// Where a BillboardGui hangs on a screen that size — over its Adornee, raised by
    /// StudsOffset — and how many points a stud is there; nil when it can't be seen.
    func placeBillboard(_ object: GuiObject, in size: CGSize) -> (center: CGPoint, pointsPerStud: CGFloat)? {
        guard let adornee = object.adornee, let anchor = worldPoint(of: adornee) else { return nil }
        let point = anchor + object.studsOffset
        let camera = renderCamera
        guard simd_distance(camera.position, point) <= object.maxDistance,
              let centre = screenPoint(of: point, in: size) else { return nil }
        let forward = normalize(camera.target - camera.position)
        let right = normalize(cross(forward, Vec3(0, 1, 0)))
        guard let aside = screenPoint(of: point + right, in: size) else { return nil }
        return (centre, hypot(aside.x - centre.x, aside.y - centre.y))
    }

    /// The middle of what a token names: "p:<part>", or "c:<character>:<body part>".
    func worldPoint(of token: String) -> Vec3? {
        let pieces = token.split(separator: ":").map(String.init)
        if pieces.first == "p", pieces.count == 2, let id = UUID(uuidString: pieces[1]) {
            return model.part(id: id)?.position
        }
        guard pieces.first == "c", pieces.count == 3, let number = Int(pieces[1]) else { return nil }
        let pose: AvatarPose
        if let owner = RemoteCharacter.owner(of: number) {
            guard let remote = remotePlayers.first(where: { $0.id == owner }) else { return nil }
            let shown = shownRemote[owner]
            pose = AvatarPose(position: shown?.position ?? remote.position, yaw: shown?.yaw ?? remote.yaw,
                              joints: remote.joints, dead: remote.dead)
        } else {
            guard number == characterGeneration else { return nil }
            pose = AvatarPose(position: character.position, yaw: character.facingYaw, joints: currentJoints,
                              dead: humanoid.isDead)
        }
        let name = pieces[2] == "HumanoidRootPart" ? "Torso" : pieces[2]
        guard let matrix = pose.partTransforms().first(where: { $0.name == name })?.matrix else { return nil }
        return Vec3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    /// A chat message arriving, from this player or another: TextChatService.MessageReceived.
    func receiveChat(from name: String, text: String) {
        pendingEvents.append(.list([.string("Chat"), .string(name), .string(text)]))
    }

    /// The longest a chat message may be.
    static let longestChat = 200

    func guiCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        let id = Int(arguments.first?.asDouble ?? -1)
        if guiInvocationLocal && ["gui.set", "gui.destroy", "gui.setParent", "gui.worldParent"].contains(name) {
            gui.preserveSharedWorld(containing: id)
        }
        switch name {
        case "gui.create":
            guard let kind = arguments.first?.asString.flatMap(GuiObject.Kind.init(rawValue:)) else { return .number(0) }
            let made = gui.create(kind)
            gui.update(made) { $0.localOnly = arguments.count > 1 && arguments[1].asBool == true }
            return .number(Double(made))

        case "gui.class":
            return gui.object(id).map { .string($0.kind.rawValue) } ?? .nothing

        case "gui.get":
            guard let object = gui.object(id), arguments.count >= 2 else { return .nothing }
            let key = (arguments[1].asString ?? "").lowercased()
            // What depends on where it was drawn, or on typing, the store knows.
            switch key {
            case "canvasposition":
                let position = gui.canvasPosition(of: id)
                return .list([.number(Double(position.x)), .number(Double(position.y))])
            case "absolutesize", "absoluteposition":
                guard let frame = gui.absoluteFrame(of: id) else { return .list([.number(0), .number(0)]) }
                return key == "absolutesize" ? .list([.number(Double(frame.width)), .number(Double(frame.height))])
                    : .list([.number(Double(frame.minX)), .number(Double(frame.minY))])
            case "cursorposition":
                return .number(gui.focused == id ? Double(gui.cursor + 1) : -1)
            default:
                return Self.guiProperty(object, key)
            }

        case "gui.set":
            // A destroyed object takes writes quietly, as in Roblox; a value out of range is refused.
            guard arguments.count >= 3, gui.object(id) != nil else { return .nothing }
            if (arguments[1].asString ?? "").lowercased() == "currentcamera" {
                if case .nothing = arguments[2] { gui.update(id) { $0.currentCamera = nil }; return .bool(true) }
                guard let camera = arguments[2].asString.flatMap(UUID.init(uuidString:)), gui.previewCameras[camera] != nil else { return .bool(false) }
                gui.update(id) { $0.currentCamera = camera }
                return .bool(true)
            }
            if (arguments[1].asString ?? "").lowercased() == "cursorposition" {
                gui.setCursor(id, to: Int(arguments[2].asDouble ?? -1))
                return .bool(true)
            }
            var accepted = true
            gui.update(id) {
                let shared = $0.persistentProperties
                accepted = Self.setGuiProperty(&$0, (arguments[1].asString ?? "").lowercased(), arguments[2])
                if arguments.count > 3 && arguments[3].asBool == true { $0.persistentProperties = shared }
            }
            return .bool(accepted)

        case "gui.parent":
            guard let object = gui.object(id) else { return .number(-1) }
            if let part = object.worldParent { return .string("p:\(part)") }
            return .number(Double(object.parent ?? -1))

        case "gui.worldParent":
            guard arguments.count >= 2, gui.object(id)?.kind == .surfaceGui,
                  let part = arguments[1].asString.flatMap(UUID.init(uuidString:)), model.part(id: part) != nil else { return .bool(false) }
            gui.update(id) { $0.parent = nil; $0.worldParent = part }
            return .bool(true)

        case "gui.worldChildren":
            guard let parent = arguments.first?.asString.flatMap(UUID.init(uuidString:)) else { return .list([]) }
            return .list(gui.objects.values.filter { $0.worldParent == parent }.sorted { $0.id < $1.id }.map {
                .list([.string("u:\($0.id)"), .string($0.name)])
            })

        case "gui.setParent":
            guard arguments.count >= 2 else { return .bool(false) }
            let parent = Int(arguments[1].asDouble ?? -1)
            return .bool(gui.setParent(id, to: parent < 0 ? nil : parent))

        case "gui.children":
            return .list(gui.children(of: id).map { .number(Double($0)) })

        case "gui.destroy":
            gui.destroy(id)
            return .nothing

        case "gui.focus":
            gui.focus(id)
            return .nothing

        case "gui.release":
            if gui.focused == id { gui.releaseFocus(enterPressed: false) }
            return .nothing

        case "gui.focused":
            return .number(Double(gui.focused ?? 0))

        case "gui.copyOf":
            // The copy of a StarterGui object in this player's PlayerGui.
            guard let template = arguments.first?.asString.flatMap(UUID.init(uuidString:)),
                  let copy = guiCopies[template] else { return .nothing }
            return .number(Double(copy))

        case "chat.send":
            let text = String((arguments.first?.asString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(Self.longestChat))
            guard !text.isEmpty else { return .nothing }
            receiveChat(from: playerName, text: text)
            sendChat?(text)
            return .nothing

        default:
            console.error("Unknown host call \"\(name)\".")
            return .nothing
        }
    }

    static func guiProperty(_ object: GuiObject, _ key: String) -> ScriptValue {
        func numbers(_ values: [Float]) -> ScriptValue { .list(values.map { .number(Double($0)) }) }
        switch key {
        case "currentcamera": return object.currentCamera.map { .string($0.uuidString) } ?? .nothing
        case "ambient": return .triple(object.viewportAmbient.x, object.viewportAmbient.y, object.viewportAmbient.z)
        case "lightcolor": return .triple(object.viewportLightColor.x, object.viewportLightColor.y, object.viewportLightColor.z)
        case "lightdirection": return .triple(object.viewportLightDirection.x, object.viewportLightDirection.y, object.viewportLightDirection.z)

        case "name": return .string(object.name)
        case "position": return numbers(object.position.list)
        case "size": return numbers(object.size.list)
        case "anchorpoint": return numbers([object.anchorPoint.x, object.anchorPoint.y])
        case "backgroundcolor3": return .triple(object.backgroundColor.x, object.backgroundColor.y, object.backgroundColor.z)
        case "backgroundtransparency": return .number(Double(object.backgroundTransparency))
        case "visible": return .bool(object.visible)
        case "enabled": return .bool(object.enabled)
        case "zindex": return .number(Double(object.zIndex))
        case "text": return .string(object.text)
        case "textcolor3": return .triple(object.textColor.x, object.textColor.y, object.textColor.z)
        case "textsize": return .number(Double(object.textSize))
        case "texttransparency": return .number(Double(object.textTransparency))
        case "textxalignment": return .string(object.textXAlignment)
        case "textwrapped": return .bool(object.textWrapped)
        case "placeholdertext": return .string(object.placeholderText)
        case "cleartextonfocus": return .bool(object.clearTextOnFocus)
        case "cornerradius": return numbers([object.cornerScale, object.cornerOffset])
        case "layoutorder": return .number(Double(object.layoutOrder))
        case "clipsdescendants": return .bool(object.clipsDescendants)
        case "automaticsize": return .string(object.automaticSize)
        case "textyalignment": return .string(object.textYAlignment)
        case "textscaled": return .bool(object.textScaled)
        case "font": return .string(object.font)
        case "textstrokecolor3": return .triple(object.textStrokeColor.x, object.textStrokeColor.y, object.textStrokeColor.z)
        case "textstroketransparency": return .number(Double(object.textStrokeTransparency))
        case "texteditable": return .bool(object.textEditable)
        case "image": return .string(object.image)
        case "imagecolor3": return .triple(object.imageColor.x, object.imageColor.y, object.imageColor.z)
        case "imagetransparency": return .number(Double(object.imageTransparency))
        case "scaletype": return .string(object.scaleType)
        case "filldirection": return .string(object.fillDirection)
        case "padding": return numbers([object.listPadding.x, object.listPadding.y])
        case "sortorder": return .string(object.sortOrder)
        case "horizontalalignment": return .string(object.horizontalAlignment)
        case "verticalalignment": return .string(object.verticalAlignment)
        case "canvassize": return object.kind == .surfaceGui ? numbers([object.surfaceCanvasSize.x, object.surfaceCanvasSize.y]) : numbers(object.canvasSize.list)
        case "face": return .string(object.face)
        case "sizingmode": return .string(object.sizingMode)
        case "pixelsperstud": return .number(Double(object.pixelsPerStud))
        case "lightinfluence": return .number(Double(object.lightInfluence))
        case "brightness": return .number(Double(object.brightness))
        case "zoffset": return .number(Double(object.zOffset))
        case "scrollbarthickness": return .number(Double(object.scrollBarThickness))
        case "scrollingenabled": return .bool(object.scrollingEnabled)
        case "automaticcanvassize": return .string(object.automaticCanvasSize)
        case "adornee": return object.adornee.map { .string($0) } ?? .nothing
        case "studsoffset": return .triple(object.studsOffset.x, object.studsOffset.y, object.studsOffset.z)
        case "alwaysontop": return .bool(object.alwaysOnTop)
        case "maxdistance": return .number(object.maxDistance.isFinite ? Double(object.maxDistance) : .infinity)
        case "resetonspawn": return .bool(object.resetOnSpawn)
        case "displayorder": return .number(Double(object.displayOrder))
        case "paddingleft": return numbers([object.paddingLeft.x, object.paddingLeft.y])
        case "paddingright": return numbers([object.paddingRight.x, object.paddingRight.y])
        case "paddingtop": return numbers([object.paddingTop.x, object.paddingTop.y])
        case "paddingbottom": return numbers([object.paddingBottom.x, object.paddingBottom.y])
        case "color":
            if object.kind == .uiGradient { return numbers(object.gradientColor.flatMap { [$0.time, $0.color.x, $0.color.y, $0.color.z] }) }
            return .triple(object.strokeColor.x, object.strokeColor.y, object.strokeColor.z)
        case "transparency":
            if object.kind == .uiGradient { return numbers(object.gradientTransparency.flatMap { [$0.x, $0.y] }) }
            return .number(Double(object.strokeTransparency))
        case "thickness": return .number(Double(object.strokeThickness))
        case "applystrokemode": return .string(object.applyStrokeMode)
        case "linejoinmode": return .string(object.lineJoinMode)
        case "rotation": return .number(Double(object.rotation))
        case "offset": return numbers([object.gradientOffset.x, object.gradientOffset.y])
        case "cellsize": return numbers(object.cellSize.list)
        case "cellpadding": return numbers(object.cellPadding.list)
        case "filldirectionmaxcells": return .number(Double(object.fillDirectionMaxCells))
        case "startcorner": return .string(object.startCorner)
        case "aspectratio": return .number(Double(object.aspectRatio))
        case "aspecttype": return .string(object.aspectType)
        case "dominantaxis": return .string(object.dominantAxis)
        case "minsize": return numbers([object.minSize.x, object.minSize.y])
        case "maxsize": return numbers([object.maxSize.x, object.maxSize.y])
        case "mintextsize": return .number(Double(object.minTextSize))
        case "maxtextsize": return .number(Double(object.maxTextSize))
        default: return .nothing
        }
    }

    /// A ColorSequence as the host holds it — time, r, g, b, time, r, g, b… — checked:
    /// 2 to 20 keypoints, from 0 to 1, in order.
    static func colorSequence(_ numbers: [Float]) -> [GradientStop]? {
        guard numbers.count % 4 == 0, (8...80).contains(numbers.count) else { return nil }
        let stops = stride(from: 0, to: numbers.count, by: 4).map {
            GradientStop(time: numbers[$0], color: Vec3(numbers[$0 + 1], numbers[$0 + 2], numbers[$0 + 3]))
        }
        return validSequence(stops.map(\.time)) ? stops : nil
    }

    /// A NumberSequence: time, value, time, value…
    static func numberSequence(_ numbers: [Float]) -> [SIMD2<Float>]? {
        guard numbers.count % 2 == 0, (4...40).contains(numbers.count) else { return nil }
        let stops = stride(from: 0, to: numbers.count, by: 2).map { SIMD2(numbers[$0], numbers[$0 + 1]) }
        return validSequence(stops.map(\.x)) ? stops : nil
    }

    private static func validSequence(_ times: [Float]) -> Bool {
        times.first == 0 && times.last == 1 && zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Sets a property from a script, already checked and converted by the Luau side;
    /// false when the value is the wrong shape.
    static func setGuiProperty(_ object: inout GuiObject, _ key: String, _ value: ScriptValue) -> Bool {
        guard applyGuiProperty(&object, key, value) else { return false }
        object.persistentProperties[key] = SceneModel.storable(key, value)
        return true
    }

    private static func applyGuiProperty(_ object: inout GuiObject, _ key: String, _ value: ScriptValue) -> Bool {
        func floats() -> [Float]? {
            guard case .list(let items) = value else { return nil }
            let numbers = items.compactMap(\.asFloat)
            return numbers.count == items.count ? numbers : nil
        }
        switch key {
        case "currentcamera":
            if case .nothing = value { object.currentCamera = nil; return true }
            guard let id = value.asString.flatMap(UUID.init(uuidString:)) else { return false }; object.currentCamera = id
        case "ambient", "lightcolor", "lightdirection":
            guard let values = value.asList?.compactMap(\.asFloat), values.count == 3, values.allSatisfy(\.isFinite) else { return false }
            let vector = Vec3(values[0], values[1], values[2])
            if key == "lightdirection" { guard simd_length_squared(vector) > 1e-8 else { return false }; object.viewportLightDirection = simd_normalize(vector) }
            else if key == "ambient" { object.viewportAmbient = simd_clamp(vector, .zero, Vec3(repeating: 1)) }
            else { object.viewportLightColor = simd_clamp(vector, .zero, Vec3(repeating: 1)) }

        case "name": guard let v = value.asString else { return false }; object.name = v
        case "position": guard let v = floats().flatMap(UDim2.init(list:)) else { return false }; object.position = v
        case "size": guard let v = floats().flatMap(UDim2.init(list:)) else { return false }; object.size = v
        case "anchorpoint":
            guard let v = floats(), v.count == 2 else { return false }
            object.anchorPoint = SIMD2(v[0], v[1])
        case "backgroundcolor3": guard let (r, g, b) = value.asTriple else { return false }; object.backgroundColor = Vec3(r, g, b)
        case "backgroundtransparency": guard let v = value.asFloat else { return false }; object.backgroundTransparency = min(max(v, 0), 1)
        case "visible": guard let v = value.asBool else { return false }; object.visible = v
        case "enabled": guard let v = value.asBool else { return false }; object.enabled = v
        case "zindex": guard let v = value.asDouble else { return false }; object.zIndex = Int(v)
        case "text": guard let v = value.asString else { return false }; object.text = v
        case "textcolor3": guard let (r, g, b) = value.asTriple else { return false }; object.textColor = Vec3(r, g, b)
        case "textsize": guard let v = value.asFloat else { return false }; object.textSize = min(max(v, 1), 100)
        case "texttransparency": guard let v = value.asFloat else { return false }; object.textTransparency = min(max(v, 0), 1)
        case "textxalignment":
            guard let v = value.asString, ["Left", "Center", "Right"].contains(v) else { return false }
            object.textXAlignment = v
        case "textwrapped": guard let v = value.asBool else { return false }; object.textWrapped = v
        case "placeholdertext": guard let v = value.asString else { return false }; object.placeholderText = v
        case "cleartextonfocus": guard let v = value.asBool else { return false }; object.clearTextOnFocus = v
        case "cornerradius":
            guard let v = floats(), v.count == 2 else { return false }
            object.cornerScale = v[0]
            object.cornerOffset = v[1]
        case "layoutorder": guard let v = value.asDouble else { return false }; object.layoutOrder = Int(v)
        case "clipsdescendants": guard let v = value.asBool else { return false }; object.clipsDescendants = v
        case "automaticsize", "automaticcanvassize":
            guard let v = value.asString, ["None", "X", "Y", "XY"].contains(v) else { return false }
            if key == "automaticsize" { object.automaticSize = v } else { object.automaticCanvasSize = v }
        case "textyalignment":
            guard let v = value.asString, ["Top", "Center", "Bottom"].contains(v) else { return false }
            object.textYAlignment = v
        case "textscaled": guard let v = value.asBool else { return false }; object.textScaled = v
        case "font": guard let v = value.asString, !v.isEmpty else { return false }; object.font = v
        case "textstrokecolor3": guard let (r, g, b) = value.asTriple else { return false }; object.textStrokeColor = Vec3(r, g, b)
        case "textstroketransparency": guard let v = value.asFloat else { return false }; object.textStrokeTransparency = min(max(v, 0), 1)
        case "texteditable": guard let v = value.asBool else { return false }; object.textEditable = v
        case "image": guard let v = value.asString else { return false }; object.image = v
        case "imagecolor3": guard let (r, g, b) = value.asTriple else { return false }; object.imageColor = Vec3(r, g, b)
        case "imagetransparency": guard let v = value.asFloat else { return false }; object.imageTransparency = min(max(v, 0), 1)
        case "scaletype":
            guard let v = value.asString, ["Stretch", "Fit", "Crop", "Tile", "Slice"].contains(v) else { return false }
            object.scaleType = v
        case "filldirection":
            guard let v = value.asString, ["Vertical", "Horizontal"].contains(v) else { return false }
            object.fillDirection = v
        case "padding":
            guard let v = floats(), v.count == 2 else { return false }
            object.listPadding = SIMD2(v[0], v[1])
        case "sortorder":
            guard let v = value.asString, ["LayoutOrder", "Name"].contains(v) else { return false }
            object.sortOrder = v
        case "horizontalalignment":
            guard let v = value.asString, ["Left", "Center", "Right"].contains(v) else { return false }
            object.horizontalAlignment = v
        case "verticalalignment":
            guard let v = value.asString, ["Top", "Center", "Bottom"].contains(v) else { return false }
            object.verticalAlignment = v
        case "canvassize":
            if object.kind == .surfaceGui {
                guard let v = floats(), v.count == 2, v.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16384 }) else { return false }
                object.surfaceCanvasSize = SIMD2(v[0], v[1])
            } else {
                guard let v = floats().flatMap(UDim2.init(list:)) else { return false }; object.canvasSize = v
            }
        case "face":
            guard let v = value.asString, ["Front", "Back", "Left", "Right", "Top", "Bottom"].contains(v) else { return false }; object.face = v
        case "sizingmode":
            guard let v = value.asString, ["FixedSize", "PixelsPerStud"].contains(v) else { return false }; object.sizingMode = v
        case "pixelsperstud":
            guard let v = value.asFloat, v.isFinite, v > 0, v <= 1024 else { return false }; object.pixelsPerStud = v
        case "lightinfluence":
            guard let v = value.asFloat, v.isFinite else { return false }; object.lightInfluence = min(max(v, 0), 1)
        case "brightness":
            guard let v = value.asFloat, v.isFinite, v >= 0 else { return false }; object.brightness = min(v, 100)
        case "zoffset":
            guard let v = value.asFloat, v.isFinite else { return false }; object.zOffset = min(max(v, -100), 100)
        case "canvasposition":
            guard let v = floats(), v.count == 2 else { return false }
            object.canvasPosition = SIMD2(max(v[0], 0), max(v[1], 0))
        case "scrollbarthickness": guard let v = value.asFloat else { return false }; object.scrollBarThickness = max(v, 0)
        case "scrollingenabled": guard let v = value.asBool else { return false }; object.scrollingEnabled = v
        case "adornee":
            if case .nothing = value { object.adornee = nil; return true }
            guard let v = value.asString else { return false }
            object.adornee = v
        case "studsoffset": guard let (x, y, z) = value.asTriple else { return false }; object.studsOffset = Vec3(x, y, z)
        case "alwaysontop": guard let v = value.asBool else { return false }; object.alwaysOnTop = v
        case "maxdistance": guard let v = value.asFloat else { return false }; object.maxDistance = max(v, 0)
        case "resetonspawn": guard let v = value.asBool else { return false }; object.resetOnSpawn = v
        case "displayorder": guard let v = value.asDouble else { return false }; object.displayOrder = Int(v)
        case "color":
            if object.kind == .uiGradient {
                guard let stops = floats().flatMap(colorSequence) else { return false }
                object.gradientColor = stops
            } else {
                guard let (r, g, b) = value.asTriple else { return false }
                object.strokeColor = Vec3(r, g, b)
            }
        case "transparency":
            if object.kind == .uiGradient {
                guard let stops = floats().flatMap(numberSequence) else { return false }
                object.gradientTransparency = stops.map { SIMD2($0.x, min(max($0.y, 0), 1)) }
            } else {
                guard let v = value.asFloat else { return false }
                object.strokeTransparency = min(max(v, 0), 1)
            }
        case "thickness": guard let v = value.asFloat else { return false }; object.strokeThickness = max(v, 0)
        case "applystrokemode":
            guard let v = value.asString, ["Contextual", "Border"].contains(v) else { return false }
            object.applyStrokeMode = v
        case "linejoinmode":
            guard let v = value.asString, ["Round", "Bevel", "Miter"].contains(v) else { return false }
            object.lineJoinMode = v
        case "rotation": guard let v = value.asFloat, v.isFinite else { return false }; object.rotation = v
        case "offset":
            guard let v = floats(), v.count == 2 else { return false }
            object.gradientOffset = SIMD2(v[0], v[1])
        case "cellsize": guard let v = floats().flatMap(UDim2.init(list:)) else { return false }; object.cellSize = v
        case "cellpadding": guard let v = floats().flatMap(UDim2.init(list:)) else { return false }; object.cellPadding = v
        case "filldirectionmaxcells":
            guard let v = value.asDouble, v.isFinite else { return false }
            object.fillDirectionMaxCells = max(Int(v), 0)
        case "startcorner":
            guard let v = value.asString, ["TopLeft", "TopRight", "BottomLeft", "BottomRight"].contains(v) else { return false }
            object.startCorner = v
        case "aspectratio": guard let v = value.asFloat, v > 0, v.isFinite else { return false }; object.aspectRatio = v
        case "aspecttype":
            guard let v = value.asString, ["FitWithinMaxSize", "ScaleWithParentSize"].contains(v) else { return false }
            object.aspectType = v
        case "dominantaxis":
            guard let v = value.asString, ["Width", "Height"].contains(v) else { return false }
            object.dominantAxis = v
        case "minsize", "maxsize":
            guard let v = floats(), v.count == 2 else { return false }
            let size = SIMD2(max(v[0], 0), max(v[1], 0))
            if key == "minsize" { object.minSize = size } else { object.maxSize = size }
        case "mintextsize": guard let v = value.asFloat else { return false }; object.minTextSize = min(max(v, 1), 100)
        case "maxtextsize": guard let v = value.asFloat else { return false }; object.maxTextSize = min(max(v, 1), 100)
        case "paddingleft", "paddingright", "paddingtop", "paddingbottom":
            guard let v = floats(), v.count == 2 else { return false }
            let udim = SIMD2(v[0], v[1])
            switch key {
            case "paddingleft": object.paddingLeft = udim
            case "paddingright": object.paddingRight = udim
            case "paddingtop": object.paddingTop = udim
            default: object.paddingBottom = udim
            }
        default: return false
        }
        return true
    }
}
