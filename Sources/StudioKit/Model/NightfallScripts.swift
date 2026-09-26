import Foundation

/// Nightfall's scripts, in Luau, and its shaders.
enum NightfallScripts {

    // MARK: - ServerStorage modules

    static let horde = """
    -- Horde: the zombies — cloned from the templates in ServerStorage, walked towards the
    -- nearest player round walls and trees, biting when they're close — and each player's
    -- fighting stats, which the sword, the blaster and the power-ups use. GameScript runs
    -- the nights; the Sword tool calls Horde.swing, the Fire remote Horde.fire.
    local Players = game:GetService("Players")
    local ServerStorage = game:GetService("ServerStorage")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Utils = require(ReplicatedStorage:WaitForChild("Utils"))

    local Horde = {}

    -- What each kind is like on the first night; each night after makes them tougher.
    Horde.kinds = {
    \tWalker = { health = 60, speed = 7.5, damage = 10, reach = 3.2, radius = 1.2, orbs = 1 },
    \tRunner = { health = 35, speed = 12.5, damage = 6, reach = 3, radius = 1.1, orbs = 1 },
    \tBrute = { health = 220, speed = 5.5, damage = 25, reach = 4.4, radius = 1.8, orbs = 4 },
    }

    -- Every zombie in the world, by its Model.
    Horde.zombies = {}
    -- Each player's stats while they're in a run (Upgrades.fresh makes them).
    Horde.stats = {}
    -- Set by GameScript: a zombie fell at position, knocked down last by player (or nil).
    Horde.onKill = function(_position, _zombie, _player) end

    -- With nobody in sight, they drift towards the camp.
    local CAMP = Vector3.new(0, 0, 8)
    local SIGHT = 90
    local CELL = 16

    local folder = workspace:WaitForChild("Zombies")
    -- Walls, trees, rocks and houses as boxes { minX, maxX, minZ, maxZ }, by grid cell.
    local blockers = {}

    local function cellKey(x, z)
    \treturn math.floor(x / CELL) * 1000 + math.floor(z / CELL)
    end

    -- Anything solid standing on the ground, read once. A turned part counts as the
    -- square its longest side makes, which is more than it covers but never less.
    function Horde.findBlockers()
    \tblockers = {}
    \tfor _, part in workspace:GetDescendants() do
    \t\tif part:IsA("BasePart") and part.CanCollide and part.Transparency < 1 then
    \t\t\tlocal top = part.Position.Y + part.Size.Y / 2
    \t\t\tlocal bottom = part.Position.Y - part.Size.Y / 2
    \t\t\tif top > 1.5 and bottom < 3 then
    \t\t\t\tlocal halfX, halfZ = part.Size.X / 2, part.Size.Z / 2
    \t\t\t\tlocal turn = part.Orientation
    \t\t\t\tif turn.X % 180 ~= 0 or turn.Y % 90 ~= 0 or turn.Z % 180 ~= 0 then
    \t\t\t\t\tlocal widest = math.max(part.Size.X, part.Size.Y, part.Size.Z) / 2
    \t\t\t\t\thalfX, halfZ = widest, widest
    \t\t\t\telseif turn.Y % 180 ~= 0 then
    \t\t\t\t\thalfX, halfZ = halfZ, halfX
    \t\t\t\tend
    \t\t\t\tlocal box = { part.Position.X - halfX, part.Position.X + halfX, part.Position.Z - halfZ, part.Position.Z + halfZ }
    \t\t\t\t-- In every cell it (or a zombie brushing it) could be in.
    \t\t\t\tfor x = math.floor((box[1] - 2) / CELL), math.floor((box[2] + 2) / CELL) do
    \t\t\t\t\tfor z = math.floor((box[3] - 2) / CELL), math.floor((box[4] + 2) / CELL) do
    \t\t\t\t\t\tlocal key = x * 1000 + z
    \t\t\t\t\t\tblockers[key] = blockers[key] or {}
    \t\t\t\t\t\ttable.insert(blockers[key], box)
    \t\t\t\t\tend
    \t\t\t\tend
    \t\t\tend
    \t\tend
    \tend
    end

    function Horde.blocked(x, z, radius)
    \tlocal list = blockers[cellKey(x, z)]
    \tif list == nil then
    \t\treturn false
    \tend
    \tfor _, box in list do
    \t\tif x > box[1] - radius and x < box[2] + radius and z > box[3] - radius and z < box[4] + radius then
    \t\t\treturn true
    \t\tend
    \tend
    \treturn false
    end

    function Horde.count()
    \tlocal count = 0
    \tfor _ in Horde.zombies do
    \t\tcount += 1
    \tend
    \treturn count
    end

    -- A new zombie of a kind at a place, as tough as the night makes it.
    function Horde.spawn(kindName, position, night)
    \tlocal template = ServerStorage:FindFirstChild(kindName)
    \tlocal kind = Horde.kinds[kindName]
    \tlocal model = template:Clone()
    \t-- The template stands on the ground, so its height is the one to walk at.
    \tlocal y = template:GetPivot().Position.Y
    \t-- Not inside a tree: the nearest free spot, going round in widening rings.
    \tlocal x, z = position.X, position.Z
    \tlocal radius = 0
    \twhile Horde.blocked(x, z, kind.radius) and radius < 12 do
    \t\tradius += 1.5
    \t\tfor step = 0, 7 do
    \t\t\tlocal angle = step * math.pi / 4
    \t\t\tlocal tryX, tryZ = position.X + math.cos(angle) * radius, position.Z + math.sin(angle) * radius
    \t\t\tif not Horde.blocked(tryX, tryZ, kind.radius) then
    \t\t\t\tx, z = tryX, tryZ
    \t\t\t\tbreak
    \t\t\tend
    \t\tend
    \tend
    \tlocal at = Vector3.new(x, y, z)
    \tmodel:PivotTo(CFrame.lookAt(at, Vector3.new(CAMP.X, y, CAMP.Z)))
    \tmodel.Parent = folder
    \tlocal tougher = 1 + 0.15 * (night - 1)
    \tlocal health = math.floor(kind.health * tougher)
    \tlocal value = Instance.new("NumberValue")
    \tvalue.Name = "Health"
    \tvalue.Value = health
    \tvalue.Parent = model
    \tlocal most = Instance.new("NumberValue")
    \tmost.Name = "MaxHealth"
    \tmost.Value = health
    \tmost.Parent = model
    \tlocal torso = model:FindFirstChild("Torso")
    \tlocal zombie = {
    \t\tmodel = model, kind = kindName, health = health, value = value, torso = torso, colour = torso.Color,
    \t\tspeed = kind.speed * (1 + 0.03 * (night - 1)), damage = math.floor(kind.damage * (1 + 0.1 * (night - 1))),
    \t\treach = kind.reach, radius = kind.radius, orbs = kind.orbs, y = y, nextBite = 0,
    \t}
    \tHorde.zombies[model] = zombie
    \treturn zombie
    end

    -- Every zombie gone at once: a new world.
    function Horde.clear()
    \tfor model in Horde.zombies do
    \t\tmodel:Destroy()
    \tend
    \tHorde.zombies = {}
    end

    -- Hurts a zombie (a flash of white); at no health it falls and is gone.
    function Horde.hurt(zombie, amount, player)
    \tif zombie.dead then
    \t\treturn
    \tend
    \tzombie.health -= amount
    \tzombie.lastHit = player or zombie.lastHit
    \tzombie.value.Value = math.max(zombie.health, 0)
    \tif zombie.health > 0 then
    \t\tzombie.torso.Color = Color3.new(1, 1, 1)
    \t\ttask.delay(0.08, function()
    \t\t\tif not zombie.dead then
    \t\t\t\tzombie.torso.Color = zombie.colour
    \t\t\tend
    \t\tend)
    \t\treturn
    \tend
    \tzombie.dead = true
    \tHorde.zombies[zombie.model] = nil
    \tlocal position = zombie.model:GetPivot().Position
    \tzombie.model:Destroy()
    \tHorde.puff(position)
    \tHorde.onKill(position, zombie, zombie.lastHit)
    end

    -- Moves a zombie by an offset, unless something solid is in the way.
    function Horde.shove(zombie, by)
    \tlocal from = zombie.model:GetPivot().Position
    \tlocal to = Vector3.new(from.X + by.X, zombie.y, from.Z + by.Z)
    \tif not Horde.blocked(to.X, to.Z, zombie.radius) then
    \t\tzombie.model:PivotTo(CFrame.lookAt(to, to - Vector3.new(by.X, 0, by.Z)))
    \tend
    end

    local function turned(v, angle)
    \tlocal c, s = math.cos(angle), math.sin(angle)
    \treturn Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
    end
    -- Straight on first, then ever wider round whatever's in the way.
    local detours = { 0, 0.6, -0.6, 1.2, -1.2, 1.9, -1.9, 2.6, -2.6 }

    -- One step for every zombie: chase the nearest living player in sight (or drift to
    -- the camp), keep a little apart from the others, and bite anyone close enough.
    function Horde.step(dt)
    \tlocal targets = {}
    \tfor _, player in Players:GetPlayers() do
    \t\tlocal root = Utils.getRoot(player)
    \t\tlocal humanoid = Utils.getHumanoid(player)
    \t\tif root and humanoid and humanoid.Health > 0 then
    \t\t\ttable.insert(targets, { player = player, position = root.Position, humanoid = humanoid })
    \t\tend
    \tend
    \tlocal now = time()
    \tlocal list = {}
    \tfor _, zombie in Horde.zombies do
    \t\tzombie.position = zombie.model:GetPivot().Position
    \t\ttable.insert(list, zombie)
    \tend
    \tfor _, zombie in list do
    \t\tif zombie.dead then
    \t\t\tcontinue
    \t\tend
    \t\tlocal position = zombie.position
    \t\tlocal best, bestDistance = nil, SIGHT
    \t\tfor _, target in targets do
    \t\t\tlocal d = Vector3.new(target.position.X - position.X, 0, target.position.Z - position.Z).Magnitude
    \t\t\tif d < bestDistance then
    \t\t\t\tbest, bestDistance = target, d
    \t\t\tend
    \t\tend
    \t\tlocal goal = if best then best.position else CAMP
    \t\tlocal flat = Vector3.new(goal.X - position.X, 0, goal.Z - position.Z)
    \t\tlocal distance = flat.Magnitude
    \t\tif best and distance <= zombie.reach then
    \t\t\tzombie.model:PivotTo(CFrame.lookAt(position, Vector3.new(goal.X, position.Y, goal.Z)))
    \t\t\tif now >= zombie.nextBite then
    \t\t\t\tzombie.nextBite = now + 1
    \t\t\t\tbest.humanoid:TakeDamage(zombie.damage)
    \t\t\t\tlocal stats = Horde.stats[best.player]
    \t\t\t\tif stats and stats.thorns > 0 then
    \t\t\t\t\tHorde.hurt(zombie, stats.thorns, best.player)
    \t\t\t\tend
    \t\t\tend
    \t\telseif distance > 1 then
    \t\t\tlocal heading = flat / distance
    \t\t\tfor _, other in list do
    \t\t\t\tif other ~= zombie and not other.dead then
    \t\t\t\t\tlocal apart = Vector3.new(position.X - other.position.X, 0, position.Z - other.position.Z)
    \t\t\t\t\tlocal gap = apart.Magnitude
    \t\t\t\t\tif gap > 0.01 and gap < zombie.radius + other.radius then
    \t\t\t\t\t\theading += apart / gap * 0.6
    \t\t\t\t\tend
    \t\t\t\tend
    \t\t\tend
    \t\t\theading = Vector3.new(heading.X, 0, heading.Z).Unit
    \t\t\tlocal speed = zombie.speed * (if best then 1 else 0.45)
    \t\t\tlocal stride = math.min(speed * dt, distance - (if best then zombie.reach * 0.8 else 0))
    \t\t\tif stride > 0 then
    \t\t\t\tfor _, angle in detours do
    \t\t\t\t\tlocal direction = turned(heading, angle)
    \t\t\t\t\tlocal x, z = position.X + direction.X * stride, position.Z + direction.Z * stride
    \t\t\t\t\tif not Horde.blocked(x, z, zombie.radius) then
    \t\t\t\t\t\tlocal to = Vector3.new(x, zombie.y, z)
    \t\t\t\t\t\tzombie.model:PivotTo(CFrame.lookAt(to, to + direction))
    \t\t\t\t\t\tbreak
    \t\t\t\t\tend
    \t\t\t\tend
    \t\t\tend
    \t\tend
    \tend
    end

    -- A flash of light that fades: where something was hit or fell.
    local function flash(size, cframe, colour, seconds)
    \tlocal part = Instance.new("Part")
    \tpart.Name = "Flash"
    \tpart.Anchored = true
    \tpart.CanCollide = false
    \tpart.Material = Enum.Material.Neon
    \tpart.Color = colour
    \tpart.Transparency = 0.3
    \tpart.Size = size
    \tpart.CFrame = cframe
    \tpart.Parent = workspace
    \tUtils.tween(part, seconds, { Transparency = 1 })
    \ttask.delay(seconds + 0.05, function()
    \t\tpart:Destroy()
    \tend)
    end

    function Horde.puff(position)
    \tflash(Vector3.new(3, 3, 3), CFrame.new(position), Color3.fromRGB(120, 255, 140), 0.35)
    end

    -- A sword swing: every zombie in reach in front of you (or right beside you) is hit,
    -- and pushed back. Returns whether it hit anything.
    function Horde.swing(player)
    \tlocal stats = Horde.stats[player]
    \tlocal root = Utils.getRoot(player)
    \tif not stats or not root or not Utils.isAlive(player) then
    \t\treturn false
    \tend
    \tlocal now = time()
    \tif now < stats.nextSwing then
    \t\treturn false
    \tend
    \tstats.nextSwing = now + stats.swingTime
    \tlocal origin = root.Position
    \tlocal struck = {}
    \tfor _, zombie in Horde.zombies do
    \t\tlocal offset = zombie.model:GetPivot().Position - origin
    \t\tlocal flat = Vector3.new(offset.X, 0, offset.Z)
    \t\tlocal d = flat.Magnitude
    \t\tif d <= stats.reach and (d < 2.5 or flat.Unit:Dot(stats.facing) > 0) then
    \t\t\ttable.insert(struck, { zombie = zombie, away = if d > 0.01 then flat.Unit else stats.facing })
    \t\tend
    \tend
    \tfor _, hit in struck do
    \t\tlocal damage = stats.swordDamage * (if math.random() < stats.crit then 2 else 1)
    \t\tHorde.hurt(hit.zombie, damage, player)
    \t\tif not hit.zombie.dead then
    \t\t\tHorde.shove(hit.zombie, hit.away * 3)
    \t\tend
    \tend
    \tlocal centre = origin + stats.facing * (stats.reach * 0.55) + Vector3.new(0, 0.5, 0)
    \tflash(Vector3.new(stats.reach * 1.6, 0.15, stats.reach * 0.5), CFrame.lookAt(centre, centre + stats.facing),
    \t\tColor3.fromRGB(230, 240, 255), 0.18)
    \treturn #struck > 0
    end

    -- A blaster shot from the chest towards target: the first thing in the way is hit,
    -- and a beam shows the shot. Only with the blaster in hand.
    function Horde.fire(player, target)
    \tlocal stats = Horde.stats[player]
    \tlocal root = Utils.getRoot(player)
    \tif not stats or not stats.blaster or not root or not Utils.isAlive(player) or typeof(target) ~= "Vector3" then
    \t\treturn false
    \tend
    \tlocal character = Utils.getCharacter(player)
    \tlocal tool = character and character:FindFirstChildOfClass("Tool")
    \tif tool == nil or tool.Name ~= "Blaster" then
    \t\treturn false
    \tend
    \tlocal now = time()
    \tif now < stats.nextShot then
    \t\treturn false
    \tend
    \tstats.nextShot = now + stats.fireTime
    \tlocal origin = root.Position + Vector3.new(0, 1.5, 0)
    \tlocal aim = target - origin
    \tif aim.Magnitude < 0.5 then
    \t\treturn false
    \tend
    \tlocal direction = aim.Unit * 160
    \tlocal ignore = { workspace.Orbs, workspace.Keys }
    \tfor _, other in Players:GetPlayers() do
    \t\tif other.Character then
    \t\t\ttable.insert(ignore, other.Character)
    \t\tend
    \tend
    \tlocal params = RaycastParams.new()
    \tparams.FilterType = Enum.RaycastFilterType.Exclude
    \tparams.FilterDescendantsInstances = ignore
    \tlocal result = workspace:Raycast(origin, direction, params)
    \tlocal finish = if result then result.Position else origin + direction
    \tlocal hit = false
    \tif result then
    \t\tlocal zombie = Horde.zombies[result.Instance.Parent]
    \t\tif zombie then
    \t\t\tHorde.hurt(zombie, stats.blasterDamage * (if math.random() < stats.crit then 2 else 1), player)
    \t\t\thit = true
    \t\tend
    \tend
    \tlocal middle = (origin + finish) / 2
    \tflash(Vector3.new(0.25, 0.25, (finish - origin).Magnitude), CFrame.lookAt(middle, finish),
    \t\tColor3.fromRGB(80, 220, 255), 0.15)
    \treturn hit
    end

    -- A dash: a few studs forward in quick hops, stopping at anything solid.
    function Horde.dash(player)
    \tlocal stats = Horde.stats[player]
    \tlocal root = Utils.getRoot(player)
    \tif not stats or stats.dash == 0 or not root or not Utils.isAlive(player) then
    \t\treturn false
    \tend
    \tlocal now = time()
    \tif now < stats.nextDash then
    \t\treturn false
    \tend
    \tstats.nextDash = now + stats.dashTime
    \tlocal direction = stats.facing
    \ttask.spawn(function()
    \t\tfor _ = 1, 6 do
    \t\t\tlocal from = root.Position
    \t\t\tlocal to = from + direction * 2
    \t\t\tif Horde.blocked(to.X, to.Z, 1) then
    \t\t\t\tbreak
    \t\t\tend
    \t\t\troot.Position = to
    \t\t\ttask.wait()
    \t\tend
    \tend)
    \treturn true
    end

    return Horde
    """

    static let upgrades = """
    -- Upgrades: the power-ups, offered three at a time — each dawn, and whenever a
    -- player's orbs fill their bar — and what each does. They stack for the rest of the
    -- run. The stats they change live in Horde.stats; carry puts the ones a character
    -- carries (speed, jump, health) on its Humanoid.
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Utils = require(ReplicatedStorage:WaitForChild("Utils"))

    local Upgrades = {}

    -- A run's stats, before any power-up.
    function Upgrades.fresh()
    \treturn {
    \t\tspeed = 1, jump = 1, bonusHealth = 0,
    \t\tswordDamage = 25, reach = 7, swingTime = 0.5,
    \t\tblasterDamage = 18, fireTime = 0.35, blaster = false,
    \t\tlifesteal = 0, magnet = 6, thorns = 0, crit = 0.05, dash = 0, dashTime = 3,
    \t\tfacing = Vector3.new(0, 0, -1), nextSwing = 0, nextShot = 0, nextDash = 0,
    \t\tkills = 0, orbs = 0, orbsNeeded = 5, nights = 0, keys = 0,
    \t\t-- How many times each was taken, and their names in the order taken.
    \t\tlevels = {}, taken = {},
    \t}
    end

    Upgrades.list = {
    \t{ id = "swift", name = "Swift Feet", text = "Walk 15% faster.", max = 5,
    \t\tgive = function(s) s.speed *= 1.15 end },
    \t{ id = "edge", name = "Sharp Edge", text = "Your sword hits 30% harder.", max = 6,
    \t\tgive = function(s) s.swordDamage *= 1.3 end },
    \t{ id = "reach", name = "Wide Swing", text = "Your sword reaches 1.5 studs further.", max = 4,
    \t\tgive = function(s) s.reach += 1.5 end },
    \t{ id = "quick", name = "Quick Hands", text = "Swing 15% faster.", max = 4,
    \t\tgive = function(s) s.swingTime *= 0.85 end },
    \t{ id = "charge", name = "Overcharge", text = "Your blaster hits 30% harder.", max = 6, needs = "blaster",
    \t\tgive = function(s) s.blasterDamage *= 1.3 end },
    \t{ id = "rapid", name = "Rapid Fire", text = "Your blaster fires 20% faster.", max = 4, needs = "blaster",
    \t\tgive = function(s) s.fireTime *= 0.8 end },
    \t{ id = "iron", name = "Iron Skin", text = "25 more health, and 25 back now.", max = 6, heal = 25,
    \t\tgive = function(s) s.bonusHealth += 25 end },
    \t{ id = "vampire", name = "Vampire", text = "3 health back for every zombie you take down.", max = 5,
    \t\tgive = function(s) s.lifesteal += 3 end },
    \t{ id = "spring", name = "Spring Heels", text = "Jump 20% higher.", max = 3,
    \t\tgive = function(s) s.jump *= 1.2 end },
    \t{ id = "magnet", name = "Magnet", text = "Pick up orbs from 5 studs further away.", max = 4,
    \t\tgive = function(s) s.magnet += 5 end },
    \t{ id = "thorns", name = "Thorns", text = "Zombies that bite you take 12 damage.", max = 5,
    \t\tgive = function(s) s.thorns += 12 end },
    \t{ id = "lucky", name = "Lucky Strike", text = "10% more chance of a double-damage hit.", max = 5,
    \t\tgive = function(s) s.crit += 0.1 end },
    \t{ id = "dash", name = "Dash", text = "Press Q to dash forward. Again: a shorter wait between dashes.", max = 3,
    \t\tgive = function(s)
    \t\t\ts.dash += 1
    \t\t\ts.dashTime = 3.5 - s.dash
    \t\tend },
    \t{ id = "mend", name = "Second Wind", text = "Heal to full, now.", max = 99, heal = "full",
    \t\tgive = function() end },
    }

    Upgrades.byId = {}
    for _, upgrade in Upgrades.list do
    \tUpgrades.byId[upgrade.id] = upgrade
    end

    -- Three different ones this run can still take, as the screen shows them.
    function Upgrades.offer(stats)
    \tlocal open = {}
    \tfor _, upgrade in Upgrades.list do
    \t\tif (stats.levels[upgrade.id] or 0) < upgrade.max and (upgrade.needs == nil or stats[upgrade.needs]) then
    \t\t\ttable.insert(open, upgrade)
    \t\tend
    \tend
    \tlocal chosen = {}
    \tfor _, upgrade in Utils.shuffle(open) do
    \t\tif #chosen == 3 then
    \t\t\tbreak
    \t\tend
    \t\ttable.insert(chosen, { id = upgrade.id, name = upgrade.name, text = upgrade.text,
    \t\t\tlevel = (stats.levels[upgrade.id] or 0) + 1 })
    \tend
    \treturn chosen
    end

    -- What a character's Humanoid gets from the stats.
    function Upgrades.carry(stats, humanoid)
    \thumanoid.WalkSpeed = 16 * stats.speed
    \thumanoid.JumpPower = 50 * stats.jump
    \thumanoid.MaxHealth = 100 + stats.bonusHealth
    end

    -- Takes one: its stats, then what the Humanoid carries, then any healing.
    function Upgrades.take(stats, id, humanoid)
    \tlocal upgrade = Upgrades.byId[id]
    \tif upgrade == nil then
    \t\treturn false
    \tend
    \tupgrade.give(stats)
    \tstats.levels[id] = (stats.levels[id] or 0) + 1
    \ttable.insert(stats.taken, upgrade.name)
    \tif humanoid then
    \t\tUpgrades.carry(stats, humanoid)
    \t\tif upgrade.heal == "full" then
    \t\t\thumanoid.Health = humanoid.MaxHealth
    \t\telseif upgrade.heal then
    \t\t\thumanoid.Health = math.min(humanoid.Health + upgrade.heal, humanoid.MaxHealth)
    \t\tend
    \tend
    \treturn true
    end

    return Upgrades
    """

    // MARK: - The server

    static let game = """
    -- GameScript: Nightfall's rules. A day to explore, then a night of zombies — more,
    -- faster and tougher each night — then a short dawn and a power-up. Three keys are
    -- hidden in new places every run; find them all and the north gate opens. A run ends
    -- when you fall, or escape through the gate: you see how you did, and a new run
    -- starts from nothing. The numbers to tune it by are in ServerStorage.Settings. Each
    -- player's best score is saved (an OrderedDataStore), and the top five shown.
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local Lighting = game:GetService("Lighting")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local ServerStorage = game:GetService("ServerStorage")
    local DataStoreService = game:GetService("DataStoreService")

    local Utils = require(ReplicatedStorage.Utils)
    local Horde = require(ServerStorage.Horde)
    local Upgrades = require(ServerStorage.Upgrades)

    local Settings = ServerStorage.Settings
    local Status = ReplicatedStorage.Status
    local Notify = ReplicatedStorage.Notify
    local Offer = ReplicatedStorage.Offer
    local Choose = ReplicatedStorage.Choose
    local Fire = ReplicatedStorage.Fire
    local Dash = ReplicatedStorage.Dash
    local RunOver = ReplicatedStorage.RunOver

    -- Everyone's best, by name, sorted for the top scores.
    local BestScores = DataStoreService:GetOrderedDataStore("BestScores")
    local function saveKey(player)
    \treturn "player_" .. player.Name
    end

    local function topScores()
    \tlocal ok, top = pcall(function()
    \t\tlocal list = {}
    \t\tfor _, entry in BestScores:GetSortedAsync(false, 5):GetCurrentPage() do
    \t\t\ttable.insert(list, { name = string.gsub(entry.key, "^player_", ""), score = entry.value })
    \t\tend
    \t\treturn list
    \tend)
    \treturn if ok then top else {}
    end

    local gate = workspace.Gate
    local shut = { gate.DoorLeft.Position, gate.DoorRight.Position }
    local CAMP_SPAWN = Vector3.new(0, 4, 18)

    -- The world everyone shares: which night, the phase and when it ends, the zombies
    -- still to come tonight, the keys.
    local world = { night = 0, phase = "day", endsAt = 0, toCome = 0, nextSpawn = 0, keys = {} }
    -- Who is in a run, their power-ups waiting to be chosen, and the orbs lying about.
    local inRun = {}
    local offers = {}
    local orbs = {}

    local function setting(name)
    \treturn Settings:FindFirstChild(name).Value
    end

    local function tell(text, player)
    \tif player then
    \t\tNotify:FireClient(player, text)
    \telse
    \t\tNotify:FireAllClients(text)
    \tend
    end

    -- What the player's own screen shows about their run.
    local function update(player)
    \tlocal stats = Horde.stats[player]
    \tlocal run = player:FindFirstChild("Run")
    \tif stats == nil or run == nil then
    \t\treturn
    \tend
    \trun.Orbs.Value = stats.orbs
    \trun.OrbsNeeded.Value = stats.orbsNeeded
    \trun.Dash.Value = stats.dash
    \trun.Picks.Value = table.concat(stats.taken, ",")
    \tplayer.leaderstats.Kills.Value = stats.kills
    end

    -- MARK: Power-ups

    local function showOffer(player)
    \tlocal queue = offers[player]
    \tif queue and queue[1] then
    \t\tOffer:FireClient(player, queue[1])
    \tend
    end

    local function offer(player)
    \tlocal stats = Horde.stats[player]
    \tif stats == nil then
    \t\treturn
    \tend
    \tlocal choice = Upgrades.offer(stats)
    \tif #choice == 0 then
    \t\treturn
    \tend
    \toffers[player] = offers[player] or {}
    \ttable.insert(offers[player], choice)
    \tif #offers[player] == 1 then
    \t\tshowOffer(player)
    \tend
    end

    Choose.OnServerEvent:Connect(function(player, id)
    \tlocal queue = offers[player]
    \tlocal current = queue and queue[1]
    \tif current == nil then
    \t\treturn
    \tend
    \tfor _, option in current do
    \t\tif option.id == id then
    \t\t\ttable.remove(queue, 1)
    \t\t\tUpgrades.take(Horde.stats[player], id, Utils.getHumanoid(player))
    \t\t\tupdate(player)
    \t\t\ttell(option.name .. "!", player)
    \t\t\tshowOffer(player)
    \t\t\treturn
    \t\tend
    \tend
    end)

    -- MARK: Orbs

    local function dropOrb(position)
    \tlocal orb = Instance.new("Part")
    \torb.Name = "Orb"
    \torb.Shape = Enum.PartType.Ball
    \torb.Size = Vector3.new(0.9, 0.9, 0.9)
    \torb.Material = Enum.Material.Neon
    \torb.Color = Color3.fromRGB(90, 255, 150)
    \torb.Anchored = true
    \torb.CanCollide = false
    \torb.Position = Vector3.new(position.X, 1.4, position.Z)
    \torb.Parent = workspace.Orbs
    \ttable.insert(orbs, { part = orb, position = orb.Position, born = time() })
    end

    local function collect(player)
    \tlocal stats = Horde.stats[player]
    \tstats.orbs += 1
    \tif stats.orbs >= stats.orbsNeeded then
    \t\tstats.orbs -= stats.orbsNeeded
    \t\tstats.orbsNeeded += 3
    \t\ttell("Level up! Choose a power-up.", player)
    \t\toffer(player)
    \tend
    \tupdate(player)
    end

    -- Orbs float to whoever comes near enough (their Magnet), and fade after a while.
    local function gatherOrbs(now)
    \tfor index = #orbs, 1, -1 do
    \t\tlocal orb = orbs[index]
    \t\tif now - orb.born > 45 then
    \t\t\torb.part:Destroy()
    \t\t\ttable.remove(orbs, index)
    \t\t\tcontinue
    \t\tend
    \t\tlocal closest, nearest = nil, math.huge
    \t\tfor player in inRun do
    \t\t\tlocal stats = Horde.stats[player]
    \t\t\tlocal root = Utils.getRoot(player)
    \t\t\tif stats and root then
    \t\t\t\tlocal d = (root.Position - orb.position).Magnitude
    \t\t\t\tif d <= stats.magnet and d < nearest then
    \t\t\t\t\tclosest, nearest = player, d
    \t\t\t\tend
    \t\t\tend
    \t\tend
    \t\tif closest and nearest < 2.5 then
    \t\t\torb.part:Destroy()
    \t\t\ttable.remove(orbs, index)
    \t\t\tcollect(closest)
    \t\telseif closest then
    \t\t\torb.position = orb.position:Lerp(Utils.getRoot(closest).Position, 0.35)
    \t\t\torb.part.Position = orb.position
    \t\tend
    \tend
    end

    Horde.onKill = function(position, zombie, player)
    \tfor _ = 1, zombie.orbs do
    \t\tdropOrb(position + Vector3.new(Utils.randomBetween(-2, 2), 0, Utils.randomBetween(-2, 2)))
    \tend
    \tlocal stats = player and Horde.stats[player]
    \tif stats then
    \t\tstats.kills += 1
    \t\tlocal humanoid = Utils.getHumanoid(player)
    \t\tif humanoid and stats.lifesteal > 0 then
    \t\t\thumanoid.Health = math.min(humanoid.Health + stats.lifesteal, humanoid.MaxHealth)
    \t\tend
    \t\tupdate(player)
    \tend
    end

    -- MARK: Keys and the gate

    local function openGate(finder)
    \tStatus.GateOpen.Value = true
    \tUtils.tween(gate.DoorLeft, 2, { Position = shut[1] - Vector3.new(9, 0, 0) })
    \tUtils.tween(gate.DoorRight, 2, { Position = shut[2] + Vector3.new(9, 0, 0) })
    \tgate.GateLight.Color = Color3.fromRGB(90, 240, 140)
    \tlocal glow = gate.GateLight:FindFirstChild("PointLight")
    \tif glow then
    \t\tglow.Color = Color3.fromRGB(90, 240, 140)
    \tend
    \ttell(finder.Name .. " found the last key! The north gate is open: escape through it!")
    end

    local function closeGate()
    \tStatus.GateOpen.Value = false
    \tgate.DoorLeft.Position = shut[1]
    \tgate.DoorRight.Position = shut[2]
    \tgate.GateLight.Color = Color3.fromRGB(230, 60, 50)
    \tlocal glow = gate.GateLight:FindFirstChild("PointLight")
    \tif glow then
    \t\tglow.Color = Color3.fromRGB(230, 60, 50)
    \tend
    end

    local function takeKey(entry, player)
    \tentry.taken = true
    \tentry.model:Destroy()
    \tlocal found = Status.KeysFound.Value + 1
    \tStatus.KeysFound.Value = found
    \tlocal stats = Horde.stats[player]
    \tif stats then
    \t\tstats.keys += 1
    \tend
    \tif found >= Status.KeysNeeded.Value then
    \t\topenGate(player)
    \telse
    \t\ttell(player.Name .. " found a key! (" .. found .. "/" .. Status.KeysNeeded.Value .. ")")
    \tend
    end

    -- Keys in new places: a few of the KeySpots, chosen at random.
    local function hideKeys()
    \tfor _, entry in world.keys do
    \t\tif not entry.taken then
    \t\t\tentry.model:Destroy()
    \t\tend
    \tend
    \tworld.keys = {}
    \tlocal needed = setting("KeysNeeded")
    \tStatus.KeysFound.Value = 0
    \tStatus.KeysNeeded.Value = needed
    \tlocal spots = Utils.shuffle(workspace.KeySpots:GetChildren())
    \tfor index = 1, math.min(needed, #spots) do
    \t\tlocal key = ServerStorage.Key:Clone()
    \t\tkey:PivotTo(CFrame.new(spots[index].Position))
    \t\tkey.Parent = workspace.Keys
    \t\tlocal entry = { model = key, spot = spots[index].Position, taken = false }
    \t\ttable.insert(world.keys, entry)
    \t\tfor _, part in key:GetChildren() do
    \t\t\tpart.Touched:Connect(function(hit)
    \t\t\t\tlocal player = Utils.playerFromPart(hit)
    \t\t\t\tif player and inRun[player] and not entry.taken then
    \t\t\t\t\ttakeKey(entry, player)
    \t\t\t\tend
    \t\t\tend)
    \t\tend
    \tend
    end

    -- MARK: Days and nights

    local function setPhase(phase, seconds)
    \tworld.phase = phase
    \tworld.endsAt = time() + (seconds or 0)
    \tStatus.Phase.Value = phase
    end

    local function resetWorld()
    \tHorde.clear()
    \tfor _, orb in orbs do
    \t\torb.part:Destroy()
    \tend
    \torbs = {}
    \tworld.night = 0
    \tworld.toCome = 0
    \tStatus.Night.Value = 0
    \tStatus.ZombiesLeft.Value = 0
    \thideKeys()
    \tcloseGate()
    \tsetPhase("day", setting("DayLength"))
    end

    local function startNight()
    \tworld.night += 1
    \tStatus.Night.Value = world.night
    \tworld.toCome = setting("FirstNight") + (world.night - 1) * setting("MorePerNight")
    \tsetPhase("night")
    \ttell("Night " .. world.night .. ": here they come!")
    end

    local function startDawn()
    \tsetPhase("dawn", setting("DawnLength"))
    \ttell("Dawn. You lived through night " .. world.night .. ".")
    \tfor player in inRun do
    \t\tlocal stats = Horde.stats[player]
    \t\tstats.nights += 1
    \t\tlocal humanoid = Utils.getHumanoid(player)
    \t\tif humanoid then
    \t\t\thumanoid.Health = math.min(humanoid.Health + 30, humanoid.MaxHealth)
    \t\tend
    \t\toffer(player)
    \tend
    end

    -- Somewhere away from everyone, if there is such a place.
    local function spawnOne()
    \tlocal night = world.night
    \tlocal roll = math.random()
    \tlocal kind = "Walker"
    \tif night >= 3 and roll < 0.08 + 0.02 * night then
    \t\tkind = "Brute"
    \telseif night >= 2 and roll < 0.4 then
    \t\tkind = "Runner"
    \tend
    \tlocal points = Utils.shuffle(workspace.SpawnPoints:GetChildren())
    \tlocal chosen = points[1]
    \tfor _, point in points do
    \t\tlocal near = false
    \t\tfor player in inRun do
    \t\t\tif Utils.distance(player, point) < 45 then
    \t\t\t\tnear = true
    \t\t\t\tbreak
    \t\t\tend
    \t\tend
    \t\tif not near then
    \t\t\tchosen = point
    \t\t\tbreak
    \t\tend
    \tend
    \tHorde.spawn(kind, chosen.Position, night)
    end

    -- MARK: Runs

    local startRun

    local function endRun(player, escaped)
    \tif not inRun[player] then
    \t\treturn
    \tend
    \tinRun[player] = nil
    \toffers[player] = nil
    \tlocal stats = Horde.stats[player]
    \tHorde.stats[player] = nil
    \tif stats then
    \t\tlocal score = stats.nights * 100 + stats.kills * 10 + stats.keys * 50 + (if escaped then 1000 else 0)
    \t\tlocal best = player.leaderstats.Best
    \t\tlocal record = score > best.Value
    \t\tif record then
    \t\t\tbest.Value = score
    \t\t\tlocal ok, problem = pcall(function()
    \t\t\t\tBestScores:SetAsync(saveKey(player), score)
    \t\t\tend)
    \t\t\tif not ok then
    \t\t\t\twarn("Couldn't save " .. player.Name .. "'s best: " .. tostring(problem))
    \t\t\tend
    \t\tend
    \t\tRunOver:FireClient(player, {
    \t\t\tescaped = escaped, night = world.night, nights = stats.nights, kills = stats.kills, keys = stats.keys,
    \t\t\tpicks = stats.taken, score = score, best = best.Value, record = record, top = topScores(),
    \t\t})
    \tend
    \t-- The blaster belonged to that run.
    \tfor _, place in { player:FindFirstChild("Backpack"), player.Character } do
    \t\tlocal blaster = place and place:FindFirstChild("Blaster")
    \t\tif blaster then
    \t\t\tblaster:Destroy()
    \t\tend
    \tend
    \tif next(inRun) == nil then
    \t\tresetWorld()
    \tend
    end

    startRun = function(player, character)
    \tlocal humanoid = Utils.getHumanoid(character)
    \tif humanoid == nil then
    \t\treturn
    \tend
    \tlocal stats = Upgrades.fresh()
    \tHorde.stats[player] = stats
    \tinRun[player] = true
    \toffers[player] = {}
    \tUpgrades.carry(stats, humanoid)
    \thumanoid.Health = humanoid.MaxHealth
    \thumanoid.Died:Connect(function()
    \t\tif Horde.stats[player] == stats then
    \t\t\tendRun(player, false)
    \t\tend
    \tend)
    \tupdate(player)
    end

    local function setUp(player)
    \tlocal leaderstats = Instance.new("Folder")
    \tleaderstats.Name = "leaderstats"
    \tleaderstats.Parent = player
    \tfor _, name in { "Kills", "Best" } do
    \t\tlocal value = Instance.new("IntValue")
    \t\tvalue.Name = name
    \t\tvalue.Parent = leaderstats
    \tend
    \t-- Their best from last time.
    \tlocal ok, saved = pcall(function()
    \t\treturn BestScores:GetAsync(saveKey(player))
    \tend)
    \tif ok and type(saved) == "number" then
    \t\tleaderstats.Best.Value = saved
    \tend
    \tlocal run = Instance.new("Folder")
    \trun.Name = "Run"
    \trun.Parent = player
    \tfor _, name in { "Orbs", "OrbsNeeded", "Dash" } do
    \t\tlocal value = Instance.new("IntValue")
    \t\tvalue.Name = name
    \t\tvalue.Parent = run
    \tend
    \tlocal picks = Instance.new("StringValue")
    \tpicks.Name = "Picks"
    \tpicks.Parent = run
    \tplayer.CharacterAdded:Connect(function(character)
    \t\tstartRun(player, character)
    \tend)
    \tif player.Character then
    \t\tstartRun(player, player.Character)
    \tend
    end

    Players.PlayerRemoving:Connect(function(player)
    \tif inRun[player] then
    \t\tinRun[player] = nil
    \t\tHorde.stats[player] = nil
    \t\tif next(inRun) == nil then
    \t\t\tresetWorld()
    \t\tend
    \tend
    \toffers[player] = nil
    end)

    gate.EscapeZone.Touched:Connect(function(hit)
    \tlocal player = Utils.playerFromPart(hit)
    \tif player and inRun[player] and Status.GateOpen.Value then
    \t\tendRun(player, true)
    \t\t-- Back to the camp, and a new run.
    \t\tlocal root = Utils.getRoot(player)
    \t\tif root then
    \t\t\troot.Position = CAMP_SPAWN
    \t\tend
    \t\tlocal character = Utils.getCharacter(player)
    \t\tif character then
    \t\t\tstartRun(player, character)
    \t\tend
    \tend
    end)

    workspace.Town.Armory.BlasterPickup.Touched:Connect(function(hit)
    \tlocal player = Utils.playerFromPart(hit)
    \tlocal stats = player and Horde.stats[player]
    \tif stats and not stats.blaster then
    \t\tstats.blaster = true
    \t\tServerStorage.Blaster:Clone().Parent = player.Backpack
    \t\ttell("You found the blaster! Press 2 to hold it, and click to shoot where you point.", player)
    \tend
    end)

    Fire.OnServerEvent:Connect(function(player, target)
    \tif inRun[player] then
    \t\tHorde.fire(player, target)
    \tend
    end)

    Dash.OnServerEvent:Connect(function(player)
    \tif inRun[player] then
    \t\tHorde.dash(player)
    \tend
    end)

    -- MARK: Every tick

    local function tick(dt, now)
    \tHorde.step(dt)
    \tgatherOrbs(now)
    \t-- Which way each player faces, for swings and dashes: the way they last moved.
    \tfor player in inRun do
    \t\tlocal humanoid = Utils.getHumanoid(player)
    \t\tlocal stats = Horde.stats[player]
    \t\tif humanoid and stats then
    \t\t\tlocal moving = humanoid.MoveDirection
    \t\t\tif Vector3.new(moving.X, 0, moving.Z).Magnitude > 0.1 then
    \t\t\t\tstats.facing = Vector3.new(moving.X, 0, moving.Z).Unit
    \t\t\tend
    \t\tend
    \tend
    \tif world.phase == "night" then
    \t\tif world.toCome > 0 and now >= world.nextSpawn and Horde.count() < setting("MaxZombies") then
    \t\t\tworld.nextSpawn = now + 0.7
    \t\t\tworld.toCome -= 1
    \t\t\tspawnOne()
    \t\tend
    \t\tlocal left = world.toCome + Horde.count()
    \t\tif Status.ZombiesLeft.Value ~= left then
    \t\t\tStatus.ZombiesLeft.Value = left
    \t\tend
    \t\tif left == 0 then
    \t\t\tstartDawn()
    \t\tend
    \telseif now >= world.endsAt and next(inRun) ~= nil then
    \t\tstartNight()
    \tend
    \tlocal countdown = math.max(0, math.ceil(world.endsAt - now))
    \tif Status.Countdown.Value ~= countdown then
    \t\tStatus.Countdown.Value = countdown
    \tend
    \t-- The keys turn and bob where they lie.
    \tfor _, entry in world.keys do
    \t\tif not entry.taken then
    \t\t\tentry.model:PivotTo(CFrame.new(entry.spot + Vector3.new(0, math.sin(now * 2) * 0.3, 0))
    \t\t\t\t* CFrame.Angles(0, now * 1.5, 0))
    \t\tend
    \tend
    \t-- Dusk to dark and back.
    \tlocal wanted = if world.phase == "night" then 22.5 else 16.5
    \tlocal clock = Lighting.ClockTime
    \tif math.abs(wanted - clock) > 0.02 then
    \t\tLighting.ClockTime = clock + (wanted - clock) * math.min(dt * 1.2, 1)
    \tend
    end

    Horde.findBlockers()
    resetWorld()
    for _, player in Players:GetPlayers() do
    \tsetUp(player)
    end
    Players.PlayerAdded:Connect(setUp)

    local waited = 0
    RunService.Heartbeat:Connect(function(dt)
    \twaited += dt
    \tif waited < 1 / 20 then
    \t\treturn
    \tend
    \tlocal step = waited
    \twaited = 0
    \ttick(step, time())
    end)
    print("Nightfall is ready. Survive the nights, find the keys, escape.")
    """

    static let ambience = """
    -- Ambience: the windmill's sails turn, the campfire flickers, and the graveyard's
    -- wisps drift.
    local RunService = game:GetService("RunService")

    local sails = workspace.Farm.Windmill.Sails
    local flames = workspace.Camp.Flames
    local fireLight = flames:FindFirstChild("PointLight")
    local wisps = {}
    for _, part in workspace.Graveyard:GetChildren() do
    \tif part.Name == "Wisp" then
    \t\ttable.insert(wisps, { part = part, home = part.Position, phase = #wisps * 1.7 })
    \tend
    end

    local flicker = 0
    RunService.Heartbeat:Connect(function(dt)
    \t-- The sails' middle is the hub, so turning them turns them round it.
    \tlocal pivot = sails:GetPivot()
    \tsails:PivotTo(CFrame.new(pivot.Position) * CFrame.Angles(0, 0, dt * 0.8))
    \tflicker += dt
    \tif flicker > 0.1 then
    \t\tflicker = 0
    \t\tif fireLight then
    \t\t\tfireLight.Brightness = 2.6 + math.random() * 0.8
    \t\tend
    \tend
    \tlocal now = time()
    \tfor _, wisp in wisps do
    \t\twisp.part.Position = wisp.home + Vector3.new(math.sin(now * 0.7 + wisp.phase) * 1.5,
    \t\t\tmath.sin(now * 1.3 + wisp.phase) * 0.5, math.cos(now * 0.6 + wisp.phase) * 1.5)
    \tend
    end)
    """

    static let sword = """
    -- SwordScript: a click swings the sword. The Horde module finds the zombies in front
    -- of you and hits them, as hard as your power-ups make it.
    local Players = game:GetService("Players")
    local ServerStorage = game:GetService("ServerStorage")
    local Horde = require(ServerStorage:WaitForChild("Horde"))
    local tool = script.Parent

    tool.Activated:Connect(function()
    \tlocal player = Players:GetPlayerFromCharacter(tool.Parent)
    \tif player then
    \t\tHorde.swing(player)
    \tend
    end)
    """

    // MARK: - Each player's screen

    static let screen = """
    -- Nightfall: each player's screen. The night and what's left of it, the keys found,
    -- the orb bar and the power-ups taken; the choice of three when one is offered
    -- (click one, or press Z, X or C); how the run went when it ends; health bars over
    -- the zombies; the screen going red when you're hurt and cold at night — on this
    -- screen only. And what the server needs from here: where the blaster points, and Q.
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local UserInputService = game:GetService("UserInputService")

    local player = Players.LocalPlayer
    local mouse = player:GetMouse()
    local Status = ReplicatedStorage:WaitForChild("Status")
    local Notify = ReplicatedStorage:WaitForChild("Notify")
    local Offer = ReplicatedStorage:WaitForChild("Offer")
    local Choose = ReplicatedStorage:WaitForChild("Choose")
    local Fire = ReplicatedStorage:WaitForChild("Fire")
    local Dash = ReplicatedStorage:WaitForChild("Dash")
    local RunOver = ReplicatedStorage:WaitForChild("RunOver")
    local run = player:WaitForChild("Run")
    local orbsValue = run:WaitForChild("Orbs")
    local neededValue = run:WaitForChild("OrbsNeeded")
    local dashValue = run:WaitForChild("Dash")
    local picksValue = run:WaitForChild("Picks")

    local GOLD = Color3.fromRGB(255, 205, 80)
    local GREEN = Color3.fromRGB(90, 255, 150)
    local WHITE = Color3.new(1, 1, 1)

    local function make(className, properties, parent)
    \tlocal object = Instance.new(className)
    \tfor key, value in properties do
    \t\tobject[key] = value
    \tend
    \tif parent then
    \t\tobject.Parent = parent
    \tend
    \treturn object
    end

    local screen = make("ScreenGui", { Name = "Nightfall", ResetOnSpawn = false })

    -- Top: the night, the keys, the orb bar.
    local top = make("Frame", {
    \tName = "Top", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
    \tSize = UDim2.fromOffset(460, 66), BackgroundTransparency = 1,
    }, screen)
    local phaseLabel = make("TextLabel", {
    \tName = "Phase", Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, TextColor3 = WHITE,
    \tTextSize = 22, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.4, Text = "",
    }, top)
    local keysLabel = make("TextLabel", {
    \tName = "Keys", Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
    \tTextColor3 = GOLD, TextSize = 14, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.5, Text = "",
    }, top)
    local bar = make("Frame", {
    \tName = "OrbBar", Position = UDim2.fromOffset(80, 54), Size = UDim2.new(1, -160, 0, 8),
    \tBackgroundColor3 = Color3.fromRGB(24, 36, 30), BackgroundTransparency = 0.2,
    }, top)
    make("UICorner", { CornerRadius = UDim.new(0, 4) }, bar)
    local fill = make("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = GREEN }, bar)
    make("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)

    -- Left: the power-ups taken this run.
    local picks = make("TextLabel", {
    \tName = "Picks", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 16, 0.45, 0),
    \tSize = UDim2.fromOffset(230, 240), BackgroundTransparency = 1, TextColor3 = Color3.fromRGB(200, 230, 210),
    \tTextSize = 13, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.5, TextWrapped = true,
    \tTextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "",
    }, screen)

    -- The choice of three.
    local chooser = make("Frame", {
    \tName = "Chooser", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.56),
    \tSize = UDim2.fromOffset(660, 196), BackgroundTransparency = 1, Visible = false,
    }, screen)
    make("TextLabel", {
    \tName = "Title", Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, TextColor3 = GOLD,
    \tTextSize = 22, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.4, Text = "Choose a power-up",
    }, chooser)
    local cards = {}
    local offered = nil
    local function choose(index)
    \tif offered and offered[index] then
    \t\tChoose:FireServer(offered[index].id)
    \t\toffered = nil
    \t\tchooser.Visible = false
    \tend
    end
    for index, key in { "Z", "X", "C" } do
    \tlocal card = make("TextButton", {
    \t\tName = "Card" .. index, Position = UDim2.fromOffset((index - 1) * 224, 38), Size = UDim2.fromOffset(212, 152),
    \t\tBackgroundColor3 = Color3.fromRGB(22, 26, 36), BackgroundTransparency = 0.08, Text = "",
    \t}, chooser)
    \tmake("UICorner", { CornerRadius = UDim.new(0, 12) }, card)
    \tmake("UIStroke", { Color = GOLD, Thickness = 2, Transparency = 0.3 }, card)
    \tmake("TextLabel", {
    \t\tName = "Heading", Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -24, 0, 24), BackgroundTransparency = 1,
    \t\tTextColor3 = GOLD, TextSize = 18, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left,
    \t}, card)
    \tmake("TextLabel", {
    \t\tName = "Body", Position = UDim2.fromOffset(12, 42), Size = UDim2.new(1, -24, 0, 70), BackgroundTransparency = 1,
    \t\tTextColor3 = WHITE, TextSize = 14, Font = Enum.Font.Gotham, TextWrapped = true,
    \t\tTextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    \t}, card)
    \tmake("TextLabel", {
    \t\tName = "Key", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -8), Size = UDim2.fromOffset(60, 20),
    \t\tBackgroundTransparency = 1, TextColor3 = Color3.fromRGB(160, 170, 190), TextSize = 13, Font = Enum.Font.GothamBold,
    \t\tTextXAlignment = Enum.TextXAlignment.Right, Text = "press " .. key,
    \t}, card)
    \tcard.MouseButton1Click:Connect(function()
    \t\tchoose(index)
    \tend)
    \tcards[index] = card
    end

    -- How the run went.
    local summary = make("Frame", {
    \tName = "RunOver", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42),
    \tSize = UDim2.fromOffset(420, 290), BackgroundColor3 = Color3.fromRGB(14, 16, 22), BackgroundTransparency = 0.1,
    \tVisible = false,
    }, screen)
    make("UICorner", { CornerRadius = UDim.new(0, 14) }, summary)
    make("UIStroke", { Color = GOLD, Thickness = 2, Transparency = 0.3 }, summary)
    local summaryTitle = make("TextLabel", {
    \tName = "Title", Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1,
    \tTextColor3 = GOLD, TextSize = 26, Font = Enum.Font.GothamBold,
    }, summary)
    local summaryLines = make("TextLabel", {
    \tName = "Lines", Position = UDim2.fromOffset(24, 62), Size = UDim2.new(1, -48, 1, -76), BackgroundTransparency = 1,
    \tTextColor3 = WHITE, TextSize = 15, Font = Enum.Font.Gotham, TextWrapped = true,
    \tTextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    }, summary)

    local banner = make("TextLabel", {
    \tName = "Banner", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 250),
    \tSize = UDim2.fromOffset(640, 40), BackgroundTransparency = 1, TextColor3 = WHITE,
    \tTextSize = 26, Font = Enum.Font.GothamBold, TextStrokeTransparency = 0.4, TextTransparency = 1,
    }, screen)

    screen.Parent = player.PlayerGui

    -- MARK: News, one at a time; an area's name only when there's no news.

    local news = {}
    local telling = false
    local lastShown = 0

    local function show(text, colour)
    \tbanner.Text = text
    \tbanner.TextColor3 = colour or WHITE
    \tbanner.TextTransparency = 0
    \tbanner.TextStrokeTransparency = 0.4
    \tlastShown = time()
    end

    local function hideLater(seconds)
    \tlocal shownAt = lastShown
    \ttask.delay(seconds, function()
    \t\tif lastShown == shownAt then
    \t\t\tbanner.TextTransparency = 1
    \t\t\tbanner.TextStrokeTransparency = 1
    \t\tend
    \tend)
    end

    local function tell(text, colour)
    \ttable.insert(news, { text = text, colour = colour })
    \tif telling then
    \t\treturn
    \tend
    \ttelling = true
    \ttask.spawn(function()
    \t\twhile #news > 0 do
    \t\t\tlocal item = table.remove(news, 1)
    \t\t\tshow(item.text, item.colour)
    \t\t\ttask.wait(2.6)
    \t\tend
    \t\ttelling = false
    \t\thideLater(0)
    \tend)
    end

    Notify.OnClientEvent:Connect(function(text)
    \ttell(text, GOLD)
    end)

    local areas = {
    \t{ name = "The Graveyard", min = Vector3.new(-128, -5, 85), max = Vector3.new(-72, 40, 135) },
    \t{ name = "The Old Town", min = Vector3.new(55, -5, 58), max = Vector3.new(160, 40, 145) },
    \t{ name = "The Dark Forest", min = Vector3.new(-180, -5, -180), max = Vector3.new(-40, 40, -40) },
    \t{ name = "The Farm", min = Vector3.new(60, -5, -140), max = Vector3.new(145, 40, -66) },
    \t{ name = "The Mine", min = Vector3.new(150, -5, -40), max = Vector3.new(190, 40, 45) },
    \t{ name = "The Ruins", min = Vector3.new(-180, -5, -20), max = Vector3.new(-140, 40, 30) },
    \t{ name = "The North Gate", min = Vector3.new(-25, -5, 170), max = Vector3.new(25, 40, 215) },
    \t{ name = "Camp", min = Vector3.new(-20, -5, -12), max = Vector3.new(20, 40, 28) },
    }
    local lastArea = nil

    local function areaAt(position)
    \tfor _, area in areas do
    \t\tif position.X >= area.min.X and position.X <= area.max.X and position.Z >= area.min.Z
    \t\t\tand position.Z <= area.max.Z then
    \t\t\treturn area.name
    \t\tend
    \tend
    \treturn nil
    end

    -- MARK: The choice of three

    Offer.OnClientEvent:Connect(function(options)
    \toffered = options
    \tfor index, card in cards do
    \t\tlocal option = options[index]
    \t\tcard.Visible = option ~= nil
    \t\tif option then
    \t\t\tcard.Heading.Text = option.name .. (if option.level > 1 then " " .. option.level else "")
    \t\t\tcard.Body.Text = option.text
    \t\tend
    \tend
    \tchooser.Visible = true
    end)

    UserInputService.InputBegan:Connect(function(input, processed)
    \tif processed then
    \t\treturn
    \tend
    \tif input.KeyCode == Enum.KeyCode.Z then
    \t\tchoose(1)
    \telseif input.KeyCode == Enum.KeyCode.X then
    \t\tchoose(2)
    \telseif input.KeyCode == Enum.KeyCode.C then
    \t\tchoose(3)
    \telseif input.KeyCode == Enum.KeyCode.Q and dashValue.Value > 0 then
    \t\tDash:FireServer()
    \tend
    end)

    -- The blaster shoots where the pointer is.
    mouse.Button1Down:Connect(function()
    \tlocal character = player.Character
    \tlocal tool = character and character:FindFirstChildOfClass("Tool")
    \tif tool and tool.Name == "Blaster" then
    \t\tFire:FireServer(mouse.Hit.Position)
    \tend
    end)

    RunOver.OnClientEvent:Connect(function(result)
    \toffered = nil
    \tchooser.Visible = false
    \tsummaryTitle.Text = if result.escaped then "You escaped!" else "You fell on night " .. result.night
    \tlocal lines = {
    \t\t"Nights lived through: " .. result.nights,
    \t\t"Zombies taken down: " .. result.kills,
    \t\t"Keys found: " .. result.keys,
    \t\t"Power-ups: " .. (if #result.picks > 0 then table.concat(result.picks, ", ") else "none"),
    \t\t"",
    \t\t"Score: " .. result.score .. (if result.record then "  (a new best!)" else "   Best: " .. result.best),
    \t}
    \tif result.top and #result.top > 0 then
    \t\tlocal names = {}
    \t\tfor _, entry in result.top do
    \t\t\ttable.insert(names, entry.name .. " " .. entry.score)
    \t\tend
    \t\ttable.insert(lines, "")
    \t\ttable.insert(lines, "Top scores: " .. table.concat(names, ", "))
    \tend
    \tsummaryLines.Text = table.concat(lines, "\\n")
    \tsummary.Visible = true
    \ttask.delay(7, function()
    \t\tsummary.Visible = false
    \tend)
    end)

    -- MARK: Health bars over the zombies

    local bars = {}

    local function barFor(zombie)
    \tlocal head = zombie:FindFirstChild("Head")
    \tlocal health = zombie:FindFirstChild("Health")
    \tlocal most = zombie:FindFirstChild("MaxHealth")
    \tif head == nil or health == nil or most == nil then
    \t\treturn nil
    \tend
    \tlocal board = make("BillboardGui", {
    \t\tAdornee = head, Size = UDim2.fromOffset(70, 8), StudsOffset = Vector3.new(0, 1.8, 0), MaxDistance = 80,
    \t}, screen)
    \tlocal back = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(40, 10, 10) }, board)
    \tlocal left = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(230, 60, 50) }, back)
    \treturn { board = board, fill = left, health = health, most = most }
    end

    -- MARK: Every little while

    local shown = { hurt = false, night = false }

    local function effect(name, on)
    \tif shown[name] == on then
    \t\treturn
    \tend
    \tshown[name] = on
    \tlocal shader = Shaders:FindFirstChild(if name == "hurt" then "Hurt" else "Night")
    \tif shader == nil then
    \t\treturn
    \tend
    \tif on then
    \t\tScreen:AddShader(shader)
    \telse
    \t\tScreen:RemoveShader(shader)
    \tend
    end

    local function refresh()
    \tlocal phase = Status.Phase.Value
    \tlocal countdown = Status.Countdown.Value
    \tlocal clock = string.format("%d:%02d", countdown // 60, countdown % 60)
    \tif phase == "night" then
    \t\tphaseLabel.Text = "NIGHT " .. Status.Night.Value .. "  —  " .. Status.ZombiesLeft.Value .. " zombies left"
    \t\tphaseLabel.TextColor3 = Color3.fromRGB(255, 120, 110)
    \telseif phase == "dawn" then
    \t\tphaseLabel.Text = "DAWN  —  night " .. (Status.Night.Value + 1) .. " in " .. clock
    \t\tphaseLabel.TextColor3 = Color3.fromRGB(255, 220, 160)
    \telse
    \t\tphaseLabel.Text = "DAY  —  night falls in " .. clock
    \t\tphaseLabel.TextColor3 = WHITE
    \tend
    \tif Status.GateOpen.Value then
    \t\tkeysLabel.Text = "The north gate is open!"
    \telse
    \t\tkeysLabel.Text = "Keys " .. Status.KeysFound.Value .. "/" .. Status.KeysNeeded.Value
    \tend
    \tlocal needed = math.max(neededValue.Value, 1)
    \tfill.Size = UDim2.fromScale(math.clamp(orbsValue.Value / needed, 0, 1), 1)
    \t-- The power-ups, counted.
    \tlocal counts, order = {}, {}
    \tfor name in string.gmatch(picksValue.Value, "[^,]+") do
    \t\tif counts[name] == nil then
    \t\t\ttable.insert(order, name)
    \t\tend
    \t\tcounts[name] = (counts[name] or 0) + 1
    \tend
    \tlocal lines = {}
    \tfor _, name in order do
    \t\ttable.insert(lines, name .. (if counts[name] > 1 then "  x" .. counts[name] else ""))
    \tend
    \tpicks.Text = table.concat(lines, "\\n")

    \tlocal character = player.Character
    \tlocal humanoid = character and character:FindFirstChildOfClass("Humanoid")
    \teffect("hurt", humanoid ~= nil and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth * 0.35)
    \teffect("night", phase == "night")

    \t-- Bars for new zombies; none for the fallen.
    \tlocal alive = {}
    \tfor _, zombie in workspace.Zombies:GetChildren() do
    \t\talive[zombie] = true
    \t\tif bars[zombie] == nil then
    \t\t\tbars[zombie] = barFor(zombie)
    \t\tend
    \t\tlocal entry = bars[zombie]
    \t\tif entry then
    \t\t\tentry.fill.Size = UDim2.fromScale(math.clamp(entry.health.Value / math.max(entry.most.Value, 1), 0, 1), 1)
    \t\tend
    \tend
    \tfor zombie, entry in bars do
    \t\tif not alive[zombie] then
    \t\t\tif entry then
    \t\t\t\tentry.board:Destroy()
    \t\t\tend
    \t\t\tbars[zombie] = nil
    \t\tend
    \tend

    \tlocal root = character and character:FindFirstChild("HumanoidRootPart")
    \tif root then
    \t\tlocal area = areaAt(root.Position)
    \t\tif area ~= lastArea then
    \t\t\tlastArea = area
    \t\t\tif area and not telling then
    \t\t\t\tshow(area, Color3.fromRGB(210, 220, 235))
    \t\t\t\thideLater(2.2)
    \t\t\tend
    \t\tend
    \tend
    end

    task.spawn(function()
    \twhile true do
    \t\trefresh()
    \t\ttask.wait(0.2)
    \tend
    end)

    task.delay(1, function()
    \ttell("Nightfall. Explore by day; survive the night. Find three keys to escape.", GOLD)
    end)
    """

    // MARK: - Shaders

    static let fireShader = """
    // Fire: flames that flicker between yellow and orange.
    float flicker = 0.75 + 0.25 * sin(time * speed * 9.0 + worldPosition.y * 3.0) * sin(time * speed * 5.3 + worldPosition.x * 2.0);
    float edge = saturate(1.0 - dot(normal, viewDirection));
    float3 hot = float3(1.0, 0.85, 0.35);
    float3 warm = float3(1.0, 0.35, 0.05);
    return mix(hot, warm, edge) * (1.1 + 0.6 * flicker);
    """

    static let keyGlowShader = """
    // KeyGlow: gold that shines as it turns.
    float shine = pow(saturate(dot(reflect(-lightDirection, normal), viewDirection)), 12.0);
    float sweep = 0.5 + 0.5 * sin(time * speed * 3.0 + (worldPosition.x + worldPosition.y) * 2.0);
    float3 gold = float3(1.0, 0.78, 0.25);
    return gold * (0.9 + 0.5 * sweep) + shine * 0.8;
    """

    static let hurtShader = """
    // Hurt: red creeping in from the edges, beating like a pulse, while health is low.
    float2 centre = uv - 0.5;
    float edge = smoothstep(0.25, 0.75, length(centre * float2(1.3, 1.0)));
    float beat = 0.6 + 0.4 * pow(abs(sin(time * 3.2)), 6.0);
    return mix(sceneColor, float3(0.75, 0.02, 0.02), saturate(edge * beat * 0.75 * amount));
    """

    static let nightShader = """
    // Night: colours drained towards a cold moonlight, darker at the edges.
    float2 centre = uv - 0.5;
    float vignette = 1.0 - smoothstep(0.35, 0.9, length(centre * float2(1.2, 1.0)));
    float luma = dot(sceneColor, float3(0.2126, 0.7152, 0.0722));
    float3 moon = mix(float3(luma), sceneColor, 0.55) * float3(0.8, 0.9, 1.15);
    return mix(sceneColor, moon * mix(0.6, 1.0, vignette), amount);
    """
}
