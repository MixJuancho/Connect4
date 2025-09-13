--!strict
-- Shared/UI/SkinsUI.luau
-- Module to populate and manage skins list UI and equip/unequip interactions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local M = {}

export type InitOptions = {
	scrollingPath: {string}, -- path inside PlayerGui to the scrolling frame
	templateName: string, -- name of template inside ReplicatedStorage.UITemplates
	iconsFolderName: string, -- folder name under UITemplates containing icon ImageLabels
	autoRefreshSeconds: number?,
}

local function waitForPath(root: Instance, path: {string}, timeout: number?): Instance?
	local current: Instance? = root
	for _, segment in ipairs(path) do
		if not current then return nil end
		local child = current:FindFirstChild(segment)
		local start = tick()
		while not child and (not timeout or tick()-start < timeout) do
			current.ChildAdded:Wait()
			child = current:FindFirstChild(segment)
		end
		current = child
	end
	return current
end

-- Search across all ScreenGuis under PlayerGui for first path match
local function findScrollingFrame(playerGui: PlayerGui, path: {string}, timeout: number?): ScrollingFrame?
	local deadline = if timeout then tick() + timeout else nil
	while true do
		for _, sg in ipairs(playerGui:GetChildren()) do
			if sg:IsA("ScreenGui") then
				local found = waitForPath(sg, path, 0)
				if found and found:IsA("ScrollingFrame") then
					print("[SkinsUI] Found scrolling frame at", found:GetFullName())
					return found
				end
			end
		end
		if not deadline or tick() > deadline then break end
		playerGui.ChildAdded:Wait()
	end
	return nil
end

function M.init(opts: InitOptions)
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	-- Previous logic incorrectly assumed path started directly under PlayerGui. Now scan ScreenGuis.
	local scrolling = findScrollingFrame(playerGui, opts.scrollingPath, 25)
	if not scrolling then
		local pathStr = table.concat(opts.scrollingPath, ".")
		warn("[SkinsUI] ScrollingFrame not found at path:", pathStr, "(waited 25s)")
		-- Fallback heuristic search: try to locate a descendant named like last segment under an ancestor named 'Skins'
		local pg = playerGui
		if pg then
			local lastSeg = opts.scrollingPath[#opts.scrollingPath]
			for _, sg in ipairs(pg:GetChildren()) do
				if sg:IsA("ScreenGui") then
					local candidate = sg:FindFirstChild("Skins", true)
					if candidate then
						local found = candidate:FindFirstChild(lastSeg, true)
						if found and found:IsA("ScrollingFrame") then
							warn("[SkinsUI] Fallback located scrolling frame at", found:GetFullName())
							scrolling = found
							break
						end
					end
				end
			end
		end
		if not scrolling then return end
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local uiTemplates = assets and assets:FindFirstChild("UITemplates") or ReplicatedStorage:FindFirstChild("UITemplates")
	if not uiTemplates then
		warn("[SkinsUI] UITemplates missing")
		return
	end
	-- Flexible template resolution: direct child, folder wrapper, or descendant
	local function resolveTemplate(root: Instance, name: string): GuiObject?
		local direct = root:FindFirstChild(name)
		if direct then
			if direct:IsA("Frame") or direct:IsA("ImageButton") then return direct :: GuiObject end
			if direct:IsA("Folder") then
				-- Prefer a Frame child named name or first Frame
				local exact = direct:FindFirstChild(name)
				if exact and (exact:IsA("Frame") or exact:IsA("ImageButton")) then return exact :: GuiObject end
				for _, c in ipairs(direct:GetChildren()) do
					if c:IsA("Frame") or c:IsA("ImageButton") then return c :: GuiObject end
				end
			end
		end
		-- Descendant search (first match with exact name)
		for _, d in ipairs(root:GetDescendants()) do
			if (d:IsA("Frame") or d:IsA("ImageButton")) and d.Name == name then return d :: GuiObject end
		end
		return nil
	end

	local template = resolveTemplate(uiTemplates, opts.templateName)
	if not template then
		-- Diagnostics: list candidate frames at top level
		local candidates = {}
		for _, c in ipairs(uiTemplates:GetChildren()) do
			if c:IsA("Frame") or c:IsA("ImageButton") then table.insert(candidates, c.Name)
			elseif c:IsA("Folder") then
				for _, sub in ipairs(c:GetChildren()) do
					if sub:IsA("Frame") or sub:IsA("ImageButton") then table.insert(candidates, c.Name .. "/" .. sub.Name) end
				end
			end
		end
		warn("[SkinsUI] Skin template missing:", opts.templateName, "Available:", #candidates>0 and table.concat(candidates, ", ") or "(none)")
		return
	end
	local iconFolder = uiTemplates:FindFirstChild(opts.iconsFolderName)

	-- UI Click SFX (single clone reused)
	local clickSfx: Sound? = nil
	pcall(function()
		local assetsRoot = ReplicatedStorage:FindFirstChild("Assets")
		local soundsFolder = assetsRoot and assetsRoot:FindFirstChild("Sounds")
		local baseClick = soundsFolder and soundsFolder:FindFirstChild("InterfaceButtonClick")
		if baseClick and baseClick:IsA("Sound") then
			local SoundService = game:GetService("SoundService")
			local existing = SoundService:FindFirstChild("UI_SkinClickSFX")
			if existing and existing:IsA("Sound") then
				clickSfx = existing
			else
				local cloned = baseClick:Clone()
				cloned.Name = "UI_SkinClickSFX"
				cloned.Parent = SoundService
				clickSfx = cloned
			end
		end
	end)

	local invFolder = ReplicatedStorage:WaitForChild("TokenInventory")
	local request = invFolder:WaitForChild("Request") :: RemoteFunction
	local buttons: {[string]: GuiObject} = {}
	local equipped: string? = player:GetAttribute("TokenSkin")

	local function setEquippedVisual(name: string?, state: boolean)
		if not name then return end
		local fr = buttons[name]
		if not fr then return end
		local eq = fr:FindFirstChild("Equipped")
		if eq and eq:IsA("GuiObject") then eq.Visible = state end
	end
	local function clearEquipped()
		for _, fr in pairs(buttons) do
			local eq = fr:FindFirstChild("Equipped")
			if eq and eq:IsA("GuiObject") then eq.Visible = false end
		end
	end

	local function equip(skin: string?)
		local result = request:InvokeServer({ action = "Equip", skin = skin })
		if result and result.success then
			local prev = equipped
			if skin and skin ~= "" then
				equipped = skin
			else
				equipped = nil
			end
			if prev and prev ~= equipped then setEquippedVisual(prev, false) end
			clearEquipped()
			if equipped then setEquippedVisual(equipped, true) end
		end
	end

	local function createButton(name: string)
		local clone = template:Clone() :: GuiObject
		clone.Name = name
		local label = clone:FindFirstChild("ItemName")
		if label and label:IsA("TextLabel") then label.Text = name end
		if iconFolder then
			local srcIcon = iconFolder:FindFirstChild(name)
			if srcIcon and srcIcon:IsA("ImageLabel") then
				local target = clone:FindFirstChild("Image")
				if target and target:IsA("ImageLabel") then
					target.Image = srcIcon.Image
				elseif clone:IsA("ImageButton") or clone:IsA("ImageLabel") then
					(clone :: any).Image = srcIcon.Image
				end
			end
		end
		local eq = clone:FindFirstChild("Equipped")
		if eq and eq:IsA("GuiObject") then eq.Visible = false end
		clone.Parent = scrolling
		buttons[name] = clone
		local function playClick()
			if clickSfx then
				clickSfx.TimePosition = 0
				clickSfx:Play()
			end
		end
		if clone:IsA("GuiButton") then
			clone.Activated:Connect(function()
				playClick()
				if equipped == name then equip("") else equip(name) end
			end)
		else
			clone.InputBegan:Connect(function(input)
				if input.UserInputType.Name == "MouseButton1" or input.UserInputType.Name == "Touch" then
					playClick()
					if equipped == name then equip("") else equip(name) end
				end
			end)
		end
	end

	local function rebuild()
		local result = request:InvokeServer({ action = "List" })
		if not result then return end
		local owned = result.owned or {}
		pcall(function()
			if #owned == 0 then
				print("[SkinsUI] Owned skins: (none)")
			else
				print("[SkinsUI] Owned skins:", table.concat(owned, ", "))
			end
		end)
		-- cleanup
		for _, fr in pairs(buttons) do if fr.Parent then fr:Destroy() end end
		buttons = {}
		for _, name in ipairs(owned) do createButton(name) end
		if equipped and buttons[equipped] then setEquippedVisual(equipped, true) end
	end

	-- Immediate refresh when server notifies of a purchase
	local purchasedEvent = invFolder:FindFirstChild("Purchased")
	if purchasedEvent and purchasedEvent:IsA("RemoteEvent") then
		purchasedEvent.OnClientEvent:Connect(function(skinName: string)
			-- Debounce rapid multiple fires by delaying rebuild to end of frame
			task.defer(function()
				rebuild()
			end)
		end)
	end

	player:GetAttributeChangedSignal("TokenSkin"):Connect(function()
		local newVal = player:GetAttribute("TokenSkin")
		if newVal == nil or newVal == "" then
			if equipped then setEquippedVisual(equipped, false) end
			equipped = nil
		else
			local prev = equipped
			equipped = newVal
			if prev and prev ~= equipped then setEquippedVisual(prev, false) end
			if equipped then setEquippedVisual(equipped, true) end
		end
	end)

	rebuild()
	local interval = opts.autoRefreshSeconds or 0
	if interval > 0 then
		spawn(function()
			while true do
				task.wait(interval)
				rebuild()
			end
		end)
	end
end

return M
