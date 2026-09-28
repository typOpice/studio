# AGENTS.md — orientation for AI agents working on this repo

Read this before changing anything. It covers what exists, the invariants that are
easy to break silently, and recipes for the changes you are most likely to be asked
for. `README.md` is the human-facing guide; this file is the engineering contract.

---

## 1. What this is

A Roblox-Studio-style 3D editor and a play client for macOS, in Swift + Metal. Scripts
are written in **Luau** (primary, Roblox-flavoured API) or **Wren** (secondary); users
also write Metal shaders for surfaces and full-screen effects.

| Target | Kind | Contents |
| --- | --- | --- |
| `StudioKit` | library | Everything: model, renderer, physics, scripting, shaders, both UIs |
| `StudioApp` | executable | 4 lines — calls `StudioEditor.run()` |
| `StudioClient` | executable | 4 lines — calls `StudioClientApp.run()` |
| `CLuau` | C++ target | Luau 0.640 (VM, Compiler, Ast) verbatim, plus our C shim |
| `CWren` | C target | Wren 0.4.0, verbatim (MIT) |

The executables are deliberately trivial so both apps share one module and nothing
needs `public` access modifiers. **If you add an entry point, keep the logic in
`StudioKit`.**

### Language policy

**Luau is primary and gets every new scripting feature first. Wren catches up on
alternate major releases** — so the Wren API may trail Luau's by up to one major
release. When you add a scripting feature, do the Luau side (library, host call,
completion, tests) now; mirror it into Wren only when the release is a Wren release,
or when asked. Do not let Wren work block a Luau change.

### Where to look first

| To change… | Start in |
| --- | --- |
| What scripts can call (Luau) | `Scripting/LuauLibrary/NN-*.swift` for the Luau side, `Scripting/ScriptRuntime+<Namespace>.swift` for the host side (`part.get` → `ScriptRuntime+Parts.swift`); the player's calls are in `Play/PlayerHost.swift` |
| The scene's data, undo, saving | `Model/SceneModel.swift` (state, selection, undo), `SceneModel+Scripts/Shaders/Animations/StarterScene.swift`, `SceneTree.swift`, `Constraints.swift` |
| What happens when you press Play | `Play/PlayController.swift` (the frame), `Play/Physics/PhysicsWorld.swift` (the only Swift that talks to Jolt), `Play/CharacterController.swift` |
| Multiplayer | `Network/LAN.swift` (the wire), `App/ClientSession.swift` (hosting, joining, syncing), `Play/PlayController+Multiplayer.swift` (the other players in a game) |
| Tools | `Model/SceneModel+Tools.swift` (where a Tool is, parked parts), `Play/PlayController+Tools.swift` (Backpack, hand, clicks, pick-ups; `backpack.*`), `Scripting/LuauLibrary/12-Tools.swift`, `CoreScripts.backpackScript` (the hotbar) |
| The screen GUI and chat | `Play/Gui.swift` (GuiObject, GuiStore, layout), `UI/GuiLayer.swift` (drawing), `Play/PlayController+Gui.swift` (`gui.*`/`chat.*` host calls, typing), `Scripting/LuauLibrary/09-Gui.swift` (the Luau side), `CoreScripts.chatScript` (the chat window, in Luau) |
| The editor's window | `UI/ContentView.swift` (layout, ribbon), `UI/DocumentViews.swift` (tabs), `UI/ExplorerView.swift`, `UI/PropertiesView.swift` |
| Drawing | `Render/Renderer.swift`, shaders in `Render/Shaders.swift` and `Render/LightingShaders.swift` |

Most features touch three places: the model (so it saves and undoes), the play session
(so it runs), and a test. Search for an existing feature like yours — a Luau call name
such as `"part.get"` finds both sides of the bridge — and follow it.

## 2. Commands

```bash
swift build                          # build everything (first build compiles Luau: slow)
swift run StudioApp --selftest       # 2977 checks — THE test suite, ~5 minutes
swift run StudioApp --selftest --only Editor   # one suite while you work (see SelfTest.swift)
swift run StudioApp                  # run the editor
swift run StudioClient [scene.json]  # run the client
./make_app.sh release                # produce Studio.app and StudioClient.app
```

**Xcode 27 is installed and selected** (`xcode-select -p` →
`/Applications/Xcode.app/Contents/Developer`; Swift 6.4, the newer Metal compiler),
and the package builds cleanly with it — keep it free of new warnings. But the project
does **not** depend on Xcode: it began on a Mac with Command Line Tools only, and it
must still build there. That is why Metal shaders compile at runtime from Swift
strings, why Luau, Wren and Jolt are vendored as source, and why there is no Xcode
project. Do not "fix" any of that. (The newer Metal compiler rejects lambdas in shader
source: use a macro, as the screen-effect wrapper's `sample` does.)

## 3. The test suite is the contract

`Sources/StudioKit/*SelfTest.swift` is a hand-rolled headless suite (no XCTest — it
has to run inside the app binary so it can exercise Metal, AppKit and both VMs). It is
**not** decorative: every bug listed in §6 was found by it, and most would be
invisible in casual manual testing.

**Always run `swift run StudioApp --selftest` before reporting a change as done, and
add checks for anything you fix.** A change that makes the suite fail is not finished.
The process exits 0 only when everything passes; a crash shows up as exit 133 with
output cut off mid-line — get a backtrace with
`lldb --batch -o run -o bt -- ./.build/debug/StudioApp --selftest`.

**Every new feature must be tested in multiplayer, not just alone.** A feature isn't
done until a self-test shows it working in a game that one client hosts and another
joins over the local network. Do it the way `LANSelfTest.testClientSession` does,
over loopback so it needs no second Mac:

1. Build a scene that uses the feature, in a `ClientSession` with its own
   `UserDefaults` suite (never `.standard` — tests must not touch the user's profile).
2. `hostOnLAN(advertise: false)`, wait for `host.port`, then join from a second
   `ClientSession` with a `LANGame` whose endpoint is `LANSelfTest.loopback` and that port.
   That is `localhost`, not `127.0.0.1`: a network policy on a Mac (a VPN, say) can make
   Network.framework refuse IPv4 loopback with "Can't assign requested address" while
   plain sockets and `::1` work — then every join times out and nothing says why.
3. Check the feature on **both** sides: the joiner got it intact in the host's scene,
   it runs there without errors, and it behaves the same for the host and the joiner.
   Anything tied to a player — names, colours, input, the character — must be checked
   for each player separately, never assumed from the host's.

Players share one world run by the host (invariant 74), so the test must also show the
feature staying in step between host and joiner — `LANSelfTest.testChat` is a short
example that drives both players' input and checks both screens. A feature that can't work
in multiplayer is only acceptable if its test says so explicitly and the limitation is
listed in §9.

| File | Covers |
| --- | --- |
| `SelfTest.swift` | Entry point + render loop, shaders, uniform layout, mesh winding, camera, picking, gizmos, undo |
| `PlaySelfTest.swift` | Collision shapes, player camera, character controller |
| `HierarchySelfTest.swift` | The tree: children, ancestry, grouping, ungrouping, moving, duplicating and deleting subtrees, pivots, saving and model files; Luau CFrame maths and the Instance hierarchy API |
| `JointsSelfTest.swift` | Squashed shapes as hulls; welds as assemblies (offsets kept, anchored spreads, disabling); hinges (swing, hinge point, limits, motor, servo); ball socket, rope, spring, slider; editor commands, saving; the click-to-join tools (two clicks, whole-selection on pick and its setting, Unjoin, viewport click routing); the Luau Attachment and constraint API |
| `PhysicsSelfTest.swift` | Physics against textbook numbers: fall distance, resting height, a six-box tower, sliding distance, bounce, rolling down a wedge, no tunnelling, scene sync, collisions, 100-box timing; in play: landing on the player, pushing light vs heavy, the script API, part-to-part Touched, falling out of the world; a dead character's capsule going, and coming back with the next |
| `LightingSelfTest.swift` | Sun/moon/sky maths, lighting saving and undo, uniform layouts, the Luau Lighting and PointLight API, both user-shader variants, and **rendered frames read back pixel by pixel**: shadows, GlobalShadows, exposure, night, point lights and range, fog, and (if the GPU can) ray-traced shadows, occlusion, reflections and point-light shadows |
| `AnimationSelfTest.swift` | Animation keys, sampling and easing, saving/undo, track playback (fades, loops, markers), priority layering, the editor (snapping, posing, picking, preview), the Luau AnimationTrack API |
| `AvatarSelfTest.swift` | Avatar meshes (size, face placement), body layout and facing, walk/jump/fall/fly/dead animations, blending |
| `PlayerSelfTest.swift` | Humanoid, default ControlScript/Health, respawn and scopes, player Luau API, StarterPlayer saving; a tap of Space is one jump, holding repeats, jump pads work; the first character isn't re-announced |
| `ScriptSelfTest.swift` | **Luau**: the library, scheduler (task: defer in the same frame and nested, a runaway defer, cancel on waits/defers/events and its refusals, argument errors, the deprecated wait/spawn/delay, synchronize), watchdog (slow host calls not counted, a loop after one still stopped), sandbox, errors; both languages together |
| `WrenScriptSelfTest.swift` | **Wren**: the VM, `studio` module, host bridge |
| `WrenMathSelfTest.swift` | Wren's `math` module, through the real VM |
| `ShaderSelfTest.swift` | Surface shaders: generated Metal, error line mapping, compile pipeline |
| `ScreenShaderSelfTest.swift` | Full-screen effects, rendered on the GPU and read back |
| `DocumentSelfTest.swift` | Scene files, dirty tracking, model export, old-file compatibility, repairing a file with duplicate ids |
| `EditorSelfTest.swift` | Code-editor caret, selection, indent, substitutions, highlighting; the suggestion list, typed into as a keyboard does (waiting for a pause, nothing written until chosen, Return a new line unless one was picked with the arrows, Tab, Esc, ⌥Esc, a word typed in full, `end`/`then`/… then Return in one press, naming a local, a loop variable or a parameter, inside a word, a number's dot, comments, Backspace widening, moving off the word, clicking a row, one undo step, placed under the word; Wren and Metal through it; `require(` and Tab, a module's functions, `WaitForChild("` names with a space, `GetService("` and `GetService(`); Cut/Copy/Paste in the menu, and no two menu commands on one shortcut |
| `GuiLayoutSelfTest.swift` | UIListLayout (order, padding, alignments, horizontal), AutomaticSize (text and frames), ScrollingFrame (automatic canvas, clipping, bar, the wheel, its end), ClipsDescendants, TextScaled, fonts, the TextBox caret, ⌘A, paste, TextEditable; the new classes from Luau (enums, ImageButton, BillboardGui Adornee and where it's drawn, CursorPosition); StarterGui (made, only changes kept, saved, undone, previewed with the selection outlined, copied at play, its LocalScript and clicks, ResetOnSpawn on and off, one copy per player over the network) |
| `HudSelfTest.swift` | The default HUD: in the starter and new scenes, old files given it on opening, a deleted one staying deleted, an old custom ControlScript keeping F and R, Insert Default HUD; in play its health bar, countdown, numbers, H, ` and the output (through LogService, MessageOut, GetLogHistory), error count, first-person crosshair (MouseBehavior LockCenter), F and R; a scene without it showing nothing and F, R, ` doing nothing; host and joiner each with their own, R and F only their own |
| `SelectionSelfTest.swift` | One thing selected at a time (parts, GUI objects, Sounds, files, scripts), a click on empty space leaving nothing selected, Esc deselecting everything (join tool, Lighting, StarterPlayer; the Animation tab's animation kept) through the window's key monitor wherever the keyboard is, but not in play |
| `GuiEditorSelfTest.swift` | UIStroke, UIGradient, UIGridLayout (cells, max per row, alignment, StartCorner, vertical, order), UIAspectRatioConstraint (both types, both axes), UISizeConstraint, UITextSizeConstraint — laid out, drawn and read back (stroke outside the border, Contextual round text, gradient along and turned, transparency), from Luau (ColorSequence/NumberSequence and their errors, per-class Color types, enums, IsA), saved (no infinities), and copied for a joined player with a LocalScript reading them; the GUI tab: inserting where the selection says, one of each modifier, Align/Fill/Front/Back/Duplicate/Delete, To Scale/To Pixels, device previews, dragging (live then one undo step, units kept, guides, grid, handles, AnchorPoint, layouts), arrow keys, and a real click and drag in a window with a click beside it reaching the world |
| `GuiSelfTest.swift` | The screen GUI: UDim2/AnchorPoint layout, nesting, ZIndex, UICorner, UIPadding, Visible/Enabled; focus, typing and clicks; the Luau GUI API; keys going to a TextBox and not the game (real key events through the viewport); TextChatService; the default ChatScript (`/`, Return, Escape, eight lines, an edited copy, turned off) |
| `SplitAndEffectsSelfTest.swift` | Split view hosted in a real window (both showing, half the width each, the keyboard staying in the code, Delete deleting code not parts, a click giving the world the keyboard); screen effects chained, drawn and read back (one, two in Explorer order, reordered, one switched off, saved, old files); `Screen:GetShaders/AddShader/RemoveShader`; effects reaching a joiner |
| `TweenSelfTest.swift` | TweenInfo and TweenService:Create: timing, easing, delay, pause/resume, cancel, one tween taking over another, reverse and repeat, GUI values, the errors; a host tween reaching a joiner |
| `MovementSelfTest.swift` | The world moving the character: platforms carrying and turning it, a wall and a thrown crate pushing it; Seats (class, Occupant, Sit, SeatPart, Seated, getting up, Disabled); climbing a TrussPart (up, hold, down, top, jumping off); swimming (floating, Space, out onto land); in multiplayer a joiner pushing crates like the host, sitting, climbing, and riding the host's platform |
| `MouseSelfTest.swift` | The mouse in play: Player:GetMouse (Hit, Target, Button1Down), ClickDetectors (connected before parenting, hover in and out, click, reach), MouseBehavior; real clicks through the viewport with the pointer free; a joined player hovering and clicking on the host |
| `ToolSelfTest.swift` | Tools: StarterPack and parked parts (no picking, undo, saving), a copy per character, the hotbar's keys and slots, the hand (in front, following, arm out, not collided with), clicks, Backspace dropping, picking up by the Handle, respawning, the Luau API (StarterPack, Backpack, EquipTool, Parent, Instance.new, Enabled); a sword fight between host and joiner |
| `RunModeSelfTest.swift` | Studio's Run mode: no player (no character, no StarterPlayer scripts, no LocalPlayer), the editor keeping input, scripts and physics running on the editor's frames, Stop restoring; events still reaching scripts (part-to-part Touched, a Sound's Ended) |
| `AudioSelfTest.swift` | Pictures and sounds (WAV and PNG made in memory): importing (kinds, refusals, unique names, references, rename, undo, saving); a sound file imported from disk, the place saved through `SceneDocument`, the file deleted, the place reopened, played and hosted for a joiner; Models saving their Sounds and files, and inserting them (brought, shared, renamed with Sounds and scripts following, undone); decoding and mono mixdown, fading with distance; a part's Sounds deleted and copied with it; the Luau Sound/SoundService API against a `RecordingOutput` (3D position, volume, TimePosition, Pause/Resume, Ended once, Looped, PlaybackSpeed, reach, Stop, Destroy, a Sound made in Studio playing at start, read-only and typed properties, LocalScript Sounds kept local through task.spawn and events); an ImageLabel drawing its picture (rendered and read back); the StarterGui preview's pictures; a host's Sounds heard by a joiner (same part, stopping, ending) while each machine's LocalScript Sounds stay its own |
| `MeshSelfTest.swift` | MeshParts (OBJ, STL and PLY made in memory): decoding (triangles, size, texture coordinates, hard edges kept when a file has no normals, squeezed into the unit cube, the hull and its volume, a broken file refused); inserting (size, on the ground, too-big models rescaled, fidelity and picture undoable, Reset Size, saving, old files); an arch clicked through its opening whatever it collides as, and walked into by each CollisionFidelity (Precise lets a capsule stand in the opening, Hull and Box push it out, pillars push sideways, turned); Jolt with a cup (a block lands inside a Precise one, on top of a Hull or Box one) and an unanchored MeshPart resting and weighing its hull; drawn plain, textured and ray traced and read back; the Luau MeshPart API (Instance.new, ClassName, IsA, MeshId → MeshSize, TextureID, CollisionFidelity, the errors, Clone); saved Models carrying models and pictures and renaming a clash; a joiner getting the models, walking through a Precise arch, and seeing a host script's MeshPart |
| `WardrobeSelfTest.swift` | What characters wear: every catalog accessory's mesh (sane size, wound outwards), faces and clothing pictures (sizes, a tee's sleeves, shorts to the knee); Roblox's clothing template on the torso, arms and hands, the face patch; a place's and a player's looks combined (own look kept or not, ten at most, built-in only for players), saving, old files, renaming a picture (and undo); accessories hung from their attachments, turning, nodding and lying down with the body, imported models by their anchor; drawn and read back (shirt over pants, pants, a top hat, a face picture in place of the smile, ray traced); in play (StarterPlayer over the player's look, afresh each character, the Animation Editor's rig); the Luau API (Accessory, AddAccessory, parenting, Shirt, Pants, Head.face, errors, GetAppliedDescription, Destroy, ApplyDescription with body colours, RemoveAccessories); the profile (kept, old profiles, applied); two players seeing each other's looks and a host script dressing a joined player, read back at once |
| `RemotesSelfTest.swift` | Scripts working together: ModuleScripts and data objects in the scene (made, saved, old files, deleted and undone, copied and deleted with a part); `require` (once, the same value to every script, ReplicatedStorage, Script Service and parts, never by themselves, loops, nothing returned, errors, compile errors, wrong arguments); Values (IntValue rounding, StringValue from a number, BoolValue refusing, Folders, Clone, WaitForChild waiting, Changed with each value, Destroy, a Folder becoming a Player's leaderstats); remotes played alone (FireServer with tables, Vector3s and parts, FireClient, FireAllClients, InvokeServer and its errors, the wrong side refused); Raycast (first hit and all its fields, IgnoreWater, RespectCanCollide, Exclude and Include, too short, bad params, characters and excluding them); the leaderboard (hidden with no leaderstats, columns and rows, the HUD numbers moved, Tab); storage (a Model kept in ServerStorage by Studio, left out of what joiners get, saved, undone; its module and Value reached, a clone coming into the world with its script, a part into ReplicatedStorage and back, a LocalScript seeing ServerStorage empty); ObjectValue, Vector3Value, Color3Value, CFrameValue, BindableEvent, BindableFunction, UnreliableRemoteEvent and RunService:IsServer/IsClient; remotes queuing events until a handler connects and carrying Sounds, GUI objects and the Workspace; the README's examples; a host and a joined player (modules on each, FireServer as that player with a part, FireClient back, InvokeServer, leaderstats and Changed reaching the player, a late remote waited for, both on the joiner's leaderboard, the host's rays meeting the joiner, leaderstats leaving with the player); and with two players: ServerStorage never sent and empty to the joiner, a clone from it reaching them, an event queued for a late handler, an UnreliableRemoteEvent, a GUI object from another machine arriving as nil, and an InvokeClient failing when its player leaves |
| `AdventureSelfTest.swift` | The sample game, played: every area, NPC, gem, script, data object and shader there (all seven compiled), saved and reopened, opened in Studio, the spawn; the talk prompt, dialogue and its keys, walking away closing it, NPCs turning; each area's screen effect and the underwater one while swimming; a gem, the baker's trade, the crown worn again after respawning; the obby's checkpoint, lava, respawning at the checkpoint, jump pad, trophy (a win, the time, the party hat, back to the start), mover and spinner; the lab's lever switching the lighting and its sign, the colour button; with two players: no errors, the joiner's own dialogue and screen effect, the joiner's gem counted for them, the lever's lighting reaching them |
| `UtilsSelfTest.swift` | The Utils module: in the starter scene and a new scene (which no longer keep the last place's data objects), not added to an old place, Insert Utils Module (named, one undo step, Utils1, saved); every maths, table and text function run in Luau (random ranges, cycles and parts in deepCopy, a class's metatable, thousands, K/M/B, titles); the game helpers in play on a real character (getCharacter/Humanoid/Root from a player, a character and a body part, playerFromPart, isAlive, distance, positionOf, debounce and cooldown over time, weld, tween); suggested with every function, parameters and its comment; a host's script and a joined player's LocalScript each using it |
| `HomeSelfTest.swift` | The home page: every template built (Baseplate locked and just above the grid, Obby's Course and script, the HUD and Utils in each, Starter Scene as before, Empty, Adventure Island) and opened as a new place; the Obby played (start, checkpoint, kill brick, back at the checkpoint, finish and its Win, back to the start) and by a host and a joined player; recent places (missing and repeated files dropped, twelve at most, "Edited 2 hours ago", ~); pictures (drawn, none for an empty place, framing past a baseplate, a saved place's kept and read back, drawn again when the file changes); opening from the page through the app delegate (File › Home ⇧⌘H, editing menu items waiting, a template untitled with nothing to undo, back, a recent file, the starter scene after a file untitled, Adventure Island) |
| `NightfallSelfTest.swift` | Nightfall: the place (areas, templates in ServerStorage, the sword in StarterPack, scripts, key spots and spawn points, four shaders compiled); played (a day, night 1's zombies coming for you and biting, the sword taking them down, an orb coming to you, dawn and a choice of three taken with Z, the armory's blaster on 2 shooting where the pointer is, three keys and the gate opening, escaping with a score, the world and the run starting again, falling and a new run); a host and a joined player (the night and zombies reaching them, their sword run by the host's tool script and the kill theirs, their own power-up choice, a key they find counting for everyone) |
| `MegaObbySelfTest.swift` | Mega Obby: 60 numbered checkpoints in order, a stage between each, six named worlds, the finish, every kind of obstacle, heights, scripts, shaders; every stage possible (each gap and rise within a running jump worked out from the character's speed, jump and gravity; trusses tall enough; the jump pad reaching its landing); played (stage 1, checkpoints and the banner, a world's name, a kill brick and back at the checkpoint with a death counted, Q and E within what you've reached, fading tiles, movers, spinners, jump pads, R, the finish's Win); a host and a joined player each with their own stage, checkpoint and picker |
| `ShiftLockSelfTest.swift` | Shift lock: on in new places, old files and every template; kept off when a place turns it off; the controls panel's line, the sample games keeping their own; Left Ctrl on (the pointer held, LockCenter and the crosshair, the camera over the right shoulder, the body turned with the camera and strafing), off again (the body turning to where it walks); a place with it off, and `Player.DevEnableMouseLock` read and set false by a script; a joined player's own shift lock, their facing seen by the host |
| `DataStoreSelfTest.swift` | DataStores: a place id for each new place and New Scene, saved and reopened, one from its path for an old file (the same each time, not marked edited), fixed ones for the sample games (from the home page too); kept on disk by place, store and scope, files named safely, read back, removed, cleared for one place only; from Luau: the same store each time, tables read back as copies, UpdateAsync (and nil leaving it), IncrementAsync, RemoveAsync, number keys, scopes, every refusal (Instance, Vector3, function, NaN, mixed and cyclic tables, nil, long keys, incrementing text, fractions in an ordered store) with nothing written, ordered pages both ways and between two values, GetGlobalDataStore, a LocalScript refused, Run mode; saved across plays, reopened, another place apart, cleared; completion; the README example; Mega Obby, Nightfall and Adventure Island carrying on next time; a joined player saving nothing themselves, the host keeping their stage by name, and on stage 4 when they join again |
| `GamePickerSelfTest.swift` | The client's game picker: where it starts, the sample games and the Starter Scene with their pictures; places opened remembered (newest first, once each, not Studio's hand-over copy, kept between runs, a deleted one left out), one chosen opening on the menu, one that can't be opened saying so; the character and join screens returning where they came from; choosing, playing and choosing another game; a host choosing Mega Obby there and a joined player (from the picker) playing it |
| `GameSoundsSelfTest.swift` | Built-in sounds: twenty effects and three loops, each mono, levelled, effects short, music without a gap at the loop, the same every time, made once, unknown names refused; a script's built-in Sound loaded with its length and playing, a scene Sound looping from the start, the README's coin; Nightfall (music and news sounds in SoundService, a groan in every zombie's head, day music then night music and a gong, groans from zombies, a bite's hit and your own hurt, a swing and a fall, your orb, dawn's chime and the day music back, the end of a run heard by you alone); Mega Obby (music, sounds in every jump pad and fading tile, your checkpoint ding, a boing from the pad, a crack, an oof); a joined player hearing the host's music and a pad the host boings for them, their checkpoint ding heard by them and not the host |
| `PathfindingSelfTest.swift` | PathfindingService: the grid round a wall (start to goal, round the end and never through, evenly spaced and walkable, on the ground), none into a closed box, a step walked, a platform jumped onto (marked on the landing), none without jumping or too high, a gap one agent fits and a bigger doesn't, a Neon strip crossed or avoided by cost, a wall put down blocking an old path from where it meets it, a start inside the agent's own body; from Luau (CreatePath, ComputeAsync, Status, PathWaypoints, Blocked firing and CheckOcclusionAsync when a crate lands on the path, FindPathAsync, a bad start refused, PathWaypoint.new, completion); the README's example walking a character round a wall to a flag; a Nightfall zombie behind a pen's back wall going round and in to bite; the same for a joined player, seen from their game; then water — deep water swum at its surface with a jump out onto the far bank, shallow water waded, a Water cost of infinity keeping out, the Terrain's lake; a loft out of reach unless climbing, the climb's top labelled Climb, not blocked by its own truss; a gap jumped across (not by an agent that can't jump, not one too wide); a Rig following a path across a pond, over a gap and up a truss to a goal, alone and in a joined player's game |
| `DebuggerSelfTest.swift` | The Luau debugger: a breakpoint stopping each time its line runs, in the function and called from the script's line, with locals, upvalues and the caller's (a table shown by its entries, no compiler temporaries), the script carrying on after; a breakpoint on a line with no code landing on the next; values described (a long string cut short, an Instance by class and name, an empty table, nil); Step Over (to the next line, out to the caller, on to the breakpoint again), Step Into (into the called function), Step Out (back to the caller), Stop (no more stops, the session asked to end); a breakpoint put on and taken off while running; a LocalScript's and a ModuleScript's called from it; a character script's for the first character and the next; the world waiting while stopped and the watchdog not counting the wait; breakpoints saved (and not written when there are none), toggling not an undoable edit, kept through Stop in Studio, and moving with added or removed lines; watch expressions (locals, upvalues, globals, another call's; failing, not Luau, a runaway one cut short, the script unaffected); conditional breakpoints (holding, never holding, calling the script's functions with breakpoints of their own, failing with a note, two on one line, changed and taken away while running); tables opened (by name with paths, numbered in order, nested, empty, not a table); conditions saved, moved, dropped and kept through Stop; logpoints (printing as print does and going on, only when their condition holds, failing into the output, beside a breakpoint) and hit counts (stopping or not, shown live in Studio); watches and log messages saved with the place, not sent to joined players, kept through Stop and undo; a host stopped in a RemoteEvent handler with a joined player's message — only for what its condition asks, the player's name in a watch, the table they sent opened, a logpoint printing every player's message and both lines counting them — the replies reaching them after |
| `EngineSelfTest.swift` | The engine over a long game, through the real audio engine rendered offline: nightfall's sounds (music stopped and started, a gong, then the first sound in a part, which once crashed the game), none knocking another off the mix, sound coming out; 200 sounds started and stopped, flat and in parts, all heard; a change of audio device (the engine started again, the music carrying on, new sounds in parts starting); Nightfall played into the night and its fighting through it, with no errors and nothing growing (parts, Sounds, Models, GUI, Luau's memory) |
| `SceneIndexSelfTest.swift` | The scene index: 3000 random changes of every kind (parts and groups made, deleted, reparented through the array and through update(id:), moved, sent to storage and back, the parts replaced whole with the same count, shuffled, data objects and Sounds made and deleted, reparenting undone) with parts, groups, parents, children, data objects and Sounds all found as a search finds them; finding a part, a Model's pivot, moving a Model and a folder's children no dearer with 16 times the parts |
| `SoakSelfTest.swift` | Each sample game played by `Soak.play`'s player (running, jumping, swinging, falling; the same moves every time) — Adventure Island and Mega Obby for 40 seconds, Nightfall for 60, night included: no script errors, and no parts, Models, Sounds, values, GUI objects, voices or Luau memory growing from the settled sample to the last; a host and a joined player in Nightfall for 50 seconds, both moving and fighting: no errors, and the joined player's parts and Sounds keeping the same distance from the host's (nothing the host has done with piling up) |
| `NPCSelfTest.swift` | NPCs: Insert › Rig (the seven parts, a Humanoid, one undo step, standing on the spot, saved and reopened); MoveTo at the WalkSpeed, facing the way it goes with legs swinging, MoveDirection, WalkToPoint and the Running state, MoveToFinished(true) within a stud and standing on the ground; a wall stopping it and MoveToFinished(false) after eight seconds; a kerb stepped up, moved by a script (PivotTo) then walking off a ledge, Jump up and down; the README's PathfindingService example round a wall to a flag; TakeDamage and HealthChanged, MaxHealth lowering Health, Died once at no health, falling apart; Instance.new("Humanoid") in a script's Model walking at its own WalkSpeed, FindFirstChildOfClass, a wrong type refused; the player bumping into an NPC; Adventure Island's Postie Pat round, every stop reached; a host's NPC walking and dying in a joined player's game, their script hearing Died, the parts let go there too |
| `TerrainSelfTest.swift` | Terrain: FillBall (full, part-full, empty), Air carving, a turned FillBlock, FillCylinder, FillWedge's slope, FillRegion, ReplaceMaterial, the seven brushes, Generate (materials, the same from a seed), saved small and read back, a place without it saving as before; meshes (a flat top at its height, whole across chunks, Precise collision parts, water at its level, only the changed chunk remade, the chunks round a corner edit); played on (standing on it and a hill, swimming with no floor at 0, a block landing, Raycast hitting it as workspace.Terrain with its material and normal, its water unless IgnoreWater, filtered out, a path round a hill); from Luau (workspace.Terrain found by name and class, every Fill, Region3, ReplaceMaterial, Read/WriteVoxels, material colours, water, cells, Clouds in it, five wrong values refused); drawn; painted with a brush in Studio (a stroke one undo step, the preview, a join tool putting it down); the Hills and Lake template (a player lands on it); the README's island as written; a host's terrain and a script's edits in a joined player's game |
| `ForceSelfTest.swift` | AlignPosition, VectorForce and NoCollisionConstraint: a Force of the block's weight holding it up (none, it falls; twice, it rises), RelativeTo Attachment0 turning with the part, off the middle turning it unless ApplyAtCenterOfMass; pulled to Attachment1 and held against gravity, not with too little MaxForce, no faster than MaxVelocity, at once with RigidityEnabled and slower at Responsiveness 5, OneAttachment to Position, following a moving target; falling through a shelf it mustn't collide with and resting on it when disabled; Studio (the Align Position and No Collision tools, Add VectorForce's hover, undo, saved with MaxVelocity's no-limit, a hinge saving as before); from Luau (all three, their enums, five wrong values refused, math.huge); the README's lift as written; a host's AlignPosition lifting a crate in a joined player's game |
| `ToolboxSelfTest.swift` | The Toolbox: each of its eight models going in as a Model in front of Studio's camera, standing on the Platform, selected, one step to undo; the car, boat, door and windmill bringing their scripts; a picture of each, drawn by one renderer; the boat floating high on a pond, driving forward and turning right at about TurnSpeed; the door shut in its frame, swinging open when clicked and shut again; the windmill's sails turning at 1.2 rad/s in Run mode; the campfire's fire, smoke and shadowing light, the lamp's light, the tree, the rig's Humanoid; a joined player's click opening the host's door, which they see open |
| `CarSelfTest.swift` | Cars: Insert › Car's Model (a body, a VehicleSeat, four wheels, two knuckles; motors, servos, axles, welds and no-collisions; its Drive script; on the ground where it was put), a second car keeping its parts' names, one undo step each, a loose part still renamed; driving with the real ControlScript (W to MaxSpeed with the driver riding along, the speedometer, stopping when let go, S backwards, D and A turning, Space getting out and the controls going back to 0); VehicleSeat from Luau (its class, properties and defaults, whole-number Throttle, wrong values refused, a Part having no Throttle, a script driving a car nobody's in, in Run mode); saving (and a Seat from before); the README's circling car as written; a joined player driving the host's car (their keys reaching the host's script, the car going and them riding in it, stopping when they get out) |
| `FloatSelfTest.swift` | Floating: in a water part, plastic about 0.7 under and still, wood about 0.35 under, metal on the bottom, staying where it fell; a welded wood-and-metal raft floating on their weight together; a plank dropped on its side settling flat; a crate sent skimming slowed by the water; nothing afloat on dry land; a crate and a log in the Terrain's water; a script turning a crate to metal (sinks) and to wood (back up); Adventure Island's driftwood and beach ball afloat on the lake; a host's crate floating in its pond in a joined player's game |
| `MotorSelfTest.swift` | Motor6D, AlignOrientation and Torque: an arm swung on an anchored base to DesiredAngle (MaxVelocity a frame at most) and held there against gravity, turned by Transform, pulled to where C0 and C1 say, two unanchored parts falling and landing together, let go when disabled; a floating block turned to face as another does (not moved), to a CFrame in OneAttachment mode, slowly with little MaxTorque, no faster than MaxAngularVelocity, at once with RigidityEnabled, only its axis with PrimaryAxisOnly; a Torque spinning a block about its direction (twice as hard, twice as fast), about its attachment's axis, and Studio's turning a crate where it rests; Studio (the Motor6D tool holding the part where it is, the Align Orientation tool, Add Torque, saved and reopened, a weld saving as before); from Luau (all three, IsA JointInstance, CFrame properties, the new enum, wrong values refused, CurrentAngle read as it turns and set); the README's windmill and vane as written; a host's Motor6D turning a windmill in a joined player's game |
| `SkySelfTest.swift` | Lighting's Sky, Atmosphere and Clouds: none in a new place (a default sun, moon and stars) and it saving as before, added with undo, saved and reopened, what the shaders get; drawn — stars at night and none at StarCount 0, the sun's disc and not with CelestialBodiesShown off, clouds whitening the sky and going when disabled, a far wall fading into the Atmosphere's colour, a skybox's sides where they belong and the right way up, the day's sky again without all six; from Luau (made loose then put in Lighting, found by name and class, children, the Roblox types, Offset kept in range, five wrong values refused, Clone, out and back, Destroy); the README's dusk fog as written; a host's Atmosphere and Clouds in a joined player's sky and scripts |
| `RibbonSelfTest.swift` | Beams: the curve (Segments, its ends, CurveSize bending it), Width0 to Width1, Color and Transparency along it, flat across the attachments, Stretch and Wrap, TextureSpeed scrolling, FaceCamera, Enabled; Trails: a point each MinLength, as wide as the attachments are apart, gone after Lifetime, drawn from now back, WidthScale, MaxLength, Clear, Enabled off, forgotten in storage; a Beam not holding a part up; Studio (the Beam tool middle to middle facing the camera, Add Trail top to bottom, undo, neither a join tool, saved, a joint saving as before); from Luau (Beam and Trail made and read in their types, not Constraints, wrong values refused, a Beam has no Clear, Clear and Enabled); drawn, and not when off; the README's laser as written; a host's Beam and moving Trail in a joined player's game |
| `ParticleSelfTest.swift` | ParticleEmitters: Rate and Lifetime (how many alive), made in the part and out of its top at their Speed, a turned part's top, SpreadAngle's fan, Acceleration, Drag, Enabled off, Emit(40) at once, Clear, a machine seeing an emitter first making only its last burst, LockedToPart, TimeScale 0, Size/Transparency/Color/Brightness/LightEmission through a life with envelopes, the 2000 cap, none in storage; Studio (presets, undo, saved and reopened, a part without one saving as before, copied with the part, deleted); from Luau (Instance.new, FindFirstChild, the Roblox types read back, six wrong values refused, GetChildren, Emit bursting, Clone, moved between parts and out, Clear, Enabled, Destroy); drawn red where they are, hidden behind a wall, gone when cleared; a host script's emitter and Emit(40) reaching a joined player and bursting there, a joined player's LocalScript emitter staying theirs |
| `FrameStatsSelfTest.swift` | The Stats service: frame, script and physics times (the frame the most, the scripts' work in it), memory, the service being itself, parts and instances; no drawing time until something draws, then counted in the frame; the HUD's three lines showing the frame, drawing, scripts, physics, memory and the right part count; a version-2 place given them once under its numbers, one with its numbers deleted not; a joined player's numbers being their own machine's |
| `LANSelfTest.swift` | Animations across players (a joiner's own seen by the host; a host script playing one on a joiner, IsPlaying, Stopped); host scripts reading a joined player's velocity and MoveDirection, and reading back at once what they set on them; welds, joints and all sixteen shader parameters reaching joiners; chat (the host relays under the joined name, not back to the sender, blank dropped; the ChatScript host ↔ joiner with join/leave lines); host scripts seeing a joined player (PlayerAdded, GetPlayers, touches, kill brick, coin, speed pad, teleport, Died, respawn, PlayerRemoving); one world (host-run parts, scripts, lighting and new parts reaching the joiner; scene scripts only on the host; parts landing on joiners); players colliding unless the map says not; players seeing each other (place, colours, names, movement, death, leaving); LAN message framing, games from TXT records, a real host and players over loopback TCP (welcome with the scene, player lists, leaving, version refusal), the player profile (saved, `player.Name`, colours), the client's menu/play/host/join flow |
| `ScriptTemplateSelfTest.swift` | The code new scripts start with: one per place (part, Model, Folder, Script Service, both StarterPlayer folders, Wren), each run where it was made — output, a debounced touch, keys, death and respawn — and again with every suggested line uncommented |
| `DocumentTabsSelfTest.swift` | The tabs: opening, closing, cycling, following deletes/undo/new scenes, Play; scene undo keeping script text; line numbers; Output error links; ⌘Z/⌘A/⌘⌫/⌘F going to the code editor; each tab's text view surviving a switch (hosted in a real window); the hidden viewport — no keys, no drawing, but play and shader compiles keep ticking |
| `SyntaxSelfTest.swift` | Luau, Wren and Metal lexers, and all three completion engines (Luau's order: case typed, locals, keywords, globals; nothing while naming something; a local not on its own line); modules and the scene: reading a module (values, functions with parameters, tables, methods, `return { … }`, a constructor's objects, a nested return), `require(` listing every ModuleScript as its path (script.Parent, GetService, the script's own local, no second `)`), places listing what's in them (and only modules inside `require(`), `WaitForChild("…")` names, script.Parent, a required module's members, tables, types, methods and objects; built from a SceneModel (a part's module, a Folder's, ServerStorage's) and from Adventure Island; `GetService("` (every service, closing or not, single quotes, narrowing, the declared local's first, the script's own last, before the quote, each one run through the real `game:GetService`) |

Assertions use `Checker` (`PlaySelfTest.swift`): `check("name", condition, "detail")`,
detail printed only on failure. `ScriptSelfTest.assertAll` evaluates a list of Luau
boolean expressions in one script and reports the ones that were false — the fastest
way to test library behaviour.

## 4. Repository map

```
Sources/StudioApp/main.swift       editor entry point
Sources/StudioClient/main.swift    client entry point
Sources/CLuau/                     Luau 0.640 under luau/, our shim under include/ and shim/
Sources/CWren/                     Wren 0.4.0, vendored verbatim
Sources/CJolt/                     Jolt Physics 5.6.0 under Jolt/ (MIT, verbatim; GPU
                                   backends excluded), our C shim under include/ and shim/

Sources/StudioKit/
  App/EditorLauncher.swift   editor window, menu bar, document actions, quit guard;
                             `--make-adventure out.json` writes the sample game
  App/ClientLauncher.swift   client window and menu bar
  App/LaunchClient.swift     editor → standalone client handoff via a temp file

  Math/MathUtil.swift        matrices, quaternion↔euler, ray/shape intersection

  Model/Part.swift           the Part record; hand-written Codable and Equatable
  Model/ScriptObject.swift   a script (its language and ScriptHost), and SceneState (with its
                             duplicate-id repair)
  Model/ScriptTemplates.swift the code a new script starts with, for each place it can be made
  Model/PlayerProfile.swift  the client player's name and body colours, saved in UserDefaults
  Network/LAN.swift          LAN play: message framing, LANLink, LANHost (Bonjour + TCP), LANBrowser,
                             LANJoin/LANMembership
  App/ClientSession.swift    the client's state: screens, profile, play, hosting and joining
  UI/ClientMenuView.swift    the client's menu, character editor (BodyFigure), join list, in-game bar
  Model/StarterPlayer.swift  StarterPlayerSettings: the character template, BodyColors
  Model/Constraints.swift    SceneAttachment, SceneConstraint (weld, hinge, ball socket,
                             rope, spring, prismatic), and the join/weld editor commands
  Model/SceneTree.swift      the tree: SceneGroup (Model/Folder), parentIDs, Pose (CFrame),
                             children/descendants, group/ungroup, subtree clone/delete, pivots
  Model/Lighting.swift       LightingSettings (technology, clock, sun, sky, fog…), PointLight,
                             the sun/moon/sky maths
  Model/AnimationObject.swift custom animations: keys per R6 joint (degrees), markers,
                             easing, sampling; the Wave example
  Model/ShaderObject.swift   a user shader, its kind and its named parameters
  Model/SceneModel.swift     the hub: published state, selection, undo/redo, parts, scene files;
                             `unique(_:among:)` names copies
  Model/SceneModel+Scripts.swift, +Shaders.swift, +Animations.swift, +StarterScene.swift
                             the model's other collections, and the scene Studio opens on
  Model/SceneDocument.swift  file URL, dirty tracking, model export/insert
  Model/EditorSession.swift  Play and Run (F8), scene snapshot/restore, the tabs
                             (EditorDocument, open/close/cycle, line reveal) and the
                             bottom panel

  Render/Camera.swift        orbit/fly camera, screen→world picking rays
  Render/Mesh.swift          procedural geometry, all unit-sized
  Render/Shaders.swift       built-in Metal source (scene, grid, sky, flat) + uniform mirrors
  Render/LightingShaders.swift the shared Metal lighting library + LightingUniforms,
                             PointLightData, InstanceInfo mirrors
  Render/RayTracingScene.swift acceleration structures: per-mesh once, instances per frame
  Render/Renderer.swift      the frame: offscreen pass, effect pass, overlays
  Render/ShaderSource.swift  generates the Metal around a user's body (both kinds)
  Render/ShaderLibrary.swift debounced background compile and pipeline swap
  Render/ViewportSource.swift  the protocol the renderer draws a frame from; AvatarPose
                               and its `partTransforms()` (where each body part goes)
  Render/AvatarSnapshot.swift  `--render-avatar out.png`: every pose side by side, no window;
                               `--render-adventure out.png [view] [ray]`: the sample game from
                               one of `adventureViews`, with that area's screen effect

  Interaction/Picking.swift            exact per-shape ray tests
  Interaction/Gizmo.swift              handle hit-testing and drag math
  Interaction/ViewportController.swift editor camera + drag state (a ViewportSource)
  Interaction/AnimationEditor.swift    Animation Editor state: playhead, joint, rig, drag-to-pose

  Play/Collision.swift           capsule↔part contacts, closest points, normals
  Play/CharacterController.swift gravity, walking, step-up, ground probes
  Play/PlayerCamera.swift        third/first person with wall avoidance
  Play/PlayController.swift      the play session: scripts → physics → lifecycle (a ViewportSource)
  Play/PlayController+Multiplayer.swift  other players: drawn, named, walked into, in the physics
  Play/Humanoid.swift            Humanoid state, state machine and events — no physics
  Play/PlayerHost.swift          every player./humanoid./root./body./input. host call
  Play/CoreScripts.swift         the default ControlScript, Health, ChatScript and BackpackScript, in Luau
  Play/PlayController+Tools.swift  Tools in play: StarterPack copies, Backpack, hand, clicks,
                                 dropping and picking up; `backpack.*` host calls
  Model/SceneModel+Tools.swift   where each Tool is (ToolPlace) and parking its parts
  Play/Gui.swift                 the screen GUI: UDim2, GuiObject, GuiFont, GuiStore (tree,
                                 focus, the caret, clicks, scrolling, layout with lists,
                                 automatic sizes, canvases, clipping and billboards)
  Model/SceneModel+StarterGui.swift  StarterGuiObject (GUIs made in Studio) and editing them
  Model/DefaultHud.swift         StarterGui's PlayerHud a new scene starts with (objects,
                                 HudScript, FlyAndRespawn), and giving it to old scenes
  Model/SceneModel+Assets.swift  SceneAsset (a picture, sound or 3D model file kept in the scene,
                                 named "studio://Name") and SceneSound (a Sound), and editing them
  Model/MeshGeometry.swift       MeshSettings (a part's MeshId, TextureID, CollisionFidelity),
                                 MeshGeometry (a model decoded by Model I/O into the unit cube,
                                 with its hull) and MeshLibrary (decoded once per asset)
  Model/TriangleSet.swift        triangles with a BVH: ray casts and closest points to a segment
  Model/AvatarLook.swift         AvatarLook (face, shirt, pants, accessories), AvatarAccessory,
                                 AccessoryType (attachments), combining a place's and a player's,
                                 `look.*` values, `AvatarPose.accessoryTransforms`
  Model/AvatarCatalog.swift      the built-in accessories (meshes from shapes), faces and clothing
                                 (drawn in code), and ClothingTemplate (Roblox's 585 × 559 layout)
  Render/AvatarWardrobe.swift    accessory meshes, clothed body parts, the face patch, and pictures
                                 as textures for the renderer
  UI/AvatarPreview.swift         the avatar drawn alone (a still frame per change), thumbnails
  UI/AvatarLookEditor.swift      StarterPlayer's Avatar section
  Model/SceneModel+Mesh.swift    inserting MeshParts and editing their mesh settings
  UI/MeshUI.swift                importing models, the ribbon's Mesh button, the Mesh section
  Play/Audio.swift               AudioOutput (SpeakerOutput: AVAudioEngine; RecordingOutput for
                                 the tests) and SoundSystem, which makes the scene's Sounds heard
  App/Soak.swift                 `--soak`: a sample game played for minutes, headless or in a
                                 window, reporting memory and object counts as it goes; and
                                 `--bench`, what the scene's everyday operations cost
  Model/SceneIndex.swift         finding parts, groups, data objects and Sounds by id, and each
                                 node's children, without searching
  Play/BuiltinSounds.swift       "builtin://Name" sounds: the catalog, a small synthesizer
                                 (`Synth`) and sequencer (`Song`); made on first use, kept;
                                 `--write-sounds <folder>` writes them as WAV files
  Scripting/ScriptRuntime+Sounds.swift  the `sound.*` host calls
  UI/AssetInspector.swift        the Properties panel for an asset and for a Sound
  UI/GuiInspector.swift          the Properties panel for a StarterGui object: sections,
                                 where it shows, modifier chips, gradient ends, limits
  UI/GuiRibbon.swift             the ribbon's GUI tab (GuiRibbonGroups), RibbonGroup,
                                 RibbonSmallButton; `EditorSession.guiHint`
  UI/GuiPreviewView.swift        StarterGui over the viewport at a device's size, framed;
                                 the GUI tab's overlay (handles, guides, presses)
  UI/GuiKinds.swift              each GUI class's icon, short name, and what can be inserted
  Interaction/GuiEditController.swift  GuiDevice, GuiPreviewGeometry, and editing the
                                 preview: hits, drags, snapping, nudges, the tab's buttons
  Play/PlayController+Gui.swift  the `gui.*` and `chat.*` host calls, keys while typing
  Play/KeyCodes.swift            macOS virtual keys → Roblox KeyCode names
  Play/Physics/PhysicsWorld.swift Jolt, seen from Swift: sync with parts, step, write back,
                                 velocities, impulses, the player's kinematic capsule, pushing
  Play/CharacterTouch.swift      which parts each body part touches (limb capsules + skin)
  Play/AvatarAnimator.swift      AvatarJoints + per-state animations, crossfaded by weight
  Play/AnimationPlayer.swift     AnimationTracks at run time: fades, loops, markers, priority layering

  Scripting/LuauInterpreter.swift  Luau VM wrapper over the CLuau shim; ScriptValue
  Scripting/StudioLibrary.swift    the Luau library's entry: `LuauLibrary.inOrder`, joined into one chunk
  Scripting/LuauLibrary/NN-*.swift the library itself, by topic, numbered in the order it runs
  Scripting/WrenInterpreter.swift  Wren VM wrapper
  Scripting/WrenModules.swift      Wren's `studio` and `math` modules, written in Wren
  Scripting/ScriptRuntime.swift    runs both VMs; `invoke` routes each host call by namespace
  Scripting/ScriptRuntime+Lighting/Animations/Tree/Joints/Parts/Shaders.swift
                                   the host calls, one file per namespace group
  Scripting/ScriptConsole.swift    buffered output: info, output, warning, error
  Model/SceneModel+Storage.swift   StoragePlace; parts and Models kept in Replicated/ServerStorage,
                                   and ServerStorage left out of what joined players get
  Scripting/ScriptRuntime+Data.swift  `data.*` (Folders, Values, remotes as data objects),
                                   `module.*`, `workspace.raycast`
  Scripting/ScriptRuntime+Pathfinding.swift  `path.*`: PathfindingService's searches and checks
  Scripting/ScriptDebugger.swift  the Luau debugger: breakpoints (and conditions) per script, stops, stepping, watches
  UI/DebuggerPanel.swift         the dock's Debugger tab: controls, call stack, breakpoints, variables, watches
  Play/Pathfinding.swift         NavigationGrid: the world as 2-stud cells of solid spans, kept
                                 up to date part by part; A* over floors; waypoints
  Scripting/ScriptRuntime+DataStore.swift  `datastore.*`: DataStoreService's reads and writes,
                                   on the machine running the scene's scripts only
  Model/DataStores.swift           DataStoreFiles (what DataStores keep, a folder per place),
                                   `UUID(stableFrom:)`, `ensurePlaceID`
  Model/DataObjects.swift          DataObject, DataClass, DataParent, and editing them; a
                                   Humanoid's numbers
  Model/Terrain.swift            TerrainData: voxels in 16³ chunks (material, occupancy, stamps),
                                 fills, brushes, Generate, packing; TerrainPatch for joined players
  Play/TerrainMesher.swift       surface nets per chunk (and water), TerrainGeometry: meshes and the
                                 chunks as Precise MeshParts for collision, remade as they change
  Scripting/ScriptRuntime+Terrain.swift  `terrain.*`: fills, regions, voxels, water, colours
  UI/TerrainUI.swift             the dock's Terrain Editor
  Scripting/ScriptRuntime+Forces.swift  `force.*`: the own properties of AlignPosition, VectorForce, AlignOrientation, Torque, Motor6D
  Model/SkyObjects.swift         Lighting's Sky, Atmosphere and Clouds (SkySettings and the rest)
  Model/ToolboxModels.swift      the Toolbox's models (car, boat, door, windmill…) built in code, as ModelFiles
  UI/ToolboxView.swift           the dock's Toolbox tab: a card per model, its picture drawn once
  Model/SceneModel+Insert.swift  inserting a ModelFile (a saved model or a Toolbox one), re-identified
  Scripting/ScriptRuntime+Sky.swift  `sky.*`: making, reading, moving them; SkyObject; loose ones
  UI/SkyUI.swift                 SkyObjectsEditor: their sections in Lighting's Properties
  Model/RibbonLook.swift         a Beam's or Trail's looks (SceneConstraint.ribbon), addTrail
  Play/Ribbons.swift             Beams' curves and Trails' history (TrailSystem) as strips
  Render/RibbonRenderer.swift    RibbonRenderer: strips with a repeating picture; the ribbon pictures
  Scripting/ScriptRuntime+Ribbons.swift  `ribbon.*`: a Beam's or Trail's looks
  UI/RibbonUI.swift              RibbonSection: a Beam's or Trail's Properties
  Model/ParticleEmitter.swift    ParticleEmitter (in `Part.emitters`), NumberKey/ColorKey
                                 sequences, the Studio presets, EmitterRef and editing them
  Play/ParticleSystem.swift      each machine's particles: made by Rate and Emit, moved, aged,
                                 cleared; `sprites` for drawing. Seeded, so tests repeat
  Render/Particles.swift         ParticleRenderer: camera-facing squares, premultiplied alpha,
                                 the built-in pictures drawn in code; `particleMetalSource`
  Scripting/ScriptRuntime+Particles.swift  `emitter.*`: "<part>:<emitter>" names, loose ones
  UI/ParticleUI.swift            the Properties panel for a ParticleEmitter
  Play/NPCSystem.swift           NPCs: a body (CharacterController) per Humanoid in a Workspace
                                 Model; MoveTo, Move, Jump; the parts placed round its root
                                 with limbs swinging; teleports noticed; falling apart
  Model/NPCRig.swift             Insert › Rig: the R6 Model with a Humanoid (`NPCRig.make`,
                                 `SceneModel.addRig`)
  Scripting/ScriptRuntime+NPC.swift  `npc.*`: a Humanoid's numbers, state, and steering it
  Model/PlaceTemplates.swift       the home page's templates (Baseplate, Obby and its script,
                                   Starter Scene, Empty, Adventure Island) and `loadTemplate`
  Render/PlaceThumbnail.swift      pictures of places, drawn off screen by one shared renderer,
                                   a saved place's cached by path and modification date
  UI/HomeView.swift                the home page (HomeView), what it shows (HomeModel), RecentPlace
  UI/GamePickerView.swift          the client's first screen: the sample games and places opened
                                   there (a HomeModel of the games, `ClientSession.games`)
  Model/UtilsModule.swift          the Utils ModuleScript every new place has (Luau source), and
                                   `insertUtilsModule()` for older places
  Model/PlaceBuilding.swift        what the places built in code share: part, group, script,
                                   shader, light and a seeded random (Adventure Island, Nightfall)
  Model/Nightfall.swift            the second sample game's world (`Builder`), templates and tools
  Model/MegaObby.swift             the third: 60 stages built from 14 obstacle kinds, sized by
                                   how far along they are (`Builder.build(_:in:)`)
  Model/MegaObbyScripts.swift      its Luau (ObbyGame, Mechanics, ObbyScreen) and floor shaders
  Model/NightfallScripts.swift     its Luau (GameScript, Horde, Upgrades, Ambience, SwordScript,
                                   the Nightfall LocalScript) and shaders
  Model/AdventureIsland.swift      the sample game's world, built in code (`Builder`), and
                                   `loadAdventureIsland()`
  Model/AdventureIslandScripts.swift  its Luau scripts, dialogue, zones and shader bodies
  Play/PlayController+Remotes.swift  `remote.*` across machines, `character.raycast`,
                                   Values' Changed from outside
  UI/DataObjectsUI.swift           the Explorer's ReplicatedStorage, the data-object inspector

  Editor/LuauSyntax.swift      Luau lexer
  Editor/LuauAPI.swift         tables the Luau completion is driven from
  Editor/LuauCompletion.swift  Luau suggestions: `.` vs `:`, GetService, locals, their order,
                               and where a new name is being made (no suggestions); with a
                               scene, what's in each place, `require(` paths, WaitForChild names
  Editor/LuauScene.swift       what a script can reach by name, built from the model
                               (`SceneModel.luauScene(editing:)`), for completion
  Editor/LuauModuleShape.swift what a ModuleScript returns, read from its code without running it
  Editor/WrenSyntax.swift      Wren lexer
  Editor/WrenAPI.swift         tables the Wren completion is driven from
  Editor/WrenCompletion.swift  Wren suggestions, with type inference
  Editor/MetalSyntax.swift     Metal lexer; also validates a shader body
  Editor/MetalCompletion.swift suggestions for the shader editor
  Editor/SyntaxTheme.swift     token colours, the CodeLanguage switch, highlighting

  UI/ContentView.swift    tabbed ribbon (Home/Model/Physics/Script/View), the window
                          layout (middle + console + sidebar), status bar
  UI/ExplorerView.swift   the tree: Workspace, Script Service, Shaders, StarterPlayer, Screen,
                          StarterPack, StarterGui, SoundService, Assets (import, drag and drop)
  UI/PropertiesView.swift inspector
  UI/DocumentViews.swift  the tab strip, DocumentArea (world or document), and the full-size
                          script, shader and core-script views
  UI/DockView.swift       bottom panel: the Output console (errors link to lines) and the
                          Animation tab
  UI/CodeEditor.swift     NSTextView-backed editor: language-parameterised, LineNumberRuler,
                          CodeEditorCache (a tab's text view kept across switches),
                          TextCommand (menu keys routed to text), LineNumbers; the
                          coordinator decides when to suggest and handles the list's keys
  UI/CompletionList.swift the suggestion list: its state and its panel under the word
  UI/ViewportView.swift   MTKView subclass, render loop + all mouse/keyboard input
  UI/ClientView.swift     the client's game view (the viewport only; the HUD is StarterGui's)
  UI/GuiLayer.swift       draws a GuiStore over the game (client and editor play test)
  UI/StarterPlayerView.swift  StarterPlayer inspector, read-only core script viewer
  UI/AnimationEditorView.swift the Animation tab: toolbar, KeyframeTimeline, JointInspector
  UI/LightingView.swift       Lighting inspector, a part's PointLight editor, RenderCapabilities
  UI/PanelSnapshot.swift      `--render-panel animation|inspector|explorer|ribbon|suggestions|picked|require|module|service|utils out.png`,
                              `--render-window script|shader|world|split|gui|guitab|guigradient|sounds|picture|mesh|meshasset|avatar|replicated out.png`
                              (whole window),
                              `--render-client menu|character|faces|clothes|outfit|join|chat|leaderboard|talk out.png`;
                              `--render-meshes out.png [ray]` (AvatarSnapshot) draws MeshParts;
                              `--render-looks out.png [ray] [back]` the sample outfits
  UI/Theme.swift          colours, NumericField, VectorEditor
```

`SceneModel` is the single source of truth for scene data. `ViewportController` and
`PlayController` hold *view* state (camera, drag, input) deliberately **outside**
SwiftUI, so 60 Hz camera motion never invalidates a view.

## 5. How a frame is drawn

Worth knowing before touching `Renderer.draw`, because there are two paths.

First, always, `prepareLighting` works out the frame's `LightingUniforms` and point
lights, then either encodes the **shadow map** (conventional: a depth pass from the
sun, 2048², an orthographic box around the camera's target) or builds the **instance
acceleration structure** (ray traced). `snapshot` goes through the same step.

**No screen effect switched on** — one pass straight into the drawable:

```
encodeScene     sky → grid → opaque parts → transparent parts → avatar
encodeOverlays  selection boxes → gizmo
```

**A screen effect switched on and compiled** — two passes:

```
offscreen pass  encodeScene, into a 4× multisample texture that resolves to a
                sampled colour texture, with its multisample depth kept
drawable pass   the effect (one full-screen triangle) → encodeOverlays
```

Overlays land in the drawable pass either way, so the gizmo is never tinted by an
effect. Lit pipelines (scene, grid, user surface shaders) exist in two variants — the
`studioRayTraced` function constant off and on — and `prepareLighting` picks one per
frame; flat, sky and shadow pipelines have one. Each part picks its pipeline in `drawPart`: its own compiled surface shader if
it has one, otherwise the built-in.

## 6. How scripts run

`ScriptRuntime.start()` builds a fresh VM per language that has enabled scripts —
none if there are none. Both reach the scene only through `ScriptRuntime.invoke`, the
shared host dispatch (`part.get`, `part.set`, `workspace.find`, `shader.param.set`, …),
so scene semantics are written once. Scripts in different languages share the scene
but cannot call each other.

**Luau:** load `StudioLibrary.swift` into the shared globals → `luaL_sandbox` → for each
script, a per-script environment in the registry whose misses fall through to the
globals, a setup chunk that gives it `script`, `shared` and `_G`, then `studio_lua_spawn`,
which runs the script's top level inside a coroutine. Each frame the host calls
`__studio_tick(dt)`, which fires `RenderStepped`, `Stepped`, `Heartbeat` (each handler in
its own thread) and wakes sleeping `task.wait` threads. Every resume is given a fresh
time budget by `__studio_arm`; the interrupt hook stops anything over budget.

**Wren:** one VM; each script is interpreted with a two-line prelude that defines
`script`; `import "studio"` / `"math"` are served from `WrenModules.swift`; each frame
calls `Runtime.tick_(dt)`. An error in an update callback stops Wren's updates.

## 6b. How the player works

The character is controlled **by scripts, through a Humanoid** — as in Roblox. Nothing
in Swift reads WASD any more. The layers, each only talking to the next:

```
StarterPlayerSettings   saved template (WalkSpeed, JumpPower, BodyColors, camera, …)
      │ copied into each new character
Humanoid                runtime state: properties, MoveDirection, Jump, state, events
      │ turned into a CharacterIntent each frame
CharacterController     the body: capsule physics, gravity, ground, step-up
```

Scripts reach the Humanoid through `PlayerHost` host calls (`humanoid.set`,
`humanoid.move`, …); the Luau library wraps them as `Players.LocalPlayer.Character.Humanoid`.
Keys arrive as `UserInputService` events; the default **ControlScript** (in
`CoreScripts.swift`, plain Luau) turns them into `humanoid:Move(...)`, `Jump`, sprint and
fly. **Health** regenerates. A scene script with the same name in the same folder
replaces a core script — a *disabled* one removes it.

**Script hosts** (`ScriptObject.host`): `.scene` (Workspace / Script Service, once per
session), `.starterPlayer` (once per session, scope 0), `.starterCharacter` (once per
character, scope = the character's generation, `script.Parent` = the character).
Starter hosts are Luau-only for now; Wren ones are skipped with a warning.

**Frame order** in `PlayController.step(dt:)`:
1. `scripts.update` — `__studio_tick` first drains `player.events` (last frame's
   Humanoid events, CharacterAdded/Removing, input) and fires the signals, then
   RenderStepped/Stepped/Heartbeat and sleepers;
2. `simulate` — MoveTo, Humanoid → `CharacterIntent` → physics, state machine, void death;
3. `animator.update` — the avatar's pose from the Humanoid state and body speed, then
   `animationPlayer.step` — custom tracks advance, queueing `["Track", handle, …]`
   events; `currentJoints` layers them over the built-in pose for the renderer;
4. `updateTouches` — diff this frame's `CharacterTouch.contacts` against last frame's
   and queue `["Touch", "Began"|"Ended", partID, bodyPart, generation]`;
5. `simulateParts` — physics: `sync` the parts into Jolt, move the character's
   kinematic capsule, `step`, write moved parts back (one `model.parts` assignment),
   destroy fallen parts, push what the character walks into, queue part-to-part
   `["PartTouch", …]` events;
6. `handleLifecycle` — death countdown (`RespawnTime`), respawn → new generation →
   `ScriptRuntime.characterRespawned` kills the old scope and re-runs character scripts.

## 7. Invariants — break these and things fail quietly

Roughly ordered by how much time they will cost you.

### Geometry and picking

1. **Meshes are unit-sized.** Every shape in `MeshFactory` fits inside a unit cube
   centred on the origin, so `Part.size` scales it directly and picking can test in
   local space. A new shape must follow this or picking, gizmos and collision all
   silently disagree with what is drawn.

2. **Triangle winding must be counter-clockwise as seen from outside.** The renderer
   sets `.counterClockwise` front-facing with back-face culling, so a reversed face is
   invisible rather than obviously wrong. `testMeshNormals` checks every triangle of
   every mesh against its vertex normals.

3. **Ray directions are not normalized in local space.** `Picking.intersect` transforms
   the ray by the inverse model matrix, which includes scale, so intersection maths must
   be scale-agnostic — solve the full quadratic, never the `|d| = 1` shortcut. This
   silently broke sphere picking once.

4. **Ray tests must handle an origin inside the shape's bounding box.** The character's
   ground probe casts from only 2 studs above the feet, which is *inside* a ramp's
   bounding box while above its surface. `intersectWedge` therefore intersects the box
   interval with the slope half-space rather than testing a single entry point. Getting
   this wrong made every ramp unwalkable.

5. **The character controller's shape is deliberate.** Walls resolve against a capsule
   whose bottom is *lifted by the step height*; support comes from five downward probes,
   not the capsule's rounded base, because a rounded base slides off ledges and stair
   nosings. Do not "simplify" this back to one capsule — the step, ramp and thin-floor
   tests exist to catch exactly that.

6. **`Camera` derives its eye position from yaw/pitch as an offset *from* the target.**
   `PlayerCamera` uses the opposite convention and converts with `Y = π/2 − yaw`. If you
   touch either, `testCameraConvention` will tell you.

### Rendering

7. **Swift uniform structs must match the Metal source byte-for-byte.**
   `FrameUniforms` 112, `DrawUniforms` 144, `Vertex` 32, `ShaderUniforms` 32,
   `ScreenUniforms` 80, `LightingUniforms` 272, `PointLightData` 48, `InstanceInfo` 96.
   Each is asserted in the suite. Add a field on one side and you
   must add it on the other and update the test.

8. **The viewport owns its render loop; do not hand it back to `MTKView`.**
   `MTKView`'s internal timer and `CADisplayLink` are both driven by a display's vsync.
   With **no display attached** — headless, or screen sharing only — neither ever fires:
   the delegate, device and drawable are all valid, a manual `draw()` renders correctly,
   and not one frame is requested. `StudioMTKView.startRenderLoop` uses a display link
   and falls back to a run-loop timer if nothing arrives within 0.75s. `testRenderLoop`
   guards this. Setting `isPaused = false` and trusting `MTKView` appears to work on a
   normal Mac and silently renders nothing in CI or over screen sharing.

9. **The renderer draws from `ViewportSource`, not a concrete type.** Editor and play
   sessions both implement it, so pressing Play swaps the frame source rather than
   standing up a second Metal stack. Keep new render inputs behind that protocol.

10. **A screen effect costs nothing when none is switched on.** `Renderer.draw` takes
    the direct path unless `model.activeScreenShader` is set *and* compiled; only then
    are offscreen targets allocated. Do not "simplify" this into always rendering
    offscreen and blitting — that is a full-resolution copy every frame, forever, to
    achieve nothing.

11. **Overlays are drawn after the effect, into the drawable.** Moving gizmos or
    selection boxes into `encodeScene` would tint the editor's own furniture with
    whatever effect is running, which makes editing under one unusable.

12. **Screen-effect depth is read, not resolved.** The offscreen depth texture is
    multisample and stored, and the shader reads sample 0 via `depth2d_ms`. Multisample
    *depth* resolve needs a filter and is less portable than colour resolve. Both raw
    `depth` and linearised `distance` are exposed — dropping `distance` would leave
    learners with a value that behaves nothing like the distance it looks like.

85. **Screen effects are a chain, in scene order.** `SceneModel.screenShaderIDs` is the
    set switched on (`screenShaderID` is the first, for old code and old files, which
    still load); `activeScreenShaders` runs them in the order the shaders are listed.
    `Renderer.encodeFrame` draws the world into a texture, each effect but the last into
    one of two in-between textures at the view's formats (the pipelines are compiled for
    the view's pass, so every target matches its sample count and depth), and the last
    into the view, then the overlays. Every effect reads the world's depth.
    `frameSnapshot` runs the same path off screen for the tests.

### Shaders

13. **A user shader supplies a function body, never a whole file.** `ShaderSource.wrap`
    and `wrapScreen` generate the uniform structs, the vertex stage and the entry
    points. Widening that to whole translation units hands users the ability to declare
    structs that disagree with Swift's — which fails *silently*, as garbage geometry
    rather than an error. New inputs go in `ShaderSource.inputs` / `screenInputs`, which
    is both what the editor lists and what the tests check is really in scope.

14. **`#line 1` is what makes shader errors readable.** It sits immediately before the
    user's body so clang counts from their first line. Without it every error is
    reported tens of lines off, against generated code the user never wrote.

15. **A shader compile must never block the render thread and never lose the last good
    pipeline.** `ShaderLibrary` debounces, compiles on a background queue, and keeps the
    previous pipeline until a new one succeeds. Compiling inline would stutter every
    keystroke; dropping the pipeline on failure would black out the viewport mid-edit.

### Luau

16. **The interrupt hook must not touch the Lua stack.** It runs at arbitrary safepoints
    where the stack may be full; pushing there trips Luau's API assert and aborts. The
    shim finds its wrapper through `lua_callbacks(L)->userdata`, never the registry.

17. **Host calls read and write the *calling* thread's stack.** `__studio_invoke` can be
    called from a coroutine, which has its own stack. The shim records `current` and
    every `studio_lua_*` accessor uses it. Using the main state instead once made every
    `print` inside a `Heartbeat` handler vanish silently — no error, no output.

18. **Nothing may `lua_setglobal` after `studio_lua_sandbox`.** The globals table is
    read-only then, and a host-side write outside a protected call aborts the process.
    That is why per-script environments live in the registry.

19. **Mutable library state lives in locals; assignable singletons are userdata.**
    Sandboxing freezes every table reachable as a global, and read-only is checked
    *before* `__newindex`. So the scheduler, connections and object registries are
    locals, and `workspace`, `game`, `Screen`, `RunService` and friends are
    `newproxy` userdata — a frozen table would turn `Screen.Shader = x` into "attempt
    to modify a readonly table". (`newproxy` objects are why `typeof` is overridden:
    Luau's own `typeof` ignores `__type` on them.)

20. **Chunk names start with `=`.** `"=Spinner"` makes Luau print `Spinner:12: …`
    verbatim; without it errors read `[string "..."]:12:`. No prelude is prepended to
    Luau scripts, so line numbers are the user's own with no offset.

21. **`Vector3` and `Color3` components are float32.** The scene stores `Float`, and so
    does Roblox. Without rounding at construction, a vector read back from a part stops
    comparing equal to the one written (`Instance.new`'s default grey was the case that
    exposed it).

22. **`LuauAPI` must track `StudioLibrary.swift`.** The completion tables are a
    hand-written mirror. Add a member to one and not the other and the editor will
    confidently suggest something that does not exist, or hide something that does.
    Properties and methods are separate kinds because `.` offers one and `:` the other.

### The player

29. **Only the Humanoid moves the character.** No Swift code turns keys into motion;
    `PlayController.key` only records held keys and queues input events. If you add a
    control, add it to `CoreScripts.controlScript` (and a test driving `session.key`).
    `PlayerSelfTest.testScriptsOwnTheControls` fails if a disabled ControlScript still
    lets the player walk.

30. **Characters are addressed by generation.** Every `humanoid.*`, `root.*` and
    `body.*` call carries one; a stale generation reads as dead (`Health` 0, state
    `Dead`) and writes are ignored. Never route those calls to "the current character"
    without the check, or a script holding an old Humanoid will steer the new one.

31. **Everything a character's scripts start is in that character's scope.** The Luau
    scheduler tags threads, sleepers and connections with a scope (the generation for
    StarterCharacterScripts, 0 otherwise); children inherit it. `__studio_kill_scope`
    disconnects and closes all of it on respawn. A new way to start a thread must go
    through `adopt(thread, currentScope())`, or it outlives its character.

32. **Host events are drained once per frame, at the top of `__studio_tick`.** Events are
    `ScriptValue` lists appended to `PlayController.pendingEvents`; `player.events`
    empties the queue. Don't fire Luau signals from Swift directly — it would re-enter
    the VM mid-frame.

33. **Jumps are exact.** `CharacterController.step` applies gravity half before and half
    after moving (velocity Verlet) so the peak is `JumpPower²/2g` or `JumpHeight` at any
    frame rate; `PlayerSelfTest` checks within a few hundredths of a stud.

34. **Touches are diffed, never re-sent.** `PlayController.touching` is the set of
    (part, body part) pairs in contact; only changes become events, so standing still
    on a part fires once. Death and respawn end every touch (with events); a destroyed
    part is dropped without one. Limb swing is deliberately ignored by
    `CharacterTouch`, or walking would flicker the legs' contacts every step.

35. **`CanCollide` must be honoured everywhere the character or its camera meets
    geometry**: `CharacterController.step` (solids), `chooseSpawn`, and the camera's
    wall probe in `PlayController.renderCamera`. Touch detection ignores it on purpose.
    Editor picking ignores it too — you must still be able to select a trigger zone.

36. **Touch dispatch re-checks `part.exists` between handlers.** A pickup's handler
    destroys the part; without the check the next handler (or the other leg's event
    in the same frame) is handed a destroyed part and errors.

37. **The avatar's look and its touch volume share one table.** `AvatarPose.bodyParts`
    sizes both the rendered meshes' placement and `CharacterTouch`'s capsules. Change a
    body part's size or joint there, not in the renderer, or you will touch things
    the model doesn't reach. The avatar meshes are built at *real* size (a scaled
    rounded box squashes its corners), so the renderer never applies `Mat.scale` to them.

38. **The avatar faces −Z at yaw 0**, matching `CharacterController.facingYaw`. The
    face mesh sits on the head's −Z side; `AvatarSelfTest.testFacing` checks the face
    points the way the character walks at three yaws.

39. **Animations crossfade by state weight; they don't ease joints.** Easing the joints
    lags a cyclic motion and shrank the walk to 60% of its stride. Each state's pose is
    evaluated fresh every frame and weighted; only speed is smoothed.

40. **Animation keys are degrees; everything after sampling is radians.** The editor
    and saved files use degrees (as Roblox's editor does); `AnimationObject.sample`
    converts. `AnimationEditor.rotation(of:)` converts back for display.

41. **Tracks are addressed by handle and belong to one generation.** `track.*` host
    calls ignore a handle from an old character (`trackHandle` checks the generation);
    `spawnCharacter` empties the `AnimationPlayer`; `__studio_kill_scope` drops the Luau
    track records. A track only animates the joints its animation keys.

42. **Rig posing is a stroke.** `AnimationEditor.beginPose` opens `beginStroke`,
    `endPose` closes it, so a whole drag is one undo step. Anything else that edits an
    animation goes through `SceneModel.editAnimation` (one commit) or a stroke.

43. **`ImageRenderer` can't draw AppKit-backed views.** `--render-panel` shows scroll
    views as blank and text fields as yellow placeholders; that is the tool, not a bug.
    `JointInspector.content` exists so the inspector can be drawn without its scroll view.

67. **`Humanoid.Jump` waits until the character can jump, as in Roblox** — it is cleared
    only by a jump happening — so a control script must clear it when the key is let go,
    or a tap's requests from the frames just after take-off jump again on landing. The
    default ControlScript sets it each frame Space is held and clears it in `InputEnded`.
    Never write `Jump = false` every frame instead: a frame dispatches queued events
    (Touched, input) *before* RenderStepped, so it would cancel a jump pad's request.
    `PlayerSelfTest` pins all three: one tap one jump, holding repeats, jump pads work.

68. **The first character is not announced.** `start()` spawns it before any script
    runs, so `player.Character` already has it; `spawnCharacter` queues `CharacterAdded`
    only for later ones. Queuing it too reached scripts that connected at their top
    level, and Roblox's idiom — handle `player.Character`, then connect `CharacterAdded`
    — ran twice for the first character.

### Lighting

44. **Anything that includes `lightingMetalSource` is compiled with
    `Renderer.lightingCompileOptions(rayTracing:)`** — it defines `STUDIO_RAYTRACING`,
    which guards every `metal_raytracing` use — and its lit fragment functions are made
    with `Renderer.lightingConstants(rayTraced:)`. Forget the options and the library
    compiles without ray tracing; forget the constants and `makeFunction` fails.

45. **Lit fragments take `STUDIO_LIGHTING_PARAMS` and bind at fixed slots**: lighting
    buffer 4, point lights 5, shadow map texture 0, and (ray traced) acceleration
    structure 6, instance info 7, face normals 8. `Renderer.bindLighting` binds them
    all once per scene pass; primitive structures go in through `useResources`, or rays
    silently hit nothing.

46. **Every ray-traced mesh is registered in `buildMeshes` via `traced(...)`.** A mesh
    drawn but not traced casts no ray-traced shadow and shows in no reflection. The
    instance's `mesh` name must match; `faceNormals` is indexed by the mesh's offset
    plus `primitive_id`.

47. **Parts holding a light are masked out of that light's shadow rays**
    (`maskLightHousing`); otherwise the part around the light would shadow everything.

48. **The default lighting reproduces the old look.** Brightness 2 × 0.425 is the old
    0.85 sun, Ambient/OutdoorAmbient give the old 0.22–0.52 hemisphere, and specular is
    normalised by `sunColor / 0.85`. Keep that when retuning, or every existing scene
    changes brightness.

### The tree and physics

49. **The tree is stored flat.** Parts and groups carry `parentID` (nil = Workspace);
    nothing iterates the tree to draw or collide. `SceneModel.parts` stays one array
    in creation order. Anything that removes nodes goes through `removeSubtrees`
    (children and scripts go too); anything that copies goes through `cloneSubtree`
    (ids, parents, PrimaryPart and scripts are remapped).

50. **`selection` holds parts and groups; `effectiveSelection` is what moves.** A
    selected Model contributes every part inside it; a Folder contributes nothing.
    Gizmos, the Properties panel's part editing and outlines use `selectedParts` /
    `effectiveSelection`, never `selection` directly.

51. **CFrame crosses as 12 numbers in Roblox's order**: x, y, z, then the rotation
    matrix row by row (`Pose.components` / `Pose(components:)` in Swift, the table
    layout in Luau). Rotations compose as Y·X·Z for `Orientation`, X·Y·Z for
    `CFrame.Angles`. The Luau suite checks both against each other and against parts.

52. **Luau tree calls return tokens** — `p:<id>`, `g:<id>`, `w` — so Luau knows what to
    wrap. Parts and groups share one id space; `nodeId` in the library maps back.
    Wren keeps the flat `workspace.*` calls and never sees groups.

53. **Only `PhysicsWorld` talks to Jolt**, and only through `CJolt`'s C API. Pass
    vectors as `[Float]` arrays (`PhysicsWorld.floats`) — a pointer to one SIMD lane
    isn't guaranteed to lead on to the next.

54. **The scene is the truth; Jolt follows it.** `sync` runs every frame and before any
    script physics call: a part whose pose differs from `Body.written` was moved by a
    script and is teleported. Physics writes back only through `step`'s `moved` list,
    updating `written` so the next sync sees no difference.

55. **Jolt's units are studs, tuned by hand** (a stud ≈ 0.28 m, gravity 196.2): the
    slop, speculative distance and sleep threshold in `studio_jolt_create` are scaled
    up from Jolt's metre defaults. Change them and re-run `PhysicsSelfTest` — the
    tower and tunnelling tests are the sensitive ones.

56. **The character is a kinematic capsule in its own layer** that meets only
    unanchored parts, so falling parts land on the player; pushing, which should
    depend on mass, is `PhysicsWorld.push`, not the capsule. A teleport of more than 8
    studs is placed, not swept.

57. **Welded parts are one Jolt body.** `PhysicsWorld.sync` unions the enabled
    `WeldConstraint`s and builds a compound shape per group, anchored if any member is.
    The offsets are taken when the assembly is built (as Roblox's WeldConstraint does),
    and `Assembly.colliders` maps Jolt's sub-shape indices back to parts for `Touched`.
    A script moving any member teleports the whole assembly.

58. **Joints connect assemblies, never parts directly.** `syncJoints` skips a
    constraint whose ends are in the same assembly or both static, rebuilds when its
    fingerprint changes (ends, anchors, limits, lengths), and writes motor targets
    every frame. A servo is a velocity motor steered by a speed-limited controller,
    because Jolt's position motor has no speed limit.

59. **Hinges, ball sockets and sliders switch off collision between their two bodies**
    through the `JointFilter` group filter in the shim. Ropes and springs don't.

60. **Round shapes stay exact; squashed ones become hulls.** `PhysicsWorld.shape(of:)`
    uses Jolt's sphere and cylinder only while the part is uniform (within 1%), and a
    hull of the true ellipsoid or elliptical prism otherwise.

69. **Only a living character has a capsule.** While the Humanoid is dead,
    `simulateParts` calls `PhysicsWorld.removeCharacter` instead of `moveCharacter`, so
    what rested on the player falls when they die; the next character gets a new one.
    `removeCharacter` wakes every body first — Jolt leaves a sleeping body in place
    when what it rested on is removed.

### Wren

23. **Wren reserves leading double underscores for static fields.** `__Foo` cannot be a
    variable name; the prelude imports `Script` as `StudioScript_` for this reason.

24. **`WrenAPI` must track `WrenModules.swift`**, as `LuauAPI` tracks the Luau library.

### Scene data and the editor

25. **Anything added to the scene must live in `SceneState`.** Undo, redo, saving,
    play-test restore and model export all operate on it. A new collection on
    `SceneModel` that is not in `SceneState` will not save, will not undo, and will
    survive a play test that should have rolled it back.

26. **A script with no `language` field decodes as Wren.** Every file saved before Luau
    existed is Wren and has no such field. New scripts default to Luau in code; the
    *decoder* must not. `DocumentSelfTest` pins this.

27. **`Vec3.rotatedY` (Wren) and `Vector3:RotatedY` (Luau) must agree with a part's Y
    rotation.** A positive turn takes +X towards −Z, matching `simd_quatf` about +Y.
    Both suites check against simd at four angles; the first version turned the wrong
    way and every other geometric check still passed.

28. **The code editor must never re-assign identical text.** `CodeEditor.syncText`
    returns early when `textView.string == text`; re-assigning collapses the caret to
    the end on every keystroke. Do not replace it with SwiftUI's `TextEditor`, which has
    exactly that bug and also turns on smart quotes.

61. **A join tool takes the viewport over.** While `SceneModel.joinTool` is set,
    `ViewportController.mouseDown` sends clicks to `pickJoinTarget` before any gizmo or
    selection handling, and returns without starting a drag or touching `selection`;
    the overlay reports gizmo mode `.select` so no gizmo is drawn. Transform tools
    are picked through `selectGizmo`, which puts a join tool away — setting
    `gizmoMode` directly does not. Esc in the viewport cancels the tool before it
    clears the selection.

62. **Joins go through `makeJoin`, which has no undo step of its own.** `join` and
    `joinSelection` wrap it in one `commit`, so a whole wall is one undo. `makeJoin`
    refuses to stack a second weld on a pair that already has one (`weld(between:and:)`).
    `joinSelectionOnPick` is the one editor preference kept in `UserDefaults`
    (`SceneModel.joinSelectionKey`); tests that change it must put it back.

63. **The viewport never leaves the view tree.** `DocumentArea` keeps `ViewportView` as
    the first child of its ZStack and lays the document over it; rebuilding the view
    would build a new `Renderer` and recompile every Metal pipeline. While a tab is in
    front, `StudioMTKView.showsWorld` is false: the view is hidden, draws nothing,
    swallows keys (Delete must never delete parts behind a script), lets go of the mouse
    and held keys, and a 60 Hz timer calls `Renderer.tick` — `stepFrame` plus the shader
    library refresh — because the play test and shader compiles are driven from the
    draw loop. `updateNSView` sets `showsWorld` before `player`, so Play from a script
    tab can take the mouse.

64. **A tab's text view outlives its SwiftUI view.** `CodeEditor` with a `cache` and
    `cacheKey` (`EditorSession.codeViews`, keyed by `EditorDocument.id`) returns a
    fresh container and moves the cached scroll view into it, so caret, scroll and undo
    survive tab switches; `EditorSession.close` forgets the entry. Each entry has its
    own `UndoManager`, handed out by the coordinator's `undoManager(for:)`. Don't
    rebuild editors with `.id(language)`: a language change re-highlights instead.

65. **Menu keys that mean something in text go to the code editor first.** Undo, Redo,
    Select All, Delete (⌘⌫), Focus (⌘F → find) and Group (⌘G → find next) call
    `TextCommand.perform` with the key window's first responder, and act on the world
    only when that isn't a `CodeTextView`; `validateMenuItem` retitles them to match.
    Shortcuts with shifted punctuation must name the shifted character (`"}"`, not `"]"`
    with ⇧) — AppKit matches what the key types. Cut, Copy and Paste are the opposite
    case: menu items with **no target**, so AppKit carries them down the responder chain
    to whatever text has the keyboard; the menu bar is ours, and without them ⌘C and ⌘V
    did nothing anywhere. `makeMainMenu()` builds it, so the suite can inspect it — and checks that no two
    commands share a shortcut (the second would never run from the keyboard).

66. **Scene undo/redo keeps script and shader text.** `SceneModel.keepingText` copies the
    current source of every script and shader that exists on both sides into the state
    being restored; text has its own undo in its editor. Without it, undoing a part move
    silently reverted code typed since.

70. **Ids are unique, and loading makes sure.** Everything is looked up by id — the
    physics builds `Dictionary(uniqueKeysWithValues:)` from them and traps on a repeat.
    New things get fresh ids and copies are remapped, so only a hand-edited file could
    repeat one: `SceneState.repairingDuplicateIDs()` runs on every scene opened (editor
    and client) and model inserted, giving later copies fresh ids.

86. **GUI layout is worked out afresh on every draw, and StarterGui is copied, never shared.**
    `GuiStore.layout(in:)` places everything from the objects each time — a
    UIListLayout's children in order (their Position ignored), AutomaticSize grown to
    measured text (`GuiFont.measure`) or to children, a ScrollingFrame's children on its
    canvas offset by CanvasPosition (clamped only when read, so `1e9` means "the end"),
    clip rectangles from ScrollingFrames and ClipsDescendants, BillboardGuis from
    `billboardPlacer` (the play session projects the Adornee: "p:<part>" or
    "c:<character>:<body part>"). What depends on a draw (AbsoluteSize, CanvasPosition)
    uses the last screen size. StarterGui lives in the scene as `StarterGuiObject`s
    keeping only changed properties by their host names; `GuiStore.copy` makes a
    player's copy (and Studio's preview), `PlayController.guiCopies` maps each original
    to its copy, and `tree.scriptParent` answers "u:<id>" for a LocalScript's copy.

### LAN and the client

71. **The Bonjour type lives in two places.** `LAN.serviceType` and each app's
    `NSBonjourServices` in `make_app.sh` must match, or macOS's local-network privacy
    blocks browsing in the bundled app. Change a `LANMessage` and bump
    `LAN.protocolVersion`; hosts refuse other versions with `sendAndClose` — a plain
    `close` after `send` drops the message.

72. **The profile goes on before `start()`.** `PlayerProfile.apply` sets the scene's
    StarterPlayer body colours and `PlayController.playerName`; the character spawns in
    `start()`. `player.Name` and the character's Name come from `player.get "name"`.
    `ClientSession` snapshots the scene at play and restores it on leaving.

73. **Characters travel as `PlayerState`; the host is the relay.** While in a network game
    `ClientSession.syncNetwork` runs 20 times a second: it sends this player's
    `networkState` (to the host as `.state`, or via `LANHost.share` when hosting) and
    hands the others to `PlayController.remotePlayers`, which `avatars` draws — gliding
    towards each update, snapping on jumps of 20+ studs — and `remoteNameTags` labels.
    The host overwrites a player's id, name and colours with what their hello said.
    `LANSelfTest.testSeeingEachOther` is the multiplayer check new features copy.

74. **One world, run by the host.** A joiner's `PlayController.worldFromHost` is true:
    its `ScriptRuntime` skips scene scripts (StarterPlayer/Character ones still run,
    like Roblox LocalScripts) and `simulateParts` does nothing. The host diffs
    `model.state` against what it last sent (`SceneDelta.between`) each sync and
    broadcasts parts changed or removed, and groups, lighting, shaders, attachments and
    constraints (whole lists) when they change; applying is idempotent, so late joiners (who get the live scene in their
    welcome) come out right. Other players are capsules in the host's physics
    (`PhysicsWorld.moveCharacter(id:…)`, 0 is the local player) and upright cylinders in
    every `CharacterController.step` — unless `StarterPlayerSettings.playersCollide` is
    off. `LANSelfTest.testOneWorld` and `testPlayersCollide` pin it.

75. **The Character layer must query the Moving broadphase layer.** Jolt tests a pair
    of awake bodies from one side only — the one that woke first — through that body's
    `ObjectVsBroadPhase` filter. With the capsule's layer querying nothing, a part added
    while the player was awake (walking, just landed) fell straight through them; only
    a capsule asleep in Jolt ever caught anything. Likewise size any buffer for
    `studio_jolt_awake_bodies` for capsules too — it lists them — and re-ask if it
    overflows, or moving parts go unread and freeze.

76. **The Luau library is one chunk in files.** `LuauLibrary.inOrder` joins the parts
    with newlines and runs them as a single chunk, so a part may use any `local` from an
    earlier part and none from a later one; moving code between parts can break that
    silently only at run time (the Luau suite catches it). **A chunk has at most 200
    locals at its top level, and the whole library shares them: 153 are used.** (The self-test counts unindented `local` lines, so a part that wraps its helpers in `do … end` indents them, as part 15 does.) Past
    200 nothing compiles, so `ScriptSelfTest` fails at 190 — before then, gather related
    locals into a table instead of adding more, as `gui`, `cframeMath`, `lights`,
    `constraintKit`, `easings`, `randoms`, `tweens` and `otherPlayers` do. A renamed
    helper must not become a table-constructor key (`{ lookAt = … }` stays as it is).

77. **Other players' characters are numbered, not special-cased.** Player `p`'s `g`th
    character is `RemoteCharacter.number` = `(p + 1) × 1 000 000 + g` (the host is player
    0; this player's own generations stay below a million). Every character host call
    already takes the number first, so `playerInvoke` sends numbers it doesn't own to
    `remoteCharacterCall` (PlayController+Multiplayer.swift): reads answer from the
    player's last `PlayerState` (velocity and MoveDirection included); writes
    (`humanoid.set`/`damage`/`move`/`moveTo`/`state`, `root.set`, `body.set`,
    `character.moveTo`, `look.set`; remotes have their own messages, invariant 96) go to that player as `.call` and run there as their own call.
    The host also keeps each write in `pendingRemoteWrites` — Health clamped and damage
    taken off as the player's Humanoid will — and answers reads with it until the
    player's report agrees, their character changes, or 0.5 s pass, so a script reads
    back what it just set. Animation tracks on another player get handles in the same
    numbering (`remoteTracks`): `track.load` and each play/stop/set go to that player as
    one `.call("track.remote", [hostHandle, operation, …])`, which their game maps to its
    own handle (`hostTracks`) and plays for everyone; the host answers reads from a
    `RemoteTrack` it keeps by its own clock, and raises Stopped when that runs out. `noteRemoteChanges` raises PlayerAdded/Removing,
    CharacterAdded/Removing and Humanoid events from state changes; `updateRemoteTouches`
    raises touches on the host. In Luau, `character.owner` is −1 for this player, and
    `otherPlayers` (one table — the local budget) holds the other Player objects.

78. **The screen GUI lives in the host; Luau holds only faces.** Each GUI object is a
    `GuiObject` in the session's `GuiStore` under a number (0 is the PlayerGui); the
    Luau proxies from `gui.wrap` read and write it through `gui.get`/`gui.set`, which
    take the property's lower-cased name. A property is listed in two places:
    `gui.properties` in 09-Gui.swift (its type and which classes have it) and
    `guiProperty`/`setGuiProperty` in PlayController+Gui.swift. Clicks and focus
    changes come back through `player.events` as `["Gui", id, what, …]`. Only what is
    inside an enabled ScreenGui parented to the PlayerGui is drawn; UICorner and
    UIPadding are modifiers of their parent, never drawn. GUIs are per machine, like
    Roblox's — nothing about them crosses the network.

79. **Keys go to a focused TextBox first.** `StudioMTKView.keyDown` hands every key to
    `PlayController.typeKey` while `isTyping`, so no InputBegan fires (Backquote types
    rather than showing the HUD's output); focusing calls `releaseAllKeys` (nothing stays held)
    and makes the view first responder (a click on the GUI may come first). Chat is a
    host call, not a core feature: `chat.send` echoes locally and calls
    `PlayController.sendChat`, which `ClientSession.startSyncing` wires to
    `LANHost.chat` or `LANMembership.chat`; arrivals come in via `receiveChat` as
    `["Chat", name, text]`. The host relays a joiner's `.chat` to everyone but the
    sender, with the name from their hello. `ChatScript` is an ordinary core script, so
    a scene can override or disable it by name.

80. **Run mode is a play session without a player.** `EditorSession.startRun` makes a
    `PlayController(withPlayer: false)`: no character or capsule, `scripts.player` nil
    (so no StarterPlayer/Character scripts, and `player.present` is false — LocalPlayer
    is nil and GetPlayers empty), and `step` only runs scripts and parts. It sits in
    `session.play` (so everything that checks `isPlaying` locks editing) but
    `session.player` is nil, so the viewport keeps the editor's camera and input;
    `ViewportController.running` steps it with the editor's frames. Studio-only: nothing
    about it goes over the network.

81. **Tweens run in the library.** `TweenService:Create` returns a service proxy whose
    record lives in `tweens`; `tweens.step`, called from `__studio_tick` between Stepped
    and Heartbeat, writes each running tween's properties through the ordinary setters —
    so host tweens replicate like any other change, and a tween on a destroyed part
    writes nowhere and runs out quietly, as in Roblox. Starting values are read when the
    delay ends; a tween started on a property another is changing cancels that one.

82. **A Tool is a group that moves between places; its parts park.** `SceneGroup.tool`
    (`ToolSettings`) says where it is — `ToolPlace` workspace, starterPack, backpack(n)
    or hand(n), players by number (0 the host; `PlayController.playerID`). Out of the
    world (StarterPack, a Backpack) `setToolPlace` sets `Part.parked`, and every system
    that used `visible` checks `inWorld` instead — drawing, picking, touching, collision,
    physics — so nothing else knows about tools; `children(of: nil)` leaves such tools
    out of the Workspace, and scene scripts inside parked tools don't start. The host
    copies StarterPack for each character (`copyStarterTools`) and runs the copies'
    scripts under that character's scope — remote players' too, as Roblox's server
    does — and `script.Parent` is the tool, not the character. Held tools follow the
    hand each frame (`positionHeldTools`, from `AvatarPose.partTransforms`), are touched
    by bodies but not collided with or simulated (`partsOutOfHands`). A joined player
    asks the host with `LANMessage.action` (`backpack.equip`/`unequip`/`drop`/`activate`)
    and positions only its own held tool; the host's updates bring everything else.

83. **The mouse is Roblox's: free in third person, captured in first.** `StudioMTKView`
    captures the pointer only while the camera is first person or a script sets
    `UserInputService.MouseBehavior` (`hud.firstPerson`/`hud.mouseLock`, watched by
    `captureWatch`); otherwise right-drag turns the camera (the cursor held in place
    meanwhile) and the view keeps `PlayController.pointer`/`viewSize` up to date. Escape
    lets go of a captured pointer until the next click. Everything aimed comes from
    `mouseRay()`, through the pointer or the middle of the view: `input.mouse` (the
    Mouse's Hit and Target), ClickDetector hover (`updateHover`, each frame) and clicks.
    A click with a tool in hand uses the tool instead. ClickDetectors live on the part
    (`Part.clickDetector`, like a light); the host fires them (`["Click", part, player,
    what]`) — a joined player's game sends `click.part`/`click.hover` actions and the
    host checks the reach from where that player is.

84. **The world moves the character through three hooks, not physics.** The capsule is
    kinematic, so Jolt never moves it: `rideGround` carries the body by however the part
    it stood on (`CharacterController.groundPartID`, noted at the end of each frame in
    `standingOn`) moved since, turning it too; `takeHits` turns dynamic parts closing on
    it (checked before the physics step, which would bounce them) into
    `CharacterController.shove`, a velocity that fades; a Seat (`Part.seat`) holds a
    seated body in place each frame (`holdInSeat`) instead of stepping it. Climbing
    (moving into a `.truss` part) and swimming (the middle of the body in a `.water`
    part, which nothing collides with) are the controller's own modes. Other players'
    capsules are placed, not swept, in the host's physics — swept to each 20-a-second
    report they'd slam parts — and `remotePlayersPush` shoves what they walk into, with
    a lead for the network's delay.

88. **Sounds are scene data; the SoundSystem only makes them heard.** A `SceneSound`'s
    `playing`, `plays` (a counter bumped by every Play or Resume — a new value starts it
    again, from `timePosition`) and `timePosition` are all a script changes; each frame
    `PlayController.updateSounds` has `SoundSystem.sync` start, stop, move and fade
    voices to match, with the ears at `renderCamera`. So a host's Sounds reach joiners in
    `SceneDelta.sounds` with nothing else to send. Only the host decides a Sound ran out
    (sets `playing = false` and queues `["Sound", id, "Ended"]`); a joiner's copy just
    goes quiet (`finished` stops it restarting until `plays` changes). A Sound a
    LocalScript makes is `local`: never sent (`SceneModel.sharedState` drops them from
    the welcome and the deltas) and kept through deltas on a joiner. The library knows
    a LocalScript's thread by `threadLocal`, set at spawn (`__studio_set_spawn_local`)
    and carried like scopes through task.spawn/delay/defer and connections — all
    scripts share one VM, so this is the only way to tell. `SelfTest.run` sets
    `SoundSystem.makeOutput` to a `RecordingOutput` first: tests never make a sound,
    and read what would have played from it. Assets are decoded to mono so any sound
    can be placed; ImageLabels get pictures through `GuiStore.imageProvider` (the play
    session's, or the editor's for the StarterGui preview), cached by asset.

89. **StarterGui is edited through its preview copies, and a drag commits once.** The
    editor's `guiPreview` store holds copies of StarterGui, rebuilt on every change to
    `starterGui` or `selectedGui`; `GuiEditController.copies` maps each template to its
    copy (their numbers change on every rebuild — always look them up by template). A
    drag writes only to the copy (`store.update`) until it ends, then `setGuiProperties`
    commits Position and Size as one undo step; a component all in scale stays in scale
    (`GuiEditController.udims`). The overlay's hit shape is just the drawn objects and
    the selection's handles, so every other click reaches the viewport underneath. The
    preview is laid out at `GuiPreviewGeometry.screen` (a device's size, or the view's),
    drawn scaled — convert with `toScreen`/`toView`, never mix the two spaces. Scene
    files can't hold infinity, so `SceneModel.storable` keeps "no limit" as 1e9 (and a
    MaxSize with none at all as nothing). Modifiers are `GuiObject.Kind.modifiers`;
    `isLayout` and `needsGuiObject` say where they may go.

90. **One thing is selected at a time, and Esc clears it all.** Each kind has its own
    property (`selection`, `selectedGui`, `selectedSound`, `selectedAsset`,
    `selectedScript`, `selectedShader`, `selectedConstraint`/`Attachment`, Lighting,
    StarterPlayer); setting one lets go of the others in its `didSet`
    (`leaveOthers(for:)`), so an old pick never comes back when a newer one is cleared —
    the Properties panel shows the first that's set, in a fixed order. Parts stay
    selected beside a script added to them. `deselectAll()` clears every kind and the
    join tool; the editor window's local key monitor calls `EditorSession.monitorKey`,
    so Esc deselects before whatever has the keyboard sees it (and still passes it on).
    A new kind of selection must join `leaveOthers`, `deselectAll` and `hasAnySelection`.

91. **Nothing on screen in play is built in.** The editor's play test draws the viewport
    and the player's `GuiLayer` only (Stop is the ribbon's); the client draws the
    viewport, the GuiLayer, other players' name tags and its own menu bar (the way out
    of the game, like Roblox's). The HUD players see is StarterGui's PlayerHud
    (`DefaultHud`), and F/R are its FlyAndRespawn LocalScript — not the ControlScript,
    not a menu. `PlayHUD` holds only what the view needs (first person, the pointer).
    A scene carries `defaultGui` (the HUD version it was given): `loadScene` gives an
    older file the HUD, but a host's welcome is loaded as-is (`upgrading: false`), and
    a scene whose HUD was deleted keeps it deleted. Every console line reaches LogService
    through `ScriptConsole.onAppend` → a `["Log", text, type]` event next frame, and
    `logHistory`. First person reads as `MouseBehavior.LockCenter`, as in Roblox. A child
    named like a property (`Position`) is shadowed by the property — name HUD pieces so
    they aren't.

92. **The scheduler wakes threads in order, defers to the outermost resume, and
    never resumes a dead thread.** `resumeThread` counts how deep resumes are nested;
    when the outermost returns it drains `deferring.queue` (task.defer), so deferred
    code runs in the same frame, after the code that deferred it — and `__studio_tick`
    drains once more for anything deferred outside a thread. A drain runs at most
    10,000 threads (a thread deferring itself forever carries on next frame, not
    hangs). Threads due in the same tick wake in the order they slept. A thread closed
    while waiting (`task.cancel`, `coroutine.close`) is skipped wherever it waits —
    `task.cancel` also takes it off every signal's `waiting` — and `__studio_kill_scope`
    drops deferred threads of a character's scope like sleeping ones. task's arguments
    are checked with `taskSeconds`/`taskThread` (Roblox's messages).

93. **A MeshPart is a block with `Part.mesh` set, and its model is unit-sized.**
    `part.shape` stays `.block` (the fallback when the model can't be read), so switches
    over `PartShape` never see meshes; everything that cares checks `part.mesh` first.
    `MeshGeometry` squeezes the model into the unit cube (invariant 1), so `Size` scales
    it like any shape; `nativeSize` is `MeshSize`. Geometry is found by asset id through
    `MeshLibrary.shared` (filled from `SceneModel.assets`' didSet), so physics, collision
    and picking need no model. `CollisionFidelity` decides the collider in
    `PhysicsWorld.shape(of:still:)`, `Collision.meshContact` and `Picking.intersect` alike —
    box, hull (Jolt's `ConvexHullBuilder` via `studio_jolt_convex_hull`), or precise, which
    is a Jolt `MeshShape` only for a static assembly (moving ones use the hull; Jolt's
    mesh shapes can't be dynamic). A click (`Picking.pick`) always tests the real
    triangles. Meshes are drawn two-sided (imported winding isn't trusted) and textured
    through a separate UV buffer at vertex index 3, so `Vertex` and `DrawUniforms` keep
    their sizes; each model is added to the ray-tracing scene as `"mesh:<uuid>"`.

94. **What a character wears is an `AvatarLook`, owned by the machine that runs the
    character.** `PlayController.look` is set at each spawn from
    `StarterPlayerSettings.look.worn(by: playerLook, …)` — `playerLook` is the client
    profile's, built-in things only, since a place's imported files don't travel with
    the player — and rides in every `PlayerState` (so others draw it; `LAN.protocolVersion`
    went to 12 for it, and to 13 for data objects). Scripts read and write it through `look.get`/`look.set` (the
    whole look as `{face, shirt, pants, {accessory…}}`; `set` takes one key), which for
    another player go to them as `.call` with a pending write (invariant 77). The Luau
    Accessory, Shirt, Pants, face Decal and HumanoidDescription (`avatarKit`, in the
    player part) are views of that value, never objects of their own: a worn accessory is
    its entry's id. Accessories hang from R6 attachments (`AccessoryType.attachment`) via
    `AvatarPose.accessoryTransforms`: a built-in one is made at its real size around the
    attachment point; an imported model is the unit-cube MeshGeometry stretched to its
    native size and placed by the type's `anchor`. Clothes use the classic template: the
    clothed body parts are `MeshFactory.clothedBox` (the same rounded boxes as the plain
    body, with UVs per face region) drawn with `scene_fragment_clothed`, which lays the
    premultiplied picture over the body colour; pants and shirt are layered into one
    texture for the torso. A face picture is drawn on `faceDecal` instead of the classic
    shape face (look.face `""`); `builtin://None` draws neither.

95. **ModuleScripts are compiled when the Luau VM starts and run on first `require`.**
    A module is a `ScriptObject` with `kind == .module` (in ReplicatedStorage —
    `ScriptHost.replicatedStorage` — Script Service, or a part or Model); `start()`
    never runs one. `ScriptRuntime.defineModule` compiles each as
    `__studio_define_module(id, function(...) <source>\nend)` — the wrapper on the
    module's first line, so its errors keep its own line numbers — in its own
    environment, whose `script` answers ClassName "ModuleScript". Luau's `require`
    (part 15) runs it once per VM under `pcall` (yields allowed), caches the single value,
    and gives Roblox's errors for a loop, a count other than one, and a module that
    failed (which then stays failed). The cache is kept per side — "server:" or
    "client:" by `inLocalScript` — so the host's scene scripts and its LocalScripts each
    run a module once, as Roblox's server and client do; a joined player has only a
    client side.

96. **Folders, Values and remotes are data objects; remotes ride the existing channels.**
    `DataObject` (DataObjects.swift) covers Folder, Int/Number/String/BoolValue,
    RemoteEvent and RemoteFunction, with a `DataParent`: none, the Workspace,
    ReplicatedStorage, a Player (their number) or a node (part, group or another data
    object) by id. They live in `SceneState.dataObjects`, travel in `SceneDelta.dataObjects`
    (a joined player's own are `local` and stay), are pruned and cloned with the tree, and
    reach Luau as "v:<id>" tokens (`dataKit`, part 15); ReplicatedStorage is "rs", Script
    Service "sss", a player "pl:<n>" (`data.children`/`data.find`). `Instance.new("Folder")`
    still makes a tree Folder; parenting it to a Player, ReplicatedStorage or a data
    Folder turns it into a data Folder of the same id (`data.fromGroup`), and its proxy
    delegates to `dataKit.Meta` from then on (`dataKit.adopted`) and stays the one object
    for that id. A script's own `.Value` write fires Changed at once in Luau and tells
    the session (`noteDataWritten`); any other change — the host's, arriving — is found
    by `noteDataChanges` diffing each frame and raised as `["DataChanged", id]`.
    Remotes (`remote.*`, PlayController+Remotes.swift) go joined player → host as
    `sendAction("remote.server"/"remote.invoke"/"remote.replied")` and host → player as
    `forwardToPlayer("remote.client"/"remote.invoke.client"/"remote.replied")`; the
    machine that runs the world (host, or alone) is the server and delivers its own
    locally. Arguments are encoded by `dataKit.encode` into tagged lists (`{"$v3", …}`,
    `{"$p", id}`, `{"$pl", n}`, `{"$t", k, v, …}`). On the host, LocalScripts are the
    client and scene scripts the server (`inLocalScript`), which decides FireServer vs
    FireClient. A player who leaves takes their `.player(n)` objects with them. The
    leaderboard is StarterGui's PlayerList (`DefaultHud.makeLeaderboard`, HUD version 2),
    which reads `leaderstats` like any LocalScript would. More classes are data objects
    too: ObjectValue (a token — "p:", "g:", "v:", "s:", "pl:<n>"… — in `text`),
    Vector3Value, Color3Value and CFrameValue (`numbers`), UnreliableRemoteEvent (a
    RemoteEvent) and BindableEvent/BindableFunction (same machine: `Fire` fires `Event`
    directly, `Invoke` calls `OnInvoke` in the caller's thread). A remote event that
    arrives with no handler is queued on its signal (`dataKit.deliver`; the signal's
    `onConnect` hook flushes it when the first handler connects), and the host fails
    an InvokeClient whose player leaves (`invokesWaiting`). GUI objects cross only to
    their own VM (`dataKit.vmTag`).

97. **ReplicatedStorage and ServerStorage keep tree nodes by parking them.** A part or
    group at the top of the tree may have `storage` (SceneModel+Storage.swift): it isn't
    among the Workspace's children, its parts are `parked` (like a Tool's in a
    Backpack), and `isParked` keeps its scripts from starting. `setStorage` moves things
    in and out; Luau's `Parent = ReplicatedStorage/ServerStorage` is `tree.store`, and
    `tree.parent` answers "rs"/"ss". A clone of a stored thing lands in the Workspace
    with its scripts started (`landInWorld`), as does a stored thing parented back
    (`tree.setparent`). `sharedState` goes through `withoutServerStorage`, so joined
    players never receive ServerStorage's nodes, scripts, modules or data objects; in
    Luau, ServerStorage and ServerScriptService look empty to a client.

98. **A LocalScript's screen effects are its own machine's.** `Screen:AddShader`,
    `RemoveShader` and `Screen.Shader =` from a LocalScript pass `local = true`
    (`dataKit.isLocal()`), which lands in `SceneModel.localScreenAdded/Removed` rather
    than the shaders' `enabled` flags. `activeScreenShaders` applies them on top, so
    nothing a LocalScript does is replicated or saved, and `PlayController.start/stop`
    clears them. A Script on the host still changes `enabled` for everyone.

99. **Adventure Island is built in code and played by the suite.** `AdventureIsland.state()`
    makes a fresh `SceneState` each time (its random numbers are seeded, so it's the same
    island every time); it is not a file in the repo. Its ground's top is at y 0.2, and
    everything standing on it a little above, because the editor's grid and the physics
    ground plane are at y 0 and would z-fight with it. `AdventureSelfTest` plays it
    through `PlayController`, so a change to the player, remotes, GUI or scripting that
    breaks the game fails there — fix the engine, not the test, unless the game itself
    was wrong.

100. **Suggestions never touch the text until chosen, and Return is a new line unless one
    was picked.** The editor does not use AppKit's completion (`complete(_:)` is
    overridden to open `CompletionList`, and Esc is swallowed so AppKit can't open its
    own): AppKit's wrote its first guess into the text and took Return, so every `end`
    then Return needed two presses. The coordinator's `doCommandBy` handles the list's
    keys first — ↑↓ move (and set `picked`), Tab accepts, Return accepts only if
    `picked`, Esc closes. `mayOffer` and the engine's `isNamingSomething` decide where
    nothing is offered; `isSameWord` drops a suggestion that is the word already typed,
    which is what closes the list on a finished `end`. Keep these when changing it, and
    extend `EditorSelfTest.testSuggestions`, which types through `insertText` and
    `doCommand` the way the keyboard does.

101. **Luau completion sees the scene only through `LuauScene`.** The script tab's
    completion closure builds `model.luauScene(editing:)` on each request (cheap: it
    groups by parent once), and `LuauCompletion.items(…, scene:)` stays a pure function
    of text, caret and scene — tests hand it a scene built by hand. Places are nodes, so
    `game:GetService("ReplicatedStorage")` and `workspace` resolve (`refine`) to the real
    place when there's a scene and to the API tables when there isn't. A module's members
    come from `LuauModuleShape`, which reads the code's shape and never runs it; keep new
    patterns there, with a test. `GetService("…")` and `WaitForChild("…")` are the only
    strings with suggestions (`nameArgument`), and their replacement starts after the
    quote (`CodeLanguage.completionRange`), since a name may contain spaces.
    `LuauAPI.services` must list exactly what the library's `services` table (14-Extras,
    plus 15-Data's three places) holds; `SyntaxSelfTest.testServices` runs each one.
    `LuauModuleShape` counts blocks by `function`/`do`/`if`/`repeat` against
    `end`/`until`, except an `if` that is a value (`return if …`, `x = if …`), which
    has no `end` — getting that wrong hides every member after it.

102. **Every new place has the Utils ModuleScript** (`UtilsModule.make()`, in
    `loadStarterScene` and `clearScene`); an old place opened is *not* given one (it's
    the place's own code, and may have been deleted on purpose) — Insert Utils Module
    is there for that. Its source is Luau in the shape `LuauModuleShape` reads, with a
    comment above every `function Utils.name`, which is what the editor shows; keep
    that shape, and add a test in `UtilsSelfTest` for anything added.

103. **The home page replaces the editor while it shows** (`session.showingHome`, in
    `ContentView.body`), so the viewport isn't drawing behind it. Everything that makes a
    new place from something built in — a template, the starter scene, Adventure Island,
    File › New — goes through `SceneDocument.startNew`, which leaves the document
    untitled: before, loading the starter scene over an open file and pressing ⌘S wrote
    it over that file. While the page shows, `validateMenuItem` allows only
    `homeActions`. The editor's thumbnails come from one `PlaceThumbnail.shared` renderer
    (making a Renderer compiles its shaders — slow), one picture per run-loop turn, so
    the page answers clicks while they come. SwiftUI's `Capsule` is hidden by the
    physics `Capsule` struct: write `SwiftUI.Capsule()` in views, or the compiler gives
    up with "failed to produce diagnostic".

104. **Nightfall's zombies are anchored Models moved by `Horde.step`**, 20 times a
    second, on the host. They are not physics bodies:
    - they steer round the boxes `Horde.findBlockers` reads *once* at the start
      (anything solid standing on the ground; a turned part as its widest square),
      trying ever wider turns when the way ahead is blocked;
    - with a blocker on the straight line to their goal (`Horde.clearLine`, checked
      every 0.4 s), they follow a PathfindingService path instead (`Horde.towards`,
      recomputed every 1–1.5 s), with a radius half a stud wider than their own so the
      waypoints keep off the walls their steering avoids;
    - a zombie spawning inside a blocker steps to the nearest free spot.
    The root part has no CFrame in Luau, so a player's facing (for swings and dashes)
    is their last `MoveDirection`. The character controller sets horizontal velocity
    from input every frame, so a dash moves the root part in hops rather than setting
    its velocity.
    The Hurt and Night screen effects keep their parameters fixed, and each player's
    LocalScript switches them on and off. Shader parameters set on the host reach every
    player, so a changing parameter would leak one player's health onto another's
    screen.
    The test hooks are data, not code: `quick` in NightfallSelfTest shortens the day and
    the nights through ServerStorage.Settings.

105. **Mega Obby's stages must stay possible.** `MegaObby.Builder` sizes every obstacle
    from `t` (how far along the course the stage is). The limits come from the
    character (walk speed 16, jump power 50, gravity 196.2): about 7 studs across at
    the same height, less going up.
    `MegaObbySelfTest.testEveryStageCanBeDone` walks each stage's footholds in order.
    A Mover counts as everywhere it goes; a turned part as its widest square. It fails
    on any gap or rise beyond `reach(rising:)`, with 10% to spare. A change to a
    stage's sizes (or to the character's jump) must keep it passing.
    What obstacles do is decided by part name in the Mechanics script, so anything
    renamed stops working.

106. **Shift lock is the engine's, on Left Ctrl** (Shift is the ControlScript's sprint).
    `PlayController.key` toggles it when `shiftLockAllowed`: StarterPlayer's
    `enableMouseLockOption` (default true, and true when a file lacks it) and the
    player's `devEnableMouseLock` (Luau `Player.DevEnableMouseLock`).
    When it's on:
    - `PlayerCamera.shiftLock` moves the target `shoulderOffset` to the camera's right;
    - after `character.step` the body's `facingYaw` is set to the camera's yaw, unless
      sitting, climbing or dead;
    - `input.mousebehavior` reports LockCenter;
    - `PlayHUD.shiftLock` makes the viewport capture the pointer.
    The controls panel's lines are numbered by position. A game changing one uses
    `DefaultHud.relabel(key:)`, never a line number.

107. **DataStores belong to a place, by `SceneState.placeID`.** New scenes (clearScene,
    the starter scene) get a fresh id; the sample games a fixed one (`placeID` on
    AdventureIsland, Nightfall, MegaObby), so they keep their data wherever opened.
    - A file without one gets `UUID(stableFrom:)` its path when opened, through
      `ensurePlaceID` (SceneDocument.open, ClientSession.open). It is set outside
      `commit`, so opening never marks the place edited.
    - `SceneState` has a hand-written `encode(to:)`: anything new in it must be added
      there too. `placeID` once wasn't, and every save lost it.
    - `DataStoreFiles.shared` writes through at once, as JSON of the library's own
      encoding ("$t" lists). `datastore.*` answers nothing unless `runsSceneScripts`,
      and the Luau library refuses LocalScripts before that.
    - The self-tests point `DataStoreFiles.shared.directory` at a temporary folder (in
      `SelfTest.run`), so they never touch real saves. The sample games' suites clear
      their place between tests, since each test expects to start with nothing saved.

108. **The client starts on its game picker, but `ClientSession` doesn't.** The app
    delegate calls `showGames()`; a bare `ClientSession()` is still on `.menu`, which the
    LAN tests rely on. The character and join screens go back with `back()` to where they
    came from (`backScreen`), never to a fixed screen. Places opened in the client are
    kept in its defaults (`recentPlaces`); Studio's hand-over copy (`LaunchClient.isHandover`)
    is not one of them. The picker's pictures come from a `HomeModel` limited to the games
    (`templates`), so it draws four, not every template.

109. **Built-in sounds are names, not assets.** A SoundId starting `builtin://` is
    resolved by `SoundSystem.buffer(forSoundId:in:)` through `BuiltinSounds`, never
    `model.asset(named:)`; anything that asks how long or whether loaded must go through
    that too. They're synthesized on first use; `PlayController.start` has
    `BuiltinSounds.prepare` make a place's off the main thread, and a buffer is made
    outside the lock so a long loop never holds up a short effect. Changing a sound's
    recipe changes every place that uses it. Keep them deterministic (the synth's noise
    is seeded).
    Nightfall's zombies groan at times from `Horde.groans`, a `Random` of their own.
    A new `math.random()` call in the Horde or GameScript shifts where zombies spawn,
    and NightfallSelfTest's "they come for you" depends on that sequence. Sounds heard
    from a spot go in `workspace.Effects` (`Horde.sound`), which the blaster's ray
    ignores.

110. **PathfindingService's grid is the runtime's, kept up to date part by part.**
    `ScriptRuntime.navigation` (a `NavigationGrid`, Play/Pathfinding.swift) is synced
    at most once a frame, before a search. Only parts whose pose, size, shape or
    material changed are drawn again, so a moving part costs only its own cells.
    - A part's span over a cell comes from exact vertical rays (`Picking.intersect`) at
      the cell's centre and at its point nearest the part, so thin posts count.
    - Clearance is measured to each part's box, not to cells.
    - Parts containing the start point (the agent's own body) are left out of that
      search and of its later `path.check`s (`state.left` in the library).
    - Jumps are marked on the waypoint landed on, and can span two cells.
    Nightfall's first search builds the grid: about 0.2 s in a debug build, 0.02 s in
    release.

111. **The debugger stops inside the VM; it never yields out of it.** Luau's
    `debugbreak` hook (in our shim) calls `ScriptDebugger`, and the scripts wait inside
    that call. In Studio `EditorSession.paused` runs a nested event loop until a command
    comes. So:
    - While `debugger.paused` is set, `PlayController.step`/`stepFrame` do nothing. Stop
      during a pause only sets the command, and the session ends on the next frame
      (`onDebuggerStop`). Never stop or free the VM from inside the hook.
    - The shim stops the watchdog's clock for the pause, and gives `__studio_describe`
      (the library, part 16) 0.2 s per value. Breakpoints reached while describing are
      passed over.
    - Stepping can't use Luau's single-step mode. It only takes effect when the VM is
      entered afresh, and our scripts run under `lua_pcall` and the library's
      scheduler, which a `lua_break` would unwind through. So a step puts a breakpoint
      on every line of every kept chunk (`breakEverywhere`), and stops in the same
      thread at the right depth. It takes them away at the next stop, and puts the
      scripts' own back.
    - Each chunk is kept (`keepChunk`, in the registry by script id) as it loads, and a
      script's breakpoints are set on it then: a character script loads anew for each
      character. The environment of a frame's function says whose script it is
      (`studio_lua_debug_frame`).
    - Chunks compile at debug level 2 for local names. Luau puts a breakpoint on the
      first instruction of a line in each function, so a line stops once per pass.
    - `ScriptObject.breakpoints` are saved with the place but changed with
      `SceneModel.setBreakpoints`, outside `commit`. `EditorSession.stopPlay` carries
      them across the snapshot restore.

112. **Nothing inside a frame may throw, and no command buffer is held while the game
    runs.** Once, 3D sounds ended the game at nightfall in Nightfall:
    - The first sound in a part hit an AVAudioEngine exception. Either it crashed, or
      AppKit swallowed it mid-frame.
    - Swallowed inside `Renderer.draw`, it left that frame's command buffer taken and
      never committed. After 64 frames `makeCommandBuffer` waited for ever with the
      GPU idle: a frozen window.
    - Swallowed in the timer loop, it left the timer marked as firing, and it never
      fired again.
    So:
    - `Renderer.draw` steps the game *before* taking the drawable and the buffer.
    - Both apps register `NSApplicationCrashOnExceptions`, so an exception is a crash
      with a report, never a silent freeze.
    - `SpeakerOutput` wires every sound to the mixer's next free bus. Plain
      `connect(_:to:format:)` takes bus 0 and knocks off whatever was there, the music
      included.
    - It wires the environment when a 3D sound needs it: starting the engine drops the
      environment's connection while nothing feeds it.
    - It starts the engine again on `AVAudioEngineConfigurationChange`.
    - It only calls `play()` on a player whose way to the output is there.
    `EngineSelfTest` runs the real engine offline (`SpeakerOutput(offline: true)`):
    nightfall's sounds, 200 starts and stops, a device change, and Nightfall played
    through it.
    A game also holds a `ProcessInfo` activity from `PlayController.start` to `stop`,
    so App Nap doesn't slow a hidden window's timers, and a host's world doesn't stop
    for its players.
    `swift run StudioApp --soak <game> <seconds> [render|audio|window]` is the tool
    for checking a long game.

113. **The scene finds things through `SceneIndex`, and its arrays change in place.**
    - `parts`, `groups`, `dataObjects` and `sounds` are computed properties over private
      stores. Their `_modify` accessor changes an element without copying the array
      (a `@Published` array was copied whole by every change: 230 µs a change at 8000
      parts).
    - Every change counts in `index.changes` / `otherChanges`.
    - A slot is trusted only if the thing there has the id asked for. The children map,
      and a miss meaning "not there", are trusted only while a fingerprint of ids,
      parents and storage is unchanged, and that is taken only after a change. So no
      change, whichever way it's made, can leave it wrong. `SceneIndexSelfTest` checks
      3000 random changes against a plain search, and that costs stay flat as scenes
      grow.
    - `update(id:)` doesn't count a change that leaves the tree as it was (a move), so
      moving Models never makes the index look again.
    - **Swift's exclusivity rule now applies.** Nothing may read the scene while one of
      its elements is being changed in place, or the app aborts ("Simultaneous
      accesses"). So `update(id:)`, `updateGroup`, `updateSound` and
      `updateDataObject` change a copy of the one element and put it back, since their
      closures read the scene (unique names, say). Never write
      `model.parts[i].x += f(model)`: compute first, then assign.
    - Use `part(id:)`, `index(of:)`, `group(id:)`, `groupIndex(of:)`,
      `dataObject(id:)` and `sound(id:)`, never `first(where: { $0.id == … })`.
    - `swift run StudioApp --bench` prints the costs.

115. **Frame times come from the play session, and scripts read them through Stats.**
    `PlayController.step` times its scripts and physics, and `Renderer.encodeFrame` its
    drawing, into `frameStats` (FrameStats.swift: smoothed averages, and the process's
    footprint). `ScriptRuntime.statsSource` hands them to the Luau `Stats` service
    (`stats.get`). The HUD's three lines are version 3 of `DefaultHud`
    (`makeFrameStats`, the **FrameStats** LocalScript in the Stats frame). Upgrading a
    version-2 place adds them only if its Stats frame is still there and has none.

116. **NPCs are walked by the host's engine, and a Humanoid's numbers are data.**
    A Humanoid is a `DataObject` (`.humanoid`) inside a Model, its Health, MaxHealth,
    WalkSpeed, JumpPower and AutoRotate in `numbers`, and `value` a list of them. So
    saving, cloning, sending to joined players and `DataChanged` (which Luau turns into
    HealthChanged and Died, `dataKit.humanoid.changed`) all come free. `NPCSystem`
    (PlayController's `npcs`, stepped only when `!worldFromHost`) gives each living one a
    `CharacterController` and moves the Model's parts from its rest poses round an
    upright root. Joined players only ever see parts move. Keep to these rules:
    - Steering host calls (`npc.moveTo/move/jump`) are refused off the host.
    - MoveToFinished comes back as an engine event (`["NPC", id, "MoveToFinished",
      reached]`), not a data change.
    - A script moving the root (PivotTo) is noticed by comparing with `placed`. Keep
      that when changing `place`.
    - A body skips putting its parts while nothing moved (`lastPut`), since each change
      is sent to every joined player.

127. **The navigation grid swims, climbs and leaps; the characters it's for do too.**
    - **Water** isn't solid, so it's no span: `update` keeps the water parts, and
      `terrainWater` is the Terrain's. `standing` looks for water just above each floor:
      shallower than half the agent, the floor is waded (material "Water"); deeper, the
      surface is the floor (swum, in `swum`). A swum node stepping onto land is a jump —
      a swimmer's feet are well below a bank level with the water, and
      `CharacterController.stepSwimming` makes a jump at the surface a leap out.
    - **Trusses** are spans marked `truss`. With `canClimb`, `climbs` links a floor
      within the agent's reach of one to its top, or to a floor beside its top; those
      nodes are corners, their waypoints labelled "Climb" (Walk: the character climbs by
      walking into the truss), and `firstBlocked` doesn't check them.
    - **Gaps**: `leapAcross`, up to `reach` cells, only when the first cell on the way has
      nothing to stand on near this height, landing no higher than a step, with the arc
      clear. Marked like any jump, on the waypoint landed on.
    - **Room round the body** is measured to a part's box, but to the cell of a mesh's
      span (a Terrain chunk's box can hold a whole lake).
    - **An NPC's Jump** stays asked for until it jumps (`NPCSystem`), as Roblox's
      Humanoid.Jump does and the player's already did; a leap out of water counts.

126. **The Toolbox's models are code, inserted as saved models are.** Each
    `ToolboxModel` builds a `ModelFile` standing on y = 0 around its pivot (the Rig is
    `addRig`, having a Humanoid), and `ViewportController.insert` puts it on whatever a
    ray straight down meets in front of the camera. So:
    - A model's script finds its own parts by name (they keep them inside the Model),
      and anything it needs to know that scripts can't read (the boat's mass) is written
      into its source when it's built.
    - The cards' pictures (`ToolboxPictures`) are drawn the first time the tab shows, one
      model a run-loop turn, by one `AvatarSnapshot.ToolboxPicture`: a renderer whose
      source is swapped, so shaders compile once. `--render-toolbox <model>` draws one.
    - Run mode's scripts read the physics (`ScriptRuntime.physicsSource`): velocities,
      joints' angles. Before, they read zeros there, as with no play session at all.
    - Water slows spinning too (`waterDrag.spin`), so a boat's Torque turns it at a rate
      rather than ever faster; the boat's script steers towards TurnSpeed.

125. **A VehicleSeat's Throttle and Steer are the script runtime's, not the part's.**
    `SeatSettings.vehicle` holds what's saved (MaxSpeed, Torque, TurnSpeed,
    HeadsUpDisplay). The controls live in `ScriptRuntime.vehicleControls` (so Run mode
    has them), read and written through `part.get/set` ("throttle", "throttlefloat"…).
    - The ControlScript (a core LocalScript) writes them while its humanoid sits in a
      VehicleSeat, instead of walking, and shows the speedometer (a ScreenGui it makes).
      A place with its own ControlScript does neither.
    - A joined driver's go to the host in `PlayerState.throttle/steer`;
      `PlayController.updateVehicleControls` copies them each frame and clears a seat
      its driver left (`drivenSeats`). A script's own setting of an empty seat stays.
    - A seated character has no capsule in the physics (`simulateParts`,
      `moveRemoteCapsules`): it would shove the car it sits in.
    - Toolbox models (`ToolboxModel.file`) go in through `SceneModel.insert(_:at:)`, as
      saved models do. Parts inside a Model keep their names there (its scripts find
      them by name); only loose parts are renamed to be unique.
    - The car's steering works through heavy (metal) knuckles, and its wheels don't
      collide with its body (NoCollisionConstraints): a light knuckle made the solver's
      steering soft, and a steered wheel met the body.

124. **Parts float by Jolt's buoyancy, against the water found once a frame.**
    `PhysicsWorld.findWater` looks for water under each awake moving body (not water
    parts themselves) at its middle and at its lowest reach (`Assembly.reach`): water
    parts (collected at `sync`) and the Terrain's (`terrainWater`, set by PlayController
    whether or not there's a player). Every substep, `studio_jolt_float` applies Jolt's
    `ApplyBuoyancyImpulse` against a flat surface at that height, then takes a share of
    the speed a second (`waterDrag.settle` up and down, `slow` sideways) as much as the
    body is under. So:
    - Buoyancy is water's density (1) over the body's: Σ volume ÷ Σ mass
      (`Assembly.volume`, `mass`), so welded parts float on their weight together.
    - Only convex and compound shapes have a submerged volume in Jolt; moving bodies
      never have mesh shapes (a moving Precise part is its hull), so keep it so.
    - A floating body stays awake (the buoyancy wakes it), so it stays in the list.

123. **Motor6D is a driven Jolt joint; AlignOrientation and Torque are twists.**
    - **Motor6D** (`part0`/`part1`, `c0`/`c1`/`transform`, all `Pose`s saved as twelve
      numbers) becomes a Jolt six-degrees-of-freedom constraint (`STUDIO_JOLT_MOTOR`),
      every axis free with a stiff position motor (25 Hz, critically damped; Jolt's
      position motors need a stiffness, so it isn't perfectly rigid).
      `PhysicsWorld.syncMotors` builds it from each end's frame where it is now: Part0 ·
      C0 on body A, Part1 · C1 on body B. Once a frame, `driveMotors` steps CurrentAngle
      towards DesiredAngle (MaxVelocity × dt × 60) and holds B's frame at Transform ·
      (CurrentAngle about Z) in A's (`studio_jolt_drive_motor`).
    - CurrentAngle is the physics' (`jointValue`, read through `physics.joint`); the
      model's `currentAngle` is only where it starts. A script setting it bumps
      `angleWrites`, and the physics takes each write up, even the same number twice.
    - Both parts anchored, or in one welded assembly, and there's nothing to move: no
      joint. The two ends stay separate bodies (Roblox makes them one assembly).
    - **AlignOrientation and Torque** are `isForce`: `applyForces` gives them angular
      impulses. An AlignOrientation wants a spin (Responsiveness × the angle to its goal,
      capped by MaxAngularVelocity) and gets it through `studio_jolt_inertia_times`,
      capped by MaxTorque × the step. It makes good what friction took since the last
      step (`aimedSpin`), no more than the spin wanted, so a part on the ground reaches
      its goal and a blocked one can't wind up.

122. **Watches and conditions run Luau on the stopped thread, in a scope built for them.**
    `studio_lua_debug_evaluate` (the shim) compiles `return <expression>` and loads it
    with an environment table holding the frame's upvalues, then its locals (so a local
    wins), whose metatable reads the rest from the function's own environment. It runs
    on the paused thread under `lua_pcall`, with 0.2 s on the watchdog's clock, as
    `describe` gets. So:
    - Breakpoints reached while it runs are passed over (the hook returns while
      `paused` is set). A condition may call the script's functions.
    - It can have side effects: `count += 1` isn't an expression, but a call is. That's
      the person's choice, as in Roblox.
    - A frame's `level` (in `ScriptDebugger.Frame`) is the VM's, not its place in the
      list: library frames are left out of the list but still count.
    - Conditions and log messages are `ScriptObject.breakpointConditions` and
      `breakpointLogs`, by the line the person set (saved as `"conditions"` and
      `"logs"`, keys as text). `ScriptDebugger.land` gives each landed line a `Rule` per
      breakpoint there. At the line, every rule counts a hit (`hits`, by the line it was
      set on); a condition that doesn't hold skips its rule, one that fails stops with
      `Pause.note`; a logpoint prints (`studio_lua_debug_log`: an expression list,
      written as print writes it) and goes on; any other rule stops.
    - Conditions and messages move with their breakpoints: the editor hands
      `movingLines` (old line to new) to `SceneModel.moveBreakpoints`.
      `setBreakpoints` drops those of lines that went. None of it is an edit, and undo
      (`keepingText`) and Stop leave breakpoints, their settings and watches as they are.
    - Tables open by expression: a variable's `path` is its name, and a field's is
      `.key`, `["key"]` or `[1]` after its table's. A watch's own is `(expression)`.
      `studio_lua_debug_fields` lists up to 200 entries; `ScriptDebugger.ordered` puts
      numbered ones first, then names. Only plain tables open (`typeof` is `"table"`).
    - Watches are the place's (`SceneState.watches`, left out of `sharedState`),
      changed with `setWatches` outside `commit`. Each play's debugger gets them and
      works them out into `Pause.watches` at every stop, and again when another call is
      picked.
    - Studio shows hits live: the debugger's `onHit` makes `EditorSession` copy `hits`
      into `breakpointHits`, at most five times a second.

121. **Terrain is voxels, meshed per chunk, and collides as MeshParts nobody else sees.**
    `SceneState.terrain` (TerrainData) holds 16³-voxel chunks. Each chunk's `stamp`
    changes with any edit, and its `edgeStamp` only when a voxel on its outside layer
    changes. That keeps equality, undo and replication cheap, and limits remeshing.
    `SceneModel.terrainGeometry` meshes changed chunks: its signature is the chunk's own
    stamp plus its neighbours' edge stamps. It also makes each chunk a Precise MeshPart
    (triangles in `MeshLibrary.register(_:as:)`).
    - Those parts go wherever parts are collided with: the character, NPCs, every
      `physics.sync`, navigation, raycasts, spawning (`model.terrainParts`). They never
      enter `model.parts`, so scripts, saving, the Explorer and touches don't see them.
      A new place that collides with parts must add them.
    - With terrain there's no invisible floor at 0 (`character.solidBaseplate`).
    - Water voxels aren't solid. Their surface sits at the top water voxel's bottom plus
      its occupancy (`waterSurface`). Swimming (`CharacterController.terrainWater`) and
      raycasts read it.
    - Joined players get `TerrainPatch`es: changed chunks whole, removed ones, settings.
    - `TriangleSet.raycast` handles rays parallel to an axis. A vertical ray at a whole
      stud once hit NaN in the box test and missed.

120. **AlignPosition and VectorForce are pushes; NoCollisionConstraint is a pair filter.**
    They're `SceneConstraint` kinds, like the joints, but only `kind.isJoint` ones become
    Jolt joints. The rest are handled like this:
    - **Forces** (`isForce`): `PhysicsWorld.syncForces` finds their bodies each sync,
      and `applyForces` pushes before every physics substep. An AlignPosition's impulse
      makes good gravity's pull and is capped by MaxForce × the step, so too little
      MaxForce can't lift.
    - **NoCollisionConstraint**: a counted pair in the shim's `JointFilter`
      (`studio_jolt_ignore_pair`). A body going away takes its pairs with it
      (`remove`).
    - **Saving:** a kind saves only its own fields, so joints save as before, and
      MaxVelocity's infinity is written as −1.

119. **The sky is drawn from Lighting, and its extras are Lighting's.** Sky, Atmosphere and
    Clouds are optional structs on `LightingSettings` (`skyObject`, `atmosphere`,
    `clouds`), so they're saved, undone and sent to joined players with Lighting. The
    rendering is in the shaders:
    - `studio_sky_over` puts the halo, stars, sun, moon, clouds and haze over the sky
      that follows the day, or over a skybox in the sky pass (a cube at fragment
      texture 6).
    - `studio_finish` fades lit surfaces into the Atmosphere.
    - The uniforms are 384 bytes, checked by LightingSelfTest.

    Keep to these rules:
    - Fragment texture slots are shared across passes: 0 is the shadow map, 3 a mesh's
      picture, 6 the skybox. Particles and ribbons use 2.
    - Scripts name the one in Lighting "L:<class>" and a loose one "-:<id>"
      (`ScriptRuntime.looseSkyObjects`).

118. **Beams and Trails are constraints that are only drawn.** They're `SceneConstraint`
    kinds (`.beam`, `.trail`; `kind.isEffect`), so saving, the Explorer, `constraint.*`,
    replication and the Luau constraint kit come with them. Their looks are
    `SceneConstraint.ribbon` (nil for joints, so a joint saves as before) and go through
    `ribbon.*`. Keep to these rules:
    - Physics and the join tools skip `isEffect` kinds. A new constraint kind has to
      say which it is.
    - A Trail's history (`TrailSystem`) is each Renderer's own, like particles. Clear
      is a counter (`look.cleared`).

117. **Particles are each machine's; only the emitters are scene data.** A ParticleEmitter
    lives in its part (`Part.emitters`), so it's saved, undone, copied and sent to joined
    players with the part. Each Renderer keeps its own `ParticleSystem`, stepped in
    `encodeFrame` with the frame's time and drawn after the avatars, in Studio as in a
    game. Nothing about particles ever goes over the network. Keep to these rules:
    - Emit and Clear are counters on the emitter (`emitted`/`lastBurst`, `cleared`).
      A system acts on the difference since it last looked. The first time it sees an
      emitter it makes only `lastBurst`, not the history.
    - Scripts name an emitter "<part>:<emitter>" (tree token "e:…"), since copying a
      part copies emitter ids; one in no part is "-:<emitter>", held in
      `ScriptRuntime.looseEmitters`. Moving it hands the Luau object its new name.
    - Scene data that older builds can't read means bumping `LAN.protocolVersion`. It
      went to 14 for Humanoids and emitters.

114. **`SoakSelfTest` plays every sample game for a while, and fails on growth.** It uses
    `Soak.play` — the same player as `--soak`, with a seeded generator so every run
    makes the same moves — and compares the settled sample with the last (thresholds in
    `SoakSelfTest.growth`). A new sample game gets a line in its `run`. If a game
    legitimately grows (a place that builds as you play), raise its thresholds there
    rather than lengthening the soak: it already adds about 90 seconds to the suite.

## 8. Recipes

### Add a GUI class or property
1. The host side: a `case` in `GuiObject.Kind` (and its defaults in `GuiObject.init`), or
   a field on `GuiObject`; read/write it in `guiProperty`/`setGuiProperty`
   (PlayController+Gui.swift) under its lower-cased name; draw it in `GuiLayer`, or
   account for it in `GuiStore.layout` if it changes where things go.
2. The Luau side: `gui.classes` (and `gui.isGuiObject`/`gui.isText` if it is one), and
   an entry in `gui.properties` with its type — UDim2, UDim, Vector2, Color3,
   ColorSequence, NumberSequence, an enum, or a plain Lua type (`byClass` when one name
   has a different type in another class, as UIGradient's Color does); events go in
   `gui.events`. A new enum goes in `Enum` (02-Values) and `gui.enumKinds`.
3. Studio: a new class needs `symbolName`/`shortName` (UI/GuiKinds.swift) and, if it can
   be inserted, a place in `insertableObjects`/`insertableModifiers`; its properties go in
   `GuiTemplateInspector.fields`. Setting a value `setGuiProperty` refuses raises in Luau
   ("out of range").
4. Completion: `LuauAPI.instanceMembers`. Tests: `GuiSelfTest`/`GuiEditorSelfTest`
   (layout, drawing, the Luau API, and a joined player's copy).

### Add a scripting API call (Luau first)
1. The host side, if it touches the scene: a `case "your.call":` in the handler for its
   namespace (`part.*` → `partsCall` in `ScriptRuntime+Parts.swift`; a new namespace
   needs a line in `ScriptRuntime.invoke` and its own file). Player calls go in
   `PlayerHost.swift`. Values are `ScriptValue` (nothing/bool/number/string/list);
   vectors and colours cross as 3-element lists. `testEveryHostCallIsAnswered` fails
   if the library calls a name no handler has.
2. The Luau side in the `LuauLibrary/` part it belongs to, in Roblox's style: PascalCase properties
   through the relevant `__index`/`__newindex`, `:Method()` functions that call
   `checkSelf` (and `checkOther` when they take a value), errors through `raise(…, 2)`
   so they point at the user's line, with Roblox's wording where Roblox has one.
3. Mirror it in `LuauAPI` with the right `returns` — or chained completion dead-ends.
4. Tests in `ScriptSelfTest` (behaviour, and the error message *and* line) and
   `SyntaxSelfTest` (completion).
5. **Wren:** only on a Wren release (§1). Then: Wren wrapper in `WrenModules.swift`,
   `WrenAPI`, `WrenScriptSelfTest`.

### Change what a new script starts with
`ScriptTemplates.source(_:in:)` picks one per language and `Place`; `SceneModel.addScript`
asks `templatePlace(parentID:host:)` where the script is going. Keep each template
runnable as it is, printing one line. Suggestions go in as commented-out code, and the
comments keep to one convention that `ScriptTemplateSelfTest` depends on — it uncomments
the code and runs it: **prose comment lines end in `.`, `:` or `,`, or contain `. `;
commented code never does.** Break that and the test uncomments prose (or skips code).
Add the new output to `testTheyRun`, and what uncommenting should do to
`testTheSuggestionsWork`.

### Add a Humanoid property (or any player feature)
1. Field on `Humanoid` (and on `StarterPlayerSettings` if it should be a saved default,
   with a `decodeIfPresent` default so old files open).
2. Read/write cases in `PlayerHost.humanoidProperty` / `setHumanoidProperty`; make it do
   something in `PlayController.simulate` via `CharacterIntent` if it affects motion.
3. An entry in `humanoidProperties` in the Luau library (`host`, `kind`, `readOnly`).
4. `LuauAPI.instanceMembers["Humanoid"]`; a row in `StarterPlayerInspector` if saved.
5. A test in `PlayerSelfTest` that drives a `PlayController` and checks the body.
A new event: a `HumanoidEvent` case, `PlayController.scriptArguments`, and a signal
name in `humanoidSignalNames` — `dispatch` picks it up.
A new service or input kind: a namespace in `PlayerHost.namespaces` (routed there
automatically by `ScriptRuntime.invoke`), plus its Luau wrapper.

### Add or change an animation
1. A case (or a change) in `AvatarAnimator.target(state:speed:verticalVelocity:)`.
   Angles are radians about the character's own axes: +X swings a limb forward, +Z
   towards +X (so a left limb goes *out* with −Z); `pitch` < 0 tips the body forward.
2. A check in `AvatarSelfTest` on the joints or on `partTransforms()` positions.
3. `swift run StudioApp --render-avatar /tmp/avatar.png` and look at it.
A new Humanoid state gets its animation the same way; the crossfade is automatic.

### Add a joint type
1. A `SceneConstraint.Kind` case with its properties and defaults.
2. Its Jolt settings in `studio_jolt_add_joint` (a `StudioJoltJoint` value), and the
   values it reads from `values[]`.
3. `PhysicsWorld.syncJoints`: the kind, its values, whether it stops collisions, and
   any motor.
4. Luau: an entry in `constraintMembers` naming its properties (and `constraintNumbers`
   for new numeric ones); `LuauAPI`.
5. The Properties panel (`ConstraintInspector`) and the Edit menu. The Physics tab's
   join tools list `Kind.allCases`, so a new kind gets a tool button for free.
6. A test in `JointsSelfTest` checking it does the physical thing it should.

### Add a physics property or method for scripts
1. The Jolt call in the C shim (`include/studio_jolt.h`, `shim/studio_jolt.cpp`) if
   there isn't one, and a wrapper on `PhysicsWorld`.
2. A `physics.*` case in `PlayerHost` (and a harmless answer in `withoutPlayer`, for
   the editor).
3. The Luau side on parts: a `partProperties` entry with `motion = …` for a vector read
   through `physics.get`, or a method in `partMethods`; `LuauAPI`.
4. A check in `PhysicsSelfTest.testScripting`.

### Update Jolt
Replace `Sources/CJolt/Jolt/` with the new release's `Jolt/`, keep the `exclude` list in
`Package.swift` in step (new GPU backends, non-source files), rebuild, run the suite.

### Add a lighting setting
1. A field on `LightingSettings` with a `decodeIfPresent` default.
2. If shaders need it: a slot in `LightingUniforms` on **both** sides (Swift and
   `lightingMetalSource`) — reuse a spare `.w` before adding a `float4`, and update
   the 272-byte check — set in `LightingUniforms.init(settings:…)`.
3. A row in `LightingInspector`; `lighting.get`/`lighting.set` cases in
   `ScriptRuntime` and a member in the Luau `Lighting` service; `LuauAPI`.
4. A check in `LightingSelfTest` — a rendered-pixel check if it changes the picture.

### Add something to the Animation Editor
Editing state and logic go in `AnimationEditor` (headless, tested in
`AnimationSelfTest.testEditor`); drawing goes in `AnimationEditorView`. Edits to the
animation itself are methods on `AnimationObject` called through `editAnimation`.
Look at it with `swift run StudioApp --render-panel animation /tmp/a.png`.

### Add something to AnimationTrack (Luau)
Host side in `PlayerHost` (`track.get` / `track.set` / a new `track.*` case) over
`AnimationPlayer`; Luau side in `makeTrack` (`trackProperties` or `methods`); mirror in
`LuauAPI.instanceMembers["AnimationTrack"]`; a check in `AnimationSelfTest.testScripting`.

### Add a `Part` property
1. Field plus `Codable` and `Equatable` in `Part` — both hand-written.
2. `read`/`write` cases in `ScriptRuntime`, and an entry in `partProperties` in the
   Luau library (with a `write` that type-checks and explains).
3. `LuauAPI.instanceMembers["Part"]`, and an editor in `PropertiesView`.
4. Round-trip check in `DocumentSelfTest`; scripting check in `ScriptSelfTest`.

### Add a part shape
1. `PartShape` case in `Model/Part.swift` (+ `displayName`, `symbolName`).
2. Unit-sized generator in `MeshFactory` (`Render/Mesh.swift`).
3. Register it in `Renderer.buildMeshes()`.
4. Exact ray test in `Picking.intersect` — handle an origin inside the bounding box.
5. Closest-point, `contains` and `surfaceNormalInFrame` cases in `Play/Collision.swift`.
6. Default size in `SceneModel.addPart`.
7. Tests: add it to `testMeshNormals`'s list, plus picking and collision checks.

Miss step 5 and the shape is solid on screen but the player walks through it.

### Add a shader input
1. Add it to `ShaderSource.inputs`, or `screenInputs` for full-screen effects.
2. Pass it into the generated shade function in `wrap` / `wrapScreen`, sourced from
   `FrameUniforms`, `DrawUniforms` or `ScreenUniforms` — a new uniform field means
   updating the Metal struct, the Swift struct and the layout test together
   (invariant 7).
3. The "is in scope" tests iterate the `inputs` list, so they pick it up automatically.

### Add a gizmo mode
`GizmoMode` case → hit test in `Gizmo.hitTest` → drag maths in `Gizmo.updateDrag` →
drawing in `Renderer.drawGizmo`. Gizmo hit tests are analytic (segment distance,
ray-plane, ring radius), not mesh-based. Add a drag test modelled on
`testTranslateDrag`, which aims a ray at a handle and asserts the resulting transform.

## 9. Known limitations — do not assume these work

- **Physics:** the character is a kinematic capsule: parts hitting it shove it (a fading
  push, by mass) and platforms carry it, but it has no real mass in Jolt; water (parts
  or Terrain) floats parts as flat, still water (no waves or currents; one surface per
  body, looked for at its middle and its lowest reach once a frame); a TrussPart draws as a plain box; a
  servo is a speed-limited controller rather than Jolt's position motor; a Motor6D is a
  very stiff spring rather than rigid, its two parts stay two bodies, and characters'
  limbs aren't Motor6Ds (scripts can't reach them); AlignOrientation has no
  AlignType, LookAtPosition or separate PrimaryAxis/SecondaryAxis (its CFrame says it
  all); no LinearVelocity, AngularVelocity or the legacy BodyMovers; a car's wheels are
  cylinders with plain friction (no tyre model, no suspension: it's rigid).
- **Multiplayer is LAN-only, host-run:** the host runs the scene's scripts and physics;
  joiners apply its `SceneDelta`s. Host scripts see joined players (invariant 77); only
  the host forwards writes (a joiner's LocalScripts can't change other players). Host
  scripts' tracks on other players raise Stopped by the host's clock, but not DidLoop or
  markers, and GetPlayingAnimationTracks lists only the ones the host plays. Joiners push crates
  only as the host's kinematic capsule does (no weighted `push`). The active screen
  effect isn't sent.
- **The mouse:** no `Mouse.Move`, `TargetFilter`, `UnitRay` or cursor icons; ClickDetectors
  only in parts (not Models), and no `RightMouseClick`; a right-click turns the camera.
- **Tools:** their scripts all run on the host (there are no LocalScripts in tools);
  held tools aren't in the physics, so they don't push crates or report part-to-part
  Touched (bodies still touch them); `Backpack.ChildAdded/ChildRemoved` aren't there and
  its `WaitForChild` doesn't wait; Luau only.
- **Sounds and pictures:** only files imported into the scene (`studio://Name`), not
  Roblox asset ids; no SoundGroups, sound effects (reverb, EQ…), RollOffMinDistance or
  roll-off modes (it fades linearly to nothing at RollOffMaxDistance); a Sound goes in a
  part or SoundService (the Workspace and nil count as SoundService), not in a Model,
  a character or a GUI; files are decoded whole, not streamed; a Sound's TimePosition
  on a joiner is only the host's last word; ImageRectOffset/Size, SliceCenter and
  TileSize aren't there. Luau only.
- **MeshParts:** only the formats Model I/O reads (OBJ, STL, PLY, USD/USDA/USDC/USDZ —
  no FBX or glTF); one texture per part, no normal/roughness maps, no SurfaceAppearance;
  a model's own materials and colours are ignored; Precise collision only while anchored
  (a moving Precise part is its hull, not a convex decomposition); Hull is capped at 128
  corners; models over 500,000 triangles are refused; MeshId must name an imported
  model (`studio://Name`), not a Roblox asset id; no `SpecialMesh`, no
  `RenderFidelity`; Wren has no MeshPart API.
- **What characters wear:** R6 only (no layered clothing, no 3D clothing, no packages or
  body scaling); accessories have no Handle part — `Offset`, `Rotation` and `Scale`
  stand in for its attachment — and don't collide or touch; one texture per imported
  accessory; T-shirt graphics (ShirtGraphic) and Decals other than the face aren't
  there; a player's own look is built-in things only (they can't bring their own
  files); HumanoidDescription covers the look and body colours, not scale or
  animations. Luau only.
- **Scripts working together:** `require` takes a ModuleScript in the place, not an
  asset id; no BrickColorValue, RayValue or the constrained Values; an ObjectValue can't
  hold a character or a GUI object; UnreliableRemoteEvent never drops anything; only
  ReplicatedStorage, ServerStorage, Players and data Folders have a `WaitForChild` that
  waits; a clone of something in the Workspace doesn't start its scripts (one from
  storage does); `workspace:Raycast` ignores CollisionGroup and meets characters as
  boxes; data objects made at run time in parts aren't shown in Studio's Explorer.
  Luau only.
- **Run mode is Studio-only:** it has no player and no network side, so it has no
  multiplayer test; a scene script that needs `Players.LocalPlayer` gets nil there, as
  on a Roblox server.
- **Wren has no watchdog.** An endless loop in a Wren script hangs the app; Luau's is
  stopped after `ScriptRuntime.timeout` (2s) of its own time. Host calls don't count:
  the shim's `invokeTrampoline` moves the deadline on by each call's length, so the
  engine's work for a script (a big map's path grid) can't get it stopped. Wren offers
  no interrupt hook to build one from.
- **Luau type annotations are parsed, not checked** — `Analysis` (the type checker) is
  not vendored.
- **Scripts in different languages cannot call each other**; they share the scene only.
- **Screen GUI:** no ViewportFrame, SurfaceGui, UIScale, UIPageLayout, UITableLayout or
  RichText; fonts are the nearest system font; text outlines (TextStroke and a Contextual
  UIStroke) are drawn with offsets; LineJoinMode only changes square corners; a
  UIGradient on a picture multiplies it but a rotated gradient runs corner to corner of a
  square, not the object's shape; ScaleWithParentSize keeps DominantAxis from the Size
  rather than the whole parent; BillboardGuis are always on top (AlwaysOnTop is kept but
  not used); a TextBox selects all or nothing (no drag selection); only StarterGui copies
  reset on spawn (GUIs scripts make keep going); no top-bar inset or MouseEnter/Leave.
  In Studio one GUI object is selected at a time (no multi-select, no dragging in the
  Explorer to reparent), text is edited in Properties, not in the view. Luau only.
- **Chat:** no filter, no commands (/whisper, /team…); bubbles are a fixed width.
- **The Toolbox** has the eight built-in models only: no online library, no search, and
  your own saved models go in with File › Insert Model…, not from the Toolbox.
- **Roblox divergences:** `Instance.new` makes parts, MeshParts, Models, Folders, Values, remotes, Accessories, Shirts, Pants, PointLights,
  Animations, Sounds and the GUI classes, and new or cloned parts go straight into the workspace; setting
  `Parent = nil` destroys; no `Unions`;
  `Vector3.zero.Unit` is zero, not NaN.
- **Scripts run only during play**, one fresh VM per language per session.
- **The player:** one local player; the character's parts are not in `workspace`; no
  `HumanoidDescription` beyond what it wears and its body colours; the body parts cannot be resized; states are
  Running/Jumping/Freefall/Landed/Flying/Dead/Seated/Climbing/Swimming (no Ragdoll,
  PlatformStanding, Physics); seats are parts (a VehicleSeat drives only through a
  script, and only the ControlScript's keys and scripts set it); climbing is on
  TrussParts only, not on ladders built of parts. StarterPlayer scripts are Luau-only.
- **Touches:** limbs are upright capsules, a part's touches come from Jolt's contacts
  (so two anchored parts never touch each other), and Wren has no `Touched` yet
  (Luau-first).
- **Lighting:** no global illumination and no denoiser, so ray-traced shadows and
  occlusion are slightly grainy (Quality trades rays for grain); 16 point lights per
  frame (nearest the camera); conventional shadows cover ~260 studs around the camera
  target; point-light shadows are ray-traced only; parts more than half transparent
  cast no shadow; no spot/surface lights; Sky, Atmosphere and Clouds are drawn but
  don't light the world (no sky-coloured ambient from the skybox); Wren has no
  Lighting API yet.
- **Animations are R6 rotations with a root offset.** No IK, no per-limb translation,
  no animation events besides markers, no `Animate` script replacing the built-in
  walk/jump (a higher-priority looped track can override them), and no Wren API.
- **Split view is two panes only:** the world and the one tab in front, side by side
  (⌘\); there is no tiling of several tabs.
- **Script and shader text edits are not in the scene undo stack** — the text view owns
  its own undo. Deliberate.
- **`Part.locked` excludes a part from picking but not from collision.**
- **DataStores** have no request budgets or throttling (every call succeeds at once and
  `GetRequestBudgetForRequestType` says 100), no versions or `DataStoreKeyInfo`, no
  `ListKeysAsync`/`ListDataStoresAsync`, no MemoryStoreService, and no size limit per
  key. They are kept on the host's disk, so a player's progress follows whoever hosts.
- **Nightfall's zombies** steer by walls read once at the start: a wall added later is
  pathed round only if the straight line is already blocked by an old one, and walked
  through otherwise. They don't climb. With every way blocked they stand still.
- **The debugger** is Luau's only (no Wren). No breakpoints in the library's own code;
  a logpoint always goes on (it can't print and stop), and its hit count isn't a
  condition ("stop on the 5th hit" is `count == 5` with a counter of your own). A table
  opens to its first 200 entries; an Instance doesn't open (its properties aren't
  listed). Watches, conditions and log messages run for up to 0.2 s each, and can change
  things if they call functions that do. Watches and breakpoints are saved with the
  place only when something else makes it save. While stopped, a network host sends nothing, so its players see
  the world stand still. A line with only `end` on it can't be stopped at.
- **Pathfinding** sees the world as 2-stud squares, so a gap must be a little wider than
  the agent. Trusses are climbed up, not down (a path drops down instead, 30 studs at
  most); a jump across a gap is 3 cells at most, landing no higher than a step; water
  is flat (one surface per cell) and swum across, not dived under; no
  PathfindingModifier or PathfindingLink. A search stays within 96 studs of the
  line between its ends. `Blocked` is checked twice a second, and only while someone
  listens.
- **Screen effects** all read the world's depth (not an earlier effect's), run in
  Explorer order rather than an order of their own, and a shader that hangs the GPU
  takes the app with it; sixteen float parameters per shader. What a LocalScript
  switches on or off lasts only for that play session (as in Roblox).

## 10. Conventions

- Comments explain *why*, not what. The codebase has few and they earn their place —
  match that density rather than annotating every line.
- Types and members read as prose: `worldAxis(_:)`, `closestPointInFrame`, `mayTouch`.
- US spelling in code (`color`, matching Apple's APIs). Test *descriptions* are prose
  and sometimes use British spelling; they are strings, so it does not matter.
- No XCTest. No third-party Swift dependencies. `CLuau/luau` and `CWren` are the only
  vendored code and are unmodified — update them by dropping in a newer release, never
  by patching in place. Our own C++ lives only in `CLuau/shim` and `CLuau/include`.
- Luau library code: tabs, PascalCase for Roblox-facing names, `raise` for errors.
- Swift 5 language mode (set in `Package.swift`), macOS 13+.
- `simd` throughout; `Vec3`/`Vec4` are typealiases in `MathUtil.swift`.

## 11. Verifying a change end-to-end

The self-tests cover logic, not presentation. For anything touching rendering, input or
layout, confirm the app runs **and draws**:

```bash
./make_app.sh release && open Studio.app
PID=$(pgrep -f "Studio.app/Contents/MacOS/Studio" | head -1)
A=$(ps -o cputime= -p $PID); sleep 4; B=$(ps -o cputime= -p $PID)
echo "$A -> $B"                               # must climb: ~0.5s per 3s of rendering
log show --last 20s --predicate 'process == "Studio"' | grep -i error
```

For the avatar, render it without a window and look:

```bash
swift run StudioApp --render-avatar /tmp/avatar.png   # idle, walk, jump, fall, fly, dead, wave
swift run StudioApp --render-panel animation /tmp/panel.png   # a Studio panel, no window
swift run StudioApp --render-panel ribbon /tmp/ribbon.png      # every ribbon tab, weld tool armed
swift run StudioApp --render-window script /tmp/window.png     # the whole window, a script tab in front
swift run StudioApp --render-scene /tmp/s.png raytraced 17.5  # the starter scene, lit
swift run StudioApp --render-physics /tmp/p.png 0.9           # crates hit by a ball
swift run StudioApp --render-car /tmp/car.png 1.6             # welds and motorised hinges
swift run StudioApp --render-adventure /tmp/lab.png lab ray    # the sample game, one area
swift run StudioApp --render-client talk /tmp/talk.png         # the client talking to an NPC
swift run StudioApp --render-home /tmp/home.png                # the home page, with two recents
swift run StudioApp --render-nightfall /tmp/nf.png night      # Nightfall, one view (the camp after dark)
swift run StudioApp --render-obby /tmp/obby.png world5        # Mega Obby, one world's first stages
swift run StudioApp --render-shiftlock /tmp/sl.png [off]       # a play session's own camera, shift lock on
```

**`ps -o %cpu` is not evidence of anything.** It reports CPU time over the process's
whole lifetime, so a freshly launched app that drew nothing still reads 7–10% purely
from startup cost. Measure the *delta* in `cputime`, as above. A window existing is not
evidence either — a live window in front of a dead render loop looks exactly like a
healthy app.

If this machine has no display attached (`CGGetActiveDisplayList` returns 0), that is
expected and the timer fallback covers it — see invariant 8.

A Metal pipeline or shader failure shows up as a black viewport and an `NSLog` line,
not a crash, so check the log rather than assuming a running process means success.
