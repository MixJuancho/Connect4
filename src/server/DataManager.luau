--!strict
-- DataManager.luau (ModuleScript)
-- Central persistence layer (DataStore) for player profile data + token inventory remote.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

-- Lazy TokenConfig loading (no infinite yield if not present yet)
local TokenConfig: any
local function tryLoadTokenConfig()
	if TokenConfig then return end
	local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
	if not sharedFolder then return end
	local configs = sharedFolder:FindFirstChild("Configs")
	if not configs then return end
	local tc = configs:FindFirstChild("TokenConfig")
	if tc and tc:IsA("ModuleScript") then
		local ok, mod = pcall(function() return require(tc) end)
		if ok then
			TokenConfig = mod
		end
	end
end
tryLoadTokenConfig()

-- Also watch for later insertion
local sharedFolderRef = ReplicatedStorage:FindFirstChild("Shared")
if sharedFolderRef then
	sharedFolderRef.ChildAdded:Connect(function(child)
		if child.Name == "Configs" then
			child.ChildAdded:Connect(function(grand)
				if grand.Name == "TokenConfig" then
					tryLoadTokenConfig()
				end
			end)
			tryLoadTokenConfig()
		end
	end)
end

local PROFILE_DS = DataStoreService:GetDataStore("PlayerDataV1")

local DataManager = {}

export type Profile = {
	Version: number,
	Coins: number,
	Wins: number,
	Streak: number,
	HighestStreak: number,
	OwnedSkins: {string},
	_dirty: boolean?,
}

local DEFAULT_PROFILE: Profile = {
	Version = 1,
	Coins = 0,
	Wins = 0,
	Streak = 0,
	HighestStreak = 0,
	OwnedSkins = {"Wood"},
}

local profiles: {[number]: Profile} = {}

local function cloneTable(t)
	local new = {}
	for k,v in pairs(t) do
		if type(v) == "table" then
			local inner = {}
			for k2,v2 in pairs(v) do inner[k2]=v2 end
			new[k]=inner
		else
			new[k]=v
		end
	end
	return new
end

local function keyFor(userId: number)
	return "Player_" .. tostring(userId)
end

local function normalizeProfile(raw: any): Profile
	if type(raw) ~= "table" then
		return cloneTable(DEFAULT_PROFILE) :: Profile
	end
	for k,v in pairs(DEFAULT_PROFILE) do
		if raw[k] == nil then
			if type(v) == "table" then
				raw[k] = cloneTable(v)
			else
				raw[k] = v
			end
		end
	end
	local ownedMap: {[string]: boolean} = {}
	for _,name in ipairs(raw.OwnedSkins) do ownedMap[name]=true end
	if not ownedMap["Wood"] then table.insert(raw.OwnedSkins, "Wood") end
	return raw :: Profile
end

local function loadProfileAsync(userId: number): Profile
	local k = keyFor(userId)
	local raw
	for i=1,3 do
		local ok, result = pcall(function() return PROFILE_DS:GetAsync(k) end)
		if ok then raw = result break end
		task.wait(0.5 * i)
	end
	local profile = normalizeProfile(raw)
	profiles[userId] = profile
	return profile
end

function DataManager.getProfile(player: Player): Profile
	local pf = profiles[player.UserId]
	if not pf then
		pf = loadProfileAsync(player.UserId)
	end
	return pf
end

function DataManager.hasSkin(player: Player, skin: string): boolean
	local pf = DataManager.getProfile(player)
	for _,s in ipairs(pf.OwnedSkins) do
		if s == skin then return true end
	end
	return false
end

function DataManager.addSkin(player: Player, skin: string)
	if DataManager.hasSkin(player, skin) then return end
	local pf = DataManager.getProfile(player)
	table.insert(pf.OwnedSkins, skin)
	pf._dirty = true
end

function DataManager.addCoins(player: Player, delta: number)
	local pf = DataManager.getProfile(player)
	pf.Coins = math.max(0, pf.Coins + delta)
	pf._dirty = true
end

function DataManager.setStatFromLeaderstat(player: Player, name: string, value: number)
	local pf = DataManager.getProfile(player)
	if pf[name] ~= nil then
		pf[name] = value
		pf._dirty = true
	end
end

function DataManager.markDirty(player: Player)
	local pf = DataManager.getProfile(player)
	pf._dirty = true
end

local function saveProfile(userId: number)
	local pf = profiles[userId]
	if not pf or not pf._dirty then return true end
	pf._dirty = false
	local k = keyFor(userId)
	local toSave = cloneTable(pf)
	toSave._dirty = nil
	for i=1,3 do
		local ok = pcall(function()
			PROFILE_DS:UpdateAsync(k, function(old)
				local merged = normalizeProfile(old)
				merged.Coins = toSave.Coins
				merged.Wins = toSave.Wins
				merged.Streak = toSave.Streak
				merged.HighestStreak = math.max(merged.HighestStreak, toSave.HighestStreak)
				local set: {[string]: boolean} = {}
				for _,s in ipairs(merged.OwnedSkins) do set[s]=true end
				for _,s in ipairs(toSave.OwnedSkins) do set[s]=true end
				local list = {}
				for s,_ in pairs(set) do table.insert(list,s) end
				merged.OwnedSkins = list
				return merged
			end)
		end)
		if ok then return true end
		task.wait(0.75 * i)
	end
	pf._dirty = true
	return false
end

function DataManager.forceSave(player: Player)
	return saveProfile(player.UserId)
end

-- Autosave
spawn(function()
	while true do
		for userId,_ in pairs(profiles) do
			saveProfile(userId)
		end
		task.wait(60)
	end
end)

Players.PlayerRemoving:Connect(function(plr)
	local ok = saveProfile(plr.UserId)
	if not ok then saveProfile(plr.UserId) end
end)

game:BindToClose(function()
	for userId,_ in pairs(profiles) do
		saveProfile(userId)
	end
end)

-- Remote for token inventory
local function ensureTokenConfig()
	if not TokenConfig then tryLoadTokenConfig() end
end

local invFolder = ReplicatedStorage:FindFirstChild("TokenInventory")
if not invFolder then
	invFolder = Instance.new("Folder")
	invFolder.Name = "TokenInventory"
	invFolder.Parent = ReplicatedStorage
end
local remote = invFolder:FindFirstChild("Request") :: RemoteFunction?
if not remote then
	remote = Instance.new("RemoteFunction")
	remote.Name = "Request"
	remote.Parent = invFolder
end

local function tryPurchase(plr: Player, skin: string)
	ensureTokenConfig()
	if not TokenConfig then return false, "Config missing" end
	local meta = TokenConfig[skin]
	if not meta then return false, "Unknown skin" end
	if not meta.costCoins then return false, "Not purchasable with coins" end
	if DataManager.hasSkin(plr, skin) then return false, "Already owned" end
	local pf = DataManager.getProfile(plr)
	if pf.Coins < meta.costCoins then return false, "Not enough coins" end
	pf.Coins -= meta.costCoins
	DataManager.addSkin(plr, skin)
	DataManager.markDirty(plr)
	local ls = plr:FindFirstChild("leaderstats")
	local coins = ls and ls:FindFirstChild("Coins")
	if coins and coins:IsA("IntValue") then coins.Value = pf.Coins end
	return true, "Purchased"
end

-- Public coin purchase helper (used by shop proximity prompt)
function DataManager.purchaseSkinCoins(plr: Player, skin: string)
	return tryPurchase(plr, skin)
end

if remote then
	remote.OnServerInvoke = function(plr, payload)
		local action = payload and payload.action
		if action == "List" then
			ensureTokenConfig()
			local pf = DataManager.getProfile(plr)
			local owned = {}
			for _,s in ipairs(pf.OwnedSkins) do table.insert(owned, s) end
			local allList = (TokenConfig and TokenConfig.AllSkinNames) or {}
			return { owned = owned, all = allList, coins = pf.Coins }
		elseif action == "Purchase" then
			local skin = payload.skin
			local ok, msg = tryPurchase(plr, skin)
			return { success = ok, message = msg }
		elseif action == "Equip" then
				local skin = payload.skin
				-- Allow unequip (nil or empty string)
				if skin == nil or skin == "" then
					plr:SetAttribute("TokenSkin", nil)
					return { success = true, unequipped = true }
				end
				if DataManager.hasSkin(plr, skin) then
					plr:SetAttribute("TokenSkin", skin)
					return { success = true }
				else
					return { success = false, message = "Not owned" }
				end
		end
		return { success = false, message = "Unknown action" }
	end
end

return DataManager
