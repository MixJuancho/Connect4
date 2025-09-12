-- Narration-only client for world-based Connect 4
-- Updates StarterGui.ScreenGui.Frames.Match.TextLabel based on server messages

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local function getMatchLabel()
    local screenGui = playerGui:FindFirstChild("ScreenGui")
    if not screenGui then return nil end
    local frames = screenGui:FindFirstChild("Frames")
    if not frames then return nil end
    local match = frames:FindFirstChild("Match")
    if not match then return nil end
    local label = match:FindFirstChildWhichIsA("TextLabel", true)
    return label
end

-- robustly acquire the Narrate RemoteEvent even if server creates it late
local function getNarrateEvent()
    local folder = ReplicatedStorage:FindFirstChild("Connect4")
    if not folder then folder = ReplicatedStorage:WaitForChild("Connect4") end
    local ev = folder:FindFirstChild("Narrate")
    if ev and ev:IsA("RemoteEvent") then return ev end
    ev = folder:WaitForChild("Narrate")
    return ev
end

local Narrate = getNarrateEvent()
if Narrate and Narrate:IsA("RemoteEvent") then
    Narrate.OnClientEvent:Connect(function(payload)
        local text = payload and payload.text or ""
        local label = getMatchLabel()
        if label then
            label.Text = text
        end
    end)
end
