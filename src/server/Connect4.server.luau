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
-- Require DataManager ModuleScript (not a Script). Add explicit check to surface clearer error if misconfigured.
local dmObj = script.Parent:WaitForChild("DataManager")
assert(dmObj:IsA("ModuleScript"), "DataManager must be a ModuleScript; found " .. dmObj.ClassName)
local DataManager = require(dmObj)

-- Lazy TokenConfig warm (no WaitForChild chain to missing path)
task.spawn(function()
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    if sharedFolder then
        local configs = sharedFolder:FindFirstChild("Configs")
        if configs then
            local tc = configs:FindFirstChild("TokenConfig")
            if tc and tc:IsA("ModuleScript") then
                pcall(function() require(tc) end)
            end
        end
    end
end)
local ROWS, COLS = 6, 7
local SHOW_COLUMN_ZONES = true -- visualize clickable column areas (for debugging/UX)
local DEBUG_CELL_MARKERS = false -- set true to spawn small parts at each cell center
local DEBUG_GEOMETRY = false -- disabled to reduce output noise
local DEBUG_ALIGNMENT = false -- controls alignment/refPart prints

-- Simple admin list: populate with UserIds allowed to run coin commands
local ADMIN_USER_IDS: {[number]: boolean} = {
    [157780202] = true, -- owner id provided
}

local function isAdmin(plr: Player): boolean
    if ADMIN_USER_IDS[plr.UserId] then return true end
    -- Treat place owner as admin (works for personal places). For group games this check is permissive only for ownerId.
    local ownerId = game.CreatorId
    if ownerId and ownerId ~= 0 and plr.UserId == ownerId then return true end
    return false
end

-- Centralized stat initialization (server-authoritative)
local function ensurePlayerStats(plr: Player)
    -- Only expose selected stats publicly (hide Coins & HighestStreak from leaderboard)
    local ls = plr:FindFirstChild("leaderstats")
    if not ls then
        ls = Instance.new("Folder")
        ls.Name = "leaderstats"
        ls.Parent = plr
    end
    local function ensureIntVisible(name)
        local v = ls:FindFirstChild(name)
        if not v then
            v = Instance.new("IntValue")
            v.Name = name
            v.Value = 0
            v.Parent = ls
        end
        return v
    end
    local wins = ensureIntVisible("Wins")
    local streak = ensureIntVisible("Streak")

    -- Hidden stats moved to attributes
    if plr:GetAttribute("Coins") == nil then plr:SetAttribute("Coins", 0) end
    if plr:GetAttribute("HighestStreak") == nil then plr:SetAttribute("HighestStreak", 0) end

    -- Sync from DataManager profile if loaded
    pcall(function()
        local pf = DataManager.getProfile(plr)
        wins.Value = pf.Wins
        streak.Value = pf.Streak
        plr:SetAttribute("Coins", pf.Coins)
        plr:SetAttribute("HighestStreak", pf.HighestStreak)
    end)

    -- Change listeners to push updates back into profile
    wins.Changed:Connect(function(val)
        DataManager.setStatFromLeaderstat(plr, "Wins", wins.Value)
    end)
    streak.Changed:Connect(function(val)
        DataManager.setStatFromLeaderstat(plr, "Streak", streak.Value)
        -- Highest streak update
        local currentHigh = plr:GetAttribute("HighestStreak") or 0
        if streak.Value > currentHigh then
            plr:SetAttribute("HighestStreak", streak.Value)
            DataManager.setStatFromLeaderstat(plr, "HighestStreak", streak.Value)
        end
    end)
end

-- Generic stat command handler (/coins, /wins, /streak, /higheststreak)
local ATTRIBUTE_STATS: {[string]: boolean} = { Coins = true, HighestStreak = true }
local LEADERSTATS_STATS: {[string]: boolean} = { Wins = true, Streak = true }

local function handleStatCommand(sender: Player, raw: string, statName: string)
    if not isAdmin(sender) then return end
    local lowerStat = statName:lower()
    if not (ATTRIBUTE_STATS[statName] or LEADERSTATS_STATS[statName]) then
        warn('[Admin]['..sender.Name..'] Unsupported stat '.. statName)
        return
    end
    -- Tokenize
    local parts = {}
    for w in raw:gmatch('%S+') do table.insert(parts, w) end
    local sub = parts[2] and parts[2]:lower() or nil
    if not sub or (sub ~= 'add' and sub ~= 'remove' and sub ~= 'set') then
        print(('[Admin][%s] Usage: /%s add|remove <amount>  OR  /%s add|remove <player> <amount>  OR  /%s set <player> <amount>')
            :format(sender.Name, lowerStat, lowerStat, lowerStat))
        return
    end
    local target: Player? = sender
    local amountIndex = 3
    if sub == 'set' then
        if not parts[3] or not parts[4] then
            print(('[Admin][%s] Usage: /%s set <player> <amount>')
                :format(sender.Name, lowerStat))
            return
        end
        target = Players:FindFirstChild(parts[3]) :: Player?
        amountIndex = 4
    else
        if parts[3] and not tonumber(parts[3]) then
            target = Players:FindFirstChild(parts[3]) :: Player?
            amountIndex = 4
        end
    end
    if not target then
        print('[Admin]['..sender.Name..'] Player not found.')
        return
    end
    local amtStr = parts[amountIndex]
    if not amtStr then
        print('[Admin]['..sender.Name..'] Missing amount.')
        return
    end
    local amt = tonumber(amtStr)
    if not amt then
        print('[Admin]['..sender.Name..'] Amount must be a number.')
        return
    end
    amt = math.floor(amt)
    ensurePlayerStats(target)

    local beforeVal: number = 0
    if ATTRIBUTE_STATS[statName] then
        local attrVal = target:GetAttribute(statName)
        if typeof(attrVal) ~= 'number' then attrVal = 0 end
        beforeVal = attrVal :: number
    else
        local ls = target:FindFirstChild('leaderstats')
        local statObj = ls and ls:FindFirstChild(statName)
        if not (statObj and statObj:IsA('IntValue')) then
            print(('[Admin][%s] Stat %s not found for %s'):format(sender.Name, statName, target.Name))
            return
        end
        beforeVal = statObj.Value
    end

    local newVal = beforeVal
    if sub == 'set' then newVal = amt
    elseif sub == 'add' then newVal = newVal + amt
    elseif sub == 'remove' then newVal = newVal - math.abs(amt) end
    if newVal < 0 then newVal = 0 end

    if ATTRIBUTE_STATS[statName] then
        target:SetAttribute(statName, newVal)
        pcall(function()
            if DataManager and DataManager.setStatFromLeaderstat then
                DataManager.setStatFromLeaderstat(target, statName, newVal)
            end
        end)
    else
        local ls = target:FindFirstChild('leaderstats')
        local statObj = ls and ls:FindFirstChild(statName)
        if statObj and statObj:IsA('IntValue') then
            statObj.Value = newVal -- existing changed connections handle persistence
        end
    end

    local delta = newVal - beforeVal
    print(string.format('[Admin][%s] %s(%s): %d -> %d (%+d)', sender.Name, statName, target.Name, beforeVal, newVal, delta))
    if sender ~= target then
        print(string.format('[Admin][Notify %s] %s adjusted your %s: %d -> %d', target.Name, sender.Name, statName:lower(), beforeVal, newVal))
    end
end

local function onPlayerAdded(plr: Player)
    ensurePlayerStats(plr)

    -- Streak tag support
    -- Clone Assets.Streak (BillboardGui) to character Head and update on streak changes.
    local TextService = game:GetService("TextService")

    local function getStreakBillboard(character: Model): BillboardGui?
        local head = character:FindFirstChild("Head")
        if not head or not head:IsA("BasePart") then return nil end
        local existing = head:FindFirstChild("StreakTag")
        if existing and existing:IsA("BillboardGui") then return existing end
        -- Locate template once
        local assets = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
        local template = assets and assets:FindFirstChild("Streak")
        if not (template and template:IsA("BillboardGui")) then return nil end
        local cloned = template:Clone()
        cloned.Name = "StreakTag"
        cloned.Enabled = false
        cloned.Parent = head
        return cloned
    end

    local function updateStreakTag(targetPlayer: Player)
        local character = targetPlayer.Character
        if not character then return end
        local bill = getStreakBillboard(character)
        if not bill then return end
        -- Obtain streak IntValue from leaderstats
        local ls = targetPlayer:FindFirstChild("leaderstats")
        local streakVal = ls and ls:FindFirstChild("Streak")
        local current = (streakVal and streakVal:IsA("IntValue")) and streakVal.Value or 0
        if current <= 0 then
            bill.Enabled = false
            return
        end
        bill.Enabled = true
        -- Expect hierarchy: BillboardGui -> Frame (maybe) -> Amount (TextLabel)
        local amountLabel: TextLabel? = nil
        -- Try direct child named Amount
        local direct = bill:FindFirstChild("Amount")
        if direct and direct:IsA("TextLabel") then
            amountLabel = direct
        else
            for _,desc in ipairs(bill:GetDescendants()) do
                if desc.Name == "Amount" and desc:IsA("TextLabel") then
                    amountLabel = desc
                    break
                end
            end
        end
        if not amountLabel then return end
        local textStr = tostring(current)
        amountLabel.Text = textStr
        -- Dynamic width sizing using GetTextBoundsParams (Montserrat ExtraBold)
        local params = Instance.new("GetTextBoundsParams")
        params.Text = textStr
        -- If the font asset isn't available, fallback to existing font face
        local okFont, fontFace = pcall(function()
            return Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold)
        end)
        if okFont and fontFace then
            params.Font = fontFace
            amountLabel.FontFace = fontFace
        elseif amountLabel.FontFace then
            params.Font = amountLabel.FontFace
        else
            params.Font = Font.fromEnum(amountLabel.Font)
        end
        -- Use the label's current pixel height as reference size
        local pixelHeight = amountLabel.AbsoluteSize.Y
        if pixelHeight <= 0 then pixelHeight = amountLabel.TextSize end
        params.Size = pixelHeight
        local success, bounds = pcall(function()
            return TextService:GetTextBoundsAsync(params)
        end)
        if success and typeof(bounds) == "Vector2" then
            amountLabel.TextSize = pixelHeight
            local pad = 8
            local desiredPixelWidth = bounds.X + pad
            local billboard = bill
            local billboardWidth = billboard.AbsoluteSize.X
            -- Fallback if AbsoluteSize is 0 on server (can happen): keep offset sizing
            if billboardWidth > 0 then
                amountLabel.Size = UDim2.fromScale(desiredPixelWidth / billboardWidth, 1)
            else
                -- Keep Scale X, adjust offset only
                amountLabel.Size = UDim2.new(amountLabel.Size.X.Scale, math.floor(desiredPixelWidth), amountLabel.Size.Y.Scale, amountLabel.Size.Y.Offset)
            end
        end
    end

    -- Expose for future modules if needed
    plr:SetAttribute("_HasStreakTag", true)

    local function hookCharacter(char: Model)
        -- ensure billboard exists immediately
        task.defer(function()
            getStreakBillboard(char)
            updateStreakTag(plr)
        end)
    end
    if plr.Character then hookCharacter(plr.Character) end
    plr.CharacterAdded:Connect(hookCharacter)

    -- React to streak changes
    task.defer(function()
        local ls = plr:FindFirstChild("leaderstats") or plr:WaitForChild("leaderstats", 10)
        if ls then
            local streakVal = ls:FindFirstChild("Streak")
            if streakVal and streakVal:IsA("IntValue") then
                streakVal.Changed:Connect(function()
                    updateStreakTag(plr)
                end)
            end
        end
    end)

    plr.Chatted:Connect(function(msg)
        local lower = msg:lower()
        -- coinadmin legacy
        if lower:sub(1,10) == '/coinadmin' or lower:sub(1,10) == '!coinadmin' then
            if isAdmin(plr) then
                print('[Admin]['..plr.Name..'] Admin stat commands active.')
            end
            return
        end
        local cmd = lower:match('^[/!](%w+)')
        if not cmd then return end
        if cmd == 'coins' then
            handleStatCommand(plr, msg, 'Coins')
        elseif cmd == 'wins' then
            handleStatCommand(plr, msg, 'Wins')
        elseif cmd == 'streak' then
            handleStatCommand(plr, msg, 'Streak')
        elseif cmd == 'higheststreak' then
            handleStatCommand(plr, msg, 'HighestStreak')
        end
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, existing in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, existing)
end

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
    local useVariant = false
    if typeof(skinName) == "string" and skinName ~= "" and TOKENS:FindFirstChild(skinName) then
        modelName = skinName
        -- Determine variant need: both players in session share same skin
        -- We'll look up current sessions by scanning active sessions for this player (simple linear search)
        for _, session in pairs(activeSessions) do
            if session.players and (session.players[1] == player or session.players[2] == player) then
                local other = (session.players[1] == player) and session.players[2] or session.players[1]
                if other and other:GetAttribute("TokenSkin") == skinName and other ~= player then
                    useVariant = (session.players[2] == player) -- arbitrarily second player gets variant
                end
                break
            end
        end
    end
    local srcParent = TOKENS
    if useVariant then
        local variantsFolder = TOKENS:FindFirstChild("Variants")
        if variantsFolder and variantsFolder:FindFirstChild(modelName) then
            srcParent = variantsFolder
        end
    end
    local src = srcParent:FindFirstChild(modelName)
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

-- Extended: now returns (won:boolean, chain: { {r,c}... } ) for the first 4+ direction found
local function checkWinAt(board, row, col, playerId)
    local dirs = { {0,1}, {1,0}, {1,1}, {1,-1} }
    for _, d in ipairs(dirs) do
        local dr, dc = d[1], d[2]
        local chain = { {row, col} }
        -- forward
        local r, c = row + dr, col + dc
        while inBounds(r, c) and board[r][c] == playerId do
            table.insert(chain, {r, c}); r = r + dr; c = c + dc
        end
        -- backward
        r, c = row - dr, col - dc
        while inBounds(r, c) and board[r][c] == playerId do
            table.insert(chain, {r, c}); r = r - dr; c = c - dc
        end
        if #chain >= 4 then
            return true, chain
        end
    end
    return false, nil
end

-- Highlight a winning chain before ending the match (1.5s delay)
local function highlightWin(session, chain, winner, loser)
    if session._winHighlighting then return end
    session._winHighlighting = true
    session.acceptMoves = false
    session.busy = false
    session.timerTurnId += 1 -- cancel any turn timers
    local rs = ReplicatedStorage
    local hlTemplate = rs:FindFirstChild("Highlight")
    if not (hlTemplate and hlTemplate:IsA("Highlight")) then
        -- Fallback: no template, end immediately
        if session.endMatch then
            session.endMatch(session, winner, loser, "win")
        end
        return
    end
    local tokenFolder = session.connect4Model:FindFirstChild("SpawnedTokens")
    local spawned = {}
    if tokenFolder then
        for _, pos in ipairs(chain) do
            local r, c = pos[1], pos[2]
            local name = ("Token_%d_%d"):format(r,c)
            local token = tokenFolder:FindFirstChild(name)
            if token then
                local hl = hlTemplate:Clone()
                -- Try adornee: prefer model PrimaryPart then first BasePart descendant
                local adornee = token.PrimaryPart
                if not adornee then
                    adornee = token:FindFirstChildWhichIsA("BasePart", true)
                end
                hl.FillTransparency = 1
                hl.OutlineTransparency = 1
                hl.Adornee = adornee
                hl.Parent = token
                table.insert(spawned, hl)
            end
        end
    end
    -- Tween transparencies
    local tweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    for _, hl in ipairs(spawned) do
        local tween = TweenService:Create(hl, tweenInfo, { FillTransparency = 0.5, OutlineTransparency = 0 })
        tween:Play()
    end
    -- After 1.5s finalize match
    task.delay(1.5, function()
        if session.endMatch and session.matchActive then
            session.endMatch(session, winner, loser, "win")
        end
    end)
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
    -- Update stats (Coins, Wins, Streak, HighestStreak) only on terminal outcomes (skip turn timeouts)
    if reason == "win" then
        if winner then
            ensurePlayerStats(winner)
            local ls = winner:FindFirstChild("leaderstats")
            local wins = ls and ls:FindFirstChild("Wins")
            local streak = ls and ls:FindFirstChild("Streak")
            if wins then wins.Value += 1; DataManager.setStatFromLeaderstat(winner, "Wins", wins.Value) end
            if streak then streak.Value += 1; DataManager.setStatFromLeaderstat(winner, "Streak", streak.Value) end
            -- Coins now stored as attribute
            local baseAward = 5
            local vipMult = 1
            if _G.Connect4_IsPlayerVIP then
                local ok, isVIP = pcall(function()
                    return _G.Connect4_IsPlayerVIP(winner)
                end)
                if ok and isVIP then vipMult = 2 end
            end
            local coinsAttr = winner:GetAttribute("Coins") :: any
            local newCoins = (typeof(coinsAttr) == "number" and coinsAttr or 0) + baseAward * vipMult
            winner:SetAttribute("Coins", newCoins)
            DataManager.setStatFromLeaderstat(winner, "Coins", newCoins)
            -- Highest streak attribute maintenance
            if streak then
                local currentHigh = winner:GetAttribute("HighestStreak")
                if typeof(currentHigh) ~= "number" or streak.Value > currentHigh then
                    winner:SetAttribute("HighestStreak", streak.Value)
                    DataManager.setStatFromLeaderstat(winner, "HighestStreak", streak.Value)
                end
            end
        end
        if loser then
            ensurePlayerStats(loser)
            local ls = loser:FindFirstChild("leaderstats")
            local streak = ls and ls:FindFirstChild("Streak")
            if streak then streak.Value = 0; DataManager.setStatFromLeaderstat(loser, "Streak", 0) end
        end
    elseif reason == "draw" then
    -- Draws give no coins now (per latest requirement). No stat mutation.
    elseif reason == "abort" then
        -- On abort do not change coins/wins but reset streak for absent player if any
        -- (Already handled indirectly when they lose? Not awarding here.)
    end

    task.delay(3, function()
        local folder = session.connect4Model:FindFirstChild("SpawnedTokens")
        if folder then folder:ClearAllChildren() end
        session.board = newBoard()
        session.turnIndex = 1
        updateCapacityText(session)
        session.preMatchCountdown = false
    -- Allow future matches to highlight again
    session._winHighlighting = false
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
            local won, chain = checkWinAt(board, dropRow, col, player.UserId)
            if won then
                print("[Connect4]["..session.slotName.."] WIN by="..player.Name)
                local winner = player
                local loser = (idx == 1) and session.players[2] or session.players[1]
                -- If highlight available, run highlightWin (delays endMatch). Otherwise immediate.
                if chain then
                    highlightWin(session, chain, winner, loser)
                else
                    if session.endMatch then
                        session.endMatch(session, winner, loser, "win")
                    end
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
            session._winHighlighting = false -- reset highlight guard for new match
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
    if refPart ~= grid and DEBUG_ALIGNMENT then
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
    if DEBUG_ALIGNMENT then
        print("[Connect4]["..session.slotName.."] Using refPart="..rp.Name.." size="..tostring(rp.Size).." position="..tostring(rp.Position))
    end
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
