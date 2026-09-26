import Foundation

/// The Utils ModuleScript every new place starts with, in ReplicatedStorage: helpers for
/// maths, tables, text and time, and the everyday game jobs — debouncing a touch, finding
/// whose character a part is in, the distance between two things.
///
/// It is ordinary Luau the place owns: it can be read, changed or deleted like any other
/// script, and an old place gets it from the Explorer (ReplicatedStorage › Insert Utils
/// Module). It is written in the shape `LuauModuleShape` reads — `function Utils.name(…)`
/// with a comment above — so `Utils.` suggests every function, its parameters and what it
/// does. `UtilsSelfTest` runs every function.
enum UtilsModule {
    static let name = "Utils"

    static let source = """
    -- Utils: handy helpers for any script. Every new place has this ModuleScript in
    -- ReplicatedStorage, so a Script or a LocalScript can use it:
    --
    --     local ReplicatedStorage = game:GetService("ReplicatedStorage")
    --     local Utils = require(ReplicatedStorage.Utils)
    --     print(Utils.formatTime(125)) --> 2:05
    --
    -- It's yours to change. Add your own helpers the same way: a comment saying what it
    -- does, then function Utils.name(...). The script editor suggests them after Utils.

    local Players = game:GetService("Players")
    local TweenService = game:GetService("TweenService")

    local Utils = {}

    ----------------------------------------------------------------------------------
    -- Maths

    -- The value a fraction t of the way from a to b (numbers, Vector3s, Color3s or CFrames).
    function Utils.lerp(a, b, t)
    \tif type(a) == "number" then
    \t\treturn a + (b - a) * t
    \tend
    \treturn a:Lerp(b, t)
    end

    -- x kept between low and high.
    function Utils.clamp(x, low, high)
    \treturn math.clamp(x, low, high)
    end

    -- x rounded to the nearest step (1 if not given): round(7.3) is 7, round(7.3, 5) is 5.
    function Utils.round(x, step)
    \tstep = step or 1
    \treturn math.floor(x / step + 0.5) * step
    end

    -- x moved from one range to another: remap(5, 0, 10, 0, 100) is 50.
    function Utils.remap(x, inLow, inHigh, outLow, outHigh)
    \tif inHigh == inLow then
    \t\treturn outLow
    \tend
    \treturn outLow + (x - inLow) * (outHigh - outLow) / (inHigh - inLow)
    end

    -- current moved towards target by at most step, without passing it.
    function Utils.approach(current, target, step)
    \tif current < target then
    \t\treturn math.min(current + step, target)
    \tend
    \treturn math.max(current - step, target)
    end

    -- A random number from low to high, fractions included.
    function Utils.randomBetween(low, high)
    \treturn low + math.random() * (high - low)
    end

    -- A random whole number from low to high, both included.
    function Utils.randomInt(low, high)
    \treturn math.random(low, high)
    end

    -- True percent times out of a hundred: chance(25) is true about a quarter of the time.
    function Utils.chance(percent)
    \treturn math.random() * 100 < percent
    end

    -- An angle in degrees brought into -180 to 180, the short way round.
    function Utils.wrapAngle(degrees)
    \tlocal wrapped = (degrees + 180) % 360 - 180
    \treturn if wrapped == -180 then 180 else wrapped
    end

    ----------------------------------------------------------------------------------
    -- Tables

    -- A new table with the same keys and values (tables inside are shared, not copied).
    function Utils.copy(t)
    \treturn table.clone(t)
    end

    local function deepCopy(value, seen)
    \tif typeof(value) ~= "table" then
    \t\treturn value
    \tend
    \tif seen[value] then
    \t\treturn seen[value]
    \tend
    \tlocal copy = {}
    \tseen[value] = copy
    \tfor key, inner in value do
    \t\tcopy[deepCopy(key, seen)] = deepCopy(inner, seen)
    \tend
    \t-- A class's objects stay objects of their class; a locked metatable can't be copied.
    \tlocal meta = getmetatable(value)
    \treturn if type(meta) == "table" then setmetatable(copy, meta) else copy
    end

    -- A new table with copies of every table inside it too. Parts and other objects stay the same ones.
    function Utils.deepCopy(t)
    \treturn deepCopy(t, {})
    end

    -- A list of a table's keys.
    function Utils.keys(t)
    \tlocal list = {}
    \tfor key in t do
    \t\ttable.insert(list, key)
    \tend
    \treturn list
    end

    -- A list of a table's values.
    function Utils.values(t)
    \tlocal list = {}
    \tfor _, value in t do
    \t\ttable.insert(list, value)
    \tend
    \treturn list
    end

    -- How many entries a table has, named keys included (# counts only a list's).
    function Utils.count(t)
    \tlocal count = 0
    \tfor _ in t do
    \t\tcount += 1
    \tend
    \treturn count
    end

    -- The key where value is in t, or nil.
    function Utils.find(t, value)
    \tfor key, inner in t do
    \t\tif inner == value then
    \t\t\treturn key
    \t\tend
    \tend
    \treturn nil
    end

    -- A new list of the items keep(item, index) says yes to.
    function Utils.filter(list, keep)
    \tlocal kept = {}
    \tfor index, item in ipairs(list) do
    \t\tif keep(item, index) then
    \t\t\ttable.insert(kept, item)
    \t\tend
    \tend
    \treturn kept
    end

    -- A new list of what change(item, index) gives for each item.
    function Utils.map(list, change)
    \tlocal changed = {}
    \tfor index, item in ipairs(list) do
    \t\tchanged[index] = change(item, index)
    \tend
    \treturn changed
    end

    -- A new list with the same items in a random order.
    function Utils.shuffle(list)
    \tlocal shuffled = table.clone(list)
    \tfor i = #shuffled, 2, -1 do
    \t\tlocal j = math.random(1, i)
    \t\tshuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    \tend
    \treturn shuffled
    end

    -- One item of a list, chosen at random (nil for an empty list).
    function Utils.pickRandom(list)
    \tif #list == 0 then
    \t\treturn nil
    \tend
    \treturn list[math.random(1, #list)]
    end

    -- A new table with every key of each table given, later ones winning.
    function Utils.merge(...)
    \tlocal merged = {}
    \tfor _, t in { ... } do
    \t\tfor key, value in t do
    \t\t\tmerged[key] = value
    \t\tend
    \tend
    \treturn merged
    end

    ----------------------------------------------------------------------------------
    -- Text and time

    -- Seconds as a clock shows them: 65 is "1:05", 3725 is "1:02:05".
    function Utils.formatTime(seconds)
    \tseconds = math.max(0, math.floor(seconds))
    \tlocal hours = seconds // 3600
    \tlocal minutes = (seconds % 3600) // 60
    \tif hours > 0 then
    \t\treturn string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
    \tend
    \treturn string.format("%d:%02d", minutes, seconds % 60)
    end

    -- A number with commas between the thousands: 12500 is "12,500".
    function Utils.commas(n)
    \tlocal sign = if n < 0 then "-" else ""
    \tlocal whole, fraction = string.match(tostring(math.abs(n)), "^(%d+)(%.?%d*)$")
    \tif whole == nil then
    \t\treturn tostring(n)
    \tend
    \twhole = string.reverse((string.gsub(string.reverse(whole), "(%d%d%d)", "%1,")))
    \tif string.sub(whole, 1, 1) == "," then
    \t\twhole = string.sub(whole, 2)
    \tend
    \treturn sign .. whole .. fraction
    end

    -- A big number made short: 1500 is "1.5K", 2000000 is "2M"; under 1000 stays as it is.
    function Utils.shorten(n)
    \tlocal sign = if n < 0 then "-" else ""
    \tlocal size = math.abs(n)
    \tfor _, unit in { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } } do
    \t\tif size >= unit[1] then
    \t\t\tlocal value = math.floor(size / unit[1] * 10) / 10
    \t\t\tlocal digits = if value == math.floor(value) then string.format("%d", value) else string.format("%.1f", value)
    \t\t\treturn sign .. digits .. unit[2]
    \t\tend
    \tend
    \treturn tostring(n)
    end

    -- text made at least width long by adding character (a space if not given) in front.
    function Utils.padLeft(text, width, character)
    \ttext = tostring(text)
    \treturn string.rep(character or " ", width - #text) .. text
    end

    -- text cut into a list at each separator (a comma if not given).
    function Utils.split(text, separator)
    \treturn string.split(text, separator or ",")
    end

    -- text without the spaces at its start and end.
    function Utils.trim(text)
    \treturn (string.gsub(text, "^%s*(.-)%s*$", "%1"))
    end

    -- Every word with a capital first letter: "hello world" is "Hello World".
    function Utils.titleCase(text)
    \treturn (string.gsub(text, "(%a)([%w']*)", function(first, rest)
    \t\treturn string.upper(first) .. string.lower(rest)
    \tend))
    end

    ----------------------------------------------------------------------------------
    -- Game helpers

    -- The character Model a player, a character or a body part belongs to.
    local function characterOf(thing)
    \tif typeof(thing) ~= "Instance" then
    \t\treturn nil
    \tend
    \tif thing:IsA("Player") then
    \t\treturn thing.Character
    \tend
    \t-- The thing itself, its parent, or its grandparent (a hat's handle is in the hat).
    \tlocal current = thing
    \tfor _ = 1, 3 do
    \t\tif current == nil or current == workspace then
    \t\t\treturn nil
    \t\tend
    \t\tif Players:GetPlayerFromCharacter(current) ~= nil then
    \t\t\treturn current
    \t\tend
    \t\tcurrent = current.Parent
    \tend
    \treturn nil
    end

    -- callback wrapped so it runs at most once every seconds, however often it's called.
    -- Good for Touched: part.Touched:Connect(Utils.debounce(1, function(hit) ... end))
    function Utils.debounce(seconds, callback)
    \tlocal last = -math.huge
    \treturn function(...)
    \t\tlocal now = time()
    \t\tif now - last < seconds then
    \t\t\treturn nil
    \t\tend
    \t\tlast = now
    \t\treturn callback(...)
    \tend
    end

    -- A checker that says yes to each key (a player, say) once every seconds:
    -- local ready = Utils.cooldown(5) ... if ready(player) then ... end
    function Utils.cooldown(seconds)
    \tlocal readyAt = setmetatable({}, { __mode = "k" })
    \treturn function(key)
    \t\tkey = if key == nil then "anyone" else key
    \t\tlocal now = time()
    \t\tif (readyAt[key] or 0) > now then
    \t\t\treturn false
    \t\tend
    \t\treadyAt[key] = now + seconds
    \t\treturn true
    \tend
    end

    -- The player whose character a part (a hit from Touched, say) is in, or nil.
    function Utils.playerFromPart(part)
    \tlocal character = characterOf(part)
    \treturn if character then Players:GetPlayerFromCharacter(character) else nil
    end

    -- The character of a player, or of the character or body part given.
    function Utils.getCharacter(thing)
    \treturn characterOf(thing)
    end

    -- The Humanoid of a player, a character or a body part.
    function Utils.getHumanoid(thing)
    \tlocal character = characterOf(thing)
    \treturn if character then character:FindFirstChildOfClass("Humanoid") else nil
    end

    -- The HumanoidRootPart of a player, a character or a body part.
    function Utils.getRoot(thing)
    \tlocal character = characterOf(thing)
    \treturn if character then character:FindFirstChild("HumanoidRootPart") else nil
    end

    -- True if a player, character or body part has a Humanoid with health left.
    function Utils.isAlive(thing)
    \tlocal humanoid = Utils.getHumanoid(thing)
    \treturn humanoid ~= nil and humanoid.Health > 0
    end

    -- Where something is: a Vector3 as it is, a CFrame's position, a character's root, a part, or a Model's pivot.
    function Utils.positionOf(thing)
    \tlocal kind = typeof(thing)
    \tif kind == "Vector3" then
    \t\treturn thing
    \telseif kind == "CFrame" then
    \t\treturn thing.Position
    \telseif kind ~= "Instance" then
    \t\treturn nil
    \tend
    \tlocal root = Utils.getRoot(thing)
    \tif root then
    \t\treturn root.Position
    \telseif thing:IsA("BasePart") then
    \t\treturn thing.Position
    \telseif thing:IsA("Model") then
    \t\treturn thing:GetPivot().Position
    \tend
    \treturn nil
    end

    -- Studs between two things: players, characters, parts, Models or Vector3s.
    function Utils.distance(a, b)
    \tlocal from, to = Utils.positionOf(a), Utils.positionOf(b)
    \tif from == nil or to == nil then
    \t\treturn math.huge
    \tend
    \treturn (from - to).Magnitude
    end

    -- Two parts held together with a WeldConstraint, which is returned.
    function Utils.weld(a, b)
    \tlocal weld = Instance.new("WeldConstraint")
    \tweld.Part0 = a
    \tweld.Part1 = b
    \tweld.Parent = a
    \treturn weld
    end

    -- Properties of object eased to goals over seconds, started at once; the Tween is returned.
    -- Utils.tween(door, 1, { Position = door.Position + Vector3.new(0, 8, 0) })
    function Utils.tween(object, seconds, goals, style)
    \tlocal info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    \tlocal tween = TweenService:Create(object, info, goals)
    \ttween:Play()
    \treturn tween
    end

    return Utils
    """

    /// A fresh Utils in ReplicatedStorage.
    static func make() -> ScriptObject {
        var script = ScriptObject.blank(language: .luau)
        script.name = name
        script.kind = .module
        script.host = .replicatedStorage
        script.source = source
        return script
    }
}

extension SceneModel {
    /// Explorer › ReplicatedStorage › Insert Utils Module: for a place made before new
    /// places came with one. Named Utils1 and so on if there is a Utils already.
    @discardableResult
    func insertUtilsModule() -> UUID {
        addModuleScript(host: .replicatedStorage, name: uniqueScriptName(base: UtilsModule.name), source: UtilsModule.source)
    }
}
