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
	Blackhole = { productId = 0, note = "Set productId for 79 Robux" },
	Fire = { productId = 0, note = "Set productId for 49 Robux" },
	Glitch = { productId = 0, note = "Set productId for 39 Robux" },
	Marble = { quest = "Play15MinutesLike", note = "Earned by staying 15 minutes and liking the game" },
	VIP = { gamepassId = 0, note = "Set VIP gamepass id" },
}

-- List of all skin names (cached)
local allNames: {string} = {}
for name, _ in pairs(M) do
	table.insert(allNames, name)
end

M.AllSkinNames = allNames

return M
