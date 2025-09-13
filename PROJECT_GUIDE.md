# Connect4 Multi-Table System – Comprehensive Project Guide

This document captures every important detail of the current Connect 4 implementation so you can resume work in a fresh session without needing prior chat history.

---
## 1. High-Level Overview
A server‑authoritative, world (3D) Connect 4 system that supports multiple physical tables ("slots") inside `Workspace.PlayingSlots`. Each table contains a `Connect4` model with a `Grid` part and two nearby seats. When two players sit, a countdown runs, the match starts, players are locked to their seats, and they take turns placing tokens by clicking invisible (optionally semi‑visible) column hitboxes in front of the grid. Server handles:
- Seating detection & capacity labeling
- Per-table session lifecycle
- Token spawning & placement animation
- Turn timing (25s + 10s warning path retained in code; current simplified spawn also has its own timer logic)
- Win / draw / abort / timeout resolution
- Seat locking & restoration
- Token skin selection & hue disambiguation when both players use same skin

Client is minimal: listens to a `Narrate` RemoteEvent to update match text UI.

---
## 2. Folder / Instance Layout Expectations
```
ReplicatedStorage/
  Connect4/
    Narrate (RemoteEvent)
  Tokens/
    Red (Model or BasePart)
    Yellow (... optional defaults)
    <OtherSkinNames> (Models)
Workspace/
  PlayingSlots/
    <SlotModel1>/
      Connect4/ (Model)
        Grid (BasePart or child containing grid surface)
      Capacity/ (Folder or Model used for world capacity display)
        Display (SurfaceGui or BillboardGui)
          TextLabel (capacity text: "0/2 Players" / hidden when full)
      (Two Seat descendants somewhere under the slot model)
    <SlotModel2>/...
ServerScriptService/
  Server/
    Connect4.server.luau  (main system script)
StarterPlayer/
  StarterPlayerScripts/
    ## Project Guide (Technical Deep Dive)

    This guide complements the top‑level `README.md` by detailing internal data structures, flows, and extension points without repeating high‑level marketing content.

    ### 1. Runtime Session Object
    Stored per slot in `Connect4.server.luau` (fields may evolve):
    ```
    session = {
      slotName: string,
      slotModel: Model,
      connect4Model: Model,
      gridPart: BasePart,      -- original Grid
      refPart: BasePart,       -- Alignment or Grid (geometry source)
      players = {p1: Player?, p2: Player?},
      seats = {Seat?, Seat?},
      board = 6x7 matrix (userId | nil),
      turnIndex = 1 | 2,
      matchActive = false,
      preMatchCountdown = false,
      busy = false,            -- token anim in progress
      acceptMoves = false,     -- gating clicks
      hitboxFolder: Folder?,
      countdownId = 0,
      timerTurnId = 0,
      locked = false,
      originalStats = { [Player] = { ws, jp } },
      _winHighlighting = false,
    }
    ```

    ### 2. Geometry Calculations
    ```
    width   = (columnsAlongZ and refPart.Size.Z) or refPart.Size.X
    cellW   = width / 7
    cellH   = refPart.Size.Y / 6
    columnX(zIndex) or columnZ(xIndex) -> along(c) = -width/2 + (c - 0.5)*cellW
    localY(r) = refPart.Size.Y/2 - (r - 0.5)*cellH
    FrontOffset attribute shifts final world CFrame along outward normal
    ```
    Alignment logic picks the wider horizontal axis to decide columns orientation.

    ### 3. Token Placement Pipeline
    1. Player click triggers server column handler.
    2. Validate: in match, correct player, column not full, not busy.
    3. Find lowest empty row; mark `busy=true`.
    4. Clone token model (skin variant logic) → pivot above column → Heartbeat lerp to target cell CFrame (drop time scales with depth).
    5. Mark board cell & release `busy`.
    6. Check win/draw → highlight or progress turn.

    ### 4. Win Highlight
    If `ReplicatedStorage.Highlight` exists: clone per token, tween Fill / Outline transparency (≈0.4s), hold 1.5s, then finalize.

    ### 5. Turn Timer & Skip Logic
    `timerTurnId` increments to invalidate previous timers. Flow: start → wait 15s (silent) → last 10s per‑second warning Narrate fires → if still same turn & no move at 25s mark: timeout narrate & switch turn (board unchanged).

    ### 6. Seat Locking Strategy
    On match start: store WalkSpeed & JumpPower, zero them, (optionally anchor HRP inside loop). On end: restore values & unanchor. Defensive reapply loop every 0.25s minimizes exploit window.

    ### 7. Persistence Model
    `DataManager` caches profile in memory keyed by UserId. `_dirty` flag triggers periodic save (60s) and on removal/shutdown. Update merges keep max `HighestStreak` and union of `OwnedSkins`.

    Profile schema:
    ```
    { Version=1, Coins, Wins, Streak, HighestStreak, OwnedSkins, _dirty? }
    ```

    ### 8. Attributes vs Leaderstats Rationale
    Attributes (`Coins`, `HighestStreak`, `TokenSkin`) allow silent internal changes and client detection without cluttering scoreboard. Leaderstats limited to `Wins`, `Streak` for social visibility. Migration kept a fallback path (legacy coins IntValue) for older sessions; new logic prefers attributes.

    ### 9. Token Skins Flow
    Module `TokenConfig.luau` enumerates all skins + metadata (costCoins, productId placeholders, quests, etc.). Purchase path:
    ```
    Client -> RemoteFunction TokenInventory/Request (Purchase, {skin})
      DataManager.tryPurchase -> cost check -> deduct Coins -> add skin -> mark dirty
      On success server fires TokenInventory/Purchased (RemoteEvent)
    Client SkinsUI listens -> rebuilds list instantly
    Player selects -> Equip action sets Player attribute TokenSkin
    Server placement uses attribute each token spawn
    Variant handling: second player same skin -> use variant folder or hue shift
    ```

    ### 10. Coins Display & SFX
    `CoinsDisplay.luau` binds to `Coins` attribute; animates label size + coin icon rotation on increments. Client SFX logic debounces by timestamp and suppresses first attribute initialization.

    ### 11. Admin Coins Command
    Parsed in chat by `Connect4.server.luau`:
    ```
    /coins add <amt>
    /coins add <player> <amt>
    /coins remove <player?> <amt>
    /coins set <player> <amt>
    ```
    Writes directly to Coins attribute then calls `DataManager.setStatFromLeaderstat` for persistence alignment. Only place owner & IDs in `ADMIN_USER_IDS` pass `isAdmin`.

    ### 12. Debug Flags
    Set near top of server script:
    * `SHOW_COLUMN_ZONES` – visualize column hitboxes.
    * `DEBUG_CELL_MARKERS` – spawn tiny cell center parts.
    * `DEBUG_GEOMETRY` – geometry prints.
    * `DEBUG_ALIGNMENT` – alignment pivot details.

    ### 13. Extension Recipes
    Add new purchasable skin:
    1. Add model under `ReplicatedStorage/Tokens/<SkinName>`.
    2. Add icon `Assets/UITemplates/TokenIcons/<SkinName>`.
    3. Insert entry in `TokenConfig.luau` with `costCoins`.
    4. (Optional) Provide variant in `Tokens/Variants/<SkinName>` for second player hue disambiguation.

    Monetized skin (Developer Product):
    1. Set `productId` in `TokenConfig`.
    2. Implement product receipt callback to call `DataManager.addSkin(player, skin)` and `DataManager.markDirty(player)`.
    3. Fire `Purchased` RemoteEvent to force UI rebuild.

    Quest skin:
    1. Define `quest` string in `TokenConfig`.
    2. Server script: detect quest completion → award via `addSkin`.

    ### 14. Security Considerations
    * No RemoteEvent for direct moves; server manipulates board exclusively.
    * Column hitboxes are server-created; client cannot spoof board placement.
    * Admin commands limited to curated IDs.
    * Persistence uses UpdateAsync with merge to avoid overwrite races.

    ### 15. Performance Notes
    Board operations are O(ROWS * COLS) in worst case (tiny). Token animation uses simple Heartbeat Lerp (negligible). Potential optimization only if scaling to hundreds of simultaneous slots (pool token models, reduce prints). Current design is adequate for typical experiences.

    ### 16. Future Enhancements (Curated)
    * Spectator floating GUI showing all active boards.
    * Ghost preview token + column highlight on hover.
    * Easing / TweenService based drop (replace manual lerp) with bounce.
    * Rich post‑match stats panel (coins gained, streak changes).
    * Anti‑AFK penalty for repeated timeouts.
    * Batched save queue with jitter to spread DataStore writes.

    ### 17. Minimal Pseudocode Recap
    ```
    onSeatStateChanged -> if two occupied & not matchActive -> startCountdown()
    startCountdown -> after 5s -> beginMatch()
    beginMatch -> lockPlayers -> resetBoard -> startTurnTimer()
    onColumnClick -> if acceptMoves -> placeToken -> checkWin/draw -> maybe highlightWin or nextTurn
    highlightWin -> tween -> delayed endMatch
    endMatch -> unlock -> reset after short delay
    ```

    ### 18. Troubleshooting Quick Table
    | Symptom | Likely Cause | Fix |
    |---------|-------------|-----|
    | Skins list empty | UITemplates/Skin mismatch | Verify template & icons folder names |
    | Coin SFX on join | Attribute init playing sound | Confirm suppression flag (attrInitialized) true |
    | Purchases delay UI | Missing Purchased RemoteEvent | Ensure `TokenShop.server.luau` fires event |
    | Second player same skin identical | No variant & no hue shift applied | Add variant model or implement hue shift fallback |
    | Coins not saving | `_dirty` never set | Use `DataManager.addCoins` / markDirty |

    ### 19. License
    Still undefined; add a LICENSE file to clarify usage & contributions.

    ---
    End of technical guide.
cellW = width / 7

cellH = size.Y / 6
