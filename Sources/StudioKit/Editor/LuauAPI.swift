import Foundation

/// Static description of everything a Luau script can reach, driving completion.
/// A hand-written mirror of `StudioLibrary.swift` plus the Luau built-ins scripts use
/// most — when the library gains a member, add it here too.
///
/// Instance members and static members are kept apart because Luau spells them
/// differently: `part.Position` and `Vector3.new` use `.`, `part:Destroy()` uses `:`.
enum LuauAPI {

    private static func property(_ name: String, _ type: String) -> CompletionItem {
        CompletionItem(label: name, insert: name, detail: type, kind: .property, returns: type)
    }

    private static func method(_ name: String, _ arguments: String, _ type: String) -> CompletionItem {
        CompletionItem(label: "\(name)(\(arguments))", insert: "\(name)(", detail: type,
                       kind: .method, returns: type == "()" ? nil : type)
    }

    /// Reached with `.` on a namespace: `Vector3.new`, `math.lerp`, `task.wait`.
    static let staticMembers: [String: [CompletionItem]] = [
        "Vector3": [
            method("new", "x, y, z", "Vector3"),
            property("zero", "Vector3"), property("one", "Vector3"),
            property("xAxis", "Vector3"), property("yAxis", "Vector3"), property("zAxis", "Vector3")
        ],
        "Color3": [
            method("new", "r, g, b", "Color3"), method("fromRGB", "r, g, b", "Color3"),
            method("fromHSV", "h, s, v", "Color3"), method("fromHex", "hex", "Color3")
        ],
        "Instance": [method("new", "className", "Part")],
        "UDim": [method("new", "scale, offset", "UDim")],
        "UDim2": [
            method("new", "xScale, xOffset, yScale, yOffset", "UDim2"),
            method("fromScale", "x, y", "UDim2"), method("fromOffset", "x, y", "UDim2")
        ],
        "Vector2": [method("new", "x, y", "Vector2"), property("zero", "Vector2"), property("one", "Vector2")],
        "ColorSequence": [method("new", "color0, color1", "ColorSequence")],
        "ColorSequenceKeypoint": [method("new", "time, color", "ColorSequenceKeypoint")],
        "NumberSequence": [method("new", "value0, value1", "NumberSequence")],
        "RaycastParams": [method("new", "", "RaycastParams")],
        "NumberSequenceKeypoint": [method("new", "time, value", "NumberSequenceKeypoint")],
        "Random": [method("new", "seed", "Random")],
        "TweenInfo": [method("new", "time, easingStyle, easingDirection, repeatCount, reverses, delayTime", "TweenInfo")],
        "Enum": [
            property("Material", "Enum.Material"), property("PartType", "Enum.PartType"),
            property("EasingStyle", "Enum.EasingStyle"), property("EasingDirection", "Enum.EasingDirection"),
            property("KeyCode", "Enum.KeyCode"), property("UserInputType", "Enum.UserInputType"),
            property("UserInputState", "Enum.UserInputState"),
            property("HumanoidStateType", "Enum.HumanoidStateType"), property("CameraMode", "Enum.CameraMode"),
            property("AnimationPriority", "Enum.AnimationPriority"),
            property("Technology", "Enum.Technology"), property("ActuatorType", "Enum.ActuatorType"),
            property("TextXAlignment", "Enum.TextXAlignment"), property("PlaybackState", "Enum.PlaybackState"),
            property("MouseBehavior", "Enum.MouseBehavior")
        ],
        "Enum.Material": enumItems(["Plastic", "SmoothPlastic", "Metal", "Neon", "Wood", "Water"]),
        "Enum.PartType": enumItems(["Block", "Ball", "Cylinder", "Wedge"]),
        "Enum.EasingStyle": enumItems(["Linear", "Sine", "Quad", "Cubic", "Quart", "Quint",
                                       "Exponential", "Circular", "Back", "Elastic", "Bounce"]),
        "Enum.EasingDirection": enumItems(["In", "Out", "InOut"]),
        "Enum.KeyCode": enumItems(KeyCodes.allNames),
        "Enum.UserInputType": enumItems(["Keyboard", "MouseButton1", "MouseButton2"]),
        "Enum.UserInputState": enumItems(["Begin", "End"]),
        "Enum.HumanoidStateType": enumItems(["Running", "Jumping", "Freefall", "Landed", "Flying", "Dead",
                                             "Seated", "Climbing", "Swimming"]),
        "Enum.CameraMode": enumItems(["Classic", "LockFirstPerson"]),
        "Enum.AnimationPriority": enumItems(["Core", "Idle", "Movement", "Action"]),
        "Enum.Technology": enumItems(["Conventional", "RayTraced"]),
        "Enum.ActuatorType": enumItems(["None", "Motor", "Servo"]),
        "Enum.TextXAlignment": enumItems(["Left", "Right", "Center"]),
        "Enum.PlaybackState": enumItems(["Begin", "Delayed", "Playing", "Paused", "Completed", "Cancelled"]),
        "Enum.MouseBehavior": enumItems(["Default", "LockCenter", "LockCurrentPosition"]),
        "task": [
            method("wait", "seconds", "number"), method("spawn", "callback, ...", "thread"),
            method("delay", "seconds, callback, ...", "thread"), method("defer", "callback, ...", "thread"),
            method("cancel", "thread", "()"), method("synchronize", "", "()"), method("desynchronize", "", "()")
        ],
        "math": [
            property("pi", "number"), property("huge", "number"),
            method("abs", "x", "number"), method("floor", "x", "number"), method("ceil", "x", "number"),
            method("round", "x", "number"), method("sqrt", "x", "number"), method("sin", "x", "number"),
            method("cos", "x", "number"), method("tan", "x", "number"), method("atan2", "y, x", "number"),
            method("min", "a, b, ...", "number"), method("max", "a, b, ...", "number"),
            method("clamp", "x, min, max", "number"), method("sign", "x", "number"),
            method("random", "min, max", "number"), method("rad", "degrees", "number"),
            method("deg", "radians", "number"), method("noise", "x, y, z", "number"),
            method("fmod", "x, y", "number"), method("log", "x, base", "number"), method("exp", "x", "number"),
            // Studio's additions
            method("lerp", "a, b, t", "number"), method("inverseLerp", "a, b, value", "number"),
            method("map", "value, fromLow, fromHigh, toLow, toHigh", "number"),
            method("smoothstep", "edge0, edge1, value", "number"),
            method("wrap", "value, length", "number"), method("pingPong", "value, length", "number"),
            method("moveTowards", "current, target, maxDelta", "number"),
            method("snap", "value, step", "number"), method("wrapAngle", "degrees", "number"),
            method("deltaAngle", "from, to", "number"),
            method("moveTowardsAngle", "current, target, maxDelta", "number"),
            method("fbm", "x, y, z, octaves", "number")
        ],
        "string": [
            method("format", "format, ...", "string"), method("sub", "s, i, j", "string"),
            method("upper", "s", "string"), method("lower", "s", "string"), method("len", "s", "number"),
            method("rep", "s, n", "string"), method("find", "s, pattern", "number"),
            method("match", "s, pattern", "string"), method("gsub", "s, pattern, replacement", "string"),
            method("split", "s, separator", "table")
        ],
        "table": [
            method("insert", "t, value", "()"), method("remove", "t, index", "any"),
            method("find", "t, value", "number"), method("sort", "t, comparator", "()"),
            method("concat", "t, separator", "string"), method("clone", "t", "table"),
            method("create", "count, value", "table"), method("freeze", "t", "table"),
            method("clear", "t", "()"), method("pack", "...", "table"), method("unpack", "t", "...")
        ]
    ]

    private static func enumItems(_ names: [String]) -> [CompletionItem] {
        names.map { CompletionItem(label: $0, insert: $0, detail: "EnumItem", kind: .property, returns: "EnumItem") }
    }

    /// What every GUI object has, then what each kind adds.
    private static let guiInstance: [CompletionItem] = [
        property("Name", "string"), property("ClassName", "string"), property("Parent", "Instance"),
        method("Destroy", "", "()"), method("FindFirstChild", "name", "Instance"),
        method("WaitForChild", "name", "Instance"), method("GetChildren", "", "table"),
        method("ClearAllChildren", "", "()"), method("IsA", "className", "boolean")
    ]
    private static let guiObject: [CompletionItem] = guiInstance + [
        property("Position", "UDim2"), property("Size", "UDim2"), property("AnchorPoint", "Vector2"),
        property("BackgroundColor3", "Color3"), property("BackgroundTransparency", "number"),
        property("Visible", "boolean"), property("ZIndex", "number"), property("LayoutOrder", "number"),
        property("ClipsDescendants", "boolean"), property("AutomaticSize", "EnumItem"),
        property("AbsoluteSize", "Vector2"), property("AbsolutePosition", "Vector2")
    ]
    private static let guiText: [CompletionItem] = guiObject + [
        property("Text", "string"), property("TextColor3", "Color3"), property("TextSize", "number"),
        property("TextTransparency", "number"), property("TextXAlignment", "EnumItem"),
        property("TextWrapped", "boolean"), property("TextYAlignment", "EnumItem"), property("TextScaled", "boolean"),
        property("Font", "EnumItem"), property("TextStrokeColor3", "Color3"), property("TextStrokeTransparency", "number")
    ]

    /// Reached on an instance: properties with `.`, methods with `:`.
    /// What every part has; a MeshPart adds its model's.
    private static let partMembers: [CompletionItem] = [
            property("Name", "string"), property("Position", "Vector3"), property("Size", "Vector3"),
            property("Orientation", "Vector3"), property("Color", "Color3"),
            property("Transparency", "number"), property("Anchored", "boolean"), property("Locked", "boolean"),
            property("Material", "EnumItem"), property("Shape", "EnumItem"), property("ClassName", "string"),
            property("Parent", "Workspace"), property("Shader", "Shader"),
            property("CanCollide", "boolean"), property("CanTouch", "boolean"),
            property("Occupant", "Humanoid"), property("Disabled", "boolean"), property("ClickDetector", "ClickDetector"),
            property("Touched", "RBXScriptSignal"), property("TouchEnded", "RBXScriptSignal"),
            property("PointLight", "PointLight"),
            method("FindFirstChildOfClass", "className", "PointLight"),
            method("Destroy", "", "()"), method("Clone", "", "Part"), method("IsA", "className", "boolean"),
            method("GetFullName", "", "string"), method("FindFirstChild", "name", "Instance"),
            method("GetChildren", "", "table")
    ]

    static let instanceMembers: [String: [CompletionItem]] = [
        "UDim": [property("Scale", "number"), property("Offset", "number")],
        "UDim2": [property("X", "UDim"), property("Y", "UDim"), property("Width", "UDim"), property("Height", "UDim")],
        "Vector2": [property("X", "number"), property("Y", "number"), property("Magnitude", "number")],
        "PlayerGui": [
            method("FindFirstChild", "name", "ScreenGui"), method("WaitForChild", "name", "ScreenGui"),
            method("GetChildren", "", "table")
        ],
        "ScreenGui": guiInstance + [property("Enabled", "boolean")],
        "Frame": guiObject,
        "TextLabel": guiText,
        "TextButton": guiText + [
            property("MouseButton1Click", "RBXScriptSignal"), property("Activated", "RBXScriptSignal")
        ],
        "TextBox": guiText + [
            property("PlaceholderText", "string"), property("ClearTextOnFocus", "boolean"),
            property("Focused", "RBXScriptSignal"), property("FocusLost", "RBXScriptSignal"),
            method("CaptureFocus", "", "()"), method("ReleaseFocus", "", "()"), method("IsFocused", "", "boolean")
        ],
        "ScrollingFrame": guiObject + [
            property("CanvasSize", "UDim2"), property("CanvasPosition", "Vector2"),
            property("ScrollBarThickness", "number"), property("ScrollingEnabled", "boolean"),
            property("AutomaticCanvasSize", "EnumItem")
        ],
        "ImageLabel": guiObject + [
            property("Image", "string"), property("ImageColor3", "Color3"), property("ImageTransparency", "number"),
            property("ScaleType", "EnumItem")
        ],
        "ImageButton": guiObject + [
            property("Image", "string"), property("ImageColor3", "Color3"), property("ImageTransparency", "number"),
            property("ScaleType", "EnumItem"),
            property("MouseButton1Click", "RBXScriptSignal"), property("Activated", "RBXScriptSignal")
        ],
        "UIListLayout": guiInstance + [
            property("FillDirection", "EnumItem"), property("Padding", "UDim"), property("SortOrder", "EnumItem"),
            property("HorizontalAlignment", "EnumItem"), property("VerticalAlignment", "EnumItem")
        ],
        "BillboardGui": guiInstance + [
            property("Adornee", "Part"), property("Size", "UDim2"), property("StudsOffset", "Vector3"),
            property("AlwaysOnTop", "boolean"), property("MaxDistance", "number"), property("Enabled", "boolean")
        ],
        "UICorner": guiInstance + [property("CornerRadius", "UDim")],
        "UIStroke": guiInstance + [
            property("Color", "Color3"), property("Thickness", "number"), property("Transparency", "number"),
            property("ApplyStrokeMode", "EnumItem"), property("LineJoinMode", "EnumItem"), property("Enabled", "boolean")
        ],
        "UIGradient": guiInstance + [
            property("Color", "ColorSequence"), property("Transparency", "NumberSequence"),
            property("Rotation", "number"), property("Offset", "Vector2"), property("Enabled", "boolean")
        ],
        "UIGridLayout": guiInstance + [
            property("CellSize", "UDim2"), property("CellPadding", "UDim2"), property("FillDirection", "EnumItem"),
            property("FillDirectionMaxCells", "number"), property("StartCorner", "EnumItem"),
            property("SortOrder", "EnumItem"), property("HorizontalAlignment", "EnumItem"),
            property("VerticalAlignment", "EnumItem")
        ],
        "UIAspectRatioConstraint": guiInstance + [
            property("AspectRatio", "number"), property("AspectType", "EnumItem"), property("DominantAxis", "EnumItem")
        ],
        "UISizeConstraint": guiInstance + [property("MinSize", "Vector2"), property("MaxSize", "Vector2")],
        "UITextSizeConstraint": guiInstance + [property("MinTextSize", "number"), property("MaxTextSize", "number")],
        "ColorSequence": [property("Keypoints", "table")],
        "NumberSequence": [property("Keypoints", "table")],
        "ColorSequenceKeypoint": [property("Time", "number"), property("Value", "Color3")],
        "NumberSequenceKeypoint": [property("Time", "number"), property("Value", "number"), property("Envelope", "number")],
        "UIPadding": guiInstance + [
            property("PaddingLeft", "UDim"), property("PaddingRight", "UDim"),
            property("PaddingTop", "UDim"), property("PaddingBottom", "UDim")
        ],
        "TextChatService": [
            property("MessageReceived", "RBXScriptSignal"), property("TextChannels", "TextChannels")
        ],
        "TextChannels": [property("RBXGeneral", "TextChannel"), method("WaitForChild", "name", "TextChannel")],
        "TextChannel": [
            property("Name", "string"), property("MessageReceived", "RBXScriptSignal"),
            method("SendAsync", "text", "()")
        ],
        "Vector3": [
            property("X", "number"), property("Y", "number"), property("Z", "number"),
            property("Magnitude", "number"), property("Unit", "Vector3"),
            method("Dot", "other", "number"), method("Cross", "other", "Vector3"),
            method("Lerp", "goal, alpha", "Vector3"), method("FuzzyEq", "other, epsilon", "boolean"),
            method("Abs", "", "Vector3"), method("Floor", "", "Vector3"), method("Ceil", "", "Vector3"),
            method("Sign", "", "Vector3"), method("Max", "other", "Vector3"), method("Min", "other", "Vector3"),
            method("Angle", "other", "number"), method("RotatedY", "degrees", "Vector3")
        ],
        "Color3": [
            property("R", "number"), property("G", "number"), property("B", "number"),
            method("Lerp", "goal, alpha", "Color3"), method("ToHSV", "", "number"), method("ToHex", "", "string")
        ],
        "Part": partMembers,
        "MeshPart": partMembers + [
            property("MeshId", "string"), property("TextureID", "string"),
            property("CollisionFidelity", "EnumItem"), property("MeshSize", "Vector3")
        ],
        "Workspace": [
            property("Name", "string"), property("Gravity", "number"),
            method("FindFirstChild", "name", "Part"), method("WaitForChild", "name", "Part"),
            method("GetChildren", "", "table"), method("GetDescendants", "", "table"),
            method("IsA", "className", "boolean"),
            method("Raycast", "origin, direction, params", "RaycastResult")
        ],
        "RaycastParams": [
            property("FilterDescendantsInstances", "table"), property("FilterType", "EnumItem"),
            property("IgnoreWater", "boolean"), property("RespectCanCollide", "boolean"),
            method("AddToFilter", "instances", "()")
        ],
        "RaycastResult": [
            property("Instance", "Part"), property("Position", "Vector3"), property("Normal", "Vector3"),
            property("Distance", "number"), property("Material", "EnumItem")
        ],
        "ReplicatedStorage": [
            method("FindFirstChild", "name", "Instance"), method("WaitForChild", "name, timeout", "Instance"),
            method("GetChildren", "", "table"), method("GetDescendants", "", "table")
        ],
        "ServerScriptService": [
            method("FindFirstChild", "name", "Instance"), method("WaitForChild", "name, timeout", "Instance"),
            method("GetChildren", "", "table")
        ],
        "ModuleScript": [
            property("Name", "string"), property("Parent", "Instance"), method("IsA", "className", "boolean")
        ],
        "RemoteEvent": [
            property("Name", "string"), property("Parent", "Instance"),
            property("OnServerEvent", "RBXScriptSignal"), property("OnClientEvent", "RBXScriptSignal"),
            method("FireServer", "...", "()"), method("FireClient", "player, ...", "()"),
            method("FireAllClients", "...", "()"), method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "RemoteFunction": [
            property("Name", "string"), property("Parent", "Instance"),
            property("OnServerInvoke", "function"), property("OnClientInvoke", "function"),
            method("InvokeServer", "...", "any"), method("InvokeClient", "player, ...", "any"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "IntValue": valueMembers, "NumberValue": valueMembers, "StringValue": valueMembers, "BoolValue": valueMembers,
        "ObjectValue": valueMembers, "Vector3Value": valueMembers, "Color3Value": valueMembers,
        "CFrameValue": valueMembers,
        "UnreliableRemoteEvent": [
            property("Name", "string"), property("Parent", "Instance"),
            property("OnServerEvent", "RBXScriptSignal"), property("OnClientEvent", "RBXScriptSignal"),
            method("FireServer", "...", "()"), method("FireClient", "player, ...", "()"),
            method("FireAllClients", "...", "()"), method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "BindableEvent": [
            property("Name", "string"), property("Parent", "Instance"), property("Event", "RBXScriptSignal"),
            method("Fire", "...", "()"), method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "BindableFunction": [
            property("Name", "string"), property("Parent", "Instance"), property("OnInvoke", "function"),
            method("Invoke", "...", "any"), method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "LogService": [
            property("MessageOut", "RBXScriptSignal"), method("GetLogHistory", "", "table"),
            method("IsA", "className", "boolean")
        ],
        "ServerStorage": [
            method("FindFirstChild", "name", "Instance"), method("WaitForChild", "name, timeout", "Instance"),
            method("GetChildren", "", "table"), method("GetDescendants", "", "table")
        ],
        "Folder": [
            property("Name", "string"), property("Parent", "Instance"),
            method("FindFirstChild", "name", "Instance"), method("WaitForChild", "name, timeout", "Instance"),
            method("GetChildren", "", "table"), method("ClearAllChildren", "", "()"),
            method("Destroy", "", "()"), method("Clone", "", "Folder"), method("IsA", "className", "boolean")
        ],
        "Game": [
            property("Workspace", "Workspace"),
            method("GetService", "name", "Instance")
        ],
        "RunService": [
            property("Heartbeat", "RBXScriptSignal"), property("Stepped", "RBXScriptSignal"),
            property("RenderStepped", "RBXScriptSignal"),
            method("IsServer", "", "boolean"), method("IsClient", "", "boolean"), method("IsStudio", "", "boolean"),
            method("IsRunning", "", "boolean"), method("IsRunMode", "", "boolean")
        ],
        "RBXScriptSignal": [
            method("Connect", "callback", "RBXScriptConnection"),
            method("Once", "callback", "RBXScriptConnection"), method("Wait", "", "number")
        ],
        "RBXScriptConnection": [property("Connected", "boolean"), method("Disconnect", "", "()")],
        "Players": [
            property("LocalPlayer", "Player"), property("RespawnTime", "number"),
            property("PlayerAdded", "RBXScriptSignal"), property("PlayerRemoving", "RBXScriptSignal"),
            method("GetPlayers", "", "table"), method("GetPlayerFromCharacter", "character", "Player")
        ],
        "Player": [
            property("Name", "string"), property("UserId", "number"), property("Character", "Model"),
            property("CharacterAdded", "RBXScriptSignal"), property("CharacterRemoving", "RBXScriptSignal"),
            property("CameraMode", "EnumItem"), property("CameraMinZoomDistance", "number"),
            property("CameraMaxZoomDistance", "number"), property("DevEnableMouseLock", "boolean"),
            property("Position", "Vector3"), property("Velocity", "Vector3"),
            property("Speed", "number"), property("Grounded", "boolean"),
            property("PlayerGui", "PlayerGui"), property("Backpack", "Backpack"),
            method("GetMouse", "", "Mouse"),
            method("LoadCharacter", "", "()"), method("Teleport", "position", "()"),
            method("IsA", "className", "boolean")
        ],
        "Model": [
            property("Name", "string"), property("ClassName", "string"), property("Parent", "Workspace"),
            property("Humanoid", "Humanoid"), property("HumanoidRootPart", "HumanoidRootPart"),
            property("PrimaryPart", "HumanoidRootPart"), property("Head", "BodyPart"), property("Torso", "BodyPart"),
            method("FindFirstChild", "name", "Instance"), method("WaitForChild", "name", "Instance"),
            method("GetChildren", "", "table"), method("IsA", "className", "boolean"),
            method("MoveTo", "position", "()")
        ],
        "Humanoid": [
            property("WalkSpeed", "number"), property("JumpPower", "number"), property("JumpHeight", "number"),
            property("UseJumpPower", "boolean"), property("Health", "number"), property("MaxHealth", "number"),
            property("MaxSlopeAngle", "number"), property("AutoRotate", "boolean"), property("Jump", "boolean"),
            property("MoveDirection", "Vector3"), property("RootPart", "HumanoidRootPart"),
            property("Parent", "Model"),
            property("Died", "RBXScriptSignal"), property("HealthChanged", "RBXScriptSignal"),
            property("StateChanged", "RBXScriptSignal"), property("Jumping", "RBXScriptSignal"),
            property("FreeFalling", "RBXScriptSignal"), property("Running", "RBXScriptSignal"),
            property("MoveToFinished", "RBXScriptSignal"), property("Touched", "RBXScriptSignal"),
            method("Move", "direction, relativeToCamera", "()"), method("MoveTo", "position", "()"),
            method("TakeDamage", "amount", "()"), method("GetState", "", "EnumItem"),
            method("EquipTool", "tool", "()"), method("UnequipTools", "", "()"),
            method("AddAccessory", "accessory", "()"), method("GetAccessories", "", "table"),
            method("RemoveAccessories", "", "()"), method("GetAppliedDescription", "", "HumanoidDescription"),
            method("ApplyDescription", "description", "()"),
            property("Sit", "boolean"), property("SeatPart", "Part"), property("Seated", "RBXScriptSignal"),
            method("ChangeState", "state", "boolean"), method("IsA", "className", "boolean"),
            property("Animator", "Animator"),
            method("LoadAnimation", "animation", "AnimationTrack"),
            method("GetPlayingAnimationTracks", "", "table"),
            method("FindFirstChild", "name", "Animator"), method("WaitForChild", "name", "Animator"),
            method("FindFirstChildOfClass", "className", "Animator")
        ],
        "Animator": [
            property("Name", "string"), property("Parent", "Humanoid"),
            method("LoadAnimation", "animation", "AnimationTrack"),
            method("GetPlayingAnimationTracks", "", "table")
        ],
        "Lighting": [
            property("ClockTime", "number"), property("TimeOfDay", "string"), property("Brightness", "number"),
            property("Ambient", "Color3"), property("OutdoorAmbient", "Color3"), property("ColorShift_Top", "Color3"),
            property("GlobalShadows", "boolean"), property("ShadowSoftness", "number"),
            property("ExposureCompensation", "number"), property("FogColor", "Color3"),
            property("FogStart", "number"), property("FogEnd", "number"),
            property("GeographicLatitude", "number"), property("Technology", "EnumItem"),
            method("GetSunDirection", "", "Vector3"), method("GetMinutesAfterMidnight", "", "number"),
            method("SetMinutesAfterMidnight", "minutes", "()")
        ],
        "Attachment": [
            property("Name", "string"), property("Parent", "Part"), property("Position", "Vector3"),
            property("Axis", "Vector3"), property("SecondaryAxis", "Vector3"), property("CFrame", "CFrame"),
            property("WorldPosition", "Vector3"), property("WorldAxis", "Vector3"),
            property("WorldCFrame", "CFrame"), property("ClassName", "string"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "WeldConstraint": [
            property("Part0", "Part"), property("Part1", "Part"), property("Enabled", "boolean"),
            property("Active", "boolean"), property("Parent", "Part"), property("Name", "string"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "HingeConstraint": [
            property("Attachment0", "Attachment"), property("Attachment1", "Attachment"),
            property("Enabled", "boolean"), property("Active", "boolean"), property("Name", "string"),
            property("ActuatorType", "EnumItem"), property("LimitsEnabled", "boolean"),
            property("LowerAngle", "number"), property("UpperAngle", "number"),
            property("AngularVelocity", "number"), property("MotorMaxTorque", "number"),
            property("TargetAngle", "number"), property("AngularSpeed", "number"),
            property("ServoMaxTorque", "number"), property("CurrentAngle", "number"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "BallSocketConstraint": [
            property("Attachment0", "Attachment"), property("Attachment1", "Attachment"),
            property("Enabled", "boolean"), property("Active", "boolean"), property("Name", "string"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "RopeConstraint": [
            property("Attachment0", "Attachment"), property("Attachment1", "Attachment"),
            property("Enabled", "boolean"), property("Active", "boolean"), property("Name", "string"),
            property("Length", "number"), property("CurrentDistance", "number"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "SpringConstraint": [
            property("Attachment0", "Attachment"), property("Attachment1", "Attachment"),
            property("Enabled", "boolean"), property("Active", "boolean"), property("Name", "string"),
            property("FreeLength", "number"), property("Stiffness", "number"), property("Damping", "number"),
            property("CurrentLength", "number"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "PrismaticConstraint": [
            property("Attachment0", "Attachment"), property("Attachment1", "Attachment"),
            property("Enabled", "boolean"), property("Active", "boolean"), property("Name", "string"),
            property("ActuatorType", "EnumItem"), property("LimitsEnabled", "boolean"),
            property("LowerLimit", "number"), property("UpperLimit", "number"),
            property("Velocity", "number"), property("MotorMaxForce", "number"),
            property("TargetPosition", "number"), property("Speed", "number"),
            property("ServoMaxForce", "number"), property("CurrentPosition", "number"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "PointLight": [
            property("Enabled", "boolean"), property("Brightness", "number"), property("Color", "Color3"),
            property("Range", "number"), property("Shadows", "boolean"), property("Parent", "Part"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "Animations": [
            method("FindFirstChild", "name", "Animation"), method("WaitForChild", "name", "Animation"),
            method("GetChildren", "", "table")
        ],
        "Animation": [
            property("Name", "string"), property("AnimationId", "string"), property("ClassName", "string"),
            property("Parent", "Animations")
        ],
        "AnimationTrack": [
            property("IsPlaying", "boolean"), property("Length", "number"), property("Looped", "boolean"),
            property("Speed", "number"), property("TimePosition", "number"), property("WeightCurrent", "number"),
            property("WeightTarget", "number"), property("Priority", "EnumItem"), property("Name", "string"),
            property("Animation", "Animation"),
            property("Stopped", "RBXScriptSignal"), property("DidLoop", "RBXScriptSignal"),
            property("KeyframeReached", "RBXScriptSignal"),
            method("Play", "fadeTime, weight, speed", "()"), method("Stop", "fadeTime", "()"),
            method("AdjustSpeed", "speed", "()"), method("AdjustWeight", "weight, fadeTime", "()"),
            method("GetMarkerReachedSignal", "name", "RBXScriptSignal")
        ],
        "HumanoidRootPart": [
            property("Position", "Vector3"), property("AssemblyLinearVelocity", "Vector3"),
            property("Size", "Vector3"), property("Parent", "Model")
        ],
        "BodyPart": [
            property("Name", "string"), property("Color", "Color3"), property("Transparency", "number"),
            property("Size", "Vector3"), property("Parent", "Model"),
            property("Touched", "RBXScriptSignal"), property("TouchEnded", "RBXScriptSignal"),
            method("IsA", "className", "boolean")
        ],
        "UserInputService": [
            property("InputBegan", "RBXScriptSignal"), property("InputEnded", "RBXScriptSignal"),
            property("MouseBehavior", "EnumItem"),
            method("IsKeyDown", "keyCode", "boolean"), method("GetKeysPressed", "", "table"),
            method("GetMouseLocation", "", "Vector2")
        ],
        "Mouse": [
            property("Hit", "CFrame"), property("Target", "Part"), property("X", "number"), property("Y", "number"),
            property("ViewSizeX", "number"), property("ViewSizeY", "number"), property("Icon", "string"),
            property("Button1Down", "RBXScriptSignal"), property("Button1Up", "RBXScriptSignal"),
            property("Button2Down", "RBXScriptSignal"), property("Button2Up", "RBXScriptSignal")
        ],
        "ClickDetector": [
            property("MaxActivationDistance", "number"), property("Parent", "Part"),
            property("MouseClick", "RBXScriptSignal"), property("MouseHoverEnter", "RBXScriptSignal"),
            property("MouseHoverLeave", "RBXScriptSignal"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "Tool": [
            property("Name", "string"), property("ToolTip", "string"), property("Enabled", "boolean"),
            property("RequiresHandle", "boolean"), property("CanBeDropped", "boolean"), property("Grip", "CFrame"),
            property("Parent", "Instance"), property("Handle", "Part"),
            property("Equipped", "RBXScriptSignal"), property("Unequipped", "RBXScriptSignal"),
            property("Activated", "RBXScriptSignal"), property("Deactivated", "RBXScriptSignal"),
            method("Activate", "", "()"), method("Deactivate", "", "()"),
            method("FindFirstChild", "name", "Instance"), method("WaitForChild", "name", "Instance"),
            method("GetChildren", "", "table"), method("Clone", "", "Tool"), method("Destroy", "", "()"),
            method("IsA", "className", "boolean")
        ],
        "Sound": [
            property("Name", "string"), property("SoundId", "string"), property("Volume", "number"),
            property("Looped", "boolean"), property("PlaybackSpeed", "number"),
            property("RollOffMaxDistance", "number"), property("TimePosition", "number"),
            property("Playing", "boolean"), property("IsPlaying", "boolean"), property("IsPaused", "boolean"),
            property("IsLoaded", "boolean"), property("TimeLength", "number"), property("Parent", "Instance"),
            property("Played", "RBXScriptSignal"), property("Ended", "RBXScriptSignal"),
            property("Stopped", "RBXScriptSignal"), property("Paused", "RBXScriptSignal"),
            property("Resumed", "RBXScriptSignal"), property("Loaded", "RBXScriptSignal"),
            method("Play", "", "()"), method("Stop", "", "()"), method("Pause", "", "()"),
            method("Resume", "", "()"), method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "Accessory": [
            property("Name", "string"), property("AccessoryType", "EnumItem"), property("MeshId", "string"),
            property("TextureID", "string"), property("Color", "Color3"), property("Offset", "Vector3"),
            property("Rotation", "Vector3"), property("Scale", "number"), property("Parent", "Model"),
            method("Destroy", "", "()"), method("Clone", "", "Accessory"), method("IsA", "className", "boolean")
        ],
        "Shirt": [
            property("ShirtTemplate", "string"), property("Parent", "Model"),
            method("Destroy", "", "()"), method("Clone", "", "Shirt"), method("IsA", "className", "boolean")
        ],
        "Pants": [
            property("PantsTemplate", "string"), property("Parent", "Model"),
            method("Destroy", "", "()"), method("Clone", "", "Pants"), method("IsA", "className", "boolean")
        ],
        "Decal": [
            property("Texture", "string"), property("Parent", "Part"),
            method("Destroy", "", "()"), method("IsA", "className", "boolean")
        ],
        "HumanoidDescription": [
            property("Face", "string"), property("Shirt", "string"), property("Pants", "string"),
            property("HatAccessory", "string"), property("HairAccessory", "string"), property("FaceAccessory", "string"),
            property("NeckAccessory", "string"), property("ShouldersAccessory", "string"),
            property("FrontAccessory", "string"), property("BackAccessory", "string"), property("WaistAccessory", "string"),
            property("HeadColor", "Color3"), property("TorsoColor", "Color3"), property("LeftArmColor", "Color3"),
            property("RightArmColor", "Color3"), property("LeftLegColor", "Color3"), property("RightLegColor", "Color3"),
            method("Clone", "", "HumanoidDescription"), method("IsA", "className", "boolean")
        ],
        "SoundService": [
            method("GetChildren", "", "table"), method("FindFirstChild", "name", "Sound"),
            method("WaitForChild", "name", "Sound"), method("PlayLocalSound", "sound", "()")
        ],
        "Backpack": [
            method("GetChildren", "", "table"), method("FindFirstChild", "name", "Tool"),
            method("WaitForChild", "name", "Tool"), method("FindFirstChildOfClass", "className", "Tool"),
            method("ClearAllChildren", "", "()")
        ],
        "StarterPack": [
            method("GetChildren", "", "table"), method("FindFirstChild", "name", "Tool"),
            method("WaitForChild", "name", "Tool")
        ],
        "InputObject": [
            property("KeyCode", "EnumItem"), property("UserInputType", "EnumItem"),
            property("UserInputState", "EnumItem")
        ],
        "TweenService": [
            method("Create", "instance, tweenInfo, goals", "Tween"),
            method("GetValue", "alpha, easingStyle, easingDirection", "number")
        ],
        "Tween": [
            property("Instance", "Instance"), property("TweenInfo", "TweenInfo"),
            property("PlaybackState", "EnumItem"), property("Completed", "RBXScriptSignal"),
            method("Play", "", "()"), method("Pause", "", "()"), method("Cancel", "", "()"),
            method("Destroy", "", "()")
        ],
        "TweenInfo": [
            property("Time", "number"), property("EasingStyle", "EnumItem"), property("EasingDirection", "EnumItem"),
            property("RepeatCount", "number"), property("Reverses", "boolean"), property("DelayTime", "number")
        ],
        "Shaders": [
            method("FindFirstChild", "name", "Shader"), method("GetChildren", "", "table"),
            method("GetScreenShaders", "", "table")
        ],
        "Shader": [
            property("Name", "string"), property("Kind", "string"), property("Enabled", "boolean"),
            property("Compiled", "boolean"),
            method("GetParameter", "name", "number"), method("SetParameter", "name, value", "()"),
            method("GetParameters", "", "table"), method("ApplyTo", "part", "()")
        ],
        "Screen": [property("Shader", "Shader")],
        "Script": [property("Name", "string"), property("Parent", "Part"), property("ClassName", "string")],
        "Random": [
            method("NextNumber", "min, max", "number"), method("NextInteger", "min, max", "number"),
            method("NextUnitVector", "", "Vector3"), method("Shuffle", "list", "()"),
            method("Clone", "", "Random")
        ],
        "EnumItem": [property("Name", "string"), property("EnumType", "string"), property("Value", "number")]
    ]

    /// Globals that are objects rather than namespaces, and the type each one is.
    static let globalInstances: [String: String] = [
        "workspace": "Workspace", "Workspace": "Workspace", "game": "Game", "script": "Script",
        "RunService": "RunService", "Players": "Players", "Player": "Player",
        "TweenService": "TweenService", "Shaders": "Shaders", "Screen": "Screen",
        "UserInputService": "UserInputService", "Animations": "Animations", "Lighting": "Lighting",
        "TextChatService": "TextChatService", "StarterPack": "StarterPack", "SoundService": "SoundService"
    ]

    /// A Value object's members.
    private static let valueMembers: [CompletionItem] = [
        property("Name", "string"), property("Value", "any"), property("Parent", "Instance"),
        property("Changed", "RBXScriptSignal"), method("GetPropertyChangedSignal", "property", "RBXScriptSignal"),
        method("Destroy", "", "()"), method("Clone", "", "Instance"), method("IsA", "className", "boolean")
    ]

    /// What `game:GetService("…")` returns, by its argument.
    static let services: [String: String] = [
        "Workspace": "Workspace", "RunService": "RunService", "Players": "Players",
        "TweenService": "TweenService", "Shaders": "Shaders", "UserInputService": "UserInputService",
        "Animations": "Animations", "Lighting": "Lighting", "TextChatService": "TextChatService",
        "StarterPack": "StarterPack", "SoundService": "SoundService",
        "ReplicatedStorage": "ReplicatedStorage", "ServerScriptService": "ServerScriptService",
        "ServerStorage": "ServerStorage", "LogService": "LogService"
    ]

    static let globalFunctions: [CompletionItem] = [
        method("print", "...", "()"), method("warn", "...", "()"), method("typeof", "value", "string"),
        method("type", "value", "string"), method("tostring", "value", "string"),
        method("tonumber", "value", "number"), method("pairs", "t", "iterator"),
        method("ipairs", "t", "iterator"), method("pcall", "f, ...", "boolean"),
        method("error", "message, level", "()"), method("assert", "value, message", "any"),
        method("select", "index, ...", "any"), method("time", "", "number"),
        method("setmetatable", "t, metatable", "table"), method("getmetatable", "t", "table"),
        method("require", "moduleScript", "any")
    ]

    static let snippets: [CompletionItem] = [
        CompletionItem(label: "local RunService = game:GetService(\"RunService\")",
                       insert: "local RunService = game:GetService(\"RunService\")",
                       detail: "service", kind: .keyword, returns: nil),
        CompletionItem(label: "Heartbeat:Connect(function(dt) … end)",
                       insert: "RunService.Heartbeat:Connect(function(dt)\n\t\nend)",
                       detail: "every frame", kind: .keyword, returns: nil),
        CompletionItem(label: "local humanoid = Players.LocalPlayer.Character:WaitForChild(\"Humanoid\")",
                       insert: "local humanoid = game:GetService(\"Players\").LocalPlayer.Character:WaitForChild(\"Humanoid\")",
                       detail: "the character", kind: .keyword, returns: nil)
    ]

    static func members(ofStatic name: String) -> [CompletionItem] { staticMembers[name] ?? [] }
    static func members(ofInstance type: String) -> [CompletionItem] { instanceMembers[type] ?? [] }

    static func isNamespace(_ name: String) -> Bool { staticMembers[name] != nil }
}
