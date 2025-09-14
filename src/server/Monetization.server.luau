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

-- Notification infrastructure (central RemoteEvent + global relay)
local notificationsFolder = ReplicatedStorage:FindFirstChild("Notifications")
if not notificationsFolder then
	notificationsFolder = Instance.new("Folder")
	notificationsFolder.Name = "Notifications"
	notificationsFolder.Parent = ReplicatedStorage
end
local showNotificationEvent: RemoteEvent = (function()
	local ev = notificationsFolder:FindFirstChild("Show")
	if ev and ev:IsA("RemoteEvent") then return ev end
	local newEv = Instance.new("RemoteEvent")
	newEv.Name = "Show"
	newEv.Parent = notificationsFolder
	return newEv
end)()

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

-- RemoteEvent for immediate gamepass purchase notification (client -> server)
local monetizationFolder = ReplicatedStorage:FindFirstChild("Monetization")
if not monetizationFolder then
	monetizationFolder = Instance.new("Folder")
	monetizationFolder.Name = "Monetization"
	monetizationFolder.Parent = ReplicatedStorage
end
local gamepassPurchasedEvent: RemoteEvent = (
	function()
		local ev = monetizationFolder:FindFirstChild("GamepassPurchased")
		if ev and ev:IsA("RemoteEvent") then return ev end
		local newEv = Instance.new("RemoteEvent")
		newEv.Name = "GamepassPurchased"
		newEv.Parent = monetizationFolder
		return newEv
	end
)()

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
	local rainAreaFolder = workspace:FindFirstChild("RainArea")
	if not rainAreaFolder then
		warn("[CoinRain] Could not start coin rain: 'RainArea' folder not found in Workspace.")
		return
	end

	-- Calculate total area for weighted random selection
	local weightedZones: {{part: BasePart, cumulativeArea: number}} = {}
	local totalArea = 0
	for _, zone in ipairs(rainAreaFolder:GetChildren()) do
		if zone:IsA("BasePart") then
			local area = zone.Size.X * zone.Size.Z
			if area > 0 then -- Ignore parts with no surface area
				totalArea += area
				table.insert(weightedZones, { part = zone, cumulativeArea = totalArea })
			end
		end
	end

	if #weightedZones == 0 then
		warn("[CoinRain] Could not start coin rain: 'RainArea' folder in Workspace has no valid BasePart children with surface area > 0.")
		return
	end

	local endTime = tick() + duration

	local debrisFolder = Instance.new("Folder")
	debrisFolder.Name = "_CoinRain_"..tostring(os.time())
	debrisFolder.Parent = workspace

	-- Locate coin template once for efficiency. Designers can place a customizable
	-- part / mesh / model named "CoinRain" under ReplicatedStorage/Assets.
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local coinTemplateSource = assets and assets:FindFirstChild("CoinRain")
	local coinTemplate: BasePart? = nil
	if coinTemplateSource then
		if coinTemplateSource:IsA("BasePart") then
			coinTemplate = coinTemplateSource
		elseif coinTemplateSource:IsA("Model") or coinTemplateSource:IsA("Folder") then
			coinTemplate = coinTemplateSource:FindFirstChildWhichIsA("BasePart", true)
		end
	end
	local warnedFallback = false

	-- Helper to pick a random zone, weighted by its surface area.
	-- Larger zones will be picked more often.
	local function pickWeightedZone(): BasePart
		local rand = math.random() * totalArea
		for _, zoneInfo in ipairs(weightedZones) do
			if rand <= zoneInfo.cumulativeArea then
				return zoneInfo.part
			end
		end
		-- Fallback in case of floating point inaccuracies, return the last zone.
		return weightedZones[#weightedZones].part
	end

	local function spawnOne()
		local part: BasePart
		if coinTemplate then
			part = coinTemplate:Clone()
		else
			-- Fallback: create a simple neon gold sphere like the original implementation
			local fallback = Instance.new("Part")
			fallback.Shape = Enum.PartType.Ball
			fallback.Material = Enum.Material.Neon
			fallback.Color = Color3.fromRGB(255, 215, 0)
			fallback.Size = Vector3.new(1,1,1)
			part = fallback
			if not warnedFallback then
				warnedFallback = true
				warn("[CoinRain] Using fallback part; place a BasePart (or Model with a BasePart descendant) named 'CoinRain' under ReplicatedStorage/Assets for custom visuals.")
			end
		end

		-- Common properties applied to both cloned template and fallback
		part.Anchored = false
		part.Name = "RainCoin"
		if part:IsA("BasePart") then
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
		end

		-- Pick a random zone (weighted by area) and spawn a coin within its bounds
		local zone = pickWeightedZone()
		local rx = (math.random() - 0.5) * zone.Size.X
		local rz = (math.random() - 0.5) * zone.Size.Z
		local dropHeight = 25 + math.random()*10
		part.CFrame = zone.CFrame * CFrame.new(rx, dropHeight, rz)

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

-- Global notification subscription (relay to all clients on this server)
pcall(function()
	MessagingService:SubscribeAsync("GlobalNotificationV1", function(message)
		local data = message.Data
		if typeof(data) == "table" and data.text and data.type then
			pcall(function()
				-- Relay UI notification to all clients on this server
				showNotificationEvent:FireAllClients(data)
				-- Also display system message in chat if provided in the payload
				if typeof(data.systemMessage) == "string" and data.systemMessage ~= "" then
					TextChatService.TextChannels.RBXGeneral:DisplaySystemMessage(data.systemMessage)
				end
			end)
		end
	end)
end)

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
					-- For one-time purchases like StarterPack, check if already owned.
					if info.grantSkin then -- Assuming packs that grant skins are one-time.
						if DataManager.hasOneTimePurchase(player, info.uiKey) then
							print(("[Monetization] Player %s already owns one-time item '%s'. Purchase granted without reward."):format(player.Name, info.uiKey))
							return
						end
					end
					awardCoins(player, info.amount)
					if info.grantSkin and DataManager and DataManager.addSkin then
						DataManager.addSkin(player, info.grantSkin)
						if purchasedEvent then
							purchasedEvent:FireClient(player, info.grantSkin)
						end
						DataManager.addOneTimePurchase(player, info.uiKey)
					end
					-- Notification
					local notificationText
					if info.uiKey == "StarterPack" then
						notificationText = "You bought the Starter Pack!"
					else
						notificationText = string.format("You purchased %s coins!", tostring(info.amount))
					end
					pcall(function()
						showNotificationEvent:FireClient(player, {
							text = notificationText,
							type = "Green",
							sound = "Purchase"
						})
					end)
					DataManager.markDirty(player)
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
					if DataManager.hasSkin(player, info.skin) then
						print(("[Monetization] Player %s already owns skin '%s'. Purchase granted without reward."):format(player.Name, info.skin))
						pcall(function()
							showNotificationEvent:FireClient(player, {
								text = "You already own this skin!",
								type = "Normal",
								sound = "Notification"
							})
						end)
						return
					end

					if DataManager and DataManager.addSkin then
						DataManager.addSkin(player, info.skin)
						if purchasedEvent then
							purchasedEvent:FireClient(player, info.skin)
						end
					end
					pcall(function()
						showNotificationEvent:FireClient(player, {
							text = string.format("You purchased the %s skin!", info.skin),
							type = "Green",
							sound = "Purchase"
						})
					end)
					DataManager.markDirty(player)
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
				PRODUCT_HANDLERS[pid] = function(player)
					if info.type == "ServerCoinRain" then
						triggerServerCoinRain(info.duration, info.coinCount)
						local message = string.format("[SERVER] %s started a Coin Rain!", player.Name)
						pcall(function()
							showNotificationEvent:FireAllClients({
								text = message,
								type = "Normal",
								sound = "Notification"
							})
							TextChatService.TextChannels.RBXGeneral:DisplaySystemMessage(message)
						end)
					elseif info.type == "GlobalCoinRain" then
						triggerGlobalCoinRain(info.duration, info.coinCount)
						-- Construct messages once
						local uiText = string.format("%s started a Global Coin Rain!", player.Name)
						local systemMessage = string.format("[GLOBAL] %s started a Global Coin Rain!", player.Name)
						-- Publish global notification for other servers
						pcall(function()
							MessagingService:PublishAsync("GlobalNotificationV1", {
								text = uiText,
								systemMessage = systemMessage,
								type = "Normal",
								sound = "Notification"
							})
						end)
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
				pcall(function()
					showNotificationEvent:FireClient(player, {
						text = string.format("You purchased the %s skin!", skinName),
						type = "Green",
						sound = "Purchase"
					})
				end)
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
			-- Set chat tag attribute for VIP players (consumed by ChatTagManager)
			if isVIP(player) then
				player:SetAttribute("ChatTag", "VIP")
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

-- VIP Chat Tag attribute (consumed by a separate chat formatter) ----
pcall(function()
	if TextChatService and TextChatService:FindFirstChild("ChatInputBarConfiguration") then
		for _, plr in ipairs(Players:GetPlayers()) do
			if isVIP(plr) then plr:SetAttribute("ChatTag", "VIP") end
		end
		Players.PlayerAdded:Connect(function(plr)
			if isVIP(plr) then plr:SetAttribute("ChatTag", "VIP") end
		end)
	end
end)

-- Immediate gamepass perk granting after client notifies purchase ----
local function grantGamepassPerks(player: Player, gpId: number)
	-- Re-validate ownership server-side
	if not ownsGamepassAsync(player, gpId) then
		warn(string.format("[Monetization] Player %s attempted to claim gamepass %d but does not own it.", player.Name, gpId))
		return
	end

	-- VIP perks
	if vipGamepassId and gpId == vipGamepassId then
		if vipSkinName and DataManager and DataManager.addSkin and DataManager.hasSkin then
			if not DataManager.hasSkin(player, vipSkinName) then
				DataManager.addSkin(player, vipSkinName)
				if purchasedEvent then
					purchasedEvent:FireClient(player, vipSkinName)
				end
			end
		end
		player:SetAttribute("ChatTag", "VIP")
		print(string.format("[Monetization] Granted VIP perks to %s (gamepass %d)", player.Name, gpId))
		pcall(function()
			showNotificationEvent:FireClient(player, {
				text = "You unlocked the VIP Gamepass!",
				type = "Green",
				sound = "Purchase"
			})
		end)
	end

	-- Tool gamepasses
	local toolName = toolGamepasses[gpId]
	if toolName then
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local gear = assets and assets:FindFirstChild("Gear")
		if gear then
			local tool = gear:FindFirstChild(toolName)
			if tool and tool:IsA("Tool") then
				if not player.Backpack:FindFirstChild(toolName) and not (player.Character and player.Character:FindFirstChild(toolName)) then
					local clone = tool:Clone()
					clone.Parent = player.Backpack
					print(string.format("[Monetization] Granted tool '%s' to %s (gamepass %d)", toolName, player.Name, gpId))
				end
			end
		end
	end
end

gamepassPurchasedEvent.OnServerEvent:Connect(function(player, gpId)
	if typeof(gpId) == "number" then
		grantGamepassPerks(player, gpId)
	end
end)

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
	pcall(function()
		showNotificationEvent:FireAllClients({
			text = "A Coin Rain has started!",
			type = "Normal",
			sound = "Notification"
		})
	end)
end
function API.GlobalCoinRain(duration: number?, coinCount: number?)
	triggerGlobalCoinRain(duration, coinCount)
	pcall(function()
		MessagingService:PublishAsync("GlobalNotificationV1", {
			text = "A Global Coin Rain has started!",
			type = "Normal",
			sound = "Notification"
		})
	end)
end

return API
