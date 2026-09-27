# Studio — a Roblox-Studio-style 3D workspace

Two native macOS apps in Swift + Metal, sharing one library:

* **Studio** — the editor. Parts live in a Workspace, you pick them in the viewport
  or the Explorer tree, and drag gizmos to change position, rotation and size.
* **Studio Client** — the player. Loads a scene and drops you into it as a walking,
  jumping character so you can explore what you built.

The editor also has a **Play** button that runs the client inside its own viewport,
and a **Client** button that launches the standalone client on the current scene.
Parts can carry **Luau scripts** — Roblox's own language and API style — that run
while you play. **Wren** is supported alongside it as a second language.

## Build & run

```bash
./make_app.sh release   # produces Studio.app and StudioClient.app
open Studio.app
open StudioClient.app
```

Or run straight from SwiftPM:

```bash
swift run StudioApp
swift run StudioClient path/to/Scene.json   # the path is optional
```

There is no Xcode dependency: the Metal shaders are compiled at runtime from
`Sources/StudioKit/Render/Shaders.swift`, and Luau, Wren and Jolt are built from
vendored sources, so Command Line Tools alone are enough. (It builds cleanly with
Xcode 27 and Swift 6.4 as well.)

## Running the zipped builds

`Studio.app.zip` and `StudioClient.app.zip` are ad-hoc signed, not notarised, so on
another Mac macOS will refuse them on a double-click. Either right-click the app and
choose **Open** once, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine Studio.app StudioClient.app
```

Both are arm64 and need macOS 13 or later. Keep them in the same folder — the
editor's **Client** button looks for the client next to itself.

## Self-tests

```bash
swift run StudioApp --selftest
```

2756 headless checks covering shader compilation, uniform struct layout, mesh winding,
camera rays, picking, all three gizmo drags, undo, saving and reopening, model
export, both scripting languages end to end (every call in the Luau library, the
scheduler, the watchdog, the sandbox, Wren's modules, and both together in one
scene), the Luau, Wren and Metal lexers and completion engines, script-editor caret
and input handling, the render loop, surface and full-screen shaders (rendered on
the GPU and read back), collision, the player camera and the character controller,
the screen GUI and chat, pictures and sounds (through a recorder, so nothing plays
aloud), MeshParts and their collision, what characters wear, modules, remotes, raycasts and leaderstats, NPCs, the sample game, and two clients playing together over loopback.

`--only <suite>` runs one suite (Adventure, Remotes, Wardrobe, Mesh, Audio, Hud, LAN,
Gui, Player or Script) while you work on it; the whole suite still has to pass.

## The home page

Studio opens on its **home page**; **File › Home** (⇧⌘H) brings it back at any time,
with a button to go back to the place you were in.

- **New place**: start from a template. **Baseplate** (a big grey baseplate and a spawn
  pad), **Obby** (jumps, kill bricks, checkpoints and a finish, with the script that runs
  them and a Wins leaderboard), **Starter Scene** (parts, a script, shaders and an
  animation to learn from) or **Empty**. Each opens as a new, untitled place with the
  default HUD and the Utils module.
- **Sample games**: Adventure Island, Nightfall and Mega Obby, to play or take apart.
- **Recent**: the places you've opened or saved, newest first, with a picture of each.
  Right-click one to show it in Finder, or **Clear Recents**. **Open…** finds any other.

The pictures are drawn off screen from the places themselves; a saved place's is kept in
`~/Library/Caches/Studio/Thumbnails` and drawn again only when the file changes.
`swift run StudioApp --render-home home.png [empty]` draws the page without a window.

## The sample game: Adventure Island

A small open world made entirely of what Studio has: parts, Models, Luau scripts,
surface and screen shaders, remotes, leaderstats and a GUI. It's the first game on
**Studio Client's game picker** (and File › Load Adventure Island). In Studio,
**File › Open Adventure Island (Sample Game)** loads it for editing: every part, script
and shader is in the Explorer to read, change or borrow.

Walk out from the fountain in the plaza; paths lead everywhere.

| Area | What's there |
| --- | --- |
| **Spawn Plaza** | the fountain, benches, and Guide Pip, who explains the rest |
| **The Village** (north) | four houses, a market stall and a well; Baker Bo trades 3 gems for a crown, Old Mara tells stories |
| **Obby Tower** (west) | stepping stones over lava, a moving platform, a spinning bar, a truss to climb, tiles that fall away, a jump pad and a trophy at the top. Three checkpoints; the trophy counts a win, shows your time and gives a party hat |
| **Mirror Lab** (east) | angled mirrors, a chrome orb and glass pillars. Click the lever to switch the island between ray-traced and ordinary lighting and watch the reflections and shadows change; the button beside it changes the lamps' colours |
| **Crystal Caves** (south) | glowing crystals (a surface shader) and a blue screen glow while you're inside |
| **Dream Garden** (north-west) | rainbow mushrooms to climb and floating islands, with a dreamy screen effect |
| **The Lake** (north-east) | swim (the screen goes underwater), a pier and an islet with a palm |
| **Lighthouse Hill** (south-east) | climb the ladder to the gallery; the beam turns |
| **Whispering Woods** | trees and rocks between it all |

Five gems are hidden around the island (they come back after 30 seconds). Gems and
Wins show on the leaderboard, and are saved with your rewards for next time (see
[DataStores](#saving-progress-datastores)). Eight people live there; walk up to one and press **E**
to talk, then **1**, **2** or **3** to answer. They turn to face you as you pass.
Postie Pat walks the village round with the post, stopping at each door. Golden arrows
(Beams) run along the paths from the plaza to the Obby Tower and the Mirror Lab.

How it's made, script by script:

- **Dialogue** and **Zones** (ModuleScripts in ReplicatedStorage): the conversations as
  plain tables, and the areas as boxes. Both the host and each player require them.
- **GameScript** (Script Service): leaderstats, gems, the baker's trade (a
  RemoteFunction), rewards worn again after respawning (a BindableEvent from the obby).
- **ObbyScript**, **LabScript**, **NPCBrain** and **Ambience**: the obstacles, the lever
  (it sets `Lighting.Technology`), NPCs turning, and everything that bobs or spins
  (the fountain's orb, with a ParticleEmitter of magic).
- **PostRound** (inside Postie Pat, a Rig with a Humanoid): his walk, one
  `Humanoid:MoveTo` and `MoveToFinished:Wait()` per stop. See [NPCs](#npcs-a-model-with-a-humanoid).
- **Adventure** (a LocalScript in StarterPlayer): the talk prompt and dialogue panel,
  news banners (a RemoteEvent), name tags and signs (BillboardGuis), and the screen
  effect for the area you're in.

It works in network games too: each player has their own conversations and screen
effects, and gems, wins and the lab's lighting are shared.

For a picture without opening a window: `swift run StudioApp --render-adventure out.png
[overview|plaza|village|obby|lab|caves|garden|lake|lighthouse] [ray]`, and
`--make-adventure Island.json` writes it as a scene file.

## The second sample game: Nightfall

A roguelike. Open it from the home page, **File › Open Nightfall (Sample Game)** in
Studio, or **File › Load Nightfall** in the client.

You wake at a campfire in a walled valley. By day, explore:

- the **old town**, where the **armory** holds a blaster;
- the **graveyard** and its crypt;
- the **dark forest**, with a cabin and a watchtower;
- the **farm**, with its barn and windmill;
- the **mine** and the **ruins**.

When night falls the zombies come, more of them each night, faster and tougher:

- **Walkers**;
- **Runners**, from night 2;
- **Brutes**, from night 3.

Fight with the **sword** you start with (**1**, then click) and the **blaster** from
the armory (**2**, then click where you want to shoot).

Zombies drop green **orbs**. Fill the bar at the top and, at every dawn, you choose
one of three **power-ups** (click one, or press **Z**, **X** or **C**). There are 14,
and they stack for the rest of the run:

- faster feet and higher jumps;
- a harder, wider or quicker sword;
- a harder or faster blaster;
- more health, healing on every kill, thorns and lucky double hits;
- a magnet for orbs;
- a **Q** dash.

Three **keys** are hidden in new places every run: on the water tower, in the crypt,
up the watchtower… Find them all and the **north gate** opens. Walk through it and
you've escaped.

Your run ends when you escape or fall. You see how it went (nights, kills, keys,
power-ups, score, and the top five scores), your best score goes on the leaderboard
and is saved for next time, and a new run starts from nothing.

It's co-op on a network game:

- the nights, the zombies and the keys are shared;
- each player's power-ups, orbs, blaster and score are their own;
- the world starts again when everyone's run has ended.

How it's made:

- **GameScript** (Script Service) runs the days and nights, the keys and the gate,
  orbs, power-up offers and runs.
- **Horde** and **Upgrades** are ModuleScripts in ServerStorage:
  - Horde moves the zombies, walking them round walls and trees, and does the sword,
    the blaster and the dash;
  - Upgrades holds the power-ups.
- The **Sword** in StarterPack has a script that calls `Horde.swing`.
- The **Nightfall** LocalScript is each player's screen. It also sends the blaster's
  aim and Q to the server, and switches the Hurt and Night screen effects on that
  screen only.
- **ServerStorage.Settings** holds the numbers to tune it by: DayLength, DawnLength,
  FirstNight, MorePerNight, MaxZombies, KeysNeeded.
- The scripts use **Utils** throughout.

`swift run StudioApp --render-nightfall out.png
[overview|camp|town|graveyard|forest|farm|mine|gate|night] [ray]` draws it without a
window.

## The third sample game: Mega Obby

Sixty stages in six worlds of ten, each world harder than the last: **Grassy
Meadows**, **Lava Caves**, **Frozen Peaks**, **Candy Land**, **Neon City** and the
**Sky Kingdom**. Open it from the home page, **File › Open Mega Obby (Sample Game)**
in Studio, or **File › Load Mega Obby** in the client.

The obstacles:

- jumps, zigzags, pillars, ledges and drop-downs;
- narrow beams, some with bumps to hop over;
- fading tiles, which give way just after you step on them;
- walls of kill bricks with gaps (and, later, low ones to jump);
- truss climbs;
- spinners with one or two bars, a red sweep (a Trail) behind each tip;
- moving platforms, and kill blocks sweeping across the path;
- jump pads.

Each stage ends at a **checkpoint** with its number over it. Fall, or touch anything
red, and you're back at your last one.

- **The screen:** your stage and world, a progress bar, your time and your deaths.
- **The leaderboard:** your furthest Stage, and your Wins. Both are saved: next time
  you start at your furthest checkpoint.
- **Q** and **E** (or the arrows at the bottom) take you back and forth between
  stages you've reached, and **R** takes you back to your checkpoint.
- **The finish** after stage 60 is a Win, with your time.

Every stage is checked to be possible: its gaps and climbs are measured against how
far the character really jumps.

What the obstacles do comes from their **part names**, in the **Mechanics** script:

- **KillBrick** and **KillFloor** knock you out.
- A **Mover** slides back and forth by its **Offset** (a Vector3Value) over its
  **Seconds**. A **KillMover** does the same and knocks you out.
- A **Spinner** turns at its **Speed** (degrees a second) and knocks you out.
- A **FadeTile** gives way when stepped on.
- A **JumpPad** throws you up at its **Power**.

So a stage you build in Studio works just by naming its parts. Give a new checkpoint
an IntValue called **Stage** and **ObbyGame** takes it in. **ObbyScreen** is the
LocalScript that draws the screen.

`swift run StudioApp --render-obby out.png [start|world2|…|world6|finish] [ray]` draws it.

## The player character

The player works the way it does in Roblox: the character has a **Humanoid**, and
**scripts** drive it. Nothing in the engine reads WASD — the default `ControlScript`
does, and calls `humanoid:Move(...)` every frame.

In the Explorer, **StarterPlayer** holds:

- **its settings** (click it): the template every character starts from — WalkSpeed,
  JumpPower or JumpHeight, MaxHealth, MaxSlopeAngle, AutoRotate, six body colours,
  what characters wear (see *What characters wear*), camera mode and zoom limits,
  respawn time. Saved with the scene.
- **StarterPlayerScripts**: run once, for the player. Holds the default
  `ControlScript` (movement, jump, Shift sprint) and `ChatScript`
  (the chat window, see *Screen GUI and chat*).
- **StarterCharacterScripts**: run again for every new character, with `script.Parent`
  as the character. Holds the default `Health` (regeneration).

Defaults are shown greyed out. Click one to read it; **Edit a Copy** makes an editable
script of the same name that replaces it; **Turn Off** replaces it with a disabled one
(no ControlScript = no movement until your own script moves the Humanoid). When a
character respawns, everything its scripts started — connections, waits, loops — is
stopped, as in Roblox.

```lua
-- StarterCharacterScripts/LowGravityRunner
local humanoid = script.Parent:WaitForChild("Humanoid")
humanoid.WalkSpeed = 24
humanoid.JumpPower = 80

humanoid.Died:Connect(function()
	print("Oof")
end)

humanoid.StateChanged:Connect(function(old, new)
	if new == Enum.HumanoidStateType.Landed then
		script.Parent.Torso.Color = Color3.fromHSV(math.random(), 0.6, 0.9)
	end
end)
```

### What characters wear

A character can wear a **face**, a **shirt** and **pants**, and up to ten
**accessories** — hats, hair, glasses, a scarf, a backpack, a cape and so on. They
come from two places:

- **The player**, in the client's **Character** screen: colours, a face, a shirt,
  pants and accessories from the built-in catalog, on a 3D preview you can drag round.
  It's kept between launches, and other players in a network game see it.
- **The place**, in Studio: click **StarterPlayer** and use its **Avatar** section.
  As well as the built-in things, a place can use its own imported pictures (faces,
  shirts, pants) and 3D models (accessories — set where each goes, its colour, picture,
  offset, rotation and scale). The place's face, shirt and pants replace the player's
  where it sets them, and its accessories are added to theirs. Untick **Players wear
  their own look too** to dress everyone the same.

Shirts and pants are pictures on Roblox's classic **clothing template** (585 × 559), so
real Roblox shirt and pants templates work as they are. Where a picture is clear, the
body colour shows through (the built-in shorts stop at the knee).

The built-in catalog, as scripts name it:

| Kind | Items (`builtin://…`) |
| --- | --- |
| Accessories | `TopHat`, `Cap`, `Crown`, `PartyHat`, `Beanie`, `ShortHair`, `Glasses`, `Scarf`, `Medal`, `Backpack`, `Cape`, `Belt` |
| Faces | `Smile` (the classic), `Grin`, `Wink`, `Surprised`, `Cool`, `Sleepy`, `Happy`, `Angry`, `None` |
| Shirts | `Tee`, `StripedTee`, `Hoodie`, `Plaid`, `Suit`, `Sweater` |
| Pants | `Jeans`, `BlackPants`, `Shorts`, `SuitPants`, `Joggers` |

Scripts dress characters the Roblox way:

```lua
-- StarterCharacterScripts/PartyTime
local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")

local hat = Instance.new("Accessory")
hat.Name = "PartyHat"
hat.MeshId = "builtin://PartyHat"      -- or "studio://MyHat", an imported model
hat.Color = Color3.fromRGB(80, 200, 255)
humanoid:AddAccessory(hat)              -- or hat.Parent = character

local shirt = Instance.new("Shirt")
shirt.ShirtTemplate = "studio://TeamShirt"
shirt.Parent = character
character.Head.face.Texture = "builtin://Grin"

-- A whole look at once:
local outfit = Instance.new("HumanoidDescription")
outfit.HatAccessory = "builtin://Crown"
outfit.Shirt = "builtin://Suit"
outfit.TorsoColor = Color3.new(0.1, 0.1, 0.1)
humanoid:ApplyDescription(outfit)
```

`Accessory` has `Name`, `AccessoryType` (`Enum.AccessoryType`: Hat, Hair, Face, Neck,
Shoulder, Front, Back, Waist), `MeshId`, `TextureID`, `Color`, and — in place of a
Handle and its attachment — `Offset`, `Rotation` (degrees) and `Scale`. A built-in
`MeshId` brings its own type and colour. The character's `GetChildren`,
`FindFirstChild` and `FindFirstChildOfClass` see its accessories, `Shirt` and `Pants`;
the Humanoid has `AddAccessory`, `GetAccessories`, `RemoveAccessories`,
`GetAppliedDescription` and `ApplyDescription`. A host script dressing a joined player
works too. Luau only.

### Lighting

Click **Lighting** in the Explorer (the sun or moon, with the time beside it). It has two
technologies:

- **Conventional** — the sun casts soft shadows from a shadow map; parts can hold point
  lights; fog and a sky that follows the time of day. Fast on any Mac.
- **Ray Traced** — the GPU traces rays for each pixel: soft shadows whose edges blur
  with distance, shadows from point lights, **ambient occlusion** (corners and gaps
  darken) and **reflections** on metal and plastic that show the parts around them.
  **Quality** sets how many rays (more rays, less grain). Needs a Mac whose GPU can
  ray trace; others fall back to conventional, and say so.

Both share the rest of the settings, named as in Roblox: **ClockTime** (the sun rises
at 6, sets at 18; the moon lights the night), GeographicLatitude, Brightness,
ExposureCompensation, Ambient, OutdoorAmbient, ColorShift_Top, GlobalShadows,
ShadowSoftness, FogColor/FogStart/FogEnd, and the Sky. They save with the scene.

A part gets a **PointLight** from its Properties (Light › PointLight): colour,
brightness, range, and — ray traced — shadows. The starter scene's orb has one.

```lua
local Lighting = game:GetService("Lighting")
game:GetService("RunService").Heartbeat:Connect(function(dt)
	Lighting.ClockTime += dt * 0.5          -- a day every 48 seconds
end)

local lamp = Instance.new("PointLight", workspace.Tower)
lamp.Color = Color3.fromRGB(255, 180, 90)
lamp.Range = 16
```

Scripts can set every Lighting property (including `Technology =
Enum.Technology.RayTraced`), plus `TimeOfDay`, `GetSunDirection()` and
`Get/SetMinutesAfterMidnight`.

`swift run StudioApp --render-scene out.png raytraced 17.5` renders the starter scene
with either technology at any time of day.

### Sky, Atmosphere and Clouds

Lighting can hold three more things. Right-click **Lighting** in the Explorer to add
them, or tick them in its Properties.

- **Sky:** how big the sun and moon are (`SunAngularSize`, `MoonAngularSize`),
  whether they show at all (`CelestialBodiesShown`), and how many stars come out at
  night (`StarCount`, up to 5000). Give it six imported pictures (`SkyboxFt`, looking
  north, `SkyboxRt` east, and `Bk`, `Lf`, `Up`, `Dn`) and they wrap round the world in
  place of the sky. A place with no Sky still has a sun, a moon and 3000 stars.
- **Atmosphere:** air that far things fade into, and that hazes the horizon. `Density`
  is how thick it is. `Offset` is how much of it lies between you and the sky. It's
  tinted `Color` towards the sun and `Decay` away from it. `Glare` puts a glow round
  the sun, and `Haze` sets how high up the sky the haze reaches.
- **Clouds:** a drifting layer across the sky, with `Cover` (how much sky), `Density`
  and `Color`.

Scripts make and change them the Roblox way: `Instance.new("Atmosphere", Lighting)`,
`Lighting.Sky.StarCount = 5000`, `Lighting:FindFirstChildOfClass("Clouds")`. A host's
reach every joined player. Unlike Roblox, Clouds go in Lighting rather than
Terrain. Adventure Island and Mega Obby have clouds; Nightfall's nights are starry.

```lua
-- A Script: a day every four minutes, with fog rolling in at dusk and clearing by morning.
local Lighting = game:GetService("Lighting")
local air = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere", Lighting)

game:GetService("RunService").Heartbeat:Connect(function(dt)
	Lighting.ClockTime = (Lighting.ClockTime + dt / 10) % 24
	local night = Lighting.ClockTime < 6 or Lighting.ClockTime > 18
	air.Density = if night then 0.6 else 0.3
end)
```

`swift run StudioApp --render-sky out.png clouds|atmosphere|night|skybox` draws each.

### Custom animations

Make your own animations in Studio and play them from scripts, as in Roblox.

**Making one.** In the Explorer, **Animations** holds them (the starter scene has a
**Wave** example); right-click it for **New Animation**. Selecting one opens the
**Animation** tab, and a rig appears in the viewport:

- **Click a body part on the rig** to select its joint, and **drag** to pose it — up and
  down swings it forward and back, left and right raises it sideways, **⌥-drag** twists
  it. Posing sets a key at the playhead.
- The **timeline** has a row per joint (RootJoint, Neck, shoulders, hips) and a row of
  markers. Click or drag to move the playhead; drag a ◆ key to move it in time;
  right-click a key to delete it or change its easing.
- The **inspector** edits the selected joint exactly — X/Y/Z in degrees, the root's
  offset in studs — and its key's **easing** (Linear, Constant, Cubic, Elastic,
  Bounce). **Mirror** copies one arm or leg to the other side, flipped.
- The toolbar previews it (▶), and sets its **length**, **Looped**, **priority** and
  1/30 s **snapping**. Everything is undoable and saved with the scene.

**Playing one.**

```lua
-- StarterCharacterScripts: wave when E is pressed
local humanoid = script.Parent:WaitForChild("Humanoid")
local animator = humanoid:WaitForChild("Animator")
local wave = animator:LoadAnimation(Animations.Wave)

wave:GetMarkerReachedSignal("Hello"):Connect(function()
	print("Hello!")
end)

game:GetService("UserInputService").InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.E then
		wave:Play()
	end
end)
```

An AnimationTrack has `:Play(fadeTime, weight, speed)`, `:Stop(fadeTime)`,
`:AdjustSpeed`, `:AdjustWeight`, `:GetMarkerReachedSignal(name)`, `IsPlaying`,
`Length`, `Looped`, `Speed`, `TimePosition`, `Priority`, and `Stopped`, `DidLoop` and
`KeyframeReached`. `humanoid:LoadAnimation` works too, as does
`Instance.new("Animation")` with `AnimationId` set to an animation's name. A track
moves only the joints its animation keys, so a wave plays over the walk; where two
tracks key the same joint, the higher **priority** wins (the built-in walk, jump and
fall are below all of them). Tracks belong to one character and stop at respawn.

### Touching the world

When the character touches a part, the part's `Touched` fires with the body part that
touched it (`Left Leg`, `Torso`, …), whose `Parent` is the character — so the usual
Roblox patterns work unchanged:

```lua
-- A kill brick
script.Parent.Touched:Connect(function(hit)
	local humanoid = hit.Parent:FindFirstChild("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end
end)
```

```lua
-- A coin: set CanCollide off so the player walks through it
local coin = script.Parent
coin.Touched:Connect(function(hit)
	if game:GetService("Players"):GetPlayerFromCharacter(hit.Parent) then
		coin:Destroy()
	end
end)
```

Each body part touches separately, so standing on a pad fires `Touched` twice (both
legs), once each — not every frame — and `TouchEnded` when they leave. Standing on or
leaning against a part counts. The Humanoid's `Touched` reports every touch in one
place, and each body part has its own `Touched` too. **CanCollide** off makes a part
something the player (and the camera) passes through — trigger zones, pickups, doors;
**CanTouch** off silences its events. Both are in the Properties panel. Once a
handler destroys a part, no later touch events for it are delivered. A dead character
touches nothing.

### Seats, trusses, water and moving platforms

- **Seats:** tick **Seat** on a part (or `Instance.new("Seat")`) and a character touching
  it sits down, legs out, until **Space**. Scripts get `seat.Occupant` (the Humanoid),
  `seat.Disabled`, `humanoid.Sit` (set it false to stand), `humanoid.SeatPart` and
  `humanoid.Seated:Connect(function(active, seatPart) … end)`.
- **Trusses:** Insert › **Truss** makes a TrussPart; walk into it to climb (forward goes
  up, back goes down, nothing holds on), **Space** jumps off, and climbing past the top
  steps onto it.
- **Water:** give a part the **Water** material and it's something to swim in, not stand
  on: characters float with their heads out, **Space** swims up, and they walk out onto
  land. (Parts don't float yet.)
- **Moving platforms and knocks:** a part moved by a script, a tween or physics carries
  whoever stands on it, turning them as it turns; a moving wall pushes them along; a
  crate thrown at them knocks them back, harder the heavier it is.

The Humanoid's states include `Seated`, `Climbing` and `Swimming`, each with its own
animation, and other players see them. In a network game a joined player pushes crates
as hard as the host does.

## Models, Folders and physics

**The Explorer is a tree.** Select parts and press **⌘G** (or the ribbon's **Group**)
to put them in a **Model**; **⌥⌘G** makes a **Folder**; **⇧⌘U** ungroups. Drag
anything onto a Model, Folder or part to move it inside, or onto *Workspace* to take
it out; scripts can be dragged onto what they belong to. Clicking a part in the
viewport selects its Model, as in Roblox Studio — **⌥-click** selects the part itself —
and a selected Model moves, rotates and scales as one. Its Properties show its
**PrimaryPart** (its pivot) and pivot position. Duplicating or deleting a Model takes
everything inside with it, and saved model files keep the whole tree.

**Welds and joints.** Pick **Weld** (on the Home or Physics tab, or **⌘J**), then click
one part and another: they are welded, and the tool stays armed for the next pair.
The first part you click is outlined in green; click it again, or empty space, to let
go of it, and press **Esc** to put the tool away. Welded parts become one rigid
assembly, and anchoring any one of them holds them all. The **Physics** tab has the
same click-two-parts tool for each joint — a **hinge** (⇧⌘J, with limits, a motor or a
servo), a **ball socket**, a **rope**, a **spring** and a **prismatic** slider.

To weld a whole brick wall at once, select all of it and pick **Weld**: with
*Join the whole selection when a tool is picked* ticked (the default, on the Physics
tab) the selection is welded into one assembly on the spot, as one undo step. Untick it
and picking a tool always waits for two clicks; **Weld All** (⌥⌘J) still welds the
selection either way, and **Unjoin** (⌃⌘J) removes every weld and joint on the
selected parts.

Each joint gets an **Attachment** on each part, which appear in the Explorer under
their parts; select one to move it or turn its axis, which is what a hinge turns about
and a slider slides along. Joints are drawn in the viewport so you can see what is
connected.

```lua
-- A powered wheel
local hinge = workspace.Car.Wheel.HingeConstraint
hinge.ActuatorType = Enum.ActuatorType.Motor
hinge.AngularVelocity = 12          -- radians a second
hinge.MotorMaxTorque = 500000
print(hinge.CurrentAngle)

-- A door that swings shut
local door = workspace.Door.HingeConstraint
door.ActuatorType = Enum.ActuatorType.Servo
door.TargetAngle = 0
door.AngularSpeed = 2
```

`swift run StudioApp --render-car out.png 1.6` builds a car — a welded body on four
motorised hinges — drives it, and renders it.

**Unanchored parts obey physics** when you press Play, simulated by
[Jolt Physics](https://github.com/jrouwe/JoltPhysics): they fall, land, stack, slide,
roll, bounce a little and knock each other over. Heavier materials weigh more (metal is
eleven times plastic). Walking into a part pushes it — a crate slides, a metal block
barely moves — and parts dropped on the player land on them. `CanCollide` off lets a
part fall through everything; parts that fall below −500 are destroyed. Stopping play
puts everything back.

```lua
local ball = workspace.Ball
ball.AssemblyLinearVelocity = Vector3.new(0, 80, 0)     -- throw it up
ball:ApplyImpulse(Vector3.new(ball.Mass * 30, 0, 0))    -- shove it sideways
ball.Touched:Connect(function(other) print("hit", other.Name) end)

local car = workspace.Car
car:PivotTo(car:GetPivot() * CFrame.Angles(0, math.rad(90), 0))   -- turn a whole Model
```

`swift run StudioApp --render-physics out.png 0.9` knocks a pyramid of crates over with a
ball and renders the result.

### Pushes, pulls and passing through

Three more constraints, on the Physics tab, act on unanchored parts:

- **AlignPosition** pulls Attachment0's part to Attachment1, or to `Position` when
  `Mode` is `OneAttachment`. It holds the part there against gravity. `MaxForce` caps
  how hard it pulls, `MaxVelocity` how fast it goes, and `Responsiveness` how quickly
  it closes the gap. `RigidityEnabled` sends it straight there. Use the **Align
  Position** tool: click the part to move, then where it goes.
- **VectorForce** pushes its part with a `Force` all the time, in the world's
  directions or its attachment's (`RelativeTo`). Off the middle, unless
  `ApplyAtCenterOfMass`, it turns the part too. **VectorForce** on the Physics tab (or a
  part's right-click menu) adds one pushing up as hard as the part weighs, so it floats.
- **NoCollisionConstraint** lets two parts pass through each other. Everything else still
  collides with them. Use the **No Collision** tool.

```lua
-- A Script: a lift that floats up to the ledge and back, passing through the Ghost.
local lift = workspace.Lift
local align = Instance.new("AlignPosition")
align.Attachment0 = Instance.new("Attachment", lift)
align.Mode = Enum.PositionAlignmentMode.OneAttachment
align.MaxForce = 1e6
align.MaxVelocity = 8
align.Parent = lift

local apart = Instance.new("NoCollisionConstraint")
apart.Part0 = lift
apart.Part1 = workspace.Ghost
apart.Parent = lift

local low, high = lift.Position, lift.Position + Vector3.new(0, 20, 0)
while true do
	align.Position = high
	task.wait(4)
	align.Position = low
	task.wait(4)
end
```

## Controls

| Action | Input |
| --- | --- |
| Select | left-click a part (⇧ or ⌘ click to add/remove); clicking empty space selects nothing |
| Deselect everything | `Esc`, wherever the keyboard is — parts, GUI objects, Sounds, scripts, joints, Lighting, and a weld or joint tool (`⇧⌘D` too) |
| Orbit | right-drag, or left-drag empty space |
| Pan | ⇧ right-drag, or middle-drag |
| Zoom | scroll / pinch |
| Fly | hold right mouse + `W A S D` (`Q`/`E` down/up, `⇧` faster) |
| Focus selection | `F` |
| Tool | `1` select · `2` move · `3` scale · `4` rotate · `Esc` puts a weld or joint tool away |
| Toggle grid / local space / snap | `G` / `L` / `T` |
| Group as Model · as Folder · Ungroup | `⌘G` · `⌥⌘G` · `⇧⌘U` |
| Open a script or shader | double-click it in the Explorer |
| Cut · Copy · Paste (code and text fields) | `⌘X` · `⌘C` · `⌘V` |
| Close tab · next tab · previous tab | `⌘W` · `⇧⌘]` · `⇧⌘[` |
| Show or hide the Output console | `⌥⌘0` |
| Split view: the world beside the tab in front | `⌘\`, or the button at the right of the tabs |
| Weld tool · Hinge tool | `⌘J` · `⇧⌘J`, then click two parts |
| Weld All · Unjoin selection | `⌥⌘J` · `⌃⌘J` |
| Delete · Duplicate · Undo · Redo | `⌫` · `⌘D` · `⌘Z` · `⇧⌘Z` |
| Insert part | `⇧⌘1…4`, the Home tab's Insert group, or the Explorer `+` |
| New script · Output · Clear output | `⇧⌘K` · `⌘0` · `⌘K` |
| Full screen | `⌃⌘F` |
| Play / Stop · Open in client | `⌘P` · `⇧⌘P` |
| Run / Stop (scripts and physics, no player; the editor keeps the camera) | `F8` or the ⚙ button by Play |

## The client: games, menu, character and local network

StudioClient opens on its **game picker**: the three sample games, each with a picture
and what's in it, then **Your places** — Open a place… for a file saved from Studio, the
Starter Scene, and the places you've opened here before, newest first. **Join a game**
and **Character** are there too, since joining needs no game of your own. **File ›
Choose a Game…** (⇧⌘G) brings the picker back from anywhere.

Choosing a game goes on to the **main menu**: Play, Host on your network, Join a game,
Choose another game, Character and Quit (a scene sent from Studio with "Open in Client"
is played straight away). **Character** sets your name, a colour for each body part, and what you wear —
a face, shirt, pants and accessories (see *What characters wear*), on a 3D preview; it
is saved and used in every scene you play — scripts see the name as `player.Name`. **Main Menu** (⌘L),
or the Menu button in the bottom-right corner while playing, leaves a game. The
top middle of the screen is left to the game's own titles.

**Local network play.** Host on your network advertises the game over Bonjour, so
another Mac on the same network sees it under Join a game with no address to type.
Joining sends your name and look, and the host sends back its world. From then on it is
**one world**: the host runs the scene's scripts and physics and sends what changes —
parts moving, falling or being made by scripts, lighting, shader settings — 20 times a
second, and a player joining mid-game gets the world as it is at that moment. Every
player's character goes out 20 times a second too, so you see each other in your own
colours with names over your heads. **Players bump into each other** and parts land on
and stop against every player; to let players pass through each other, untick
**Players collide** in StarterPlayer's settings in Studio.

**The host's scripts see every player.** `Players:GetPlayers()` lists everyone,
`Players.PlayerAdded` and `PlayerRemoving` fire as people come and go, each player has
their own `Character` and `CharacterAdded`, and `GetPlayerFromCharacter` knows whose a
character is. A joined player's body touching a part fires its `Touched`, so kill bricks,
coins, speed pads and teleporters work for everyone: setting their Humanoid's Health or
WalkSpeed, damaging them, or moving their HumanoidRootPart is sent to their game, which
runs their character. A host script reading straight back what it just set gets the
new value, and from then on reads what that player's game reports (Health, WalkSpeed,
how fast they're moving, dying). Welds and joints a host script makes or changes reach
everyone too, and a host script can play an animation on a joined player's character
(`humanoid.Animator:LoadAnimation(...)`) — it plays in their game, so everyone sees it,
as does any animation a player plays on themselves. Still to come: a joined player
nudges crates rather than shoving them.

To try it on one Mac, open two copies of the client from Terminal with
`open -n StudioClient.app`, host in one and join from the other.

## Screen GUI and chat

Scripts in StarterPlayerScripts can put things on the player's screen the Roblox way:
make a **ScreenGui**, put **Frame**, **TextLabel**, **TextButton** and **TextBox**
objects in it, place them with **UDim2** (a share of the parent plus pixels) and
**AnchorPoint**, round them with a **UICorner**, keep text off the edges with a
**UIPadding**, and parent the ScreenGui to `player.PlayerGui`.

```lua
local player = game:GetService("Players").LocalPlayer

local screen = Instance.new("ScreenGui")
local button = Instance.new("TextButton")
button.AnchorPoint = Vector2.new(0.5, 1)
button.Position = UDim2.new(0.5, 0, 1, -80) -- centred, 80 px up from the bottom
button.Size = UDim2.fromOffset(160, 40)
button.Text = "Jump!"
button.BackgroundColor3 = Color3.fromRGB(60, 140, 255)
button.TextColor3 = Color3.new(1, 1, 1)
Instance.new("UICorner", button)
button.Parent = screen
screen.Parent = player.PlayerGui

button.MouseButton1Click:Connect(function()
	player.Character.Humanoid.Jump = true
end)
```

Properties: Position, Size, AnchorPoint, BackgroundColor3, BackgroundTransparency,
Visible, ZIndex, LayoutOrder, ClipsDescendants, AutomaticSize, AbsoluteSize and
AbsolutePosition (ScreenGui: Enabled, ResetOnSpawn, DisplayOrder); for text, Text,
TextColor3, TextSize, TextTransparency, TextXAlignment, TextYAlignment, TextWrapped,
TextScaled, Font and TextStrokeColor3/Transparency; for a TextBox, PlaceholderText,
ClearTextOnFocus, TextEditable and CursorPosition. Buttons fire `MouseButton1Click` and
`Activated`; a TextBox fires `Focused` and `FocusLost(enterPressed)`, and
`CaptureFocus()` / `ReleaseFocus()` / `IsFocused()` work. While a TextBox has the
keyboard, keys type into it instead of moving the character: the arrows, Home and End
move the caret, and ⌘A, ⌘C, ⌘X and ⌘V work.

More: a **UIListLayout** stacks what is in a frame (FillDirection, Padding, SortOrder,
alignments), a **ScrollingFrame** scrolls with the wheel (CanvasSize, CanvasPosition,
AutomaticCanvasSize, ScrollBarThickness), **ImageLabel** and **ImageButton** show a
picture imported into the scene (`Image = "studio://Logo"` — see Pictures and sounds), and a **BillboardGui** hangs over a part or a character's head in the world
(Adornee, StudsOffset, MaxDistance) — its Size's scale is in studs, its offset in pixels.

Modifiers go inside an object and change it: **UICorner** rounds it, **UIPadding** keeps
its text and children in from the edges, **UIStroke** outlines it (round the border, or
round a text object's text — `ApplyStrokeMode` Contextual or Border — with Color,
Thickness, Transparency), **UIGradient** runs colours and transparencies across it
(a `ColorSequence` and a `NumberSequence`, turned by Rotation, moved by Offset),
**UIListLayout** stacks its children and **UIGridLayout** puts them in cells (CellSize,
CellPadding, FillDirectionMaxCells, StartCorner), and **UIAspectRatioConstraint**,
**UISizeConstraint** and **UITextSizeConstraint** keep its shape, its size and its
TextScaled size within limits.

```lua
local stroke = Instance.new("UIStroke", button)
stroke.Color = Color3.fromRGB(255, 200, 60)
stroke.Thickness = 3

local gradient = Instance.new("UIGradient", button)
gradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(140, 140, 160))
gradient.Rotation = 90 -- top to bottom

local grid = Instance.new("UIGridLayout", inventory)
grid.CellSize = UDim2.fromOffset(80, 80)
grid.CellPadding = UDim2.fromOffset(6, 6)
```

**StarterGui.** GUIs can be made in Studio too, and the ribbon's **GUI** tab is the
place to do it:

- **Insert** a ScreenGui, Frame, Text, Button, TextBox, Image, ImageButton or Scrolling
  frame. It goes inside the selected Frame or ScreenGui, beside anything else selected,
  or — with nothing selected — into the first ScreenGui (made for it if there isn't
  one). A new Image shows the scene's first picture.
- **Modifiers** — Corner, Padding, Stroke, Gradient, List, Grid, Aspect, Size Limit,
  Text Limit — go in the selected object; one it already has is lit, and picking it
  again selects it.
- **Arrange**: align to the parent's left, middle, right, top or bottom (by scale and
  AnchorPoint, so it stays put on every screen), **Fill** the parent, bring to the
  **Front** or send to the **Back** (ZIndex), **Duplicate** (⌘D) and **Delete** (⌫).
- **Units**: **To Scale** turns Position and Size into shares of the parent, **To
  Pixels** back — both keeping it exactly where it is on the previewed screen.
- **Preview**: see the GUI on a **Phone** (landscape or portrait), **Tablet**, **Laptop**
  or **Desktop 1080p** screen, framed in the view, or fitted to the window; snap to a
  **Grid** of 1, 4, 8 or 16 pixels, and to **Guides** (the parent's and siblings' edges
  and middles, drawn as you drag).

With the GUI tab open, click an object in the view to select it, drag it to move it,
drag its handles to resize it, and nudge it with the arrow keys (Shift: ten pixels);
Esc lets go. Something Position or Size gave in scale stays in scale as you drag. Clicks
anywhere but on the GUI still reach the world, and right-drag still turns the camera.
Objects a UIListLayout or UIGridLayout places can't be dragged about (a grid sizes its
cells too).

The Explorer has the same: right-click a ScreenGui or Frame for **Insert**, **Add
LocalScript** and **Duplicate**. Every property is in the Properties panel, in sections,
with where the object shows on the previewed screen and one-click buttons for the common
modifiers; a UIGradient's colours and transparencies are edited from one end to the
other over a strip of the gradient. When play starts each player gets their own copy in their
PlayerGui, and the LocalScripts in it run there with `script.Parent` the copy; a
ScreenGui with ResetOnSpawn (on by default) is made afresh for each new character.

**Chat.** Every game has chat: press **/**, type, press **Return**, and everyone in
the game sees `Name: message` (no filter), in a window that scrolls back through the
last hundred messages and in a bubble over the speaker's head for a few seconds
(`TextChatService.BubbleChatConfiguration.Enabled = false` turns bubbles off). It isn't built into the app — it is the
default **ChatScript** in StarterPlayerScripts, made from the GUI objects above and
sending through **TextChatService**, so you can open it, **Edit a Copy** to restyle
or change it, or **Turn Off** to remove chat from a game. Your own scripts can use the
same service:

```lua
local TextChatService = game:GetService("TextChatService")

TextChatService.MessageReceived:Connect(function(message)
	print(message.TextSource.Name .. " said " .. message.Text)
end)

TextChatService.TextChannels.RBXGeneral:SendAsync("hello!")
```

Messages go to the host, which passes them to everyone else under the name each player
joined with; a message is at most 200 characters.

## Clicking things: ClickDetector and the Mouse

The mouse works as in Roblox: in third person the pointer is free — point at things and
click them — and **right-drag** turns the camera; zoom into first person and the pointer
is captured, so moving the mouse looks around (**Esc** frees it). Tick **ClickDetector**
in a part's Properties (or `Instance.new("ClickDetector", part)`) and clicking the part
fires `MouseClick` with the player who clicked — in a network game, on the host, for
whoever it was:

```lua
local door = workspace.Door
local detector = Instance.new("ClickDetector")
detector.MaxActivationDistance = 12
detector.MouseClick:Connect(function(player)
	print(player.Name .. " opened the door")
	door.Transparency = 0.8
	door.CanCollide = false
end)
detector.Parent = door
```

ClickDetectors also have `MouseHoverEnter` and `MouseHoverLeave`. `Player:GetMouse()`
gives `Hit` (a CFrame where the mouse points), `Target` (the part under it), `X`, `Y`,
`ViewSizeX/Y`, `Button1Down/Up` and `Button2Down/Up`, and a Tool's `Equipped` hands it
over. `UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter` holds the pointer
in the middle (as in first person); `UserInputService:GetMouseLocation()` says where it is.

## Tools

A **Tool** is something a player holds — a sword, a torch, a wand. Make one with the
Explorer's **+ › New Tool** (it comes with a part named **Handle**, which is what the
hand holds), build it out of parts, add scripts to it, then right-click it and choose
**Move to StarterPack**: every player gets a copy whenever their character spawns. A
Tool left in the Workspace is a pickup — touching its Handle picks it up.

In play, the tools you have show on a hotbar at the bottom of the screen: **1–9** (or
a click on a slot) holds one, the same again puts it away, **Backspace** drops it, and
a **click** with it in hand fires `Activated`. The hotbar is the default
**BackpackScript** in StarterPlayerScripts, built from GUI objects, so it can be
replaced like the chat.

```lua
-- A Script inside a sword Tool
local tool = script.Parent
local handle = tool:WaitForChild("Handle")
local lastHit = {}

tool.Activated:Connect(function()
	print(tool.Parent.Name .. " swings")
end)

handle.Touched:Connect(function(hit)
	local humanoid = hit.Parent:FindFirstChild("Humanoid")
	-- Each body part touches on its own, so count a hit once a second.
	if humanoid and hit.Parent ~= tool.Parent and os.clock() - (lastHit[humanoid] or 0) > 1 then
		lastHit[humanoid] = os.clock()
		humanoid:TakeDamage(25)
	end
end)
```

`Tool` has `ToolTip`, `Enabled`, `RequiresHandle`, `CanBeDropped`, `Grip`, `Equipped`,
`Unequipped`, `Activated`, `Deactivated`, `:Activate()`; `Parent` is the Workspace, a
player's `Backpack` or their character, and setting it moves the tool there
(`tool.Parent = player.Backpack` gives it). Also `Humanoid:EquipTool(tool)`,
`Humanoid:UnequipTools()`, `character:FindFirstChildOfClass("Tool")`, and
`game:GetService("StarterPack")`. In a network game the host runs every tool's scripts
and everyone sees each other's tools in hand, so a sword hits whoever it touches.

## Pictures and sounds

Pictures and sounds live inside the scene: an imported file is copied into the place,
and saving the place saves the file in it, so the original can be moved or deleted and
the place still has it — opened again, in the client, or by joined players, who get
them with the world. A Model saved from a selection takes its Sounds and the files they
play with it; inserted into a place that has a different file of the same name, the
Model's comes in renamed and its Sounds and scripts use it. Bring files in with the
Explorer's **+ › Import Picture or Sound…**, or drop them on **Assets**: PNG, JPEG, GIF, TIFF, BMP and HEIC
pictures; WAV, MP3, M4A, AIFF, CAF and AAC sounds; up to 8 MB a file and 40 MB for the
scene. Scripts name one as `"studio://Name"` (right-click › **Copy Reference**, or see
it in Properties, which also shows the picture or plays the sound).

A **Sound** in a part is heard from there — placed in 3D, fading to nothing at its
`RollOffMaxDistance` — and one in **SoundService** is heard the same everywhere. Right-
click a part for **Add Sound**, or right-click SoundService for **New Sound**; its
Properties pick the SoundId and set Volume, PlaybackSpeed, Looped and whether it
**plays when the game starts**.

```lua
local SoundService = game:GetService("SoundService")

-- A bell in the tower, rung by touching the rope.
local bell = Instance.new("Sound")
bell.SoundId = "studio://Bell"
bell.Volume = 2
bell.RollOffMaxDistance = 150
bell.Parent = workspace.Tower
bell.Ended:Connect(function() print("the bell stops ringing") end)

workspace.Rope.Touched:Connect(function()
	if not bell.IsPlaying then
		bell:Play()
	end
end)

SoundService.Music.Playing = true -- one made in Studio
```

`Sound` has `SoundId`, `Volume` (0–10), `Looped`, `PlaybackSpeed`, `RollOffMaxDistance`,
`TimePosition` (read, or set to jump), `Playing`, and read-only `IsPlaying`, `IsPaused`,
`IsLoaded` and `TimeLength`; `:Play()`, `:Stop()`, `:Pause()`, `:Resume()`,
`:Destroy()`; and `Played`, `Ended`, `Stopped`, `Paused`, `Resumed`, `Loaded`.
`SoundService` has `GetChildren`, `FindFirstChild`, `WaitForChild` and
`PlayLocalSound`. In a network game the host's Sounds are heard by everyone, from the
same parts; a Sound a LocalScript makes (a button's click, say) is heard only on that
player's machine — the host's own LocalScripts included.

### Built-in sounds

Studio also makes sounds of its own, with no file: set a SoundId to
`"builtin://Name"`, or pick one under **Built in** in the SoundId menu. They're
synthesized the first time they're played, so a place using them stays small and a
network game sends only their names.

| Effects | |
| --- | --- |
| `Swing`, `Hit`, `Shoot` | a sword's whoosh, a solid thump, a blaster's zap |
| `Groan`, `ZombieDown` | a zombie's moan, and its fall |
| `Hurt`, `Oof` | taking damage, and being knocked out |
| `Pickup`, `Sparkle`, `PowerUp` | a coin or orb, something special found, a rising arpeggio |
| `Click`, `Checkpoint`, `Jump`, `Boing` | a button, two bright bells, a hop, a jump pad |
| `Crack`, `Rumble` | something giving way, heavy stone moving |
| `Chime`, `Gong` | a soft morning bell, a deep gong |
| `Victory`, `Defeat` | a short fanfare, falling notes |

Music, which loops without a gap: `CalmDay` (gentle plucked chords), `NightHunt`
(tense and driving) and `ObbyRun` (bright, bouncy chiptune).

```lua
-- A coin that goes "ding" for whoever picks it up.
local Players = game:GetService("Players")
local ding = Instance.new("Sound")
ding.SoundId = "builtin://Pickup"
ding.Parent = workspace.Coin

workspace.Coin.Touched:Connect(function(hit)
	if Players:GetPlayerFromCharacter(hit.Parent) then
		ding:Play()
	end
end)
```

Nightfall and Mega Obby use them. In Nightfall the music follows the day and the night,
with a gong as night falls and a chime at dawn; zombies groan, and swings, hits, shots
and falls are heard from where they happen; your own orbs, power-ups, hurts and the
end of a run are heard by you alone. Mega Obby has its music, jump pads that boing,
tiles that crack as they fade, and your own checkpoint dings, finish fanfare and oofs.
`swift run StudioApp --write-sounds <folder>` writes every one as a WAV file to listen to.

## Particles: fire, smoke, sparkles

A **ParticleEmitter** in a part sends out little pictures that fly, fade and go: fire,
smoke, sparkles, magic, confetti. Right-click a part in the Explorer and choose **Add
ParticleEmitter** to get one of five starting points. **Sparkles** is Roblox's default;
**Fire**, **Smoke**, **Magic** and **Confetti** are ready-made effects. You see the
particles in Studio as you edit.

In Properties:

- **Looks:** a built-in picture (Sparkle, Circle, Smoke, Fire, Star, Confetti) or one
  you've imported. The colour, size and transparency from start to end of a particle's
  life. **LightEmission** takes it from drawn over what's behind (0) to glowing, added
  to it (1).
- **Coming out:** `Rate` (a second), `Lifetime` and `Speed` (each a range the particle
  picks from), `SpreadAngle`, and the face they come out of (`EmissionDirection`). They
  start anywhere inside the part.
- **Moving:** `Acceleration`, `Drag`, `Rotation` and `RotSpeed`, `TimeScale`.
  `LockedToPart` makes them move with the part.

Scripts use Roblox's names and types: `NumberRange`, `NumberSequence` (with envelopes),
`ColorSequence`, `Vector2` and `Enum.NormalId`. `emitter:Emit(count)` bursts that many
at once, even with `Rate` 0, and `emitter:Clear()` takes them all away. A Script's
emitters and bursts reach every player. A joined player's LocalScript can make effects
of its own.

```lua
-- A Script in a part: a burst of confetti when a player touches it.
local confetti = Instance.new("ParticleEmitter")
confetti.Texture = "builtin://Confetti"
confetti.Rate = 0
confetti.Speed = NumberRange.new(20, 30)
confetti.SpreadAngle = Vector2.new(35, 35)
confetti.Acceleration = Vector3.new(0, -12, 0)
confetti.Drag = 2.5
confetti.Lifetime = NumberRange.new(2, 3)
confetti.Color = ColorSequence.new(Color3.fromRGB(255, 80, 120), Color3.fromRGB(80, 200, 255))
confetti.Parent = script.Parent

script.Parent.Touched:Connect(function(hit)
	if game:GetService("Players"):GetPlayerFromCharacter(hit.Parent) then
		confetti:Emit(60)
	end
end)
```

The sample games use them too: the smoke and embers over Nightfall's campfire, the
magic round Adventure Island's fountain, and Mega Obby's confetti when you win.

Unlike Roblox, emitters go in parts only, not in Attachments, and they aren't lit
(Roblox's default, `LightInfluence` 0).

## Beams and Trails

A **Beam** is a ribbon drawn between two attachments: a laser, a rope bridge's chain, arrows
along a path. With **Physics › Beam**, click one part, then another. The Beam goes from
the middle of one to the middle of the other, facing the camera.

- `Width0` and `Width1` set the width at each end.
- `CurveSize0` and `CurveSize1` bend it: it heads out along each attachment's axis before
  turning to the other end. `Segments` sets how smooth the bend is.
- `FaceCamera` turns it to face whoever is looking. Without it, it lies across the
  attachments' secondary axes, flat on a path.

A **Trail** is a ribbon left behind as its two attachments move: a sword's swoosh, a
racer's streak. **Physics › Trail**, or right-click a part › **Add Trail**, puts one on a
part, between its top and bottom.

- A Trail adds a point each time the part moves `MinLength` studs.
- Each point lasts `Lifetime` seconds, and `MaxLength` limits how long it gets.
- `WidthScale` narrows it as it ages.
- `trail:Clear()` wipes what it has left behind.

Both take a picture: four built in (Glow, Arrows, Dots, Chain), an imported one, or
none for plain colour. They also take `Color` and `Transparency` sequences,
`LightEmission`, `Brightness`, `TextureLength` and `TextureMode`, `Stretch` or `Wrap`
(once every `TextureLength` studs). A Beam's `TextureSpeed` scrolls its picture along
it.

```lua
-- A Script: a laser between two posts, flicking on and off.
local beam = Instance.new("Beam")
beam.Attachment0 = Instance.new("Attachment", workspace.LeftPost)
beam.Attachment1 = Instance.new("Attachment", workspace.RightPost)
beam.Texture = "builtin://Glow"
beam.Color = ColorSequence.new(Color3.fromRGB(255, 60, 60))
beam.Transparency = NumberSequence.new(0)
beam.LightEmission = 1
beam.FaceCamera = true
beam.Parent = workspace.LeftPost

while true do
	task.wait(1)
	beam.Enabled = not beam.Enabled
end
```

Joined players get the host's Beams and Trails like any other part of the world. Each
player's own game draws the trail behind a part as they see it move. Unlike Roblox,
attachments go on parts only, so characters don't have them.

## MeshParts: 3D models

A **MeshPart** is a part shaped like a 3D model. Import the model like a picture — the
Explorer's **+ › Import Picture, Sound or 3D Model…**, or drop it on **Assets** — from an
OBJ, STL, PLY or USD (USDA, USDC, USDZ) file: the formats macOS reads itself. FBX and glTF
aren't; export those as OBJ or USD first. Then **Home › Mesh** (or right-click the
model in Assets › **Insert MeshPart**) puts one on the ground in front of the camera, at
the model's own size — or 8 studs across if that is far too big or too small.

Its Properties add a **Mesh** section: the model it uses (`MeshId`), a picture wrapped
on it with the model's own texture coordinates (`TextureID`, tinted by the part's
Color), how it collides, and **Reset Size**. `Size` stretches it like any part.

**CollisionFidelity**, as in Roblox:

- **Hull** (the default) — collides as its convex hull, like shrink-wrap: an arch's
  opening is solid, a cup's inside is filled.
- **Box** — collides as its box. The cheapest.
- **Precise** (`PreciseConvexDecomposition`) — collides as its real triangles, so you
  can walk through the arch and drop things into the cup. Only while it's anchored (or
  welded to something that is); an unanchored Precise part falls as its hull.

Clicks always hit the model's real shape, whatever it collides as. A MeshPart weighs
what its hull holds.

```lua
local statue = Instance.new("MeshPart")
statue.MeshId = "studio://Statue"
statue.TextureID = "studio://Marble"
statue.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
statue.Size = statue.MeshSize * 2 -- twice the model's size
statue.Anchored = true
statue.Position = Vector3.new(0, 10, 0)
print(statue.ClassName, statue:IsA("BasePart")) -- MeshPart true
```

`MeshSize` is the model's own size, read-only. A saved Model takes its MeshParts' 3D
models and pictures with it, and joined players get them with the world. Luau only.

## Exploring a scene (the client)

| Action | Input |
| --- | --- |
| Move | `W A S D` |
| Jump | `Space` |
| Sprint | `Shift` |
| Shift lock | `Left Ctrl`, on and off |
| Look | right-drag; in first person or shift lock, move the mouse (`Esc` frees it, a click takes it back) |
| Click something | left-click — a part with a ClickDetector, a GUI button |
| Zoom out/in, first person | scroll |
| Free fly | `F` |
| Respawn | `R` |
| Chat | `/` (or click the chat bar), `Return` sends, `Esc` cancels |
| Hold a tool · put it away · drop it · use it | `1`–`9` · the same key · `Backspace` · click |
| Open another scene | `⌘O` |

These controls are not built in: moving comes from the default **ControlScript**, a Luau
script you can read, copy and replace (see *The player character* below), and `F`, `R`
and the rest from the default HUD's scripts in StarterGui (below). The
character follows Roblox's defaults: 16 studs/s walk, 50 jump power, 196.2 gravity, a
2-stud step height, 100 health that slowly regenerates, and a 5-second respawn. Walls are resolved
against a capsule lifted by the step height — so anything shorter than a step is
walked over rather than bumped into — and support underfoot comes from five downward
probes rather than the capsule's rounded base, which is what lets you stand on the
edge of a ledge instead of sliding off it. The simulation substeps whenever a frame
would move you more than a third of a stud, so sprinting across a thin plank or
falling fast never tunnels through geometry.

The avatar is a classic six-part Roblox character: rounded limbs and torso, the
round-rimmed head with its smiling face, and body colours from StarterPlayer. It
breathes when standing, swings its arms and legs in step with its speed (wider when
sprinting), throws its arms up to jump, flails as it falls, flies head-first, and
collapses when it dies — each change blended rather than snapped.
`swift run StudioApp --render-avatar avatar.png` renders every pose to an image.

Scroll all the way in for first person; the third-person camera pulls in automatically
when scenery comes between it and your head.

**Shift lock**, as in Roblox, but on **Left Ctrl**, since Shift sprints here. It works
in every game:

- the pointer is held in the middle of the screen, with the HUD's crosshair;
- moving the mouse turns the camera, which looks over your right shoulder;
- your character always faces the way the camera looks, so `A` and `D` strafe
  instead of turning;
- scripts see `UserInputService.MouseBehavior` as `LockCenter`.

It's on in every place, and in every new one: StarterPlayer's **Shift lock (Left
Ctrl)**, Roblox's `EnableMouseLockOption`. Old places are included. Untick it for a
game that shouldn't have it. A script can also take it away from one player with
`player.DevEnableMouseLock = false`.

**The default HUD.** Nothing on the screen in play is built into the app — in Studio's
play test or the client. What a new scene shows is **StarterGui › PlayerHud**, an
ordinary ScreenGui made of Frames and TextLabels: the health bar (bottom), the countdown
after dying, the position, speed, state and frame rate (top right) — with where each
frame's time goes (the whole frame, drawing it, the scripts, the physics) and the
memory used and parts, from its **FrameStats** LocalScript — the controls
(bottom left; `H` hides them), a crosshair in first person, and a script output window
(`` ` `` shows it; it also counts errors). Its **HudScript** LocalScript keeps it up to date
through the Humanoid, `RunService` and `LogService`, and its **FlyAndRespawn** LocalScript
is `F` (fly) and `R` (respawn). Restyle it in the GUI tab, change its scripts, or delete
any of it: a scene without it has no HUD and no F or R. Right-click StarterGui › **Insert
Default HUD** brings a fresh copy back. Scenes saved before it existed get it when opened;
one you've deleted it from doesn't. In Studio it shows over the world as you build, like
any StarterGui — View › **GUI** (or the GUI tab's Show) hides it.

`LogService` is there for your own scripts too: `LogService.MessageOut` fires with each
line of output and its `Enum.MessageType`, and `LogService:GetLogHistory()` returns what
has been written so far.

## Manipulating parts

* **Move** — drag an axis arrow for one axis, or a coloured corner square for two axes at once.
* **Scale** — drag an axis cube. The opposite face stays anchored, like Roblox's resize handles.
* **Rotate** — drag a ring. Snap increments are set on the ribbon's Model tab (default 15°).
* **Local space** (`L`) draws the gizmo along the part's own axes instead of the world's.
* Multi-selection moves and rotates as a group about the selection's centre.
* Everything is also typeable in the Properties inspector, which applies to the whole selection.

## Saving a creation

| Action | Shortcut |
| --- | --- |
| New scene | `⌘N` |
| Open | `⌘O` (with an Open Recent submenu) |
| Save / Save As | `⌘S` / `⇧⌘S` |
| Save Selection as Model | `⌘E` |
| Insert Model | `⌘I` |

A **scene** (`.studioscene`) is the whole creation: every part and every script.
The title bar shows the file name and an edited marker, and Studio asks before
discarding unsaved work when you quit, open or start a new scene.

A **model** (`.studiomodel`) is a saved selection — the parts you picked plus any
scripts inside them, stored relative to their own centre. Inserting one drops it
where the camera is looking, gives everything fresh identities so nothing clashes
with what is already in the scene, reattaches the scripts to the inserted copies,
and is a single undo step. It is the way to reuse a thing you built across scenes.

Both formats are plain JSON, and a scene file saved before scripts existed still opens.

## Scripting with Luau

Scripts are written in [Luau](https://luau.org), the language Roblox uses, against a
Roblox-flavoured API — if you have written a Roblox script, most of what you know works
here. The VM is vendored under `Sources/CLuau` (0.640, MIT); nothing to install.

```lua
local RunService = game:GetService("RunService")

local orb = script.Parent
local origin = orb.Position

RunService.Heartbeat:Connect(function(dt)
	orb.Position = origin + Vector3.new(0, math.sin(time() * 2) * 2, 0)
end)

-- Build a ring of pillars, one every tenth of a second.
for i = 1, 12 do
	local pillar = Instance.new("Part")
	pillar.Position = Vector3.new(20, 4, 0):RotatedY(i * 30)
	pillar.Size = Vector3.new(2, 8, 2)
	pillar.Color = Color3.fromHSV(i / 12, 0.5, 0.9)
	pillar.Material = Enum.Material.Neon
	pillar.Parent = workspace
	task.wait(0.1)
end
```

A script attached to a part gets it as `script.Parent`; standalone scripts live under
Script Service. Everything runs when you press **Play** and stops — with the scene
restored exactly — when you press Stop. `print` and `warn` go to the Output console.

**A new script starts with code for where you made it.** In a part it says hello and
answers `Touched` with a debounce (plus a line that turns it into a kill brick); in a
Model it counts the parts inside and shows how to move the Model as one; in a Folder it
goes through what the folder holds; in Script Service it is Roblox's `print("Hello
world!")` with the next steps — finding a part, `task.wait`, `Heartbeat` — ready to
uncomment. StarterPlayerScripts get the player's characters and keys, and
StarterCharacterScripts get their character's Humanoid. Wren scripts get Wren versions.
Every one runs cleanly as it is, and so does every line it suggests trying.

**What is there**

| | |
| --- | --- |
| `workspace` | `:FindFirstChild`, `:WaitForChild`, `:GetChildren`, and children by name (`workspace.Baseplate`) |
| Parts | `Name`, `Position`, `Size`, `Orientation`, `CFrame`, `Color`, `Transparency`, `Anchored`, `Locked`, `CanCollide`, `CanTouch`, `Material`, `Shape`, `ClassName`, `Parent`, `Touched`, `TouchEnded`, `AssemblyLinearVelocity`, `AssemblyAngularVelocity`, `Mass`, `:ApplyImpulse()`, `:ApplyAngularImpulse()`, `:GetPivot()`, `:PivotTo()`, `:Destroy()`, `:Clone()`, `:IsA()` |
| Welds and joints | `WeldConstraint` (`Part0`, `Part1`, `Enabled`, `Active`), `HingeConstraint` and `PrismaticConstraint` (`ActuatorType`, `AngularVelocity`/`Velocity`, `MotorMaxTorque`/`MotorMaxForce`, `TargetAngle`/`TargetPosition`, `AngularSpeed`/`Speed`, `Servo…`, `LimitsEnabled`, limits, `CurrentAngle`/`CurrentPosition`), `BallSocketConstraint`, `RopeConstraint` (`Length`), `SpringConstraint` (`FreeLength`, `Stiffness`, `Damping`), `AlignPosition` (`Mode`, `Position`, `MaxForce`, `MaxVelocity`, `Responsiveness`, `RigidityEnabled`), `VectorForce` (`Force`, `RelativeTo`, `ApplyAtCenterOfMass`), `NoCollisionConstraint`, `Attachment` (`Position`, `Axis`, `WorldPosition`, `CFrame`), `Enum.ActuatorType`, `Enum.PositionAlignmentMode`, `Enum.ActuatorRelativeTo` |
| The tree | `Model` (`PrimaryPart`, `:GetPivot`, `:PivotTo`, `:MoveTo`, `:GetBoundingBox`), `Folder`; on everything: `:GetChildren`, `:GetDescendants`, `:FindFirstChild(name, recursive)`, `:WaitForChild`, `:FindFirstChildOfClass`, `:IsDescendantOf`, `:FindFirstAncestor…`, `:GetFullName`, `:ClearAllChildren`, children by name (`workspace.Car.Seat`) |
| `CFrame` | `new` (every form), `lookAt`, `Angles`, `fromEulerAnglesXYZ/YXZ`, `fromOrientation`, `fromAxisAngle`, `fromMatrix`, `identity`; `*`, `+`, `-`; `Position`, `LookVector`, `RightVector`, `UpVector`, `Rotation`; `:Inverse`, `:Lerp`, `:ToWorldSpace`, `:ToObjectSpace`, `:PointTo…Space`, `:VectorTo…Space`, `:GetComponents`, `:ToEulerAnglesXYZ/YXZ`, `:ToOrientation`, `:ToAxisAngle`, `:FuzzyEq` |
| `Instance.new` | `"Part"`, `"WedgePart"`, `"MeshPart"`, `"Model"`, `"Folder"`, `"PointLight"`, `"Animation"`, `"Attachment"`, `"WeldConstraint"` and the five joint classes, `"IntValue"`, `"NumberValue"`, `"StringValue"`, `"BoolValue"`, `"RemoteEvent"`, `"RemoteFunction"`, `"Accessory"`, `"Shirt"`, `"Pants"`, `"HumanoidDescription"`, `"Sound"`, the GUI classes — with Roblox's defaults |
| Working together | `require` and ModuleScripts; `ReplicatedStorage`, `ServerStorage`, `ServerScriptService`; `RemoteEvent`, `UnreliableRemoteEvent`, `RemoteFunction`, `BindableEvent`, `BindableFunction`; Value objects; `RunService:IsServer/IsClient`; `workspace:Raycast` and `RaycastParams` (see *Scripts working together*) |
| `Vector3`, `Color3` | the Roblox constructors, properties, operators and methods — float32, as in Roblox |
| `Enum` | `Material`, `PartType`, `EasingStyle`, `EasingDirection`, `PlaybackState`, `KeyCode`, `UserInputType`, `UserInputState`, `HumanoidStateType`, `CameraMode`, `TextXAlignment` |
| `game:GetService` | `RunService` (`Heartbeat`, `Stepped`, `RenderStepped` with `:Connect`, `:Once`, `:Wait`; `:IsServer`, `:IsClient`), `Players`, `UserInputService`, `TweenService` (`:Create`, `:GetValue`), `Workspace` (`Gravity`), `ReplicatedStorage`, `ServerStorage`, `ServerScriptService` |
| Tweens | `TweenInfo.new(time, style, direction, repeatCount, reverses, delayTime)`; `TweenService:Create(instance, info, goals)` → `:Play`, `:Pause`, `:Cancel`, `PlaybackState`, `Completed`; numbers, booleans, `Vector3`, `Color3`, `CFrame`, `UDim2`, `UDim`, `Vector2` — parts and GUI alike |
| The player | `Players.LocalPlayer` — `Character`, `CharacterAdded`, `CharacterRemoving`, `:LoadCharacter()`, `CameraMode`, `CameraMin/MaxZoomDistance`; `Players.RespawnTime`, `Players:GetPlayerFromCharacter` |
| `Humanoid` | `WalkSpeed`, `JumpPower`, `JumpHeight`, `UseJumpPower`, `Health`, `MaxHealth`, `MaxSlopeAngle`, `AutoRotate`, `Jump`, `MoveDirection`; `:Move`, `:MoveTo`, `:TakeDamage`, `:GetState`, `:ChangeState`; `Died`, `HealthChanged`, `StateChanged`, `Jumping`, `FreeFalling`, `Running`, `MoveToFinished`, `Touched(part, bodyPart)` |
| Character | `HumanoidRootPart` (`Position`, `AssemblyLinearVelocity`), `Head`, `Torso`, `Left Arm`, … (`Color`, `Transparency`, `Touched`, `TouchEnded`), `:FindFirstChild`, `:WaitForChild`, `:MoveTo` |
| Lighting | `Lighting` (ClockTime, TimeOfDay, Brightness, Ambient, OutdoorAmbient, ColorShift_Top, GlobalShadows, ShadowSoftness, ExposureCompensation, Fog*, GeographicLatitude, Technology, `:GetSunDirection()`), `PointLight`, `Enum.Technology` |
| Animations | `Animations` (made in the Animation Editor), `Animator:LoadAnimation`, `AnimationTrack`, `Enum.AnimationPriority` |
| `UserInputService` | `:IsKeyDown`, `:GetKeysPressed`, `InputBegan`, `InputEnded` with `InputObject`s |
| `task` | `wait`, `spawn`, `delay`, `defer` (later in the same frame, once the code running now is done), `cancel` (wherever the thread waits, events included), `synchronize`/`desynchronize` (which carry straight on: there are no Actors, so everything runs in series) — plus the older `wait()`, `spawn()` and `delay()` as Roblox still runs them (never under a thirtieth of a second; `spawn` a frame later) |
| `Random` | `Random.new(seed)` with `:NextNumber`, `:NextInteger`, `:NextUnitVector`, `:Shuffle` |
| `math` | Luau's own (`clamp`, `sign`, `round`, Perlin `noise`) plus `lerp`, `map`, `inverseLerp`, `smoothstep`, `snap`, `wrap`, `pingPong`, `moveTowards`, `wrapAngle`, `deltaAngle`, `fbm` |
| `typeof` | reports `"Vector3"`, `"Color3"`, `"Instance"`, `"EnumItem"` as Roblox does |
| `shared`, `_G` | shared between scripts; everything else is private to each script |

Studio extensions, beyond Roblox: `Shaders`, `Screen`, `Player` (= `LocalPlayer`, plus
`Position`, `Velocity`, `Speed`, `Grounded`, `:Teleport`), the `Flying` humanoid state, and `Vector3:RotatedY(degrees)`, which turns exactly as a part's
`Orientation.Y` does.

**Where it knowingly differs from Roblox:** `Instance.new` and `:Clone()` put the new
thing straight into the workspace rather than leaving it unparented (setting `Parent`
afterwards moves it); setting `Parent = nil` destroys;
`Vector3.zero.Unit` is zero rather than NaN, because a NaN position makes a part
silently vanish; type annotations are accepted but not type-checked.

**Errors are meant to teach.** They name the script and your own line —
`Spinner:12: Unable to assign property Position. Vector3 expected, got number` — with
Roblox's wording, including the classic `part.Position.X = 5` trap, which is refused
rather than silently doing nothing. A `Heartbeat` handler that errors is reported once
and disconnected; the others keep running.

**A runaway script cannot freeze the app.** Each script and each handler gets two
seconds; `while true do end` is stopped with the line it was stuck on. Scripts are
sandboxed, so one cannot redefine `Vector3` or `print` for the others.

## Scripts working together

### ModuleScripts and `require`

A **ModuleScript** holds code other scripts share. It doesn't run by itself: the first
time a script calls `require` on it, it runs and hands back what it returns, and every
later `require` of it gets that same thing. Make one in **ReplicatedStorage** (the
Explorer's **+ › New ModuleScript**, or right-click ReplicatedStorage), where scripts on
the host and LocalScripts on every player's machine can reach it — or in Script Service,
or in a part or Model.

```lua
-- ReplicatedStorage/Weapons (a ModuleScript)
local Weapons = {}
Weapons.damage = { Sword = 25, Bow = 15 }
function Weapons.describe(name)
	return name .. " does " .. Weapons.damage[name] .. " damage"
end
return Weapons

-- any Script or LocalScript
local Weapons = require(game:GetService("ReplicatedStorage").Weapons)
print(Weapons.describe("Sword"))
```

A module that requires itself round a loop, returns nothing, errors or doesn't compile
gives Roblox's error at the `require`. The server and the clients each run a module
once for themselves, as in Roblox — on the host too, where the scene's scripts are the
server and its LocalScripts a client. `RunService:IsServer()` and `:IsClient()` say
which a script is.

### The Utils module

Every new place starts with a ModuleScript called **Utils** in ReplicatedStorage: helpers
most games end up writing for themselves. Use it from any Script or LocalScript:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Utils = require(ReplicatedStorage.Utils)

-- Once a second at most, however many body parts touch the pad.
workspace.Pad.Touched:Connect(Utils.debounce(1, function(hit)
	local player = Utils.playerFromPart(hit)
	if player then
		print(player.Name, "stepped on the pad at", Utils.formatTime(time()))
	end
end))
```

| | |
| --- | --- |
| **Maths** | `lerp(a, b, t)` (numbers, Vector3s, Color3s, CFrames), `clamp`, `round(x, step)`, `remap(x, inLow, inHigh, outLow, outHigh)`, `approach(current, target, step)`, `randomBetween`, `randomInt`, `chance(percent)`, `wrapAngle(degrees)` |
| **Tables** | `copy`, `deepCopy` (cycles and parts are fine), `keys`, `values`, `count`, `find(t, value)`, `filter(list, keep)`, `map(list, change)`, `shuffle`, `pickRandom`, `merge(...)` |
| **Text and time** | `formatTime(125)` → `2:05`, `commas(12500)` → `12,500`, `shorten(1500)` → `1.5K`, `padLeft(7, 3, "0")` → `007`, `split`, `trim`, `titleCase` |
| **Game helpers** | `debounce(seconds, callback)`, `cooldown(seconds)` → `ready(player)`, `playerFromPart(hit)`, `getCharacter`, `getHumanoid`, `getRoot` (each from a player, character or body part), `isAlive`, `positionOf`, `distance(a, b)` (players, characters, parts, Models or Vector3s), `weld(a, b)`, `tween(object, seconds, goals, style)` |

It's an ordinary script that belongs to the place: open it to read how anything works,
change it, or add your own helpers. For each one, write a comment saying what it does,
then `function Utils.name(...)`. The script editor suggests them after `Utils.`, with their
parameters, and shows the comment for the highlighted one. A place made before this
can have one too: right-click **ReplicatedStorage › Insert Utils Module**.

### ReplicatedStorage and ServerStorage

Both keep things out of the world until a script wants them — ModuleScripts, Values,
and **parts and Models** (right-click one in the Workspace › **Move to
ReplicatedStorage** or **Move to ServerStorage**). A stored Model's parts aren't drawn,
touched or simulated, and its scripts don't run. `:Clone()` brings a copy into the
Workspace, scripts and all; setting `Parent = workspace` brings the thing itself.
ReplicatedStorage is seen by every machine; **ServerStorage only by the host** — joined
players are never sent what's in it, and their LocalScripts find it (and
ServerScriptService) empty.

```lua
-- A Script: a new sword for whoever touches the rack, from ServerStorage.
local ServerStorage = game:GetService("ServerStorage")
workspace.Rack.Touched:Connect(function(hit)
	local sword = ServerStorage.Sword:Clone()
	sword.Name = "Sword"
	sword:PivotTo(workspace.Rack:GetPivot() + Vector3.new(0, 4, 0))
end)
```

### RemoteEvents and RemoteFunctions

In a network game the host runs the game — the **server** — and each player's machine
runs their LocalScripts — a **client**. Remotes are how they talk. Put a **RemoteEvent**
or **RemoteFunction** in ReplicatedStorage (right-click it), or make one from a host
script with `Instance.new("RemoteEvent")`.

```lua
-- A LocalScript (StarterPlayerScripts): ask the server to buy something.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Buy = ReplicatedStorage:WaitForChild("Buy")          -- a RemoteFunction
local ok, message = Buy:InvokeServer("Sword")
print(message)

-- A Script: the server decides.
ReplicatedStorage.Buy.OnServerInvoke = function(player, item)
	local coins = player.leaderstats.Coins
	if coins.Value < 100 then
		return false, "Not enough coins"
	end
	coins.Value -= 100
	ReplicatedStorage.Announce:FireAllClients(player.Name .. " bought a " .. item)  -- a RemoteEvent
	return true, "Bought a " .. item
end
```

A RemoteEvent has `:FireServer(…)` (a LocalScript's; the server hears it on
`OnServerEvent` with the player first), `:FireClient(player, …)` and
`:FireAllClients(…)` (the server's; LocalScripts hear it on `OnClientEvent`). A
RemoteFunction has `:InvokeServer(…)`, which waits for what `OnServerInvoke` returns
(an error there comes back to the caller), and `:InvokeClient(player, …)` with
`OnClientInvoke`. Numbers, strings, booleans, `nil`, tables, `Vector3`, `Vector2`,
`Color3`, `CFrame`, `EnumItem`s, parts, Models, Folders and Values, ModuleScripts,
Sounds, attachments and joints, Players, characters and their body parts all go across;
a GUI object only reaches scripts on its own machine (anywhere else it's `nil`, as in
Roblox). An event that arrives before anything listens is kept, and handed over when
the first handler connects — so a player's script that connects late still gets the
welcome the server fired on join. A call waiting on a player who leaves fails with
"The player left the game" instead of waiting for ever. `UnreliableRemoteEvent` works
as a RemoteEvent (here, nothing is dropped). The same code works in Studio's play test
and in a game played alone: that machine is server and client at once.

### BindableEvents and BindableFunctions

For scripts on the same machine: `BindableEvent:Fire(…)` reaches everything connected
to its `Event` (tables arrive as the same table), and `BindableFunction:Invoke(…)`
returns what its `OnInvoke` function does.

### Folders and Values

`Instance.new` makes `IntValue`, `NumberValue`, `StringValue`, `BoolValue`,
`ObjectValue` (a part, Model, Value, Sound, player… or `nil`), `Vector3Value`,
`Color3Value` and `CFrameValue` — each with `Value` and `Changed` (which fires with the
new value) — to keep in parts,
Models, Folders, ReplicatedStorage or a Player. A Folder that goes into a Player or
ReplicatedStorage leaves the Workspace. Values the host changes reach every player,
and fire `Changed` there too. `WaitForChild` on ReplicatedStorage, a Player or a Folder
really waits — for something the host is about to make — and warns after five seconds.

### Leaderstats and the leaderboard

Give each player a Folder called `leaderstats` with Values in it, and the leaderboard
shows them top right: a column for each Value, a row for each player, sorted by the
first column, your own row picked out. **Tab** hides it.

```lua
-- A Script in Script Service
local Players = game:GetService("Players")

local function setUp(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = leaderstats
end

for _, player in Players:GetPlayers() do setUp(player) end
Players.PlayerAdded:Connect(setUp)

workspace.Coin.Touched:Connect(function(hit)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if player then
		player.leaderstats.Coins.Value += 1
	end
end)
```

Like the rest of the screen, the leaderboard is ordinary GUI — StarterGui ›
**PlayerList**, with its LeaderboardScript — so it can be restyled or deleted. New
scenes have it; older ones that kept the default HUD get it when opened.

### Stats: where the time goes

`game:GetService("Stats")` tells a script about this machine's frames, in
milliseconds and smoothed over about a third of a second: `HeartbeatTimeMs` (the whole
frame), `ScriptTimeMs`, `PhysicsStepTimeMs` and `RenderTimeMs`. It also has
`PrimitivesCount` (parts), `InstanceCount` and `GetTotalMemoryUsageMb()`. The default
HUD's numbers top right come from it. A joined player's are their own machine's.

### Raycasts

`workspace:Raycast(origin, direction, params)` finds the first thing along a line
`direction` long: a `RaycastResult` with `Instance`, `Position`, `Normal`, `Distance`
and `Material`, or `nil`. It meets parts and characters' body parts (whose `Parent` is
the character). `RaycastParams.new()` has `FilterDescendantsInstances` and `FilterType`
(`Enum.RaycastFilterType.Exclude` or `Include`), `IgnoreWater` and `RespectCanCollide`.

```lua
-- A LocalScript: what's under the mouse, from where the character stands.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
local root = player.Character:WaitForChild("HumanoidRootPart")
local mouse = player:GetMouse()

local params = RaycastParams.new()
params.FilterDescendantsInstances = { player.Character }   -- don't hit yourself
local result = workspace:Raycast(root.Position, (mouse.Hit.Position - root.Position).Unit * 300, params)
if result then
	local victim = Players:GetPlayerFromCharacter(result.Instance.Parent)
	print("hit", result.Instance.Name, "at", result.Position, victim and victim.Name)
end
```

### Saving progress: DataStores

`game:GetService("DataStoreService")` keeps things between games, as Roblox's does.
`GetDataStore(name, scope)` gives a store; `GetAsync(key)`, `SetAsync(key, value)`,
`UpdateAsync(key, function(old) … end)` (return `nil` to leave it), `RemoveAsync(key)`
and `IncrementAsync(key, delta)` read and write it. A value can be a boolean, a number,
a string or a table of them — a list or a dictionary, not both. Parts, Vector3s,
functions and the like are refused with Roblox's `104: Cannot store …` error. What
`GetAsync` hands back is a fresh copy each time.

`GetOrderedDataStore(name)` keeps whole numbers and hands them back sorted — a
top-scores board. `GetSortedAsync(ascending, pageSize, min, max)` gives pages of
`{ key = …, value = … }` (`GetCurrentPage`, `IsFinished`, `AdvanceToNextPageAsync`).

Only the server's scripts can use them; a LocalScript gets `DataStore can't be
accessed from client`. What's saved is kept by the machine running the game — in a
network game, the host — under `~/Library/Application Support/Studio/DataStores`, a
folder per place. Every place has an id of its own, saved in its file: a place saved
under another name keeps its data, and a new place starts with none. Save players by
`Name`, so they're the same person next time whoever hosts. Studio's Play and the
client share what's saved; File › **Clear Saved Data for This Place…** starts over.

```lua
-- A Script in Script Service: coins that are still there next time.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local CoinStore = DataStoreService:GetDataStore("Coins")

local function key(player)
	return "player_" .. player.Name
end

local function setUp(player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = leaderstats

	local ok, saved = pcall(function()
		return CoinStore:GetAsync(key(player))
	end)
	if ok and saved then
		coins.Value = saved
	end
	coins.Changed:Connect(function(value)
		CoinStore:SetAsync(key(player), value)
	end)
end

for _, player in Players:GetPlayers() do setUp(player) end
Players.PlayerAdded:Connect(setUp)
```

The sample games save too: Adventure Island your gems, wins and rewards; Nightfall
your best score, with the top five after every run; Mega Obby your furthest stage and
wins, so you carry on from there.

### Finding the way: PathfindingService

`game:GetService("PathfindingService"):CreatePath(agent)` makes a path for an agent
of a size — `AgentRadius` (2), `AgentHeight` (5), `AgentCanJump` (true),
`WaypointSpacing` (4) and `Costs` (by material, `math.huge` to keep out:
`{ Water = 20, Neon = math.huge }`). `path:ComputeAsync(start, finish)` finds a way
round anything in the between, over the tops of parts and the ground. It goes up
only as high as a character can step (2 studs), or jump (about 6) if it may. Then
`path.Status` is `Enum.PathStatus.Success` (or `NoPath`, `FailStartNotEmpty`,
`FailFinishNotEmpty`). `path:GetWaypoints()` gives `PathWaypoint`s, each with
`Position` and `Action` (`Walk`, or `Jump` for one to jump up to). `path.Blocked`
fires with a waypoint's index when something comes to stand in the way, and
`path:CheckOcclusionAsync(from)` says where now (or -1).

The world is seen as a grid of 2-stud squares, so a gap has to be a little wider than
the agent to get through. The agent's own body, where the path starts, doesn't count.

```lua
-- A LocalScript in StarterCharacterScripts: walk round anything in the way to the Flag.
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local character = Players.LocalPlayer.Character
local humanoid = character:WaitForChild("Humanoid")
local root = character:WaitForChild("HumanoidRootPart")

local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentCanJump = true })
path:ComputeAsync(root.Position, workspace.Flag.Position)
if path.Status == Enum.PathStatus.Success then
	for _, waypoint in path:GetWaypoints() do
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(waypoint.Position)
		humanoid.MoveToFinished:Wait()
	end
end
```

Nightfall's zombies use it: when a wall or a house is between a zombie and whoever
it's after, it follows a path round, worked out again every second or so.

### NPCs: a Model with a Humanoid

Put a **Humanoid** in a Model and the game walks it, as it does the player. It walks at
its `WalkSpeed`, falls, steps up kerbs, jumps and stops at walls. Its arms and legs swing
as it goes. **Insert › Rig** (on the ribbon too) makes one ready to walk: a Model of
Head, Torso, arms, legs and an invisible HumanoidRootPart, with a Humanoid. To make any
other Model walk, right-click it in the Explorer and choose **Add Object › Humanoid**. A
script can do the same with `Instance.new("Humanoid", model)`.

A script steers it through its Humanoid:

- `humanoid:MoveTo(position)`, then `humanoid.MoveToFinished` fires with `true` when
  it's within a stud of the spot. It fires with `false` if something held it up for
  eight seconds.
- `humanoid:Move(direction)` walks it one way until told otherwise.
- `humanoid.Jump = true` makes it jump.
- It reads `MoveDirection`, `WalkToPoint`, `RootPart` and `GetState()`.

`Health`, `MaxHealth`, `WalkSpeed`, `JumpPower` and `AutoRotate` are set in Properties or
by scripts. `TakeDamage(amount)` hurts it, firing `HealthChanged`. At no health it fires
`Died` (once), and its parts are let go to fall. Moving it with `PivotTo` puts it there,
and it walks on from where it lands.

Only the host walks NPCs: joined players see the parts move, and hear `HealthChanged`
and `Died` too.

```lua
-- A Script: the Rig walks round the wall to the Flag, then keeps going.
local PathfindingService = game:GetService("PathfindingService")
local rig = workspace.Rig
local humanoid = rig.Humanoid

local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentCanJump = true })
path:ComputeAsync(rig.HumanoidRootPart.Position, workspace.Flag.Position)
if path.Status == Enum.PathStatus.Success then
	for _, waypoint in path:GetWaypoints() do
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			humanoid.Jump = true
		end
		humanoid:MoveTo(waypoint.Position)
		humanoid.MoveToFinished:Wait()
	end
end
```

## Wren, the second language

Scripts can also be written in [Wren](https://wren.io) (`Sources/CWren`, 0.4.0).
Pick the language per script — the segmented control in the script editor, or
**New Wren Script** in the Explorer's `+` menu — and each shows a `lua` or `wren`
badge. Both kinds run together in one scene, each in its own VM; they share the scene
but cannot call each other.

```wren
import "studio" for Workspace, Runtime, Vec3
import "math" for Math, Ease, Rand, Noise

var orb = Workspace.find("Orb")
Runtime.onUpdate { |dt| orb.position = orb.position + Vec3.new(0, dt, 0) }
```

The Wren API is its own, in Wren's style: `Workspace`, `Part` (`position`, `size`,
`rotation`, `color`, …), `Vec3`, `Color`, `Player`, `Shaders`, `Screen`, `Runtime`
(`time`, `log`, `onUpdate`) and `script`; plus a `math` module with `Math`, `Ease`,
`Rand` and `Noise`.

**Luau comes first.** New scripting features land in Luau and reach Wren on alternate
major releases, so Wren trails by up to one release. And one real difference: **Wren
has no watchdog** — an endless loop in a Wren script hangs the app, because Wren has
no hook to interrupt it.

Scene files saved before Luau existed hold Wren scripts with no language field; they
open as Wren and run exactly as before.

## The script editor

**Scripts open in tabs, full size, as in Roblox Studio.** Double-click a script in the
Explorer (a new one opens straight away) and it takes over the middle of the window;
the **World** tab, first in the strip above, takes you back to the 3D view. Shaders
open the same way, with their parameters beside the code, and the built-in
ControlScript and Health open read-only. Each tab keeps its caret, scroll position and
undo history while another is in front. **⌘W** closes a tab, **⇧⌘]** and **⇧⌘[** step
through them, and **Play** always brings the world to the front — behind a script tab
a play test keeps running, so you can read code while the game plays.

**The Output console runs along the bottom**, under whichever tab is showing. Click an
error in it and its script opens at that line. Drag the console's top edge to make it
taller or shorter; its chevron, or **View ▸ Show or Hide Output** (⌥⌘0), tucks it away.

While you type, the editing keys belong to the code: **⌘X**, **⌘C** and **⌘V** cut,
copy and paste, **⌘Z** undoes typing (the world's
undo is separate, and undoing a part move never touches code), **⌘A** selects all the
text, **⌘⌫** deletes to the start of the line, **⌘F** finds and **⌘G** finds the next
match. With the world in front they edit the world as before.

The editor is an `NSTextView`, not SwiftUI's `TextEditor`: the caret stays where you left it, smart
quotes and dashes are off so string literals stay intact, and new lines keep their
indentation (tabs in Luau, as in Roblox Studio; spaces in Wren).

It has **line numbers**, the caret's line brighter. It **highlights** whichever language the script is in — including Luau's backtick
strings with `{expressions}`, long `[[ ]]` strings and `--[[ ]]` comments.

It **suggests as you type**, resolving what the thing left of the caret is:

```lua
local RunService = game:GetService("RunService")
RunService.        →  Heartbeat, Stepped, RenderStepped
RunService.Heartbeat:   →  Connect(callback), Once(callback), Wait()
local orb = workspace:FindFirstChild("Orb")
orb.               →  Position, Size, Color, Anchored …      (properties after .)
orb:               →  Destroy(), Clone(), IsA(className) …   (methods after :)
```

`GetService` resolves by its string argument, and locals are typed from what they were
assigned (or from a type annotation).

The list is meant to help without getting in the way:

- **Nothing goes into your code until you choose.** The list sits under the word; keep
  typing and it narrows, or ignore it.
- **Tab** puts in the highlighted suggestion. **Return** does only once you've picked one
  with **↑** and **↓**; otherwise Return is a new line, even with the list open. So
  `end`, `then` or `do` followed by Return never needs Return twice. **Esc** closes the
  list, and **⌥Esc** opens it when you want it.
- After a dot or colon it opens at once. For a word it waits until two letters are typed
  and you pause, so words typed straight through don't flash a list.
- It stays away where it can't help: a word already typed in full, a new name
  (`local x`, `for i`, a function's name and parameters), the middle of a word, the dot
  in a number (`0.5`), comments and strings.
- **The best match comes first:** matches in the case you typed (`en` gives `end`
  before `Enum`), then your script's own locals, then keywords, globals and libraries.

The same list serves Wren and the shader editor.

**Luau suggestions know your scene and your ModuleScripts:**

```lua
local TweenService = game:GetService("   →  TweenService first, then every other service
                                            (those the script already has last); Tab
                                            closes the string and the call. Right after
                                            GetService( it puts the quotes in too.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Utils = require(          →  Utils, Config, Enemy …  every ModuleScript, as a path:
                                   ReplicatedStorage.Utils), script.Parent.Enemy) …
ReplicatedStorage.              →  Utils, Shared, Notify …   what's really in it
ReplicatedStorage:WaitForChild("  →  the same names, closing the string and the call
workspace.Tower.                →  Door, Roof …  and Model's properties
script.Parent.                  →  whatever the script sits beside

local Utils = require(ReplicatedStorage.Utils)
Utils.                          →  lerp(a, b, t), speed, colours …  what the module returns
Utils.colours.                  →  red, blue
local goblin = Enemy.new("Goblin")
goblin:                         →  TakeDamage(amount), Die()   a class's methods
```

After `require(` the list shows every ModuleScript in the place, each as the path from
the script you're in. A module beside the script is reached through `script.Parent`.
Anywhere else it goes through the script's own `local ReplicatedStorage =
game:GetService(…)` if there is one, and through `game:GetService` otherwise. Inside
`require(…)`, a place's list shows only what leads to a module.

What a module hands back is read from its code, without running it:

- `local M = {}` then `M.name = …`, `function M.name(…)` and `function M:name(…)`,
  then `return M`
- `return { … }`
- a class whose constructor calls `setmetatable`: its objects get the class's methods
  and their `self.` fields

A module built some other way just isn't listed.

### Debugging: breakpoints, stepping and variables

**Click beside a line number** in a Luau script for a breakpoint (a red tag), or press
**F9** on the caret's line; click again to take it away. When a line with one runs —
in a Script, a LocalScript, a ModuleScript's function or a character script, while
playing or running — **the game stops**: every script, the physics and the character
freeze, the script opens at that line (lit, with an arrow), and the **Debugger** tab
along the bottom shows:

- **Call Stack**: the function it's in and each line that called it, down to the
  script. Click one to see its line and its variables.
- **Variables**: the call's locals and upvalues, with their values — numbers, strings,
  a table's first few entries, a part as `Part "Door"`, a player as `Player "Robin"`.
- **Breakpoints**: every one in the place. Click to go there; × takes it away.

Then **Continue** (F5), **Step Over** (F10: the next line, not into what it calls),
**Step Into** (F11: into a function the line calls), **Step Out** (⇧F11: back to
the caller) or **Stop**. The same are in the Test menu. A breakpoint on a line with no
code stops at the next line that has some. Breakpoints are saved with the place, and
added lines above one move it down. They're not edits: nothing to undo, and Stop
keeps them.

Luau only: Wren scripts have no breakpoints yet.

## Working on this

`AGENTS.md` is the engineering contract: architecture invariants, recipes for common
changes, and known limitations. Read it before changing anything.

Two tools for checking the engine over a long game:

- The self-tests include a soak of their own: every sample game played for a
  minute, and a host with a joined player, failing if anything keeps growing.
- `swift run StudioApp --soak nightfall 300` plays a sample game (adventure,
  nightfall or obby) headlessly for 300 seconds of game time, a player running about
  and fighting. Every ten seconds it prints the memory used and how many parts,
  Sounds, GUI objects and so on there are, so anything that keeps growing shows up.
  Add `render` to draw every frame too, `audio` to play through the real audio engine,
  or `window` to draw into a real window in real time.
- `swift run StudioApp --bench` prints what finding, changing and moving parts and
  Models costs in scenes of 500, 2000 and 8000 parts.
- `swift run StudioApp --make-place nightfall Nightfall.json` writes a sample game as
  a place file, to open in Studio or play straight away with
  `StudioClient.app/Contents/MacOS/Client Nightfall.json`.

## Writing shaders

Parts can draw with a shader you write yourself, in Metal. Shaders live under
**Shaders** in the Explorer; double-clicking one opens it in a tab, full size, beside
its parameters and a list of everything in scope.

You write only the body of a fragment function — the host generates the surrounding
Metal, so a mistake can produce a compile error but can never desync a uniform
struct or break the vertex stage. You are given:

| | |
| --- | --- |
| `float3 worldPosition` | this pixel's position in the world |
| `float3 normal` | the surface direction, normalized |
| `float3 viewDirection` | towards the camera, normalized |
| `float3 lightDirection` | towards the light, normalized |
| `float3 baseColor` | the part's own colour |
| `float3 cameraPosition` | where the camera is |
| `float time` | seconds since the viewport started |
| `float shadow` | 1 in sunlight, 0 in shadow — soft between (shadow map or ray traced) |
| `float3 lightColor` | the sun's colour and strength; 1 at the default lighting |
| `float3 ambientColor` | sky and ambient light reaching this point (with occlusion when ray traced) |

…plus every parameter you declare, by name. Return a `float3`. Point lights, fog and
exposure are added to what you return, so every part sits in the same lighting.

```metal
// The Pulse shader that ships with the starter scene, on the Orb.
float diffuse = saturate(dot(normal, lightDirection)) * shadow;
float3 lit = baseColor * (ambientColor + diffuse * lightColor * 0.85);

float facing = saturate(dot(normal, viewDirection));
float rim = pow(1.0 - facing, 2.5);

float pulse = 0.5 + 0.5 * sin(time * speed);
return lit + float3(0.45, 0.85, 1.0) * rim * (0.35 + 0.65 * pulse) * glow;
```

It recompiles about half a second after you stop typing, off the render thread. While
it is compiling — or if it is broken — the part keeps drawing with the last version
that worked, so the viewport never goes black. Errors appear under the editor and in
the Output console, reported against **your** line numbers.

Parameters are named floats with sliders (up to sixteen per shader), and scripts can
drive them:

```lua
local pulse = Shaders:FindFirstChild("Pulse")
pulse:SetParameter("glow", 1.5)           -- drive a parameter
pulse:ApplyTo(workspace.Tower)            -- put it on another part
workspace.Orb.Shader = nil                -- back to the built-in shading
```

`Shaders:FindFirstChild`, `:GetChildren`, `:GetScreenShaders`; on a shader: `Name`,
`Kind`, `Enabled`, `Compiled`, `:GetParameter`, `:SetParameter`, `:GetParameters`,
`:ApplyTo`; and `part.Shader` reads or assigns one. (Wren: `Shaders.find`,
`shader.set`, `part.shader`.) Shaders are saved in the scene and run in the
client just as they do in the editor.

### Screen effects

A **screen shader** is a sheet of glass in front of the camera: the world is drawn
into a texture, and your shader gets the finished picture. They live under **Screen**
in the Explorer, separate from surface shaders, because they belong to the view rather
than to anything in the Workspace. Tick the box beside each one you want on: several
can be on at once, and they run one after another, top to bottom as listed — each
getting the picture the one above made. Right-click one for **Move Up** or **Move Down**
to change the order.
Scripts can do the same with `Screen:AddShader(shader)`, `Screen:RemoveShader(shader)`
and `Screen:GetShaders()` (`Screen.Shader` is the first, and setting it switches that
one on alone).

When none is switched on, the renderer draws straight to the screen exactly as it
always did. Nothing is allocated and nothing is copied; "off" costs nothing at all.

A new screen shader starts out passing the picture straight through:

```metal
return sceneColor;
```

and you get:

| | |
| --- | --- |
| `float3 sceneColor` | the rendered pixel |
| `float2 uv` | 0–1 across the screen, (0,0) top left |
| `float2 resolution` | the viewport size in pixels |
| `float time` | seconds |
| `float depth` | raw depth buffer value, 0 near → 1 far |
| `float distance` | the same depth in studs from the camera |
| `sample(uv)` | read any other pixel of the scene |

Both depth forms are there on purpose. The raw buffer is wildly non-linear — almost
all its precision sits in the first few studs — so a first fog shader written with
`depth` looks broken a metre from the camera. `distance` is that value linearised, so
fog is `saturate(distance / 200)` and simply works.

`sample(uv)` is what turns it from a tint into image processing — blurs, edge
detection and bloom all need to read their neighbours:

```metal
float2 px = 1.0 / resolution;
return abs(sample(uv + float2(px.x, 0)) - sample(uv - float2(px.x, 0))) * 4.0;
```

**Black & White** ships with the starter scene, switched off so the scene opens in
colour. Switch it on in the Explorer:

```metal
// Luma weights, not a plain average: the eye reads green as far brighter than
// blue, so (r + g + b) / 3 gives a muddy grey that looks wrong.
float luma = dot(sceneColor, float3(0.2126, 0.7152, 0.0722));
return mix(sceneColor, float3(luma), amount);
```

Selection boxes and the gizmo are drawn *after* the effect, so the world goes grey
while the things you edit with stay legible. In the client there are no overlays, so
the whole frame is affected — a real black-and-white mode.

From a script:

```lua
Screen.Shader = Shaders:FindFirstChild("Black & White")
Screen.Shader:SetParameter("amount", 0.5)
Screen.Shader = nil
```

A **LocalScript** that switches a screen effect on or off changes only its own
player's screen, as in Roblox: that's how Adventure Island tints the view in the caves
for the player who is there and nobody else. A Script (on the host) changes it for
everyone.

**One caveat worth knowing.** A Luau script that goes wrong is contained — reported,
disconnected, or stopped by the watchdog. A *shader* that goes wrong cannot be contained the same way: compile
errors are caught cleanly, but a shader that loops forever hangs the GPU, and that is
a hardware watchdog event, not something the app can catch. Broken code is safe;
infinite loops are not.

## Layout

```
Sources/StudioApp/main.swift      editor entry point
Sources/StudioClient/main.swift   client entry point
Sources/StudioKit/
  App/EditorLauncher.swift  editor window and menu bar
  App/ClientLauncher.swift  client window and menu bar
  App/LaunchClient.swift    editor → standalone client handoff
  SelfTest.swift            headless verification suite
  PlaySelfTest.swift        collision, camera and character verification
  PlayerSelfTest.swift      Humanoid, ControlScript, Health, respawn and the player API
  Math/MathUtil.swift       matrices, quaternion↔euler, ray/shape intersection
  Model/Part.swift          the Part record (shape, transform, colour, material)
  Model/SceneModel.swift    parts, selection, snapping, undo/redo, scene files
  Model/ScriptObject.swift  a script, and the scene state undo and saving use
  Model/ScriptTemplates.swift  the code a new script starts with, place by place
  Model/ShaderObject.swift  a user shader and its named parameters
  Model/SceneDocument.swift file tracking, dirty state, model export and insert
  Model/EditorSession.swift Play and Run, scene restore and the open tabs
  Scripting/LuauInterpreter.swift  the Luau VM wrapper (over the CLuau C shim)
  Scripting/StudioLibrary.swift    the Roblox-flavoured library, written in Luau
  Scripting/WrenInterpreter.swift  the Wren VM wrapper
  Scripting/WrenModules.swift      Wren's `studio` and `math` modules
  Scripting/ScriptRuntime.swift    runs both VMs, the host calls they share, errors
  Editor/                   lexers and completion for Luau, Wren and Metal
  Scripting/ScriptConsole.swift    buffered output for the console, and LogService
  Render/Camera.swift       orbit + fly camera, screen→world picking rays
  Render/Mesh.swift         procedural block/sphere/cylinder/wedge/gizmo geometry
  Render/Shaders.swift      Metal source, compiled at runtime
  Render/Renderer.swift     pipelines, draw order, gizmo and avatar drawing
  Render/ShaderSource.swift generates the Metal around a user's fragment body,
                            for surface shaders and for full-screen effects
  Render/ShaderLibrary.swift  debounced background compilation and pipeline swap
  Render/ViewportSource.swift  what the renderer draws a frame from
  Play/Collision.swift      capsule vs. part contacts and surface normals
  Play/CharacterController.swift  gravity, walking, step-up, ground probes
  Play/PlayerCamera.swift   third/first person camera with wall avoidance
  Play/PlayController.swift input, simulation, events for scripts
  Model/DefaultHud.swift    the PlayerHud a new scene starts with, in StarterGui
  Model/AdventureIsland.swift  the sample game's world, built in code
  Model/AdventureIslandScripts.swift  its Luau scripts and shaders
  AdventureSelfTest.swift   plays the sample game, alone and with two players
  Interaction/Picking.swift        exact per-shape ray tests
  Interaction/Gizmo.swift          handle hit-testing and drag math
  Interaction/ViewportController.swift  camera + drag state owned outside SwiftUI
  UI/                       ribbon, viewport bridge, Explorer, Properties, the
                            tabs (world, scripts, shaders), the Output console,
                            the code editor, the client's menu screens
Sources/CLuau/              Luau 0.640 (VM, Compiler, Ast), vendored verbatim, plus a C shim
Sources/CWren/              Wren 0.4.0, vendored verbatim (MIT)
Sources/CJolt/              Jolt Physics 5.6.0, vendored verbatim (MIT), plus a C shim
```

The renderer draws from a `ViewportSource`, which the editor viewport and the play
session both implement — so the editor's Play button just swaps the frame source
rather than standing up a second Metal stack.

Each shape is generated inside a unit cube, so a part's `size` scales the mesh directly
and picking can test the ray in the part's local space.
