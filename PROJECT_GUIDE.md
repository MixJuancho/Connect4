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
    Connect4.client.luau  (narration listener)
# Connect4 Multi-Table System – Final Guide

This guide documents the finalized multi‑table Connect 4 implementation (alignment ref part, centered geometry, skip‑turn timeout, camera focus, and win highlighting).

---
## 1. Overview
Multiple simultaneous games run on physical slot models under `Workspace.PlayingSlots`. Each slot has a `Connect4` model and seats for two players. When both are seated: 5s countdown -> match starts -> seats lock -> players alternate clicks on column hitboxes. System is server‑authoritative.

Key server features:
* Auto slot discovery & per‑slot session state
* Alignment override part (`Grid/Alignment`) for geometry (movement/resize live rebuild)
* Centered column hitboxes & token placement with optional `FrontOffset` attribute
* Turn timer (25s + 10s warning). Timeout now skips the turn (no immediate end)
* Win chain detection returning exact coordinates
* Win highlight tween using `ReplicatedStorage.Highlight` (optional) before ending match
* Camera focus / reset events (`MatchCamera`) – client handles cinematic view & temporary player transparency
* Token skins + hue disambiguation for same-skin players
* Robust seat locking & graceful cleanup

Client features:
* Receives match narration via `Narrate`
* Camera / transparency handling via `MatchCamera`

---
## 2. Expected Hierarchy
```
ReplicatedStorage/
  Connect4/
    Narrate (RemoteEvent)
    MatchCamera (RemoteEvent)
  Tokens/
    Red
    Yellow
    <OtherSkinModels>
  Highlight (Highlight)  -- optional template for win effect
Workspace/
  PlayingSlots/
    <SlotModel>/
      Connect4/
        Grid (Part or Model)
          Alignment (Part, optional precision ref)
      (Two Seat descendants somewhere under SlotModel)
ServerScriptService/Server/Connect4.server.luau
StarterPlayer/StarterPlayerScripts/Connect4.client.luau
```
Runtime folders: `SpawnedTokens`, `ColumnHitboxes`, optional `DebugCells`.

---
## 3. Session State
```
session = {
  slotModel, connect4Model,
  gridPart, refPart,
  players = {p1, p2},
  turnIndex = 1|2,
  board = 6x7 matrix (userId|nil),
  hitboxFolder,
  timerTurnId,
  countdownId,
  matchActive, preMatchCountdown,
  busy, acceptMoves,
  seats = {seat1, seat2}, locked,
  originalStats = { [Player] = {ws, jp} },
  _winHighlighting
}
```

---
## 4. Geometry & Alignment
`refPart` = `Alignment` (if present) else `Grid`. All math uses `refPart.CFrame` & `Size`.
Orientation: `columnsAlongZ(size)` picks the wider horizontal axis.
Column center along axis:
```
width  = (alongZ and size.Z) or size.X
cellW  = width / 7
along(c) = -width/2 + (c - 0.5) * cellW
```
Tokens & hitboxes are centered in thickness; `FrontOffset` (attribute, studs) moves them along outward normal (positive toward players). Default = 0.

Vertical cell center:
```
cellH = size.Y/6
localY(r) = size.Y/2 - (r - 0.5) * cellH
```

---
## 5. Token Placement & Animation
Spawn CFrame: above column (heightAbove=5). Target: `cellWorldCFrame` with same `FrontOffset`.
Animation: manual Heartbeat Lerp in `pivotTween` (duration scales with drop depth: `0.35 + (ROWS - row)*0.03`).

---
## 6. Turn Flow & Timer (Skip‑Turn Timeout)
1. Countdown (5..1) when both seats occupied.
2. Match starts: lock seats, clear tokens, `turnIndex=1`, start turn timer.
3. Turn timer: 25s passive + 10s warning (per‑second narration). If no move: announce timeout, flip turn, start new timer (board unchanged).
4. Player click: validate -> find lowest empty row -> spawn & animate token -> write board -> win/draw check -> switch turn & start new timer if game continues.

---
## 7. Win Detection & Highlight
`checkWinAt` returns `(won, chain)` where `chain` = array of `{row,col}` (≥4). On win:
* If `Highlight` exists: clone onto each winning token, tween FillTransparency 1→0.5 & OutlineTransparency 1→0 (≈0.4s).
* After 1.5s delay call `endMatch(...,'win')`.

---
## 8. Seat Locking
Locked state: seat enforced, WalkSpeed=0, JumpPower=0, HumanoidRoot anchored (loop reasserts every 0.25s). Unlock & stat restore on match end.

---
## 9. Camera System
Server fires `MatchCamera` with actions:
* `Focus` – client switches to Scriptable cam, positions behind/in front (depending on orientation) & hides characters (transparency).
* `Reset` – client restores camera & player visibility.

---
## 10. Match End
`endMatch(session, winner, loser, reason)` handles narration, camera reset, loser elimination (if applicable), unlock, delayed board reset (3s). Reasons now effectively: `win`, `draw`, `abort` (timeout is non‑terminal: handled earlier as skip).

Reason table:
| Reason | Notes |
|--------|-------|
| win    | Highlight chain then delayed finalize |
| draw   | Board full, no chain |
| abort  | Player left mid‑match |
| timeout (legacy) | Replaced by skip-turn logic |

---
## 11. Narration
`Narrate` RemoteEvent; helpers: `narrateTo` (same msg) & `narrateCustom` (per‑player). Warning countdown & timer messages originate server‑side.

---
## 12. Flags / Debug
| Flag | Purpose |
|------|---------|
| SHOW_COLUMN_ZONES | Visualize clickable columns (semi‑transparent ForceField parts) |
| DEBUG_CELL_MARKERS| Spawn per-cell neon cubes |
| DEBUG_GEOMETRY    | Prints geometry build & column centers |

---
## 13. Key Functions (Reference)
| Function | Purpose |
|----------|---------|
| getTwoSeatsForSlot | Nearest two seats to grid |
| newBoard | Fresh 6x7 nil matrix |
| checkWinAt | Returns (won, chain) |
| isBoardFull | Board filled? |
| columnsAlongZ | Decide horizontal axis |
| cellWorldCFrame / columnSpawnCFrame | Token target / spawn transforms |
| ensureHitboxes | Build column Parts (centered) |
| startTurnTimer | Unified 25s + 10s warning + skip-turn on timeout |
| highlightWin | Tween highlight & delayed endMatch |
| lockPlayers | Seat freeze/restore |
| endMatch | Finalize match & cleanup |

---
## 14. Coordinate Cheat Sheet
```
width = (alongZ and size.Z) or size.X
cellW = width / 7
cellH = size.Y / 6
along(c) = -width/2 + (c - 0.5)*cellW
localY(r) = size.Y/2 - (r - 0.5)*cellH
FrontOffset (attr) shifts along outward normal (default 0)
```

---
## 15. Adding a Slot
Duplicate an existing slot (with seats + Connect4/Grid). Parent under `Workspace.PlayingSlots`. System auto‑initializes.

---
## 16. Security Notes
No remote for moves (ClickDetectors handled by Roblox). All validation server‑side. Seat locking prevents timer abuse. Consider rate limiting if players spam clicks (current busy flag covers animation overlap).

---
## 17. Future Enhancements (Optional)
* Spectator UI & board replication
* Persistent scoring (leaderstats/DataStore)
* Preview ghost token on hover
* Modularize geometry & timer logic into separate ModuleScripts
* TweenService token drops & easing camera
* Logging abstraction replacing raw prints

---
## 18. Quick Deployment
1. Provide token models under `ReplicatedStorage/Tokens` (Red, Yellow).
2. (Optional) Add `Highlight` instance for win chain effect.
3. Add or adjust `Alignment` part and set `FrontOffset` attribute if needed.
4. Run the place; sit two players; play.

---
## 19. Pseudocode Summary
```
initSlot -> build session, hitboxes, seat hooks
onSeatsChanged -> manage countdown / abort / start match
startTurnTimer -> wait -> warn -> skip-turn if still idle
click column -> validate -> place token -> win? highlight -> end; draw? end; else switch turn + timer
highlightWin -> tween -> delayed endMatch
endMatch -> narration, camera reset, unlock, delayed board reset
```

---
## 20. License
Add a license file (currently unspecified).

---
End of Final Guide

