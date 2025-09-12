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
```
Dynamic runtime folders per session inside each `Connect4` model:
- `SpawnedTokens` – holds placed token models.
- `ColumnHitboxes` – one Part per column with a ClickDetector.
- `DebugCells` – optional small parts marking cell centers when `DEBUG_CELL_MARKERS = true`.
- (World Label) The capacity TextLabel is searched via: `slotModel.Capacity.Display.Frame.Textlabel` (SurfaceGui/BillboardGui) or fallback `slotModel.Display` and then first descendant `TextLabel`.


The in-match narration shown to each player is NOT the same as the world capacity label. The TextLabel is found in StarterGUI-ScreenGUI.Frames.Match.TextLabel

---
## 3. Core Data Structures
### 3.1 Session Object (per slot)
```
session = {
  slotModel: Model,            -- The slot base model
  connect4Model: Model,        -- The Connect4 model under slot
  gridPart: BasePart,          -- The part used for size/orientation
  slotName: string,            -- slotModel.Name (for logs)
  players: { Player?, Player? }, -- Index 1 = Player 1, Index 2 = Player 2
  turnIndex: number,           -- 1 or 2 (whose turn)
  board: number[][],           -- ROWS x COLS; each cell stores player.UserId or nil
  hitboxFolder: Folder?,       -- Column click parts
  timerTurnId: number,         -- Increment to invalidate active timers
  busy: boolean,               -- Move animation in progress
  acceptMoves: boolean,        -- Are clicks processed as moves
  countdownId: number,         -- Increment to invalidate countdown
  matchActive: boolean,        -- True between start & end
  preMatchCountdown: boolean?, -- True during countdown
  originalStats: { [Player] = { ws: number, jp: number } },
  seats: { Seat?, Seat? }?,    -- Two chosen seat instances
  locked: boolean?,            -- Seat lock state
  lockPlayers: (session, bool) -> (),
  endMatch: (session, winner: Player?, loser: Player?, reason: string) -> (),
}
```
### 3.2 Board Representation
```
ROWS = 6, COLS = 7
board[row][col] = player.UserId | nil
Top row index = 1 (visually top), bottom = 6.
```
### 3.3 Reasons Passed to `endMatch`
`"win" | "draw" | "timeout" | "abort"`

---
## 4. Geometry & Placement Logic
### 4.1 Orientation Detection
```
columnsAlongZ(size: Vector3) -> boolean
  returns true if size.Z > size.X
  If true: columns extend along world Z using grid.CFrame.LookVector as column axis.
  Else: columns extend along world X using grid.CFrame.RightVector.
```
This allows rotated boards (wide dimension decides horizontal axis).

### 4.2 Column Hitbox Size & Position
In `ensureHitboxes(session)`:
```
local size = grid.Size
local alongZ = columnsAlongZ(size)
local width  = alongZ and size.Z or size.X    -- horizontal span for 7 columns
local depth  = alongZ and size.X or size.Z    -- board thickness (front-back)
local cellW  = width / COLS                   -- column slice width
local planeDepth = 0.45                       -- thickness of the hitbox plane Part
local height = size.Y + 2                     -- extend slightly above/below board
```
Per column `c` (1..7):
1. Compute column center lateral offset: `along = -width/2 + (c - 0.5) * cellW` (centers each slice).  
2. Use `columnSpawnCFrame(grid, c, frontOffset, heightAbove)` with `frontOffset ≈ 0.02` and `heightAbove = 0` for hitboxes:
   - That function builds a CFrame at the front face mid-height; then code shifts it down by half the board height to span full height:
   ```lua
   local cf = columnSpawnCFrame(grid, c, 0.02, 0) * CFrame.new(0, -(size.Y/2), 0)
   ```
3. Size: 
   - If alongZ: `Size = Vector3.new(planeDepth, height, cellW)`
   - Else:      `Size = Vector3.new(cellW, height, planeDepth)`

### 4.3 Token Drop Spawn & Target Positions
Two helper functions:
```
columnSpawnCFrame(grid, col, frontOffset, heightAbove)
cellWorldCFrame(grid, row, col, frontOffset)
```
Shared math with orientation. For a given column:
- Horizontal offset identical to hitbox: `along = -width/2 + (col - 0.5) * cellW`.
- Vertical (spawn): board top + `heightAbove` (e.g. 5 studs) for aesthetic drop animation.
- Target vertical for a cell (row): `yLocal = size.Y/2 - (row - 0.5) * cellH` where `cellH = size.Y / ROWS`.
  - Row 1 (top) gets small downward offset; row 6 (bottom) is near `-size.Y/2 + cellH/2`.
- Normal direction (front) uses the narrow dimension so tokens and hitboxes sit just in front of holes: `normal = alongZ and right or look` then offset by `(depth/2 + frontOffset)`.
- Final token front offset: typically `frontOffset = 0.05` to prevent z‑fighting with board surface.

### 4.4 Y-Axis (Vertical) Token Placement Formula
Given:
```
cellH = size.Y / ROWS
row in [1..6]
localY(row) = size.Y/2 - (row - 0.5) * cellH
worldPos = grid.CFrame.Position + columnAxis*along + up*localY + normal*(depth/2 + frontOffset)
```
This creates evenly spaced centers distributed from top to bottom inside the board's vertical span.

### 4.5 Animation
`pivotTween(model, targetCF, duration)` performs a manual Heartbeat Lerp from current pivot to target. Duration scales slightly with drop depth:
```
0.35 + (ROWS - dropRow) * 0.03
```
So lower (deeper) placements fall a bit longer for a subtle effect.

---
## 5. Token Logic & Skins
- Tokens cloned from `ReplicatedStorage/Tokens/<SkinName>`.
- If a token source is a single `BasePart`, it's wrapped into a new `Model` with `PrimaryPart` set.
- Duplicate skin resolution: if both players picked same skin and player 2 places a token, a hue shift (`+0.05` in HSV) is applied via `setModelHueShift` across all BaseParts.
- Fallback cylinder generated if model not found: 1.8x1.8x0.4, colored red/yellow.

---
## 6. Turn & Timing Flow
1. After countdown completes: `matchActive = true`, `turnIndex = 1`, tokens folder cleared.
2. `startTurnTimer(session)` sets `timerTurnId` and runs a loop: 25s passive wait + 10s warning (per-second narration). (There is also a simplified in-click spawn timer in earlier code path—avoid duplication if refactoring.)
3. Player clicks a column Part:
   - Validations: session active, right player turn, column not full, not busy.
   - Determine lowest empty row scanning bottom-up.
   - Spawn and animate token.
   - Update board: `board[row][col] = player.UserId`.
   - Win check (`checkWinAt`): four-in-a-row search across directions `{(0,1),(1,0),(1,1),(1,-1)}` symmetrical expansion.
   - On win: `endMatch(session, winner, loser, "win")`.
   - On draw: `endMatch(..., "draw")`.
   - Otherwise: switch `turnIndex = 3 - turnIndex`, reset `busy`, increment `timerTurnId` to cancel prior timer coroutine.

### Timeout Path
If time expires: call `endMatch(session, other, cur, "timeout")` naming opponent as winner.

---
## 7. Seat Locking & Lifecycle
- Seats chosen: two nearest `Seat` / `VehicleSeat` descendants to `gridPart`.
- Lock occurs only when match actually starts (after countdown), not during countdown.
- Locking (`lockPlayers(session, true)`):
  - Forces occupant seat via `Seat:Sit(hum)`.
  - Stores original WalkSpeed/JumpPower in `session.originalStats[player]`.
  - Sets WalkSpeed=0, JumpPower=0, anchors `HumanoidRootPart`.
- Heartbeat loop (every 0.25s) re-applies these constraints while `session.locked`.
- Unlock after match end: restores saved movement + unanchors winner; loser is killed (Humanoid.Health=0). Both seats forced to release occupants (Humanoid.Sit = false) after unlock.

---
## 8. Match Ending
`endMatch(session, winner, loser, reason)` responsibilities:
- Guard against re-entry via `session.matchActive` flag.
- Turn off input: `acceptMoves = false`.
- Increment `timerTurnId` to invalidate timers.
- Per-player narration (win, lose, timeout, draw, abort).
- Kill loser when applicable.
- Immediate unlock & seat release.
- Delayed (3s) board reset: clear spawned tokens, create new empty board & reset turn to 1, update capacity label.

Reasons mapping:
| Reason    | Winner Required | Loser Required | Notes |
|-----------|-----------------|----------------|-------|
| win       | yes             | yes            | 4-in-a-row detected |
| draw      | no              | no             | Board full with no winner |
| timeout   | yes             | yes            | Active player exceeded timer |
| abort     | no              | no             | A player left mid-match |

---
## 9. Narration System
- `Narrate` RemoteEvent payload: `{ slotId, text }`.
- `narrateTo(session, msg)` sends identical text to both players.
- `narrateCustom(session, { msgP1, msgP2 })` allows per-player variant messaging.

Possible future enhancement: add spectator GUI filtering by slot.

---
## 10. Debug & Flags
| Flag | Location | Purpose |
|------|----------|---------|
| `SHOW_COLUMN_ZONES` | top of server script | Set column hitboxes visible/semi-transparent for UX/testing |
| `DEBUG_CELL_MARKERS`| top of server script | Spawns colored 0.4-stud cubes at each cell center |

Extensive `print` statements exist for: countdown ticks, match start, turn switches, clicks, move acceptance, win/draw detection.

---
## 11. Error History & Fixes (For Context)
| Issue | Cause | Fix |
|-------|-------|-----|
| `endMatch` nil during win | Functions defined after sessions captured nil | Moved definitions earlier & assigned during session init |
| Post-win cleanup nil call (updateCapacityText) | Forward declaration overshadowed by new local function | Rebinding: `updateCapacityText = function(...)` |
| Loser not killed / winner stuck | Unlock executed after delayed cleanup & nil call abort | Immediate unlock in `endMatch`, loser Humanoid health set, seat release |
| Seats locked during countdown | Lock invoked too early | Moved lock to only after countdown completion |

---
## 12. Extending the System
### Add Spectators
- Add `Spectators` list; only allow clicks from `session.players`.
- Provide GUI board state via remote for viewers.

### Add Score Tracking
- Maintain `leaderstats` or DataStore keyed by player.UserId -> wins/losses.
- Increment in `endMatch` based on reason == "win" or "timeout".

### Add Column Preview
- On hover, place a translucent token above column (client prediction) using additional RemoteEvent or local raycast from mouse.

### Add Anti-Abuse
- Track rapid seat swapping; add cooldown.
- Only start countdown if both players remain seated for N seconds.

### Save/Load Skins
- Players set `TokenSkin` attribute via a secure server handler to prevent spoofing.

---
## 13. Key Helper Functions (Concise Reference)
| Function | Summary |
|----------|---------|
| `getTwoSeatsForSlot(slot, grid)` | Picks two nearest seat instances to grid part |
| `newBoard()` | Returns fresh 6x7 nil matrix |
| `checkWinAt(board, row, col, userId)` | Detects 4 in a line around last move |
| `isBoardFull(board)` | True if no nil cells |
| `columnsAlongZ(size)` | Orientation decision (horizontal axis) |
| `cellWorldCFrame(grid, row, col, frontOffset)` | Target token center transform |
| `columnSpawnCFrame(grid, col, frontOffset, heightAbove)` | Spawn/drop start transform |
| `ensureHitboxes(session)` | Creates/attaches column click Parts |
| `startTurnTimer(session)` | Handles 25s + 10s warning phase and timeout resolution |
| `lockPlayers(session, bool)` | Freeze/unfreeze players & anchor |
| `endMatch(session, winner, loser, reason)` | Terminate match, narration, cleanup |
| `narrateTo` / `narrateCustom` | Broadcast messages to players |

---
## 14. Coordinate Cheat Sheet
```
width = (columnsAlongZ and grid.Size.Z) or grid.Size.X
cellW = width / 7
cellH = grid.Size.Y / 6
along(col) = -width/2 + (col - 0.5) * cellW
vertical(row) = grid.Size.Y/2 - (row - 0.5) * cellH
spawn heightAbove = typically 5 studs (drop animation start)
front offset ≈ 0.02..0.05 (hitbox/token separation from board face)
```
Vectors extracted from `grid.CFrame`:
```
right = cf.RightVector
look  = cf.LookVector
up    = cf.UpVector
columnAxis = columnsAlongZ and look or right
normal     = columnsAlongZ and right or look   -- points outward through holes
```

---
## 15. Adding a New Slot at Runtime
1. Duplicate an existing slot model (must include `Connect4` + a `Grid` part + 2 seats).
2. Parent it under `Workspace.PlayingSlots`.
3. Server auto-detects via `ChildAdded` and initializes session.

---
## 16. Safety & Integrity Notes
- All move validation occurs server-side.
- Clients only send implicit input via ClickDetector (Roblox handles origin). No remote for moves reduces exploit surface.
- Seat enforcement during match prevents players from circumventing turn timer by leaving.
- Consider throttling click spam with a short per-player debounce if needed.

---
## 17. Cleanup Tasks (Optional Future Refactor)
- Remove legacy/duplicate timer code inside click handler (currently a lightweight alternative to `startTurnTimer`). Use single unified timer.
- Convert `pivotTween` to TweenService tween for smoother motion & ease-in.
- Replace prints with a debug flag wrapper or a lightweight logging module.
- Factor geometry helpers into a separate module for reuse/testing.

---
## 18. Quick Start (Deployment)
1. Ensure the model hierarchy matches the layout above.
2. Provide at least `Red` and `Yellow` token models under `ReplicatedStorage/Tokens`.
3. Place the script at `ServerScriptService/Server/Connect4.server.luau`.
4. Start play; sit two players in the slot seats.

---
## 19. Glossary
| Term | Definition |
|------|------------|
| Slot | A physical table environment containing one Connect4 game instance |
| Session | Runtime state container per slot |
| Board | 2D array storing userIds per cell |
| Token | Model or part representing a placed disc |
| Hitbox | Invisible/semi-transparent clickable plane mapping to a column |
| Countdown | 5-second pre-match timer when both seats filled |
| Lock | State where seated players cannot move or jump |

---
## 20. Minimal Pseudocode Summary
```
for slot in PlayingSlots: initSlot(slot)
  resolve gridPart
  session = new session state
  ensureHitboxes(session)
  hook seat.Occupant changed -> onSeatsChanged

onSeatsChanged:
  update players
  if matchActive: enforce seating or abort
  elseif countdown and a seat empties: cancel
  elseif two players and idle: start 5s countdown

Countdown finished -> start match:
  reset board, lock seats, accept moves, start turn timer

Click column:
  validate + find dropRow
  animate token placement
  win? endMatch(win)
  draw? endMatch(draw)
  else switch turn + reset timer

endMatch:
  mark inactive, narration, loser kill, unlock seats, delayed board reset
```

---
## 21. License / Attribution
(Adjust if you intend to publish. Currently unspecified; treat as proprietary or add an open license header.)

---
**End of Guide**
