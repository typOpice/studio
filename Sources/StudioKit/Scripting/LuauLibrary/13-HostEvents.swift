// The Luau library, part 13 of 16: the host's events, delivered at the start of each frame.
//
// The parts run in order as one chunk (see `LuauLibrary.inOrder` in StudioLibrary.swift),
// so the locals of earlier parts are in scope here and later parts may use this one's.

extension LuauLibrary {
    static let hostEvents = #"""
-- Host events, delivered at the start of each frame.
local function dispatch(event)
	local kind = event[1]
	if kind == "Log" then
		-- ["Log", message, "MessageOutput" | "MessageInfo" | "MessageWarning" | "MessageError"]
		logKit.fire(event[2], event[3])
		return
	end
	if kind == "PartTouch" then
		-- ["PartTouch", "Began" | "Ended", partA, partB]: each part is told about the other.
		local name = if event[2] == "Began" then "Touched" else "TouchEnded"
		local a, b = event[3], event[4]
		if invoke("part.exists", a) and invoke("part.exists", b) then
			fire(partSignal(a, name), wrapPart(b))
		end
		if invoke("part.exists", a) and invoke("part.exists", b) then
			fire(partSignal(b, name), wrapPart(a))
		end
		return
	end
	if kind == "DataChanged" or kind == "NPC" or string.sub(kind, 1, 6) == "Remote" then
		dataKit.dispatch(event)
		return
	end
	if kind == "Tool" then
		-- ["Tool", toolID, "Equipped" | "Unequipped" | "Activated" | "Deactivated"]
		toolKit.fire(event[2], event[3])
		return
	end
	if kind == "Track" then
		-- ["Track", handle, "Stopped" | "DidLoop" | "Ended" | "Marker", markerName?]
		local record = tracks[event[2]]
		if record == nil then
			return
		end
		if event[3] == "Marker" then
			fire(record.signals.KeyframeReached, event[4])
			local signal = record.markers[event[4]]
			if signal ~= nil then
				fire(signal, event[4])
			end
		else
			fire(record.signals[event[3]])
		end
	elseif kind == "Touch" then
		-- ["Touch", "Began" | "Ended", partId, bodyPartName, generation]
		local began = event[2] == "Began"
		local record = characterFor(event[5])
		local limb = record and record.parts[event[4]]
		local part = wrapPart(event[3])
		if limb == nil then
			return
		end
		local name = if began then "Touched" else "TouchEnded"
		-- A handler may destroy the part (a pickup); later handlers and later events
		-- for it are then skipped rather than handed a destroyed part.
		local function exists()
			return invoke("part.exists", event[3])
		end
		if not exists() then
			return
		end
		fire(partSignal(event[3], name), limb)
		if not exists() then
			return
		end
		fire(record.partTouch[event[4]][name], part)
		if began and exists() then
			fire(record.signals.Touched, part, limb)
		end
	elseif kind == "MouseMove" then
		fire(mouseKit.buttons.Move)
	elseif kind == "Input" then
		local signal = if event[2] == "Began" then inputBegan else inputEnded
		fire(signal, inputObject(event[3], event[4], if event[2] == "Began" then "Begin" else "End"), false)
		-- The mouse's own buttons, for Player:GetMouse().
		if event[4] == "MouseButton1" or event[4] == "MouseButton2" then
			local button = if event[4] == "MouseButton1" then "Button1" else "Button2"
			fire(mouseKit.buttons[button .. (if event[2] == "Began" then "Down" else "Up")])
		end
	elseif kind == "Sound" then
		-- ["Sound", id, "Ended"]
		soundKit.fire(event[2], event[3])
	elseif kind == "Click" then
		-- ["Click", partID, player, "MouseClick" | "MouseHoverEnter" | "MouseHoverLeave"]
		mouseKit.fire(event[2], event[4], toolKit.playerOf(event[3]))
	elseif kind == "CharacterAdded" or kind == "CharacterRemoving" then
		local record = characterFor(event[2])
		if record ~= nil then
			local added = kind == "CharacterAdded"
			local owner = invoke("character.owner", event[2])
			if owner < 0 then
				fire(if added then characterAdded else characterRemoving, record.model)
			else
				local other = otherPlayers.get(owner)
				fire(if added then other.characterAdded else other.characterRemoving, record.model)
			end
		end
	elseif kind == "Gui" then
		-- ["Gui", id, "Click" | "Focused" | "FocusLost", enterPressed?]
		local id, what = event[2], event[3]
		if what == "Click" then
			gui.fire(id, "MouseButton1Click")
			gui.fire(id, "Activated")
		elseif what == "FocusLost" then
			gui.fire(id, "FocusLost", event[4] == true)
		else
			gui.fire(id, what)
		end
	elseif kind == "Chat" then
		-- ["Chat", fromName, text]
		fire(gui.chatReceived, gui.message(event[2], event[3]))
	elseif kind == "PlayerAdded" then
		fire(otherPlayers.added, otherPlayers.get(event[2]).player)
	elseif kind == "PlayerRemoving" then
		-- ["PlayerRemoving", id, name]: the name, since they're already gone.
		local other = otherPlayers.get(event[2])
		other.leftAs = event[3]
		fire(otherPlayers.removing, other.player)
		otherPlayers.byId[event[2]] = nil
	elseif kind == "Humanoid" then
		local record = characters[event[2]]
		local name = event[3]
		local signal = record and record.signals[name]
		if signal == nil then
			return
		end
		if name == "StateChanged" then
			fire(signal, Enum.HumanoidStateType[event[4]], Enum.HumanoidStateType[event[5]])
		elseif name == "Seated" then
			fire(signal, event[4], if event[5] ~= "" then wrapPart(event[5]) else nil)
		else
			fire(signal, event[4])
		end
	end
end

"""#
}
