-- World-based Connect 4 across multiple tables in Workspace.PlayingSlots
-- Per-slot requirements:
--   Slot (Model)
--     - Connect4 (Model)
--         - Grid (Part or MeshPart)  -> used to compute 6x7 cell positions
--     - Two Seat descendants for players

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Remotes: Narrate updates the on-screen match label per player
local remotesFolder = ReplicatedStorage:FindFirstChild("Connect4")
if not remotesFolder then
    remotesFolder = Instance.new("Folder")
    remotesFolder.Name = "Connect4"
    remotesFolder.Parent = ReplicatedStorage
end
local Narrate = remotesFolder:FindFirstChild("Narrate")
if not Narrate then
    Narrate = Instance.new("RemoteEvent")
    Narrate.Name = "Narrate"
    Narrate.Parent = remotesFolder
end
local MatchCamera = remotesFolder:FindFirstChild("MatchCamera")
if not MatchCamera then
    MatchCamera = Instance.new("RemoteEvent")
    MatchCamera.Name = "MatchCamera"
    MatchCamera.Parent = remotesFolder
end

local TOKENS = ReplicatedStorage:WaitForChild("Tokens")
local ROWS, COLS = 6, 7
local SHOW_COLUMN_ZONES = true -- visualize clickable column areas (for debugging/UX)
local DEBUG_CELL_MARKERS = false -- set true to spawn small parts at each cell center
local DEBUG_GEOMETRY = true -- set true to print geometry calculations for hitboxes

-- Choose the two seats closest to the grid part for this slot
local function getTwoSeatsForSlot(slotModel, gridPart)
    local candidates = {}
    for _, d in ipairs(slotModel:GetDescendants()) do
        if d:IsA("Seat") or d:IsA("VehicleSeat") then
            local dist = (d.Position - gridPart.Position).Magnitude
            table.insert(candidates, { seat = d, dist = dist })
        end
    end
    table.sort(candidates, function(a, b)
        return a.dist < b.dist
    end)
    local seats = {}
    if candidates[1] then table.insert(seats, candidates[1].seat) end
    if candidates[2] then table.insert(seats, candidates[2].seat) end
    return seats
end

local function forPlayers(playersArr, fn)
    for _, p in ipairs(playersArr) do
        if p then fn(p) end
    end
end

local function safeGetPlayerFromOccupant(humanoid)
    if not humanoid then return nil end
    local char = humanoid.Parent
    if not char then return nil end
    return Players:GetPlayerFromCharacter(char)
end

local function narrateTo(session, msg)
    forPlayers(session.players, function(p)
        Narrate:FireClient(p, { slotId = session.slotName, text = msg })
    end)
end

-- Send different messages per player (array index keyed) if table provided
local function narrateCustom(session, map)
    for idx, p in ipairs(session.players) do
        if p then
            local txt = map[idx]
            if txt then
                Narrate:FireClient(p, { slotId = session.slotName, text = txt })
            end
        end
    end
end

local function sendCameraEvent(session, action)
    local rp = session.refPart or session.gridPart
    if not rp then return end
    for _, pl in ipairs(session.players) do
        if pl then
            MatchCamera:FireClient(pl, { slotId = session.slotName, action = action, cf = rp.CFrame, size = rp.Size })
        end
    end
end

local function setModelHueShift(model, deltaHue)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local h, s, v = Color3.toHSV(d.Color)
            h = (h + deltaHue) % 1
            d.Color = Color3.fromHSV(h, s, v)
        end
    end
end

local function ensurePrimaryPart(model)
    if model.PrimaryPart then return end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            model.PrimaryPart = d
            return
        end
    end
end

local function pivotTween(model, target, duration)
    local start = model:GetPivot()
    local t0 = tick()
    while true do
        local alpha = (tick() - t0) / duration
        if alpha >= 1 then
            model:PivotTo(target)
            break
        end
        local cf = start:Lerp(target, alpha)
        model:PivotTo(cf)
        RunService.Heartbeat:Wait()
    end
end

local function getTokenModelFor(player, defaultName)
    local skinName = player:GetAttribute("TokenSkin")
    local modelName = defaultName
    if typeof(skinName) == "string" and TOKENS:FindFirstChild(skinName) then
        modelName = skinName
    end
    local src = TOKENS:FindFirstChild(modelName)
    if src and src:IsA("Model") then
        return src:Clone()
    elseif src and src:IsA("BasePart") then
        local m = Instance.new("Model")
        local part = src:Clone()
        part.Parent = m
        ensurePrimaryPart(m)
        return m
    end
    return nil
end

local function newBoard()
    local b = {}
    for r = 1, ROWS do
        b[r] = {}
        for c = 1, COLS do
            b[r][c] = nil
        end
    end
    return b
end

local function inBounds(r, c)
    return r >= 1 and r <= ROWS and c >= 1 and c <= COLS
end

local function checkWinAt(board, row, col, playerId)
    local dirs = { {0,1}, {1,0}, {1,1}, {1,-1} }
    for _, d in ipairs(dirs) do
        local dr, dc = d[1], d[2]
        local count = 1
        local r, c = row + dr, col + dc
        while inBounds(r, c) and board[r][c] == playerId do
            count = count + 1; r = r + dr; c = c + dc
        end
        r, c = row - dr, col - dc
        while inBounds(r, c) and board[r][c] == playerId do
            count = count + 1; r = r - dr; c = c - dc
        end
        if count >= 4 then return true end
    end
    return false
end

local function isBoardFull(board)
    for r = 1, ROWS do
        for c = 1, COLS do
            if board[r][c] == nil then return false end
        end
    end
    return true
end

-- Seat locking & match termination (defined early so initSlot captures local upvalues)
-- Forward declare helper referenced inside endMatch that is defined later
local updateCapacityText
local endMatch -- forward declaration

local function lockPlayers(session, lock)
    session.locked = lock
    if not session.seats then return end
    for i=1,2 do
        local pl = session.players[i]
        local seat = session.seats[i]
        if pl and seat then
            local hum = pl.Character and pl.Character:FindFirstChildOfClass("Humanoid")
            if hum then
                if lock then
                    if seat.Occupant ~= hum then seat:Sit(hum) end
                    if not session.originalStats[pl] then
                        session.originalStats[pl] = { ws = hum.WalkSpeed, jp = hum.JumpPower }
                    end
                    hum.WalkSpeed, hum.JumpPower = 0, 0
                    local root = pl.Character:FindFirstChild("HumanoidRootPart")
                    if root then root.Anchored = true end
                else
                    local st = session.originalStats[pl]
                    if st then
                        hum.WalkSpeed = st.ws; hum.JumpPower = st.jp
                    else
                        hum.WalkSpeed = 16; hum.JumpPower = 50
                    end
                    local root = pl.Character:FindFirstChild("HumanoidRootPart")
                    if root then root.Anchored = false end
                end
            end
        end
    end
end

function endMatch(session, winner, loser, reason)
    if not session.matchActive then return end
    session.matchActive = false
    session.acceptMoves = false
    session.timerTurnId += 1
    local msg
    if reason == "draw" then
        msg = "Draw!"
    elseif reason == "timeout" and winner and loser then
        msg = ("%s wins by timeout!"):format(winner.DisplayName)
    elseif reason == "win" and winner and loser then
        msg = ("%s wins!"):format(winner.DisplayName)
    elseif reason == "abort" then
        msg = "Match aborted"
    else
        msg = "Match ended"
    end
    if reason == "win" and winner and loser then
        local w,l = winner.DisplayName, loser.DisplayName
        narrateCustom(session, {
            winner == session.players[1] and ("You win! %s defeated."):format(l) or ("You lose. %s wins."):format(w),
            winner == session.players[2] and ("You win! %s defeated."):format(l) or ("You lose. %s wins."):format(w),
        })
    elseif reason == "timeout" and winner and loser then
        local w,l = winner.DisplayName, loser.DisplayName
        narrateCustom(session, {
            winner == session.players[1] and ("%s ran out of time. You win!"):format(l) or ("You ran out of time. %s wins."):format(w),
            winner == session.players[2] and ("%s ran out of time. You win!"):format(l) or ("You ran out of time. %s wins."):format(w),
        })
    elseif reason == "draw" then
        narrateTo(session, "Draw! Nobody wins.")
    else
        narrateTo(session, msg)
    end
    -- Reset camera for participants
    sendCameraEvent(session, "Reset")
    if loser and loser.Character then
        local hum = loser.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.Health = 0 end
    end
    if winner and winner.Character then
        local hum = winner.Character:FindFirstChildOfClass("Humanoid")
        local st = session.originalStats[winner]
        if hum and st then
            hum.WalkSpeed, hum.JumpPower = st.ws, st.jp
        end
        local root = winner.Character:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = false end
    end
    -- Immediately unlock seats so winner can stand up now that match ended
    if session.lockPlayers then session.lockPlayers(session, false) end
    session.locked = false
    if session.seats then
        for i=1,2 do
            local seat = session.seats[i]
            if seat and seat.Occupant then
                local hum = seat.Occupant
                task.defer(function()
                    if hum and hum.Parent then hum.Sit = false end
                end)
            end
        end
    end
    task.delay(3, function()
        local folder = session.connect4Model:FindFirstChild("SpawnedTokens")
        if folder then folder:ClearAllChildren() end
        session.board = newBoard()
        session.turnIndex = 1
        updateCapacityText(session)
        session.preMatchCountdown = false
    end)
    print("[Connect4]["..session.slotName.."] Match end reason="..tostring(reason).." winner="..(winner and winner.Name or "-").." loser="..(loser and loser.Name or "-") )
end

-- World Display helpers (per-slot SurfaceGui at slotModel.Display)
local function getWorldLabel(slotModel)
    -- Preferred path: Slot.Capacity.Display (SurfaceGui or BillboardGui) -> TextLabel
    local capacity = slotModel:FindFirstChild("Capacity")
    local display
    if capacity then
        display = capacity:FindFirstChild("Display")
    end
    if not display then
        display = slotModel:FindFirstChild("Display")
    end
    if display and (display:IsA("SurfaceGui") or display:IsA("BillboardGui")) then
        local label = display:FindFirstChildWhichIsA("TextLabel", true)
        return label
    end
    return nil
end

local function setCapacityLabel(session, text)
    local label = getWorldLabel(session.slotModel)
    if label then label.Text = text end
end

local function getCapacityDisplay(session)
    local cap = session.slotModel:FindFirstChild("Capacity")
    if not cap then return nil end
    local display = cap:FindFirstChild("Display")
    if display and (display:IsA("SurfaceGui") or display:IsA("BillboardGui")) then
        return display
    end
    return nil
end

updateCapacityText = function(session)
    local count = 0
    if session.players[1] then count = count + 1 end
    if session.players[2] then count = count + 1 end
    setCapacityLabel(session, string.format("%d/2 Players", count))
    local display = getCapacityDisplay(session)
    if display then
        -- Hide capacity label once both players are seated; show otherwise
        display.Enabled = (count < 2)
    end
end

-- Decide if columns extend along X (default) or Z (if Z wider than X)
local function columnsAlongZ(size: Vector3): boolean
    return size.Z > size.X
end

-- Token / cell world CFrame helpers
-- New semantics: frontOffset is now relative to the CENTER of the board thickness (same as hitboxes),
-- not an offset from the front face. (So 0 => geometric center, positive pushes toward the board's normal.)
local function cellWorldCFrame(grid, row, col, frontOffset)
    frontOffset = frontOffset or 0
    local size = grid.Size
    local alongZ = columnsAlongZ(size)
    local width = alongZ and size.Z or size.X
    local cellW = width / COLS
    local cellH = size.Y / ROWS
    local along = -width/2 + (col - 0.5) * cellW
    local yLocal = size.Y/2 - (row - 0.5) * cellH
    local cf = grid.CFrame
    local right = cf.RightVector
    local look = cf.LookVector
    local up = cf.UpVector
    local columnAxis = alongZ and look or right
    local normal = alongZ and right or look
    local pos = cf.Position + columnAxis * along + up * yLocal + normal * frontOffset
    return CFrame.lookAt(pos, pos + normal, up)
end

local function columnSpawnCFrame(grid, col, frontOffset, heightAbove)
    frontOffset = frontOffset or 0
    heightAbove = heightAbove or 5
    local size = grid.Size
    local alongZ = columnsAlongZ(size)
    local width = alongZ and size.Z or size.X
    local cellW = width / COLS
    local along = -width/2 + (col - 0.5) * cellW
    local cf = grid.CFrame
    local right = cf.RightVector
    local look = cf.LookVector
    local up = cf.UpVector
    local columnAxis = alongZ and look or right
    local normal = alongZ and right or look
    local pos = cf.Position + columnAxis * along + up * (size.Y/2 + heightAbove) + normal * frontOffset
    return CFrame.lookAt(pos, pos + normal, up)
end

local function getTokensFolder(connect4Model)
    local folder = connect4Model:FindFirstChild("SpawnedTokens")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "SpawnedTokens"
        folder.Parent = connect4Model
    end
    return folder
end

local sessions = {}

local function resolveGridPart(connect4Model)
    -- Try 'Grid' as BasePart first
    local g = connect4Model:FindFirstChild("Grid", true)
    if g and g:IsA("BasePart") then return g end
    -- If 'Grid' is a Model, find first BasePart under it
    if g and g:IsA("Model") then
        local bp = g:FindFirstChildWhichIsA("BasePart", true)
        if bp then return bp end
    end
    -- Otherwise, find any BasePart named 'Grid' under the Connect4 model
    for _, d in ipairs(connect4Model:GetDescendants()) do
        if d:IsA("BasePart") and d.Name == "Grid" then
            return d
        end
    end
    -- Fallback: any BasePart under Connect4 (last resort)
    return connect4Model:FindFirstChildWhichIsA("BasePart", true)
end

-- Find alignment reference: only a direct child named 'Alignment' under the 'Grid' model (no deep or variant search)
local function findAlignmentPart(connect4Model, gridPart)
    local gridContainer = connect4Model:FindFirstChild("Grid")
    if gridContainer then
        local a = gridContainer:FindFirstChild("Alignment")
        if a and a:IsA("BasePart") then return a end
    end
    return nil
end

local function createDebugCells(session)
    if not DEBUG_CELL_MARKERS then return end
    if session.debugCellsFolder and session.debugCellsFolder.Parent then return end
    local folder = Instance.new("Folder")
    folder.Name = "DebugCells"
    folder.Parent = session.connect4Model
    session.debugCellsFolder = folder
    for r=1, ROWS do
        for c=1, COLS do
            local cf = cellWorldCFrame(session.refPart or session.gridPart, r, c, 0.4)
            local part = Instance.new("Part")
            part.Name = ("Cell_%d_%d"):format(r,c)
            part.Size = Vector3.new(0.4,0.4,0.4)
            part.Anchored = true
            part.CanCollide = false
            part.Material = Enum.Material.Neon
            part.Color = Color3.fromRGB(255 - r*20, 50 + c*25, 255 - c*15)
            part.CFrame = cf
            part.Parent = folder
        end
    end
end

-- Turn timer (placed before ensureHitboxes so click handler can call it)
local function startTurnTimer(session)
    session.timerTurnId = session.timerTurnId + 1
    local myId = session.timerTurnId
    print("[Connect4]["..session.slotName.."] Turn timer start id="..myId.." turn="..session.turnIndex)
    task.spawn(function()
        local waited = 0
        while waited < 25 do
            if myId ~= session.timerTurnId then return end
            waited += 0.5
            task.wait(0.5)
        end
        print("[Connect4]["..session.slotName.."] Base 25s elapsed; 10s warning phase")
        for t = 10, 1, -1 do
            if myId ~= session.timerTurnId then return end
            local cur = session.players[session.turnIndex]
            if not cur then return end
            narrateTo(session, string.format("%s: %d seconds to move...", cur.DisplayName, t))
            task.wait(1)
        end
        if myId ~= session.timerTurnId then return end
        local cur = session.players[session.turnIndex]
        local other = session.players[3 - session.turnIndex]
        if cur and other then
            narrateTo(session, string.format("%s ran out of time. Turn passes to %s.", cur.DisplayName, other.DisplayName))
            session.turnIndex = 3 - session.turnIndex
            session.timerTurnId += 1
            startTurnTimer(session)
        end
    end)
end

local function ensureHitboxes(session)
    if session.hitboxFolder and session.hitboxFolder.Parent ~= nil then
        return
    end
    local grid = session.refPart or session.gridPart
    local connect4Model = session.connect4Model
    local hbFolder = Instance.new("Folder")
    hbFolder.Name = "ColumnHitboxes"
    hbFolder.Parent = connect4Model
    local size = grid.Size
    local alongZ = columnsAlongZ(size)
    local width = alongZ and size.Z or size.X
    local depth = alongZ and size.X or size.Z
    -- Fallback: if chosen width is extremely thin (<= planeDepth * 1.1), swap axes to avoid overlapping hitboxes
    local planeDepthFallback = 0.45
    if width <= planeDepthFallback * 1.1 then
        alongZ = not alongZ
        width = alongZ and size.Z or size.X
        depth = alongZ and size.X or size.Z
        if DEBUG_GEOMETRY then
            print("[Connect4]["..session.slotName.."] Width too small for columns; swapping axis. New alongZ="..tostring(alongZ).." width="..tostring(width).." depth="..tostring(depth))
        end
    end
    local cellW = width / COLS
    local planeDepth = 0.45
    local height = size.Y + 2
    if DEBUG_GEOMETRY then
        print( string.format("[Connect4][%s] Build hitboxes refPart=%s size=(%.3f,%.3f,%.3f) alongZ=%s width=%.3f depth=%.3f cellW=%.3f", session.slotName, grid.Name, size.X,size.Y,size.Z, tostring(alongZ), width, depth, cellW) )
    end
    for c = 1, COLS do
        local hit = Instance.new("Part")
        hit.Name = "ColHitbox_" .. c
        hit.Anchored = true
        hit.Transparency = SHOW_COLUMN_ZONES and 0.85 or 1
        if SHOW_COLUMN_ZONES then
            hit.Color = Color3.fromRGB(60 + c*20, 180, 255 - c*15)
            hit.Material = Enum.Material.ForceField
        end
        hit.CanCollide = false
        hit.CanQuery = true -- must be true so ClickDetector can pick it
        if alongZ then
            hit.Size = Vector3.new(planeDepth, height, cellW)
        else
            hit.Size = Vector3.new(cellW, height, planeDepth)
        end
        -- Center the hitbox in board thickness instead of pushing it to the front face.
        -- Optional attribute 'FrontOffset' (studs) on Grid or Alignment can nudge forward/back.
        local frontOffsetAttr = 0
        local attrSource = session.refPart or session.gridPart
        if attrSource and attrSource:GetAttribute("FrontOffset") then
            frontOffsetAttr = tonumber(attrSource:GetAttribute("FrontOffset")) or 0
        end
        -- Recompute column center manually (avoid top-only approach used before)
        local cfGrid = grid.CFrame
        local right = cfGrid.RightVector
        local look = cfGrid.LookVector
        local up = cfGrid.UpVector
        local columnAxis = alongZ and look or right
        local normal = alongZ and right or look
        local along = -width/2 + (c - 0.5) * cellW
        local normalOffset = frontOffsetAttr -- 0 means geometric center of board thickness
        local centerPos = cfGrid.Position + columnAxis * along + normal * normalOffset
        local cf = CFrame.lookAt(centerPos, centerPos + normal, up)
        hit.CFrame = cf
        hit.Parent = hbFolder
        if DEBUG_GEOMETRY then
            local pos = cf.Position
            print(string.format("[Connect4][%s] Col %d center (%.3f, %.3f, %.3f)", session.slotName, c, pos.X,pos.Y,pos.Z))
        end
        local cd = Instance.new("ClickDetector")
        cd.MaxActivationDistance = 38
        cd.Parent = hit
        if SHOW_COLUMN_ZONES then
            local originalColor = hit.Color
            cd.MouseHoverEnter:Connect(function()
                if session.acceptMoves then
                    hit.Color = Color3.fromRGB(255,255,255)
                    hit.Transparency = 0.6
                end
            end)
            cd.MouseHoverLeave:Connect(function()
                hit.Color = originalColor
                hit.Transparency = 0.85
            end)
        end

        cd.MouseClick:Connect(function(player)
            -- Always use latest reference part (alignment) for placement math
            local refGrid = session.refPart or session.gridPart
            print("[Connect4]["..session.slotName.."] Raw click c="..c.." by="..player.Name.." busy="..tostring(session.busy).." accept="..tostring(session.acceptMoves).." turn="..session.turnIndex .." refPart="..refGrid.Name)
            if session.busy or not session.acceptMoves then return end
            if player ~= session.players[1] and player ~= session.players[2] then return end
            local idx = (player == session.players[1]) and 1 or 2
            if idx ~= session.turnIndex then return end
            local col = c
            local board = session.board
            local dropRow
            for r = ROWS, 1, -1 do
                if board[r][col] == nil then dropRow = r break end
            end
            if not dropRow then return end
            session.busy = true
            print("[Connect4]["..session.slotName.."] Move accepted col="..col.." row="..dropRow.." by="..player.Name)
            local defaultTokenName = (idx == 1) and "Red" or "Yellow"
            local m = getTokenModelFor(player, defaultTokenName)
            if not m then
                local part = Instance.new("Part")
                part.Size = Vector3.new(1.8,1.8,0.4)
                part.Shape = Enum.PartType.Cylinder
                part.Material = Enum.Material.SmoothPlastic
                part.Color = (idx == 1) and Color3.fromRGB(220,60,60) or Color3.fromRGB(250,210,20)
                part.Anchored = true
                m = Instance.new("Model")
                part.Parent = m
                m.PrimaryPart = part
            end
            if session.players[1] and session.players[2] then
                local p1Skin = session.players[1]:GetAttribute("TokenSkin")
                local p2Skin = session.players[2]:GetAttribute("TokenSkin")
                if p1Skin and p2Skin and p1Skin == p2Skin and idx == 2 then
                    setModelHueShift(m, 0.05)
                end
            end
            m.Name = ("Token_%d_%d"):format(dropRow,col)
            m.Parent = getTokensFolder(session.connect4Model)
            ensurePrimaryPart(m)
            -- Use the same FrontOffset attribute (relative to center) used for hitboxes so tokens align perfectly
            local attrSource = session.refPart or session.gridPart
            local frontOffsetAttr = 0
            if attrSource and attrSource:GetAttribute("FrontOffset") then
                frontOffsetAttr = tonumber(attrSource:GetAttribute("FrontOffset")) or 0
            end
            local spawnCF = columnSpawnCFrame(refGrid, col, frontOffsetAttr, 5)
            local targetCF = cellWorldCFrame(refGrid, dropRow, col, frontOffsetAttr)
            m:PivotTo(spawnCF)
            pivotTween(m, targetCF, 0.35 + (ROWS - dropRow) * 0.03)
            board[dropRow][col] = player.UserId
            if checkWinAt(board, dropRow, col, player.UserId) then
                print("[Connect4]["..session.slotName.."] WIN by="..player.Name)
                local winner = player
                local loser = (idx == 1) and session.players[2] or session.players[1]
                session.busy = false -- clear busy so fallback still allows logic
                print("[Connect4]["..session.slotName.."] Attempting endMatch; matchActive="..tostring(session.matchActive).." endMatchFn="..tostring(session.endMatch))
                if session.endMatch then
                    session.endMatch(session, winner, loser, "win")
                else
                    -- Fallback minimal cleanup
                    narrateTo(session, winner.DisplayName .. " wins!")
                    session.acceptMoves = false
                    session.matchActive = false
                    task.delay(3, function()
                        getTokensFolder(session.connect4Model):ClearAllChildren()
                        session.board = newBoard()
                        session.turnIndex = 1
                    end)
                end
                return
            end
            if isBoardFull(board) then
                print("[Connect4]["..session.slotName.."] DRAW condition")
                if session.endMatch then session.endMatch(session, nil, nil, "draw") end
                return
            end
            session.turnIndex = 3 - session.turnIndex
            session.busy = false
            session.timerTurnId += 1
            print("[Connect4]["..session.slotName.."] Turn switched -> "..session.turnIndex)
            local mover = session.players[session.turnIndex]
            if mover then narrateTo(session,("%s is placing their token..."):format(mover.DisplayName)) end
            startTurnTimer(session)
        end)
    end
    session.hitboxFolder = hbFolder
    createDebugCells(session)
end

-- Re-select alignment reference and rebuild hitboxes if needed
local function updateRefPart(session)
    if not session or not session.connect4Model then return end
    local previous = session.refPart
    local connect4Model = session.connect4Model
    local grid = session.gridPart
    local ref = previous
    local gridModel = connect4Model:FindFirstChild("Grid")
    local a = gridModel and gridModel:FindFirstChild("Alignment")
    if a and a:IsA("BasePart") then
        ref = a
    else
        ref = grid
    end
    if ref ~= previous then
        session.refPart = ref
        -- Disconnect old watchers
        if session._refWatch then
            for _, conn in ipairs(session._refWatch) do
                if typeof(conn) == "RBXScriptConnection" then conn:Disconnect() end
            end
        end
        session._refWatch = {}
        if session.hitboxFolder then session.hitboxFolder:Destroy(); session.hitboxFolder = nil end
        if session.debugCellsFolder then session.debugCellsFolder:Destroy(); session.debugCellsFolder = nil end
        print("[Connect4]["..session.slotName.."] Alignment reference changed -> "..ref.Name)
        ensureHitboxes(session)
        if DEBUG_CELL_MARKERS then createDebugCells(session) end
        -- Attach live tracking for movement / resize to rebuild geometry
        local function attachWatch(prop)
            local ok, sig = pcall(function() return ref:GetPropertyChangedSignal(prop) end)
            if ok and sig then
                table.insert(session._refWatch, sig:Connect(function()
                    -- Rebuild only hitboxes (tokens keep their world positions)
                    if session.hitboxFolder then session.hitboxFolder:Destroy(); session.hitboxFolder = nil end
                    if DEBUG_CELL_MARKERS and session.debugCellsFolder then session.debugCellsFolder:Destroy(); session.debugCellsFolder = nil end
                    ensureHitboxes(session)
                    if DEBUG_CELL_MARKERS then createDebugCells(session) end
                end))
            end
        end
        attachWatch("CFrame")
        attachWatch("Size")
    end
end

-- (duplicate startTurnTimer removed; single definition appears earlier)

local function onSeatsChanged(session, seats)
    local p1 = seats[1] and safeGetPlayerFromOccupant(seats[1].Occupant) or nil
    local p2 = seats[2] and safeGetPlayerFromOccupant(seats[2].Occupant) or nil
    session.players[1] = p1
    session.players[2] = p2

    -- Update capacity UI on world display
    updateCapacityText(session)

    -- Cancel any pending timers/countdowns when seating changes
    session.timerTurnId = session.timerTurnId + 1
    session.countdownId = (session.countdownId or 0) + 1

    -- If match active we do NOT allow players to truly leave; reseat them if they try.
    if session.matchActive then
        -- During an active match we enforce seating & abort if someone leaves
        for i=1,2 do
            local expectedPlayer = session.players[i]
            local seat = session.seats and session.seats[i]
            if expectedPlayer and seat then
                local hum = expectedPlayer.Character and expectedPlayer.Character:FindFirstChildOfClass("Humanoid")
                if hum and seat.Occupant ~= hum then
                    task.defer(function()
                        seat:Sit(hum)
                    end)
                end
            end
        end
        if not (p1 and p2) then
            if session.endMatch then
                session.endMatch(session, nil, nil, "abort")
            end
        end
        return
    end

    -- If we are in countdown but a player left, cancel countdown
    if session.preMatchCountdown and not (p1 and p2) then
        session.preMatchCountdown = false
        session.acceptMoves = false
        narrateTo(session, "Countdown cancelled.")
        if session.lockPlayers then session.lockPlayers(session, false) end
    end

    if p1 and p2 then
        -- Two players seated: run a 5-second pre-match countdown (do NOT lock seats yet)
        session.acceptMoves = false
        session.preMatchCountdown = true
        local myCd = session.countdownId
    print("[Connect4]["..session.slotName.."] Countdown begin")
        task.spawn(function()
            for t = 5, 1, -1 do
                if myCd ~= session.countdownId then return end
                local msg = string.format("Match starting in %d", t)
                narrateTo(session, msg)
        print("[Connect4]["..session.slotName.."] t="..t)
                task.wait(1)
            end
            if myCd ~= session.countdownId then return end
            -- Start match: now lock seats
            session.board = newBoard()
            session.turnIndex = 1
            local folder = getTokensFolder(session.connect4Model)
            folder:ClearAllChildren()
            session.acceptMoves = true
            session.matchActive = true
            session.preMatchCountdown = false
            if session.lockPlayers then session.lockPlayers(session, true) end
            local startMsg = string.format("%s to move. Place your token.", p1.DisplayName)
            narrateTo(session, startMsg)
            sendCameraEvent(session, "Focus")
        print("[Connect4]["..session.slotName.."] Match start. P1="..p1.Name.." P2="..p2.Name)
            startTurnTimer(session)
        end)
    else
        -- Less than two players
        session.acceptMoves = false
    end
end

local function initSlot(slotModel)
    if sessions[slotModel] then return end
    local connect4Model = slotModel:FindFirstChild("Connect4")
    if not (connect4Model and connect4Model:IsA("Model")) then
        -- Wait for Connect4 to be added later
        slotModel.ChildAdded:Connect(function(child)
            if child.Name == "Connect4" and child:IsA("Model") then
                -- try init again
                initSlot(slotModel)
            end
        end)
        return
    end

    local grid = resolveGridPart(connect4Model)
    if not (grid and grid:IsA("BasePart")) then
        -- If grid part not present yet (e.g., streamed or inserted later), watch descendants briefly
        connect4Model.DescendantAdded:Connect(function(d)
            if not sessions[slotModel] then
                local gp = resolveGridPart(connect4Model)
                if gp and gp:IsA("BasePart") then
                    initSlot(slotModel)
                end
            end
        end)
        return
    end

    -- Optional alignment override: a transparent child part used only for token/grid math
    local refPart = findAlignmentPart(connect4Model, grid) or grid
    if refPart ~= grid then
        print("[Connect4]["..slotModel.Name.."] Using Alignment part '"..refPart.Name.."' for geometry instead of Grid")
    end

    local session = {
        slotModel = slotModel,
        connect4Model = connect4Model,
        gridPart = grid,
    refPart = refPart, -- geometry reference (Alignment if present else Grid)
        slotName = slotModel.Name,
        players = { nil, nil },
        turnIndex = 1,
        board = newBoard(),
        hitboxFolder = nil,
        timerTurnId = 0,
        busy = false,
        acceptMoves = false,
        countdownId = 0,
        matchActive = false,
        originalStats = {},
    }
    sessions[slotModel] = session
    session.lockPlayers = lockPlayers
    session.endMatch = endMatch
    -- Heartbeat enforcement for locking
    task.spawn(function()
        while sessions[slotModel] == session do
            if session.locked and session.seats then
                for i=1,2 do
                    local pl = session.players[i]
                    local seat = session.seats[i]
                    if pl and seat then
                        local hum = pl.Character and pl.Character:FindFirstChildOfClass("Humanoid")
                        if hum then
                            if seat.Occupant ~= hum then seat:Sit(hum) end
                            hum.WalkSpeed = 0; hum.JumpPower = 0
                            local root = pl.Character:FindFirstChild("HumanoidRootPart")
                            if root then root.Anchored = true end
                        end
                    end
                end
            end
            task.wait(0.25)
        end
    end)

    ensureHitboxes(session)
    -- Print initial reference summary
    local rp = session.refPart or session.gridPart
    print("[Connect4]["..session.slotName.."] Using refPart="..rp.Name.." size="..tostring(rp.Size).." position="..tostring(rp.Position))
    -- Watch for alignment part added later
    connect4Model.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") and d.Name == "Alignment" and d.Parent and d.Parent.Name == "Grid" then
            updateRefPart(session)
        end
    end)
    -- Also if a potential alignment part is removed, revert to grid
    connect4Model.DescendantRemoving:Connect(function(d)
        if d == session.refPart then
            task.defer(function()
                updateRefPart(session)
            end)
        end
    end)

    local seats = getTwoSeatsForSlot(slotModel, grid)
    if #seats < 2 then
        warn("Connect4 slot '" .. slotModel.Name .. "' needs two seats; found: " .. tostring(#seats))
    else
        local function hook(seat)
            seat:GetPropertyChangedSignal("Occupant"):Connect(function()
                onSeatsChanged(session, seats)
            end)
        end
        hook(seats[1])
        hook(seats[2])
    session.seats = seats
    onSeatsChanged(session, seats)
    end
end

-- (Removed duplicate old lockPlayers/endMatch block)

-- Boot: scan and watch Workspace.PlayingSlots
local playingSlots = Workspace:WaitForChild("PlayingSlots")
for _, slot in ipairs(playingSlots:GetChildren()) do
    if slot:IsA("Model") then
        initSlot(slot)
    end
end
playingSlots.ChildAdded:Connect(function(child)
    if child:IsA("Model") then
        task.wait()
        initSlot(child)
    end
end)
