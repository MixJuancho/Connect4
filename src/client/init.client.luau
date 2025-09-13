print("Hello world, from client!")

-- Skins UI bootstrap
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

task.defer(function()
	local ok, moduleOrErr = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("SkinsUI"))
	end)
	if ok and moduleOrErr then
		(moduleOrErr :: any).init({
			scrollingPath = {"Frames","Skins","ScrollingFrame"}, -- revert: use Frames.Skins.ScrollingFrame
			templateName = "Skin",
			iconsFolderName = "TokenIcons",
			autoRefreshSeconds = 20,
		})
	else
		warn("[Init] Failed to load SkinsUI module", moduleOrErr)
	end
end)

-- HUD frame + hover logic
task.defer(function()
	local player = Players.LocalPlayer
	local uiMod
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"))
	end)
	if ok then uiMod = mod end
	if not uiMod then
		warn("[HUDFrames] UI module missing")
		return
	end
	local pg = player:WaitForChild("PlayerGui")

	-- UI SFX setup
	local assetsRoot = ReplicatedStorage:FindFirstChild("Assets")
	local soundsFolder = assetsRoot and assetsRoot:FindFirstChild("Sounds")
	local baseHover = soundsFolder and soundsFolder:FindFirstChild("InterfaceButtonHover")
	local baseClick = soundsFolder and soundsFolder:FindFirstChild("InterfaceButtonClick")
	local baseCoinsAwarded = soundsFolder and soundsFolder:FindFirstChild("CoinsAwarded")
	local SoundServiceForUI = game:GetService("SoundService")
	local sfxHoverSound: Sound? = nil
	local sfxClickSound: Sound? = nil
	local sfxCoinsAwarded: Sound? = nil
	if baseHover and baseHover:IsA("Sound") then
		local cloned = baseHover:Clone()
		cloned.Name = "UI_HoverSFX"
		cloned.Parent = SoundServiceForUI
		sfxHoverSound = cloned
	end
	if baseClick and baseClick:IsA("Sound") then
		local cloned = baseClick:Clone()
		cloned.Name = "UI_ClickSFX"
		cloned.Parent = SoundServiceForUI
		sfxClickSound = cloned
	end
	if baseCoinsAwarded and baseCoinsAwarded:IsA("Sound") then
		local cloned = baseCoinsAwarded:Clone()
		cloned.Name = "UI_CoinsAwardedSFX"
		cloned.Parent = SoundServiceForUI
		sfxCoinsAwarded = cloned
	end

	-- Listen for Coins increases: primary = player attribute 'Coins'; fallback = legacy leaderstats IntValue
	task.defer(function()
		local lastPlay = 0
		local function play()
			if sfxCoinsAwarded and (tick() - lastPlay) > 0.08 then
				sfxCoinsAwarded.TimePosition = 0
				sfxCoinsAwarded:Play()
				lastPlay = tick()
			end
		end
		-- Attribute-based tracking
		local lastAttr = player:GetAttribute("Coins")
		local attrInitialized = false
		player.AttributeChanged:Connect(function(attr)
			if attr ~= "Coins" then return end
			local newVal = player:GetAttribute("Coins")
			-- Suppress first initialization (and potential rapid datastore sync) to avoid startup SFX
			if not attrInitialized then
				lastAttr = newVal
				attrInitialized = true
				return
			end
			if typeof(newVal) == "number" and typeof(lastAttr) == "number" and newVal > lastAttr then
				play()
			end
			lastAttr = newVal
		end)
		-- Legacy leaderstats fallback (only if IntValue still exists; harmless if removed)
		task.spawn(function()
			local deadline = tick() + 10
			local coinsValue: IntValue? = nil
			while tick() < deadline and not coinsValue do
				local ls = player:FindFirstChild("leaderstats")
				if ls then
					coinsValue = ls:FindFirstChild("Coins") :: IntValue?
				end
				if not coinsValue then task.wait(0.5) end
			end
			if not coinsValue then return end
			local lastLegacy = coinsValue.Value
			coinsValue.Changed:Connect(function(newVal)
				if typeof(newVal) ~= "number" then return end
				if newVal > lastLegacy then play() end
				lastLegacy = newVal
			end)
		end)
	end)

	local function findInAnyScreen(path: {string}): Instance?
		for _, child in ipairs(pg:GetChildren()) do
			if child:IsA("ScreenGui") then
				local cur: Instance? = child
				local ok = true
				for _, seg in ipairs(path) do
					if not cur then ok=false break end
					cur = cur:FindFirstChild(seg)
					if not cur then ok=false break end
				end
				if ok and cur then return cur end
			end
		end
		return nil
	end

	local mappings = {
		{ button = {"HUD","Left","Row1","Shop"}, frame = {"Frames","Shop"} },
		{ button = {"HUD","Left","Row1","Skins"}, frame = {"Frames","Skins"} },
		{ button = {"HUD","Left","CoinsRain"}, frame = {"Frames","CoinsRain"} },
		{ button = {"HUD","Right","Row1","FreeRewards"}, frame = {"Frames","FreeRewards"} },
		{ button = {"HUD","StarterPack"}, frame = {"Frames","StarterPack"} },
		{ button = {"HUD","Left","Coins","More"}, frame = {"Frames","Shop"} }, -- More button opens Shop
	}

	local frameSet: {GuiObject} = {}

	local function resolveClickable(root: Instance): GuiButton?
		if root:IsA("GuiButton") then return root end
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("GuiButton") then return d end
		end
		return nil
	end

	local function attachSfx(gui: GuiButton)
		if gui:GetAttribute("_SfxAttached") then return end
		gui:SetAttribute("_SfxAttached", true)
		if sfxHoverSound then
			gui.MouseEnter:Connect(function()
				if sfxHoverSound then
					sfxHoverSound.TimePosition = 0
					sfxHoverSound:Play()
				end
			end)
		end
	end

	local function attachHover(gui: GuiButton)
		if gui:GetAttribute("_HoverAttached") then return end
		gui:SetAttribute("_HoverAttached", true)
		pcall(function()
			uiMod.attachHoverClick(gui, { hoverScale = 1.04, clickScale = 1.08 })
		end)
		attachSfx(gui)
	end

	local function register(buttonContainer: GuiButton | Instance, frameObj: GuiObject)
		local buttonObj = resolveClickable(buttonContainer)
		if not buttonObj then
			warn("[HUDFrames] No clickable GuiButton found under", buttonContainer:GetFullName())
			return
		end
		if frameObj:GetAttribute("_UI_State") ~= "Open" then
			frameObj.Visible = false
			frameObj:SetAttribute("_UI_State", "Closed")
			frameObj:SetAttribute("_UI_TargetPos", frameObj.Position)
		end
		attachHover(buttonObj)
		buttonObj.Activated:Connect(function()
			if sfxClickSound then
				sfxClickSound.TimePosition = 0
				sfxClickSound:Play()
			end
			local openAlready = frameObj.Visible and frameObj:GetAttribute("_UI_State") == "Open"
			for _, fr in ipairs(frameSet) do
				if fr ~= frameObj then
					fr.Visible = false
					fr:SetAttribute("_UI_State", "Closed")
				end
			end
			if openAlready then
				uiMod.close(frameObj)
			else
				uiMod.open(frameObj)
			end
		end)
		table.insert(frameSet, frameObj)
	end

	local timeoutSeconds = 8
	local start = tick()
	local pending = {}
	for i in ipairs(mappings) do pending[i] = true end
	while next(pending) and tick() - start < timeoutSeconds do
		for i in pairs(pending) do
			local data = mappings[i]
			local btn = findInAnyScreen(data.button)
			local fr = findInAnyScreen(data.frame)
			if btn and fr and fr:IsA("GuiObject") then
				register(btn, fr)
				pending[i] = nil
			end
		end
		if next(pending) then task.wait(0.2) end
	end
	for i in pairs(pending) do
		local data = mappings[i]
		warn("[HUDFrames] Missing button or frame for mapping after wait", table.concat(data.button, "."), "->", table.concat(data.frame, "."))
	end

	for _, gui in ipairs(pg:GetDescendants()) do
		if gui:IsA("GuiButton") then attachHover(gui) end
	end

	-- Attach close logic to any button named "Close" inside a frame.
	local function attachCloseIf(btn: GuiButton)
		if btn.Name ~= "Close" then return end
		if btn:GetAttribute("_CloseAttached") then return end
		btn:SetAttribute("_CloseAttached", true)
		btn.Activated:Connect(function()
			if sfxClickSound then
				sfxClickSound.TimePosition = 0
				sfxClickSound:Play()
			end
			local frame = btn.Parent
			if frame and frame:IsA("GuiObject") then
				uiMod.close(frame)
			end
		end)
	end
	for _, inst in ipairs(pg:GetDescendants()) do
		if inst:IsA("GuiButton") then attachCloseIf(inst) end
	end
	pg.DescendantAdded:Connect(function(inst)
		if inst:IsA("GuiButton") then attachCloseIf(inst) end
	end)
	pg.DescendantAdded:Connect(function(inst)
		if inst:IsA("GuiButton") then attachHover(inst) end
	end)
	-- Music toggle (uses Playing property) (SoundService already obtained for SFX; reuse variable)
	local SoundService = game:GetService("SoundService")
	local bgm: Sound? = SoundService:FindFirstChild("BackgroundMusic") :: Sound?
	local musicButton = findInAnyScreen({"HUD","Music"}) or findInAnyScreen({"HUD","Right","Music"})
	-- UITemplates now lives under ReplicatedStorage.Assets; keep legacy fallback just in case
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local uiTemplates = assets and assets:FindFirstChild("UITemplates") or ReplicatedStorage:FindFirstChild("UITemplates")
	local musicIconsFolder = uiTemplates and uiTemplates:FindFirstChild("MusicIcons")
	local iconOn = musicIconsFolder and musicIconsFolder:FindFirstChild("On")
	local iconOff = musicIconsFolder and musicIconsFolder:FindFirstChild("Off")

	local function setIcon(stateOn: boolean)
		if not musicButton then return end
		local src = if stateOn then iconOn else iconOff
		if not src or not src:IsA("ImageLabel") then return end
		-- Always use a child named "Icon"; do NOT alter the button's own Image
		local icon = musicButton:FindFirstChild("Icon")
		if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
			(icon :: any).Image = src.Image
		end
	end

	if musicButton and musicButton:IsA("GuiButton") then
		musicButton.Activated:Connect(function()
			if not bgm then
				bgm = SoundService:FindFirstChild("BackgroundMusic") :: Sound?
			end
			if not bgm then return end
			bgm.Playing = not bgm.Playing
			setIcon(bgm.Playing)
		end)
	end
	if bgm then setIcon(bgm.Playing) end

	-- Rainbow gradient animation for HUD.Left.CoinsRain.TextLabel.Gradient
	local RunService = game:GetService("RunService")
	local gradientObj = findInAnyScreen({"HUD","Left","CoinsRain","TextLabel","Gradient"})
	local function startRainbowGradient(grad: Instance, cycleTime: number, colorCount: number)
		if not grad or not grad:IsA("UIGradient") then return end
		if grad:GetAttribute("_RainbowActive") then return end
		grad:SetAttribute("_RainbowActive", true)
		cycleTime = cycleTime > 0 and cycleTime or 1
		colorCount = math.max(2, colorCount)
		task.spawn(function()
			while grad.Parent and grad:GetAttribute("_RainbowActive") do
				local loop = tick() % cycleTime / cycleTime
				local keypoints = table.create(colorCount + 1)
				for i = 1, colorCount + 1 do
					local offset = (i - 1) / colorCount
					local h = loop - offset
					if h < 0 then h += 1 end
					local col = Color3.fromHSV(h, 1, 1)
					keypoints[i] = ColorSequenceKeypoint.new(offset, col)
				end
				grad.Color = ColorSequence.new(keypoints)
				RunService.Heartbeat:Wait()
			end
		end)
	end
	if gradientObj then
		-- Slowed cycle time from 1s to 1.6s for a slightly slower rainbow sweep
		startRainbowGradient(gradientObj, 1.6, 7)
	end

	-- Continuous rotation for HUD.StarterPack.Rayburst
	local rayburst = findInAnyScreen({"HUD","StarterPack","Rayburst"})
	if rayburst and rayburst:IsA("GuiObject") then
		if not rayburst:GetAttribute("_Rotating") then
			rayburst:SetAttribute("_Rotating", true)
			local ROT_SPEED = 20 -- slowed from 30 for a gentler spin
			task.spawn(function()
				while rayburst.Parent and rayburst:GetAttribute("_Rotating") do
					local dt = RunService.Heartbeat:Wait()
					rayburst.Rotation = (rayburst.Rotation + ROT_SPEED * dt) % 360
				end
			end)
		end
	end
end)