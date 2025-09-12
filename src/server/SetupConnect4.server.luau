-- Ensures each table 1..15 has a Connect4 model by cloning from table '3' at runtime (server-side)
-- This runs on server so models replicate to all clients and persist during the session

local Workspace = game:GetService("Workspace")

local function getTablePivot(slot)
    local t = slot:FindFirstChild("table")
    if t and t:IsA("Model") then
        return t:GetPivot()
    end
    if slot:IsA("Model") then
        return slot:GetPivot()
    end
    error("Slot '" .. tostring(slot) .. "' is not a Model and has no 'table' child model")
end

local function cloneConnect4ToSlot(srcC4, srcTablePivot, localOffset, slot)
    if slot:FindFirstChild("Connect4") then return false end
    local clone = srcC4:Clone()
    clone.Name = "Connect4"
    clone.Parent = slot
    local targetPivot = getTablePivot(slot)
    clone:PivotTo(targetPivot * localOffset)
    return true
end

local function ensureAllTables()
    local playingSlots = Workspace:FindFirstChild("PlayingSlots")
    if not playingSlots then return end
    local srcSlot = playingSlots:FindFirstChild("3")
    if not (srcSlot and srcSlot:IsA("Model")) then return end
    local srcC4 = srcSlot:FindFirstChild("Connect4")
    if not (srcC4 and srcC4:IsA("Model")) then return end

    local srcTablePivot = getTablePivot(srcSlot)
    local srcC4Pivot = srcC4:GetPivot()
    local localOffset = srcTablePivot:ToObjectSpace(srcC4Pivot)

    local placed = 0
    for i = 1, 15 do
        local name = tostring(i)
        if name ~= "3" then
            local slot = playingSlots:FindFirstChild(name)
            if slot and slot:IsA("Model") then
                if cloneConnect4ToSlot(srcC4, srcTablePivot, localOffset, slot) then
                    placed += 1
                end
            end
        end
    end
    if placed > 0 then
        print(("SetupConnect4: placed Connect4 on %d tables"):format(placed))
    end
end

-- Initial pass
task.defer(ensureAllTables)

-- Watch for new tables during the session
local playingSlots = Workspace:WaitForChild("PlayingSlots")
playingSlots.ChildAdded:Connect(function(child)
    if child:IsA("Model") then
        task.wait()
        ensureAllTables()
    end
end)
