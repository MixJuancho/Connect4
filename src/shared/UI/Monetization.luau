--!strict
-- shared/UI/Monetization.luau
-- Client-side helper to wire GUI buttons to Developer Product & Gamepass purchase prompts.
-- Usage:
--   local Monetization = require(ReplicatedStorage.Shared.UI.Monetization)
--   Monetization.init({ mappings = { {path={"Frames","Shop","SmallPack"}, product="Small"}, ... } })
-- Automatically resolves productId / gamepassId from replicated MonetizationConfig (if present).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local localPlayer = Players.LocalPlayer

local MonetizationConfig: any = nil
local function loadConfig()
	if MonetizationConfig then return end
	local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
	if not sharedFolder then return end
	local configs = sharedFolder:FindFirstChild("Configs")
	if not configs then return end
	local mod = configs:FindFirstChild("MonetizationConfig")
	if mod and mod:IsA("ModuleScript") then
		local ok, cfg = pcall(function() return require(mod) end)
		if ok then MonetizationConfig = cfg end
	end
end
loadConfig()

local M = {}

local DEBUG = true -- set false to silence logs
local lastPromptTime = 0
local PROMPT_COOLDOWN = 1.0

local function dprint(...)
	if DEBUG then
		print("[MonetizationUI]", ...)
	end
end

-- Attempts to resolve a path inside ANY ScreenGui under PlayerGui.
local function findGui(path: {string}): Instance?
	local pg = localPlayer:FindFirstChild("PlayerGui")
	if not pg then return nil end
	-- Fast path: if first segment exists directly (rare layout)
	local first = path[1]
	if pg:FindFirstChild(first) then
		local cur: Instance? = pg
		for _, seg in ipairs(path) do
			if not cur then return nil end
			cur = cur:FindFirstChild(seg)
		end
		return cur
	end
	-- Broad search across each ScreenGui
	for _, child in ipairs(pg:GetChildren()) do
		if child:IsA("ScreenGui") then
			local cur: Instance? = child
			local ok = true
			for _, seg in ipairs(path) do
				if not cur then ok = false break end
				cur = cur:FindFirstChild(seg)
				if not cur then ok = false break end
			end
			if ok and cur then return cur end
		end
	end
	return nil
end

local function getProductId(name: string): number?
	if not MonetizationConfig then return nil end
	local packs = MonetizationConfig.Products and MonetizationConfig.Products.CoinPacks
	local skins = MonetizationConfig.Products and MonetizationConfig.Products.Skins
	local effects = MonetizationConfig.Products and MonetizationConfig.Products.Effects
	for _,tbl in ipairs({packs, skins, effects}) do
		if tbl and tbl[name] and tonumber(tbl[name].productId) and tbl[name].productId > 0 then
			return tbl[name].productId
		end
	end
	return nil
end

local function getGamepassId(key: string): number?
	if not MonetizationConfig or not MonetizationConfig.Gamepasses then return nil end
	local info = MonetizationConfig.Gamepasses[key]
	if info and tonumber(info.gamepassId) and info.gamepassId > 0 then
		return info.gamepassId
	end
	return nil
end

-- mapping entry format:
-- { path={...}, product="Small" } OR { path={...}, skin="Blackhole" } OR { path={...}, effect="ServerRain" } OR { path={...}, gamepass="VIP" }
function M.init(opts)
	loadConfig()
	local mappings = opts and opts.mappings or {}
	dprint("Init with", #mappings, "mappings. Config loaded:", MonetizationConfig ~= nil)

	local pending = {}
	for i, map in ipairs(mappings) do pending[i] = map end

	local startTime = tick()
	local TIMEOUT = 10 -- seconds to keep retrying for GUI elements
	local attempt = 0
	while next(pending) and (tick() - startTime) < TIMEOUT do
		attempt += 1
		for i, map in pairs(pending) do
			local inst = findGui(map.path)
			if inst and inst:IsA("GuiButton") then
				local pathStr = table.concat(map.path, ".")
				if inst:GetAttribute("_MonetizationBound") then
					pending[i] = nil
				else
					inst:SetAttribute("_MonetizationBound", true)
					local targetKind, targetName, resolvedId
					if map.product then
						targetKind = "Product"; targetName = map.product; resolvedId = getProductId(map.product)
					elseif map.skin then
						targetKind = "Skin"; targetName = map.skin; resolvedId = getProductId(map.skin)
					elseif map.effect then
						targetKind = "Effect"; targetName = map.effect; resolvedId = getProductId(map.effect)
					elseif map.gamepass then
						targetKind = "Gamepass"; targetName = map.gamepass; resolvedId = getGamepassId(map.gamepass)
					end
					if not resolvedId then
						warn(string.format("[MonetizationUI] No ID resolved for %s '%s' (path=%s). Check MonetizationConfig.", targetKind or "?", targetName or "?", pathStr))
					else
						dprint(string.format("Bound %s '%s' -> id %d (%s) on attempt %d", targetKind or "?", targetName or "?", resolvedId, pathStr, attempt))
					end
					inst.Activated:Connect(function()
						if tick() - lastPromptTime < PROMPT_COOLDOWN then
							dprint("Prompt throttled")
							return
						end
						if map.gamepass then
							local gid = getGamepassId(map.gamepass)
							if not gid then
								warn("[MonetizationUI] Missing gamepass id for", map.gamepass)
								return
							end
							dprint("PromptGamePassPurchase", gid)
							MarketplaceService:PromptGamePassPurchase(localPlayer, gid)
						else
							local pid
							if map.product then pid = getProductId(map.product) end
							if map.skin then pid = getProductId(map.skin) end
							if map.effect then pid = getProductId(map.effect) end
							if not pid then
								warn("[MonetizationUI] Missing product id for mapping", pathStr)
								return
							end
							dprint("PromptProductPurchase", pid)
							MarketplaceService:PromptProductPurchase(localPlayer, pid)
						end
						lastPromptTime = tick()
					end)
					pending[i] = nil
				end
			end
		end
		if next(pending) then
			task.wait(0.3)
		end
	end
	for i, map in pairs(pending) do
		warn("[MonetizationUI] Button still missing after retries:", table.concat(map.path, "."))
	end
end

-- Manual debug helper: force a prompt from the console
function M.debugForcePrompt(kind: string, name: string)
	loadConfig()
	if kind == "gamepass" then
		local gid = getGamepassId(name)
		if gid then
			dprint("Force gamepass prompt", gid)
			MarketplaceService:PromptGamePassPurchase(localPlayer, gid)
		else
			warn("[MonetizationUI] debugForcePrompt: unresolved gamepass", name)
		end
	else
		local pid = getProductId(name)
		if pid then
			dprint("Force product prompt", pid)
			MarketplaceService:PromptProductPurchase(localPlayer, pid)
		else
			warn("[MonetizationUI] debugForcePrompt: unresolved product/effect/skin", name)
		end
	end
end

return M
