<div align="center">

# Connect4 – Multi‑Table, Skins, Economy & Monetization

Server‑authoritative multi‑slot (multi‑table) Connect 4 with token skins, coin economy, developer products & gamepasses, ordered leaderboards, instant UI updates, attribute‑based stats, match camera, win highlighting & modular UI helpers.

</div>

## 1. Overview
Multiple physical tables placed under `Workspace.PlayingSlots` each host an independent game. Two seats fill → 5s countdown → match → per‑turn timer (skip on timeout) → win chain highlight → reset. All move validation & state live on the server; client handles lightweight visuals (camera, narration, UI).

## 2. Key Features
Gameplay:
- Auto discovery of slot models (with `Connect4/Grid`).
- Optional `Alignment` part inside `Grid` overrides geometry (resize / reposition friendly).
- Dynamic centered column hitboxes; optional debug visibility.
- Turn timer: 25s + per‑second warning last 10s; timeout skips player (no reset).
- Win detection returns exact 4+ chain; optional `Highlight` effect tween.
- Cinematic camera focus (`MatchCamera` RemoteEvent) + player transparency; auto restore.
- Seat locking (walk/jump disabled) with safe restoration.

Economy, Skins & Monetization:
- Coin attribute (`Player:GetAttribute("Coins")`) stored in persistent profile.
- Token skins defined in `TokenConfig` (+ optional `MonetizationConfig` for product & gamepass IDs).
- Developer products & gamepasses handled in `Monetization.server.luau` (coin packs, skins, coin rain effects, VIP skin grant etc.).
- Immediate UI refresh after purchase via `TokenInventory/Purchased` RemoteEvent.
- Same‑skin disambiguation: second player auto variant (if variant asset available) or subtle hue shift.

UI & Feedback:
- Hover / click scaling + SFX (shared UI module).
- Coins display auto‑animates on change (attribute first, leaderstats fallback).
- Rainbow gradient & animated rayburst decoration examples.
- Attribute‑based coin gain SFX (suppresses initial load).

Persistence & Stats:
- Profile (DataStore key `Player_<UserId>`): Coins, Wins, Streak, HighestStreak, OwnedSkins.
- Ordered leaderboards (Wins, HighestStreak) via `LeaderboardManager.server.luau` with placeholder entries if empty.
- Coins & HighestStreak hidden from classic leaderboard (attributes only); Wins & Streak visible.
- Autosave loop + safe BindToClose flush.

Removed / Deferred:
- Prior experimental VIP chat tag system removed (no active chat tag scripts). Re‑adding later would use a lightweight TextChatService client formatter.

Admin & Debug:
- `/coins add|remove <amt>` or `/coins set <player> <amt>` (admin list in `Connect4.server.luau`).
- Debug flags in server script for geometry & hitboxes.

## 3. Project Structure (Code)
```
src/
	server/
		Connect4.server.luau        # Core multi-table game logic (session lifecycle, win logic, admin coins)
		DataManager.luau            # Persistence & token inventory RemoteFunction
		TokenShop.server.luau       # Proximity prompt coin skin purchases -> fires Purchased event
		Monetization.server.luau    # Dev products, gamepasses, coin rain, VIP skin granting
		LeaderboardManager.server.luau # OrderedDataStore leaderboards (Wins / HighestStreak)
		init.server.luau            # Entry aggregation (optional)
	client/
		Connect4.client.luau        # Client narration & camera handling
		init.client.luau            # HUD + SFX + music toggle + coins SFX + skins & monetization UI bootstrap
	shared/
		UI/
			init.luau                 # Hover/click tween helpers & open/close animations
			SkinsUI.luau              # Dynamic skins list, equip/unequip, purchase refresh
			CoinsDisplay.luau         # Attribute-first coin label updater & animation
		Configs/
			TokenConfig.luau          # Skin metadata (coin costs & legacy product ids)
			MonetizationConfig.luau   # (If present) structured products & gamepasses
		Modules/                    # (Reserved for future shared modules)
```
Expected Roblox hierarchy (runtime):
```
ReplicatedStorage/
	Connect4/
		Narrate (RemoteEvent)
		MatchCamera (RemoteEvent)
	TokenInventory/
		Request (RemoteFunction)
		Purchased (RemoteEvent)
	Tokens/ (Models or parts for each skin)
	Highlight (Highlight)  (optional win chain effect)
	Assets/
		UITemplates/
			Skin (Frame or ImageButton template)
			TokenIcons/ (ImageLabels named after skins)
			MusicIcons/ (On / Off)
		Sounds/
			InterfaceButtonHover / InterfaceButtonClick / CoinsAwarded / BackgroundMusic
Workspace/
	PlayingSlots/
		<SlotModel>/Connect4/Grid[/Alignment] + two Seats
```

## 4. Gameplay Flow (Condensed)
1. Slot discovered → hitboxes built.
2. Two seats filled → 5s countdown → lock players.
3. Turn: player clicks column → server validates → token dropped & board updated.
4. Win? highlight chain → end; draw? end; else next turn timer.
5. Timeout? announce + skip turn.
6. End → unlock → small delay → board reset.

## 5. Economy & Skins
Profile schema: `{ Version, Coins, Wins, Streak, HighestStreak, OwnedSkins }`.
Coins adjusted via gameplay (not shown here), admin command, or purchases.
Skins purchasable with coins if `costCoins` set; others reserved for monetization / quests.
Purchase flow: client invokes `TokenInventory/Request` (Purchase) → server validates & deducts → updates profile & attributes → fires `Purchased` → client rebuilds list instantly.

## 6. Admin Coin Command
Chat: `/coins add 50`, `/coins add PlayerName 200`, `/coins remove 25`, `/coins set PlayerName 5000`.
Permission: user IDs in `ADMIN_USER_IDS` or place owner.

## 7. Attributes vs Leaderstats
Visible leaderboard: `Wins`, `Streak`.
Attributes (hidden): `Coins`, `HighestStreak`, `TokenSkin`.
Reason: reduce leaderboard clutter + more flexible client change detection.

## 8. UI Utilities
`shared/UI/init.luau`: `attachHoverClick(gui, {hoverScale, clickScale})`, `open(frame)`, `close(frame)`.
`SkinsUI`: Scans all ScreenGuis for scrolling frame path; supports Frame or ImageButton template; equips & toggles.
`CoinsDisplay`: Attribute-first coin watching + size & slight rotation tween animation.

## 9. Persistence Cycle
Dirty flag on profile changes (`_dirty`). Autosave every 60s or on player leave / shutdown. Merge logic keeps max HighestStreak and unions OwnedSkins.

## 10. Development (Rojo)
Build: `rojo build -o "4 in a row.rbxlx"`
Live sync: `rojo serve`
Edit `TokenConfig.luau` to balance pricing or enable monetization IDs.

## 11. Extending
Add new skin: model under `ReplicatedStorage/Tokens`, icon under `Assets/UITemplates/TokenIcons`, entry in `TokenConfig.luau`.
Add dev product: set `productId` in `TokenConfig` and implement purchase handling (placeholder code notes already present).
Add quest logic: detect completion server-side then call `DataManager.addSkin`.

## 12. Debug Flags (in `Connect4.server.luau`)
`SHOW_COLUMN_ZONES`, `DEBUG_CELL_MARKERS`, `DEBUG_GEOMETRY`, `DEBUG_ALIGNMENT`.

## 13. License
Add a license file (currently unspecified).

---
Concise guide for quick onboarding. For deep internals see `PROJECT_GUIDE.md`.
