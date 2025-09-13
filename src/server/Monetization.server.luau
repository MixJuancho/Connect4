--!strict
-- Clean Monetization.server.luau (reconstructed after corruption)
-- Handles Developer Products, Gamepasses, VIP perks, and server/global coin rain.

local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MessagingService = game:GetService("MessagingService")
local TextChatService = game:GetService("TextChatService")

local RECEIPT_DS = DataStoreService:GetDataStore("ProcessedReceiptsV1")
local COIN_RAIN_TOPIC = "GlobalCoinRainV1"

local DataManager = require(script.Parent:WaitForChild("DataManager"))

-- Load configs -----------------------------------------------------
local function safeRequire(moduleScript: ModuleScript?): any
	if not moduleScript then return nil end
	local ok, mod = pcall(function() return require(moduleScript) end)
	if ok then return mod end
	return nil
end

local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
local configsFolder = sharedFolder and sharedFolder:FindFirstChild("Configs")
local TokenConfig = safeRequire(configsFolder and configsFolder:FindFirstChild("TokenConfig") :: ModuleScript?) or {}
local MonetizationConfig = safeRequire(configsFolder and configsFolder:FindFirstChild("MonetizationConfig") :: ModuleScript?) or {}

-- RemoteEvent for immediate client skin list refresh (also used by TokenShop)
local invFolder = ReplicatedStorage:FindFirstChild("TokenInventory")
local purchasedEvent: RemoteEvent? = nil
if invFolder then
	purchasedEvent = invFolder:FindFirstChild("Purchased") :: RemoteEvent?
	if not purchasedEvent then
		purchasedEvent = Instance.new("RemoteEvent")
		purchasedEvent.Name = "Purchased"
		purchasedEvent.Parent = invFolder
	end
end

-- Tables -----------------------------------------------------------
local PRODUCT_HANDLERS: {[number]: (player: Player, receipt: any?)->() } = {}
local vipGamepassId: number? = nil
local vipSkinName: string? = nil
local toolGamepasses: {[number]: string} = {}

-- Helpers ----------------------------------------------------------
local function awardCoins(player: Player, amount: number)
	if amount <= 0 then return end
	if DataManager and DataManager.addCoins then
		DataManager.addCoins(player, amount)
		local profile = DataManager.getProfile(player)
		if profile and profile.Coins then
			player:SetAttribute("Coins", profile.Coins)
		end
	else
		player:SetAttribute("Coins", (player:GetAttribute("Coins") or 0) + amount)
	end
end

-- Gamepasses -------------------------------------------------------
local function initGamepasses()
	local gpTable = (MonetizationConfig and MonetizationConfig.Gamepasses) or (TokenConfig and TokenConfig.Gamepasses)
	if not gpTable then return end
	for key, info in pairs(gpTable) do
		if typeof(info) == "table" then
			local gpid = tonumber(info.gamepassId)
			if gpid then
				if key == "VIP" then
					vipGamepassId = gpid
					vipSkinName = info.vipSkin or (TokenConfig.Gamepasses and TokenConfig.Gamepasses.VIP and TokenConfig.Gamepasses.VIP.vipSkin) or "VIP"
				elseif info.toolName then
					toolGamepasses[gpid] = info.toolName
				end
			end
		end
	end
end
initGamepasses()

local function ownsGamepassAsync(player: Player, gpId: number): boolean
	local ok, res = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gpId)
	end)
	return ok and res
end

local function isVIP(player: Player): boolean
	if not vipGamepassId then return false end
	return ownsGamepassAsync(player, vipGamepassId)
end
_G.Connect4_IsPlayerVIP = isVIP

-- Coin Rain --------------------------------------------------------
local function spawnCoinRain(duration: number, coinCount: number, awardPerCoin: number)
	local base = workspace:FindFirstChild("Baseplate") or workspace:FindFirstChildWhichIsA("Terrain")
	if not base then return end
	local areaCFrame = if base:IsA("BasePart") then base.CFrame else CFrame.new()
	local areaSize = if base:IsA("BasePart") then base.Size else Vector3.new(300,0,300)
	local endTime = tick() + duration
	local debrisFolder = Instance.new("Folder")
	debrisFolder.Name = "_CoinRain_"..tostring(os.time())
	debrisFolder.Parent = workspace

	local function spawnOne()
		local part = Instance.new("Part")
		part.Anchored = false
		part.Size = Vector3.new(1,1,1)
		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 215, 0)
		part.Name = "RainCoin"
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		local rx = (math.random()-0.5) * (areaSize.X * 0.8)
		local rz = (math.random()-0.5) * (areaSize.Z * 0.8)
		local dropHeight = 25 + math.random()*10
		part.CFrame = areaCFrame + Vector3.new(rx, dropHeight, rz)
		part.Parent = debrisFolder
		local touchedConn
		local claimed = false
		touchedConn = part.Touched:Connect(function(hit)
			if claimed then return end
			local char = hit and hit.Parent
			local plr = char and Players:GetPlayerFromCharacter(char)
			if plr then
				claimed = true
				awardCoins(plr, awardPerCoin)
				part:Destroy()
				if touchedConn then touchedConn:Disconnect() end
			end
		end)
	end

	task.spawn(function()
		local spawnInterval = duration / math.max(coinCount,1)
		while tick() < endTime and coinCount > 0 do
			spawnOne()
			coinCount -= 1
			task.wait(spawnInterval)
		end
		task.delay(15, function()
			if debrisFolder then debrisFolder:Destroy() end
		end)
	end)
end

local function triggerServerCoinRain(duration: number?, coinCount: number?)
	spawnCoinRain(duration or 20, coinCount or 80, 1)
end

local function triggerGlobalCoinRain(duration: number?, coinCount: number?)
	local ok, err = pcall(function()
		MessagingService:PublishAsync(COIN_RAIN_TOPIC, { at = os.time(), duration = duration, coinCount = coinCount })
	end)
	if not ok then
		warn("[Monetization] Publish global coin rain failed: ".. tostring(err))
	end
	triggerServerCoinRain(duration, coinCount) -- run locally too
end

local subscribed = false
local function ensureSubscribe()
	if subscribed then return end
	subscribed = true
	pcall(function()
		MessagingService:SubscribeAsync(COIN_RAIN_TOPIC, function(msg)
			local data = msg.Data or {}
			triggerServerCoinRain(data.duration, data.coinCount)
		end)
	end)
end
ensureSubscribe()

-- Product Handlers -------------------------------------------------
local function buildProductHandlers()
	local products = (MonetizationConfig and MonetizationConfig.Products) or (TokenConfig and TokenConfig.Products)
	if not products then return end
	-- Coin packs (includes StarterPack)
	local packs = products.CoinPacks
	if packs then
		for _, info in pairs(packs) do
			if typeof(info) == "table" and tonumber(info.productId) and tonumber(info.amount) then
				local pid = info.productId
				PRODUCT_HANDLERS[pid] = function(player)
					awardCoins(player, info.amount)
					if info.grantSkin and DataManager and DataManager.addSkin then
						DataManager.addSkin(player, info.grantSkin)
						if purchasedEvent then
							purchasedEvent:FireClient(player, info.grantSkin)
						end
					end
				end
			end
		end
	end
	-- Skins
	local skins = products.Skins
	if skins then
		for _, info in pairs(skins) do
			if typeof(info) == "table" and tonumber(info.productId) and info.skin then
				local pid = info.productId
				PRODUCT_HANDLERS[pid] = function(player)
					if DataManager and DataManager.addSkin then
						DataManager.addSkin(player, info.skin)
						if purchasedEvent then
							purchasedEvent:FireClient(player, info.skin)
						end
					end
				end
			end
		end
	end
	-- Effects
	local effects = products.Effects
	if effects then
		for _, info in pairs(effects) do
			if typeof(info) == "table" and tonumber(info.productId) and info.type then
				local pid = info.productId
				PRODUCT_HANDLERS[pid] = function(_player)
					if info.type == "ServerCoinRain" then
						triggerServerCoinRain(info.duration, info.coinCount)
					elseif info.type == "GlobalCoinRain" then
						triggerGlobalCoinRain(info.duration, info.coinCount)
					end
				end
			end
		end
	end
end
buildProductHandlers()

-- Fallback legacy simple skin entries on TokenConfig root ----------
for skinName, meta in pairs(TokenConfig) do
	if typeof(meta) == "table" and tonumber((meta :: any).productId) and (meta :: any).productId > 0 then
		local pid = (meta :: any).productId :: number
		if not PRODUCT_HANDLERS[pid] then
			PRODUCT_HANDLERS[pid] = function(player)
				if DataManager and DataManager.addSkin then
					DataManager.addSkin(player, skinName)
				end
			end
		end
	end
end

-- Receipt idempotency ----------------------------------------------
local function markReceiptProcessed(purchaseId: string)
	for i = 1,3 do
		local ok, err = pcall(function()
			RECEIPT_DS:SetAsync(purchaseId, true)
		end)
		if ok then return true end
		warn("[Monetization] Failed to mark receipt processed attempt "..i..": ".. tostring(err))
		task.wait(0.5 * i)
	end
	return false
end

local function isReceiptProcessed(purchaseId: string): boolean
	local ok, res = pcall(function() return RECEIPT_DS:GetAsync(purchaseId) end)
	return ok and res == true
end

-- Player handling --------------------------------------------------
local function onPlayerAdded(player: Player)
	task.defer(function()
		if isVIP(player) and vipSkinName and DataManager and DataManager.addSkin and DataManager.hasSkin then
			if not DataManager.hasSkin(player, vipSkinName) then
				DataManager.addSkin(player, vipSkinName)
			end
		end
	end)
	player.CharacterAdded:Connect(function(char)
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local gear = assets and assets:FindFirstChild("Gear")
		if not gear then return end
		for gpId, toolName in pairs(toolGamepasses) do
			if ownsGamepassAsync(player, gpId) then
				local tool = gear:FindFirstChild(toolName)
				if tool and tool:IsA("Tool") then
					if not player.Backpack:FindFirstChild(toolName) and not char:FindFirstChild(toolName) then
						local clone = tool:Clone()
						clone.Parent = player.Backpack
					end
				end
			end
		end
	end)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, plr in ipairs(Players:GetPlayers()) do task.spawn(onPlayerAdded, plr) end

-- ProcessReceipt ---------------------------------------------------
function MarketplaceService.ProcessReceipt(receiptInfo)
	local purchaseId = receiptInfo.PurchaseId
	if isReceiptProcessed(purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local handler = PRODUCT_HANDLERS[receiptInfo.ProductId]
	if handler then
		local ok, err = pcall(function()
			handler(player, receiptInfo)
		end)
		if not ok then
			warn("[Monetization] Handler error for product ".. receiptInfo.ProductId ..": ".. tostring(err))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end
	markReceiptProcessed(purchaseId)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Public API -------------------------------------------------------
local API = {}
function API.ServerCoinRain(duration: number?, coinCount: number?)
	triggerServerCoinRain(duration, coinCount)
end
function API.GlobalCoinRain(duration: number?, coinCount: number?)
	triggerGlobalCoinRain(duration, coinCount)
end

return API
