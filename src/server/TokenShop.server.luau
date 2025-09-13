--!strict
-- TokenShop.server.luau
-- Handles proximity prompt purchases from Workspace.TokenShop.Coins and Workspace.TokenShop.Robux descendants.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local DataManager = require(script.Parent:WaitForChild("DataManager"))

local shopRoot = Workspace:FindFirstChild("TokenShop")
if not shopRoot then
	warn("[TokenShop] TokenShop folder missing in Workspace")
	return
end

local coinsFolder = shopRoot:FindFirstChild("Coins")
local robuxFolder = shopRoot:FindFirstChild("Robux")

-- RemoteEvent to notify client UIs of newly purchased skins so they can refresh instantly
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

-- Helper to attach prompt listeners recursively
local function attach(folder: Instance, kind: string)
	for _, inst in ipairs(folder:GetDescendants()) do
		if inst:IsA("ProximityPrompt") then
			local skinName = inst.Parent and inst.Parent.Name or inst.Name
			inst.Triggered:Connect(function(player)
				if kind == "Coins" then
					local ok, msg = DataManager.purchaseSkinCoins(player, skinName)
					if not ok then
						print("[TokenShop] Purchase failed for", player.Name, skinName, msg)
					else
						print("[TokenShop] Purchased", skinName, "for", player.Name)
						if purchasedEvent then
							purchasedEvent:FireClient(player, skinName)
						end
					end
				elseif kind == "Robux" then
					-- Future: Developer Product / Gamepass logic
					print("[TokenShop] Robux purchase path not implemented for", skinName)
				end
			end)
		end
	end
end

if coinsFolder then attach(coinsFolder, "Coins") end
if robuxFolder then attach(robuxFolder, "Robux") end

-- Handle dynamic additions
shopRoot.DescendantAdded:Connect(function(inst)
	if inst:IsA("ProximityPrompt") then
		local parent = inst.Parent
		if not parent then return end
		local kind = parent:IsDescendantOf(coinsFolder or parent) and "Coins" or (parent:IsDescendantOf(robuxFolder or parent) and "Robux" or "")
		if kind ~= "" then
			local skinName = parent.Name
			inst.Triggered:Connect(function(player)
				if kind == "Coins" then
					local ok, msg = DataManager.purchaseSkinCoins(player, skinName)
					if not ok then
						print("[TokenShop] Purchase failed for", player.Name, skinName, msg)
					else
						print("[TokenShop] Purchased", skinName, "for", player.Name)
						if purchasedEvent then
							purchasedEvent:FireClient(player, skinName)
						end
					end
				else
					print("[TokenShop] Robux purchase path not implemented for", skinName)
				end
			end)
		end
	end
end)
