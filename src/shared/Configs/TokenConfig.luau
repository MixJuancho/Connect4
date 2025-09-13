--!strict
-- TokenConfig.luau
-- Central metadata for token skins.
-- Fields:
--  costCoins: number? (nil if not purchasable with coins)
--  productId: number? (Developer Product for Robux purchase skins)
--  gamepassId: number? (Gamepass required to unlock)
--  quest: string? (identifier for special unlock condition)
--  free: boolean? (granted automatically)
--  note: string? (extra info)

local M = {
	Wood = { costCoins = 150 },
	Ice = { costCoins = 250 },
	Magma = { costCoins = 350 },
	["Coin"] = { costCoins = 450 },
	Neon = { costCoins = 600 },
	Noob = { costCoins = 900 },
	["Yin&Yan"] = { costCoins = 1500 },
	Blackhole = { productId = 3402976137, note = "79 Robux Blackhole skin" },
	Fire = { productId = 3402976328, note = "49 Robux Fire skin" },
	Glitch = { productId = 3402976482, note = "39 Robux Glitch skin" },
	Marble = { quest = "Play15MinutesLike", note = "Earned by staying 15 minutes and liking the game" },
	VIP = { gamepassId = 1462168838, note = "VIP gamepass" },
}

-- List of all skin names (cached)
local allNames: {string} = {}
for name, _ in pairs(M) do
	table.insert(allNames, name)
end

M.AllSkinNames = allNames

return M
