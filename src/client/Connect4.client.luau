-- Narration-only client for world-based Connect 4
-- Updates StarterGui.ScreenGui.Frames.Match.TextLabel based on server messages

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

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

local function getMatchCameraEvent()
    local folder = ReplicatedStorage:WaitForChild("Connect4")
    return folder:WaitForChild("MatchCamera")
end

local camera = workspace.CurrentCamera
local originalCameraType = camera.CameraType
local originalSubject = camera.CameraSubject
local originalCF
local activeFocus = false

local function setCharactersTransparency(alpha)
    for _, pl in ipairs(Players:GetPlayers()) do
        local char = pl.Character
        if char then
            for _, d in ipairs(char:GetDescendants()) do
                if d:IsA("BasePart") or d:IsA("Decal") then
                    if d:IsA("BasePart") then
                        d.LocalTransparencyModifier = alpha
                    else
                        d.Transparency = alpha
                    end
                end
            end
        end
    end
end

local function tweenCamera(targetCF)
    local duration = 0.75
    local startCF = camera.CFrame
    local t0 = tick()
    while tick() - t0 < duration do
        local a = (tick() - t0)/duration
        camera.CFrame = startCF:Lerp(targetCF, a)
        RunService.RenderStepped:Wait()
    end
    camera.CFrame = targetCF
end

local MatchCamera = getMatchCameraEvent()
MatchCamera.OnClientEvent:Connect(function(payload)
    if not payload then return end
    local action = payload.action
    local cf = payload.cf
    local size = payload.size
    if action == "Focus" and cf and size then
        if not activeFocus then
            originalCameraType = camera.CameraType
            originalSubject = camera.CameraSubject
            originalCF = camera.CFrame
        end
        activeFocus = true
        camera.CameraType = Enum.CameraType.Scriptable
    local widthAlongZ = size.Z > size.X
    local normal = widthAlongZ and cf.RightVector or cf.LookVector
    -- Place camera on the opposite side of the normal (behind board relative to previous view)
    normal = -normal
        local up = cf.UpVector
    local distance = math.max(size.X, size.Z) * 1.3
        local focusPos = cf.Position
        local camPos = focusPos - normal * distance + up * (size.Y * 0.35)
        local targetCF = CFrame.lookAt(camPos, focusPos, up)
        setCharactersTransparency(1)
        tweenCamera(targetCF)
    elseif action == "Reset" then
        if activeFocus then
            setCharactersTransparency(0)
            camera.CameraType = originalCameraType
            if originalSubject then
                camera.CameraSubject = originalSubject
            end
            if originalCF then
                camera.CFrame = originalCF
            end
        end
        activeFocus = false
    end
end)
