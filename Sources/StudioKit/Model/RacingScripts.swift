import Foundation

enum RacingScripts {
    static let rules = #"""
--!strict
-- Four real VehicleSeats, motor hinges and breakable joints. The host owns the race.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local race = RS:WaitForChild("RaceState")
local recover = RS:WaitForChild("RecoverCar")
local cars = {}
local assigned = {}
local elapsed: number = 0
local phaseTime: number = 0
local places: number = 0
local round: number = 1
local phase: string = "GRID"
local waypointCount: number = 32
local gateCount: number = 8
local maxLaps: number = 3

local function flat(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end
local function value(class, name, parent, initial)
    local object = Instance.new(class)
    object.Name = name
    object.Value = initial
    object.Parent = parent
    return object
end
local function stopCar(car, anchored)
    for _, part in car.parts do
        part.Anchored = anchored
        part.AssemblyLinearVelocity = Vector3.zero
        part.AssemblyAngularVelocity = Vector3.zero
    end
    car.seat.ThrottleFloat = 0
    car.seat.SteerFloat = 0
end
local function placeDriver(car)
    local player = car.player
    if player and player.Character then
        local root = player.Character:FindFirstChild("HumanoidRootPart")
        if root then root.Position = car.seat.Position + Vector3.new(0, 4, 0); root.AssemblyLinearVelocity = Vector3.zero end
    end
end
local function resetCar(car, wholeRace)
    local frame = car.start
    if not wholeRace then
        local gate = workspace.RaceGates:FindFirstChild("Gate" .. tostring(car.lastGate))
        local nextGate = workspace.RaceGates:FindFirstChild("Gate" .. tostring(car.lastGate % gateCount + 1))
        frame = CFrame.lookAt(gate.Position + Vector3.new(0, 2.2, 0), nextGate.Position + Vector3.new(0, 2.2, 0))
    end
    stopCar(car, true)
    for _, part in car.parts do
        part.CFrame = frame * car.offsets[part]
        part.Transparency = car.transparency[part]
        part.CanCollide = car.collision[part]
        part.CanTouch = true
    end
    for _, joint in car.joints do joint.Enabled = true end
    car.health.Value = 100
    car.body.DamageSmoke.Enabled = false
    car.body.DamageSmoke:Clear()
    car.body.CrashSparks:Clear()
    car.broken = {}
    car.damageTime = elapsed + 1
    car.previousVelocity = Vector3.zero
    car.stalled = 0
    car.grace = elapsed + 0.8
    if wholeRace then
        car.lap.Value = 1; car.next.Value = 2; car.place.Value = 0; car.lastGate = 1; car.route = 2
    else
        car.route = ((car.lastGate - 1) * 4 + 2) % waypointCount + 1
    end
    stopCar(car, phase ~= "RACING")
    placeDriver(car)
end
local function damage(car, hit)
    if phase ~= "RACING" or elapsed < car.damageTime or car.place.Value > 0 then return end
    if hit.Parent == car.model then return end
    local opponent = nil
    for _, other in cars do
        if other ~= car and hit.Parent == other.model then opponent = other; break end
    end
    if hit.Name ~= "Barrier" and opponent == nil then return end
    local otherVelocity = if opponent then opponent.previousVelocity else Vector3.zero
    local impact = (flat(car.previousVelocity) - flat(otherVelocity)).Magnitude
    if impact < 17 then return end
    car.damageTime = elapsed + 0.8
    car.health.Value = math.max(0, car.health.Value - math.clamp(math.floor(impact * 1.3), 25, 65))
    local names = {"Hood", "Bumper", "WheelFrontLeft", "WheelFrontRight"}
    local wanted = math.min(4, math.max(1, math.ceil((100 - car.health.Value) / 25)))
    for i = 1, wanted do
        local part = car.model:FindFirstChild(names[i])
        if part and car.broken[part] == nil then
            car.broken[part] = elapsed
            for _, joint in car.joints do
                if joint.Parent == part then joint.Enabled = false end
            end
            part.AssemblyLinearVelocity = car.previousVelocity + Vector3.new((i % 2 == 0 and 1 or -1) * 8, 10 + i, 2)
            part.AssemblyAngularVelocity = Vector3.new(i, 3, -2)
        end
    end
    car.body.CrashSparks:Emit(24)
    car.body.DamageSmoke.Enabled = car.health.Value <= 50
    local sound = car.body:FindFirstChild("Crash")
    if sound then sound:Play() end
    race.Message.Value = car.driver.Value .. " hit hard!  " .. tostring(car.health.Value) .. "% car health"
    -- One contact can arrive on either assembly first; apply the same impact to both.
    if opponent then damage(opponent, car.body) end
end
for i = 1, 4 do
    local model = workspace:WaitForChild("Racer" .. tostring(i))
    local body = model:WaitForChild("Body")
    local car = {model = model, body = body, seat = model.VehicleSeat, health = model.Health, lap = model.Lap,
        next = model.NextGate, place = model.Place, driver = model.Driver, parts = {}, joints = {}, offsets = {},
        transparency = {}, collision = {}, start = body.CFrame, broken = {}, previousVelocity = Vector3.zero,
        damageTime = 1, route = 2, lastGate = 1, grace = 0, stalled = 0, index = i}
    for _, object in model:GetDescendants() do
        if object:IsA("BasePart") then
            table.insert(car.parts, object)
            car.offsets[object] = body.CFrame:ToObjectSpace(object.CFrame)
            car.transparency[object] = object.Transparency
            car.collision[object] = object.CanCollide
            object.Touched:Connect(function(hit) damage(car, hit) end)
        elseif object:IsA("Constraint") or object:IsA("WeldConstraint") then
            table.insert(car.joints, object)
        end
    end
    table.insert(cars, car)
    stopCar(car, true)
end
local function addPlayer(player)
    if assigned[player] then return end
    local car = nil
    for _, candidate in cars do if candidate.player == nil then car = candidate; break end end
    if car == nil then return end
    car.player = player
    assigned[player] = car
    car.driver.Value = player.Name
    local stats = Instance.new("Folder"); stats.Name = "leaderstats"; stats.Parent = player
    car.playerLap = value("IntValue", "Lap", stats, 1)
    car.playerPlace = value("IntValue", "Place", stats, 0)
    player.CharacterAdded:Connect(function()
        task.delay(0.2, function() if assigned[player] == car then resetCar(car, false) end end)
    end)
    task.delay(0.2, function() if assigned[player] == car then resetCar(car, true) end end)
end
Players.PlayerAdded:Connect(addPlayer)
Players.PlayerRemoving:Connect(function(player)
    local car = assigned[player]
    if car then
        car.player = nil; car.playerLap = nil; car.playerPlace = nil
        car.driver.Value = "NPC " .. tostring(car.index); assigned[player] = nil; resetCar(car, false)
    end
end)
for _, player in Players:GetPlayers() do addPlayer(player) end
recover.OnServerEvent:Connect(function(player)
    local car = assigned[player]
    if car and elapsed > car.grace then resetCar(car, false) end
end)

-- The start board is a SurfaceGui carried by a real world part.
local board = Instance.new("SurfaceGui")
board.Name = "RaceBoard"; board.Adornee = workspace.StartSign; board.Face = Enum.NormalId.Back
board.CanvasSize = Vector2.new(900, 220); board.Parent = workspace.StartSign
local title = Instance.new("TextLabel")
title.Size = UDim2.fromScale(1, 1); title.BackgroundTransparency = 1; title.TextScaled = true
 title.TextColor3 = Color3.fromRGB(255, 230, 140); title.Text = "CRASH CIRCUIT"; title.Parent = board

RunService.Heartbeat:Connect(function(dt: number)
    elapsed += dt; phaseTime += dt
    if phase == "GRID" then
        race.Countdown.Value = math.max(0, math.ceil(4 - phaseTime))
        title.Text = "START IN " .. tostring(race.Countdown.Value)
        if phaseTime >= 4 then
            phase = "RACING"; phaseTime = 0; race.Countdown.Value = 0; race.Message.Value = "GO!  Three laps — follow the gold gates."
            title.Text = "GO!  3 LAPS"
            for _, car in cars do stopCar(car, false) end
            local sound = game:GetService("SoundService"):FindFirstChild("RaceGo"); if sound then sound:Play() end
        end
    elseif phase == "RACING" then
        if places == #cars or phaseTime > 180 or (places > 0 and phaseTime > 30 and places >= 3) then
            phase = "FINISHED"; phaseTime = 0; race.Message.Value = "Race over — next race in 8 seconds"; title.Text = "RACE COMPLETE"
            for _, car in cars do car.seat.ThrottleFloat = 0 end
        end
    elseif phaseTime >= 8 then
        phase = "GRID"; phaseTime = 0; places = 0; round += 1; race.Round.Value = round
        race.Message.Value = "Fresh cars. Get ready!"
        for _, car in cars do resetCar(car, true) end
    end
    race.Phase.Value = phase
    for _, car in cars do
        if phase == "RACING" and car.place.Value == 0 then
            local target = workspace.RaceGates:FindFirstChild("Gate" .. tostring(car.next.Value))
            if flat(car.body.Position - target.Position).Magnitude < 19 then
                car.lastGate = car.next.Value
                if car.next.Value == 1 then
                    car.lap.Value += 1
                    if car.lap.Value > maxLaps then
                        places += 1; car.place.Value = places; car.seat.ThrottleFloat = 0
                        race.Message.Value = car.driver.Value .. " finished #" .. tostring(places)
                    end
                end
                car.next.Value = car.next.Value % gateCount + 1
            end
            if car.playerLap then car.playerLap.Value = math.min(car.lap.Value, maxLaps); car.playerPlace.Value = car.place.Value end
            if car.player == nil and car.health.Value > 0 then
                local route = workspace.Circuit:FindFirstChild("Route" .. tostring(car.route))
                local delta = flat(route.Position - car.body.Position)
                if delta.Magnitude < 15 then car.route = car.route % waypointCount + 1 end
                if delta.Magnitude > 0.1 then
                    local forward = flat(car.body.CFrame.LookVector).Unit
                    local direction = delta.Unit
                    local turn = math.atan2(-forward:Cross(direction).Y, forward:Dot(direction))
                    car.seat.SteerFloat = math.clamp(turn * 2.0, -1, 1)
                    car.seat.MaxSpeed = if math.abs(turn) > 0.6 then 16 else 28
                    local clear = true
                    for _, other in cars do
                        if other ~= car then
                            local gap = flat(other.body.Position - car.body.Position)
                            local ahead = gap:Dot(forward)
                            if ahead > 0 and ahead < 16 and math.abs(gap:Cross(forward).Y) < 8 then clear = false end
                        end
                    end
                    car.seat.ThrottleFloat = if clear then 1 else 0
                end
                if car.body.AssemblyLinearVelocity.Magnitude < 2 then car.stalled += dt else car.stalled = 0 end
                if car.stalled > 5 then resetCar(car, false) end
            end
            if car.health.Value == 0 then
                car.seat.ThrottleFloat = 0
                if car.player == nil and elapsed > car.damageTime + 3 then resetCar(car, false) end
            end
            if car.body.Position.Y < -10 then resetCar(car, false) end
        else
            car.seat.ThrottleFloat = 0
        end
        for part, since in car.broken do
            if elapsed - since > 8 then
                part.Anchored = true; part.Transparency = 1; part.CanCollide = false; part.CanTouch = false
            end
        end
        car.previousVelocity = car.body.AssemblyLinearVelocity
    end
end)
"""#

    static let dashboard = #"""
--!strict
local player = game:GetService("Players").LocalPlayer
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local race = RS:WaitForChild("RaceState")
local recover = RS:WaitForChild("RecoverCar")
local mouse = player:GetMouse()
local screen = Instance.new("ScreenGui"); screen.Name = "RaceDashboard"; screen.ResetOnSpawn = false; screen.Parent = player.PlayerGui
local status = Instance.new("TextLabel")
status.Position = UDim2.new(0.5, -270, 0, 18); status.Size = UDim2.fromOffset(540, 62)
status.BackgroundColor3 = Color3.fromRGB(12, 20, 32); status.BackgroundTransparency = 0.12
status.TextColor3 = Color3.fromRGB(255, 230, 155); status.TextSize = 23; status.Parent = screen
local news = Instance.new("TextLabel")
news.Position = UDim2.new(0.5, -300, 0, 83); news.Size = UDim2.fromOffset(600, 28); news.BackgroundTransparency = 1
news.TextColor3 = Color3.new(1, 1, 1); news.TextSize = 15; news.Parent = screen
local reset = Instance.new("TextButton")
reset.Position = UDim2.new(1, -220, 1, -66); reset.Size = UDim2.fromOffset(202, 44)
reset.BackgroundColor3 = Color3.fromRGB(220, 74, 37); reset.TextColor3 = Color3.new(1, 1, 1)
reset.TextSize = 18; reset.Text = "Recover car [T]"; reset.Parent = screen
reset.MouseButton1Click:Connect(function() recover:FireServer() end)
UIS.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.T then recover:FireServer() end
end)
local help = Instance.new("TextLabel")
help.Position = UDim2.new(0, 18, 1, -90); help.Size = UDim2.fromOffset(620, 72); help.BackgroundTransparency = 0.3
help.BackgroundColor3 = Color3.fromRGB(12, 20, 32); help.TextWrapped = true
help.TextColor3 = Color3.new(1, 1, 1); help.TextSize = 15; help.TextXAlignment = Enum.TextXAlignment.Left
help.Text = "W / S  drive & brake    A / D  steer\nSpace  leave seat    T  recover    Click a rival to inspect\nRight-drag  look    Scroll  zoom    /  chat    Tab  standings"; help.Parent = screen
local preview = Instance.new("ViewportFrame")
preview.Name = "CarPreview"; preview.Position = UDim2.new(1, -190, 0, 110); preview.Size = UDim2.fromOffset(170, 126)
preview.BackgroundColor3 = Color3.fromRGB(16, 25, 39); preview.Parent = screen
local world = Instance.new("Model"); world.Parent = preview
local camera = Instance.new("Camera"); camera.CFrame = CFrame.lookAt(Vector3.new(12, 8, 14), Vector3.new(0, 2, 0)); camera.FieldOfView = 42; camera.Parent = preview; preview.CurrentCamera = camera
local body = Instance.new("Part"); body.Name = "PreviewBody"; body.Size = Vector3.new(6, 1, 10); body.Position = Vector3.new(0, 2, 0); body.Anchored = true; body.Parent = world
for _, x in {-3.5, 3.5} do
    for _, z in {-3.3, 3.3} do
        local wheel = Instance.new("Part"); wheel.Shape = Enum.PartType.Cylinder; wheel.Size = Vector3.new(3, 1, 3)
        wheel.CFrame = CFrame.new(x, 1.5, z) * CFrame.Angles(0, 0, math.pi / 2); wheel.Color = Color3.fromRGB(25, 25, 29); wheel.Anchored = true; wheel.Parent = world
    end
end
local caption = Instance.new("TextLabel"); caption.Position = UDim2.new(1, -210, 0, 240); caption.Size = UDim2.fromOffset(210, 25)
caption.BackgroundTransparency = 1; caption.TextColor3 = Color3.new(1, 1, 1); caption.TextSize = 13; caption.Parent = screen
local mine = nil
local inspected = nil
mouse.Button1Down:Connect(function()
    local target = mouse.Target
    if target then
        for i = 1, 4 do
            local car = workspace:FindFirstChild("Racer" .. tostring(i))
            if car and target.Parent == car then inspected = car end
        end
    end
end)
RunService.Heartbeat:Connect(function()
    if mine == nil then
        for i = 1, 4 do
            local car = workspace:FindFirstChild("Racer" .. tostring(i))
            if car and car.Driver.Value == player.Name then mine = car; mouse.TargetFilter = car end
        end
    end
    local target = mouse.Target
    local rival = false
    if target then
        for i = 1, 4 do
            local car = workspace:FindFirstChild("Racer" .. tostring(i))
            if car and target.Parent == car then rival = true end
        end
    end
    mouse.Icon = if rival then "builtin://hand" else ""
    local phase = race.Phase.Value
    if phase == "GRID" then status.Text = "START IN  " .. tostring(race.Countdown.Value)
    elseif mine then
        if mine.Place.Value > 0 then status.Text = "FINISHED #" .. tostring(mine.Place.Value) .. "  •  well driven!"
        else status.Text = "LAP " .. tostring(math.min(mine.Lap.Value, 3)) .. " / 3   •   CAR " .. tostring(mine.Health.Value) .. "%   •   " .. tostring(math.floor(mine.Body.AssemblyLinearVelocity.Magnitude)) .. " studs/s" end
    else status.Text = "CRASH CIRCUIT  •  SPECTATING" end
    news.Text = race.Message.Value
    local shown = inspected or mine
    if shown then body.Color = shown.Body.Color; caption.Text = shown.Driver.Value .. "  •  " .. tostring(shown.Health.Value) .. "%" end
end)
"""#
}
