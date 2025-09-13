--!strict
-- MonetizationConfig.luau
-- Central configuration for Developer Products, Gamepasses, and special effect purchases.
-- Fill in real productId / gamepassId values in Studio (they must be published first).
-- Any productId or gamepassId left as 0 will be ignored by purchase logic.

-- Schema:
-- return {
--   Products = {
--       CoinPacks = { Name = { productId = number, amount = number } },
--       Skins     = { SkinName = { productId = number, skin = "SkinName" } },
--       Effects   = { Entry = { productId = number, type = "ServerCoinRain" | "GlobalCoinRain" } },
--   },
--   Gamepasses = {
--       VIP = { gamepassId = number, doubleCoins = true, vipSkin = "VIP" },
--       <Key> = { gamepassId = number, toolName = "ToolName" },
--   }
-- }

local M = {
	Products = {
		CoinPacks = {
			["250Coins"]   = { productId = 3402977955, amount = 250,  uiKey = "250Coins" },
			["1000Coins"]  = { productId = 3402978114, amount = 1000, uiKey = "1000Coins" },
			["2500Coins"]  = { productId = 3402978266, amount = 2500, uiKey = "2500Coins" },
			["4000Coins"]  = { productId = 3402978422, amount = 4000, uiKey = "4000Coins" },
			StarterPack    = { productId = 3402979037, amount = 500, grantSkin = "Coin", uiKey = "StarterPack" },
		},
		Skins = {
			Blackhole = { productId = 3402976137, skin = "Blackhole" },
			Fire      = { productId = 3402976328, skin = "Fire" },
			Glitch    = { productId = 3402976482, skin = "Glitch" },
		},
		Effects = {
			ServerRain = { productId = 3402977469, type = "ServerCoinRain", duration = 15, coinCount = 50 },
			GlobalRain = { productId = 3402977652, type = "GlobalCoinRain", duration = 15, coinCount = 50 },
		},
	},
	Gamepasses = {
		VIP = { gamepassId = 1462168838, doubleCoins = true, vipSkin = "VIP" },
		GravityGun  = { gamepassId = 1461887082, toolName = "GravityGun" },
		MagicCarpet = { gamepassId = 1461539361, toolName = "MagicCarpet" },
		Boombox     = { gamepassId = 1462284806, toolName = "Boombox" },
	},
}

return M
