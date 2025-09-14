--!strict
-- QuestManager.server.luau
-- Manages time-based and interaction-based rewards, like the "Play 15 mins + Like" quest.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local DataManager = require(script.Parent:WaitForChild("DataManager"))

local invFolder = ReplicatedStorage:WaitForChild("TokenInventory")
local purchasedEvent = invFolder:WaitForChild("Purchased") :: RemoteEvent

local MARBLE_REWARD_SKIN = "Marble"
local REQUIRED_PLAY_TIME_SECONDS = 900 -- 15 minutes

local playerJoinTimes: {[number]: number} = {}

local questsFolder = ReplicatedStorage:FindFirstChild("Quests")
if not questsFolder then
	questsFolder = Instance.new("Folder")
	questsFolder.Name = "Quests"
	questsFolder.Parent = ReplicatedStorage
end

local claimMarbleReward = Instance.new("RemoteFunction")
claimMarbleReward.Name = "ClaimMarbleReward"
claimMarbleReward.Parent = questsFolder

-- Notification remote (wait since this runs early at server start)
local showNotificationEvent = (function()
	local notifications = ReplicatedStorage:FindFirstChild("Notifications")
	if notifications then
		local show = notifications:FindFirstChild("Show")
		if show and show:IsA("RemoteEvent") then return show end
	end
	-- Create lazily if Monetization hasn't created it yet
	local folder = notifications or Instance.new("Folder")
	folder.Name = "Notifications"
	folder.Parent = ReplicatedStorage
	local ev = folder:FindFirstChild("Show")
	if ev and ev:IsA("RemoteEvent") then return ev end
	local newEv = Instance.new("RemoteEvent")
	newEv.Name = "Show"
	newEv.Parent = folder
	return newEv
end)()

-- Status probe so clients can hide UI early if already owned or show remaining time.
local marbleStatus = Instance.new("RemoteFunction")
marbleStatus.Name = "GetMarbleQuestStatus"
marbleStatus.Parent = questsFolder

-- Returns a table:
-- { owned: boolean, secondsRemaining: number, liked: boolean? (nil if not attempted) }
marbleStatus.OnServerInvoke = function(player: Player)
	local owned = DataManager.hasSkin(player, MARBLE_REWARD_SKIN)
	local joinTime = playerJoinTimes[player.UserId]
	local secondsRemaining = 0
	if joinTime then
		local elapsed = tick() - joinTime
		local remaining = REQUIRED_PLAY_TIME_SECONDS - elapsed
		if remaining > 0 then secondsRemaining = math.floor(remaining) else secondsRemaining = 0 end
	else
		secondsRemaining = REQUIRED_PLAY_TIME_SECONDS
	end
	return { owned = owned, secondsRemaining = secondsRemaining }
end

claimMarbleReward.OnServerInvoke = function(player: Player)
	if DataManager.hasSkin(player, MARBLE_REWARD_SKIN) then
		return { success = false, reason = "already_owned" }
	end
	local joinTime = playerJoinTimes[player.UserId]
	if not joinTime or (tick() - joinTime) < REQUIRED_PLAY_TIME_SECONDS then
		return { success = false, reason = "time" }
	end
	-- Bypass like check in Studio, as it only works in live games.
	local hasLiked = if RunService:IsStudio() then true else false
	if not hasLiked then
		local ok, result = pcall(function()
			return MarketplaceService:PlayerHasLikedGameAsync(player)
		end)
		if ok and result then hasLiked = true end
	end

	if not hasLiked then
		return { success = false, reason = "like" }
	end
	print(string.format("[QuestManager] Granting '%s' to %s for completing the quest.", MARBLE_REWARD_SKIN, player.Name))
	DataManager.addSkin(player, MARBLE_REWARD_SKIN)
	DataManager.markDirty(player)
	if purchasedEvent then
		purchasedEvent:FireClient(player, MARBLE_REWARD_SKIN)
	end
	pcall(function()
		showNotificationEvent:FireClient(player, {
			text = string.format("You claimed the %s skin!", MARBLE_REWARD_SKIN),
			type = "Green",
			sound = "Notification"
		})
	end)
	return { success = true }
end

local function onPlayerAdded(player: Player)
	playerJoinTimes[player.UserId] = tick()
end

local function onPlayerRemoving(player: Player)
	playerJoinTimes[player.UserId] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, plr in ipairs(Players:GetPlayers()) do task.spawn(onPlayerAdded, plr) end
Players.PlayerRemoving:Connect(onPlayerRemoving)

print("[QuestManager] Ready to handle free rewards.")
