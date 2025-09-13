--!strict
-- CoinsDisplay.luau
-- Client helper: shows player's Coins in HUD.
-- Now prefers Player attribute `Coins` (after Coins/HighestStreak were hidden from leaderstats)
-- Falls back to legacy leaderstats.IntValue("Coins") if attribute missing.
-- Usage (client):
--   local UI = require(ReplicatedStorage.Shared.UI)
--   require(ReplicatedStorage.Shared.UI.CoinsDisplay).start()

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local module = {}
local started = false

-- Strong wait-based path resolution for guaranteed label reference
local function waitForLabel(): TextLabel?
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local screen = pg:WaitForChild("ScreenGui", 10)
	if not screen then return nil end
	local hud = screen:WaitForChild("HUD", 5)
	if not hud then return nil end
	local left = hud:WaitForChild("Left", 5)
	if not left then return nil end
	-- Coins frame might be nested; search recursively if direct child missing
	local coinsFrame = left:FindFirstChild("Coins") or left:FindFirstChild("Coins", true)
	if not coinsFrame then
		for _, d in ipairs(left:GetDescendants()) do
			if d:IsA("Frame") and d.Name == "Coins" then coinsFrame = d break end
		end
	end
	if not coinsFrame then return nil end
	local amount = coinsFrame:FindFirstChild("Amount")
	if not amount then
		amount = coinsFrame:FindFirstChildWhichIsA("TextLabel", true)
	end
	if amount and amount:IsA("TextLabel") then return amount end
	return nil
end

local amountLabel: TextLabel? = nil
local coinIcon: ImageLabel? = nil
local originalLabelSize: UDim2? = nil
local activeAnimId = 0

local function playCoinAnim()
	if not amountLabel then return end
	if not originalLabelSize then originalLabelSize = amountLabel.Size end
	if not coinIcon then
		local parent = amountLabel.Parent
		if parent then coinIcon = parent:FindFirstChildWhichIsA("ImageLabel") end
	end
	activeAnimId += 1
	local myId = activeAnimId

	-- Total desired duration 0.3s: 0.15s out + 0.15s back
	local phaseTime = 0.15
	local outInfo = TweenInfo.new(phaseTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(phaseTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	-- Scale label size to 1.1x (maintain aspect ratio by scaling both axes)
	local baseSize = originalLabelSize or amountLabel.Size
	local function scaleUDim2(u: UDim2, factor: number): UDim2
		return UDim2.new(u.X.Scale * factor, math.floor(u.X.Offset * factor + 0.5), u.Y.Scale * factor, math.floor(u.Y.Offset * factor + 0.5))
	end
	local targetSize = scaleUDim2(baseSize, 1.07)

	-- Reset baseline
	if coinIcon then coinIcon.Rotation = 0 end
	amountLabel.Size = baseSize

	local rotOut, sizeOut
	if coinIcon then rotOut = TweenService:Create(coinIcon, outInfo, { Rotation = 10 }) end
	sizeOut = TweenService:Create(amountLabel, outInfo, { Size = targetSize })
	if rotOut then rotOut:Play() end
	sizeOut:Play()

	task.delay(phaseTime, function()
		if myId ~= activeAnimId then return end
		local rotBack, sizeBack
		if coinIcon then rotBack = TweenService:Create(coinIcon, backInfo, { Rotation = 0 }) end
			sizeBack = TweenService:Create(amountLabel, backInfo, { Size = baseSize })
		if rotBack then rotBack:Play() end
		sizeBack:Play()
	end)
end

local function updateDisplay(v: number)
	if not amountLabel then return end
	amountLabel.Text = tostring(v)
end

local function hookCoins()
	local player = Players.LocalPlayer
	-- Attribute-first approach
	local function connectAttribute()
		local attrVal = player:GetAttribute("Coins")
		if typeof(attrVal) == "number" then
			updateDisplay(attrVal)
		else
			-- If attribute not yet set, default 0 display
			updateDisplay(0)
		end
		player:GetAttributeChangedSignal("Coins"):Connect(function()
			local v = player:GetAttribute("Coins")
			if typeof(v) == "number" then
				updateDisplay(v)
				playCoinAnim()
			end
		end)
	end

	connectAttribute()

	-- Legacy fallback: some older sessions may still create a leaderstats Coins IntValue
	local ls = player:FindFirstChild("leaderstats")
	if ls then
		local coinsVal = ls:FindFirstChild("Coins")
		if coinsVal and coinsVal:IsA("IntValue") then
			updateDisplay(coinsVal.Value)
			coinsVal.Changed:Connect(function()
				updateDisplay(coinsVal.Value)
				playCoinAnim()
			end)
		else
			ls.ChildAdded:Connect(function(child)
				if child.Name == "Coins" and child:IsA("IntValue") then
					updateDisplay(child.Value)
					child.Changed:Connect(function()
						updateDisplay(child.Value)
						playCoinAnim()
					end)
				end
			end)
		end
	end
end

function module.start()
	if started then return end
	started = true
	-- Resolve label (retry loop)
	local attempts = 0
	while attempts < 80 do
		amountLabel = waitForLabel()
		if amountLabel then break end
		attempts += 1
		task.wait(0.1)
	end
	if amountLabel and amountLabel.Parent then
		coinIcon = amountLabel.Parent:FindFirstChildWhichIsA("ImageLabel")
	end
	if amountLabel and (amountLabel.Text == "" or tonumber(amountLabel.Text) == nil) then
		amountLabel.Text = "0"
	end
	hookCoins()
	-- Safety poll: ensure label stays synced (attribute priority)
	task.spawn(function()
		while started do
			local player = Players.LocalPlayer
			local attrVal = player:GetAttribute("Coins")
			if typeof(attrVal) == "number" and amountLabel then
				if amountLabel.Text ~= tostring(attrVal) then
					amountLabel.Text = tostring(attrVal)
				end
			end
			task.wait(1)
		end
	end)
end

return module
