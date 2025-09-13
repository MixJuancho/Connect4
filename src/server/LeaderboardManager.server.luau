--!strict
-- LeaderboardManager.server.luau
-- Maintains global OrderedDataStore based leaderboards for Wins and HighestStreak
-- and periodically refreshes in-world UI boards.
-- Expected world models (optional naming convention, adjust below):
--   Workspace.Leaderboards.TopWins  (Model containing a SurfaceGui with ScrollingFrame)
--   Workspace.Leaderboards.TopStreak (Model containing a SurfaceGui with ScrollingFrame)
-- UI Templates expected at ReplicatedStorage.Assets.UITemplates.Leaderboards:
--   First, Second, Third, Regular (Frames)
-- Each cloned entry contains descendants:
--   Top (TextLabel)  -> rank text (e.g. "#1")
--   PlayerName (TextLabel)
--   Amount (TextLabel)
--   PlayerThumbnail (ImageLabel)
-- Configure constants below if your hierarchy differs.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService") -- only for safe pcall maybe not strictly needed

-- DataStore names (version bump friendly)
local WINS_DS_NAME = "WinsLeaderboardV1"
local STREAK_DS_NAME = "HighestStreakLeaderboardV1"

-- World model names (adjust here if your models differ)
local BOARD_NAME_WINS = "TopWins"
local BOARD_NAME_STREAK = "TopStreak"

-- Configuration flags
local INCLUDE_ZERO_VALUES = true -- show players even if value == 0
local SHOW_PLACEHOLDER_WHEN_EMPTY = true
local DEBUG_DISCOVERY = true -- set false to silence extra discovery info

local winsStore = DataStoreService:GetOrderedDataStore(WINS_DS_NAME)
local streakStore = DataStoreService:GetOrderedDataStore(STREAK_DS_NAME)

-- Refresh interval seconds for visual boards
local REFRESH_INTERVAL = 60 -- reduced to 1 minute per request
local TOP_LIMIT = 10

-- Paths for world boards
local function findBoardModel(name: string): Model?
	local lbFolder = workspace:FindFirstChild("Leaderboards")
	if not lbFolder then
		return nil
	end
	local direct = lbFolder:FindFirstChild(name)
	if direct and direct:IsA("Model") then return direct end
	-- Fallback: search descendants (allows nesting one level deeper or mis-grouping)
	for _,desc in ipairs(lbFolder:GetDescendants()) do
		if desc.Name == name and desc:IsA("Model") then
			return desc
		end
	end
	return nil
end

local function findScrollingFrame(boardModel: Model): ScrollingFrame?
	-- Flexible: search any SurfaceGui descendants for a ScrollingFrame named "ScrollingFrame"
	for _,desc in ipairs(boardModel:GetDescendants()) do
		if desc:IsA("ScrollingFrame") and desc.Name == "ScrollingFrame" then
			return desc
		end
	end
	return nil
end

local function getTemplates(): {[string]: Frame} | nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local uiTemplates = assets and assets:FindFirstChild("UITemplates")
	local lbFolder = uiTemplates and uiTemplates:FindFirstChild("Leaderboards")
	if not lbFolder then return nil end
	local result: {[string]: Frame} = {}
	for _,name in ipairs({"First","Second","Third","Regular"}) do
		local inst = lbFolder:FindFirstChild(name)
		if inst and inst:IsA("Frame") then
			result[name] = inst
		end
	end
	if not (result.First and result.Second and result.Third and result.Regular) then
		return nil
	end
	return result
end

-- Update OrderedDataStores for a player
local function updateWins(userId: number, amount: number)
	for i=1,3 do
		local ok, err = pcall(function()
			winsStore:SetAsync(tostring(userId), amount)
		end)
		if ok then return true end
		warn("[Leaderboard] Wins SetAsync failed attempt"..i..": ".. tostring(err))
		wait(0.4 * i)
	end
	return false
end

local function updateHighestStreak(userId: number, amount: number)
	for i=1,3 do
		local ok, err = pcall(function()
			streakStore:SetAsync(tostring(userId), amount)
		end)
		if ok then return true end
		warn("[Leaderboard] Streak SetAsync failed attempt"..i..": ".. tostring(err))
		wait(0.4 * i)
	end
	return false
end

-- Player join hook: push their current values (leaderstats Wins & HighestStreak attribute)
local function initPlayer(plr: Player)
	local ls = plr:WaitForChild("leaderstats", 15)
	local winsVal = ls and ls:FindFirstChild("Wins")
	if winsVal and winsVal:IsA("IntValue") then
		updateWins(plr.UserId, winsVal.Value)
		winsVal.Changed:Connect(function()
			updateWins(plr.UserId, winsVal.Value)
		end)
	end
	-- HighestStreak attribute (persistent best streak, not current Streak value)
	local currentHigh = plr:GetAttribute("HighestStreak")
	if typeof(currentHigh) == "number" then
		updateHighestStreak(plr.UserId, currentHigh)
	end
	plr:GetAttributeChangedSignal("HighestStreak"):Connect(function()
		local nv = plr:GetAttribute("HighestStreak")
		if typeof(nv) == "number" then
			updateHighestStreak(plr.UserId, nv)
		end
	end)
end

Players.PlayerAdded:Connect(initPlayer)
for _,p in ipairs(Players:GetPlayers()) do task.spawn(initPlayer, p) end

-- Data fetch for display
local function getTopPages(store: OrderedDataStore): { {userId: number, value: number} }
	local data: { {userId: number, value: number} } = {}
	local ok, pagesOrErr = pcall(function()
		-- descending=false sorts HIGH -> LOW per docs (false = descending order)
		return store:GetSortedAsync(false, TOP_LIMIT)
	end)
	if not ok then
		warn("[Leaderboard] GetSortedAsync failed: ".. tostring(pagesOrErr))
		return data
	end
	local pages = pagesOrErr
	local current = pages:GetCurrentPage()
	for _,entry in ipairs(current) do
		local uid = tonumber(entry.key)
		if uid and entry.value ~= nil then
			if INCLUDE_ZERO_VALUES or (typeof(entry.value) == "number" and entry.value > 0) then
				table.insert(data, {userId = uid, value = entry.value})
			end
		end
	end
	return data
end

local function fetchPlayerName(userId: number): string
	local name: string = "Unknown"
	local ok, result = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(result) == "string" then
		name = result
	end
	return name
end

local function fetchHeadshot(userId: number): string
	local ok, content, _isReady = pcall(function()
		return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
	end)
	if ok and type(content) == "string" then
		return content
	end
	return ""
end

local function clearChildren(frame: ScrollingFrame)
	for _,child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end
end

local templatesCache = getTemplates()

local function populateBoard(boardModelName: string, store: OrderedDataStore)
	local model = findBoardModel(boardModelName)
	if not model then
		if DEBUG_DISCOVERY then
			local lbFolder = workspace:FindFirstChild("Leaderboards")
			if not lbFolder then
				warn("[Leaderboard] Leaderboards folder missing in Workspace (expecting Workspace.Leaderboards). Current Workspace children:")
				for _,c in ipairs(workspace:GetChildren()) do warn("  - "..c.Name.." ["..c.ClassName.."]") end
			else
				warn("[Leaderboard] Board model '".. boardModelName .."' not found. Children of Workspace.Leaderboards:")
				for _,c in ipairs(lbFolder:GetChildren()) do warn("  - "..c.Name.." ["..c.ClassName.."]") end
			end
		end
		return
	end
	local scroll = findScrollingFrame(model)
	if not scroll then
		warn("[Leaderboard] ScrollingFrame missing for board '".. boardModelName .."'")
		return
	end
	if not templatesCache then
		templatesCache = getTemplates()
	end
	local templates = templatesCache
	if not templates then
		warn("[Leaderboard] UI templates missing (Assets/UITemplates/Leaderboards with First/Second/Third/Regular)")
		return
	end
	local topData = getTopPages(store)
	clearChildren(scroll)
	if (#topData == 0) and SHOW_PLACEHOLDER_WHEN_EMPTY then
		local placeholderTemplate = templates.Regular or templates.First or templates.Second or templates.Third
		if placeholderTemplate then
			local ph = placeholderTemplate:Clone()
			ph.Name = "Placeholder"
			local topLabel = ph:FindFirstChild("Top")
			if topLabel and topLabel:IsA("TextLabel") then topLabel.Text = "--" end
			local nameLabel = ph:FindFirstChild("PlayerName")
			if nameLabel and nameLabel:IsA("TextLabel") then nameLabel.Text = "No Data Yet" end
			local amountLabel = ph:FindFirstChild("Amount")
			if amountLabel and amountLabel:IsA("TextLabel") then amountLabel.Text = "0" end
			local thumbImg = ph:FindFirstChild("PlayerThumbnail")
			if thumbImg and thumbImg:IsA("ImageLabel") then thumbImg.Image = "" end
			ph.Parent = scroll
		end
		return
	end
	local rank = 0
	local inserted: {[number]: boolean} = {}
	for _,entry in ipairs(topData) do
		if inserted[entry.userId] then
			continue -- guard against any accidental duplicate userIds in returned page
		end
		inserted[entry.userId] = true
		rank += 1
		local template: Frame? = nil
		if rank == 1 then template = templates.First elseif rank == 2 then template = templates.Second elseif rank == 3 then template = templates.Third else template = templates.Regular end
		if not template then continue end
		local cloned = template:Clone()
		cloned.Name = "Entry"..rank
		-- Fill fields
		local topLabel = cloned:FindFirstChild("Top")
		if topLabel and topLabel:IsA("TextLabel") then
			topLabel.Text = tostring(rank) -- remove leading '#'
		end
		local nameLabel = cloned:FindFirstChild("PlayerName")
		local amountLabel = cloned:FindFirstChild("Amount")
		local thumbImg = cloned:FindFirstChild("PlayerThumbnail")
		local playerName = fetchPlayerName(entry.userId)
		local headshot = fetchHeadshot(entry.userId)
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = playerName
		end
		if amountLabel and amountLabel:IsA("TextLabel") then
			amountLabel.Text = tostring(entry.value)
		end
		if thumbImg and thumbImg:IsA("ImageLabel") then
			thumbImg.Image = headshot
		end
		cloned.Parent = scroll
	end
end

local function refreshAll()
	populateBoard(BOARD_NAME_WINS, winsStore)
	populateBoard(BOARD_NAME_STREAK, streakStore)
end

-- Reattempt discovery shortly after start in case boards replicate late
task.spawn(function()
	for i=1,5 do
		refreshAll()
		wait(3)
	end
end)

-- Periodic refresh loop
spawn(function()
	while true do
		refreshAll()
		wait(REFRESH_INTERVAL)
	end
end)

-- Initial small delayed refresh (gives world time to replicate boards & templates)
wait(10)
refreshAll()
