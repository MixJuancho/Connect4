--!strict
-- NotificationManager.client.luau
-- Listens for server events and displays on-screen notifications.
-- Manages the lifecycle of notification labels (creation, tweening, destruction).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

-- FADE_TIME left for potential future use but not used now
local FADE_TIME = 0.3
local VISIBLE_TIME = 4
local NOTIFICATION_SPACING = 8

-- Player GUI references (customize these to match your actual hierarchy)
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Expect a ScreenGui named "ScreenGui" -> Frames -> Notifications (Frame)
local screenGui = playerGui:WaitForChild("ScreenGui")
local framesFolder = screenGui:WaitForChild("Frames")
local notificationFrame = framesFolder:WaitForChild("Notifications") :: Frame

-- Ensure UIListLayout for automatic stacking (newest at bottom)
local listLayout = notificationFrame:FindFirstChildOfClass("UIListLayout")
if not listLayout then
    listLayout = Instance.new("UIListLayout")
    listLayout.FillDirection = Enum.FillDirection.Vertical
    listLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, NOTIFICATION_SPACING)
    listLayout.Parent = notificationFrame
end

-- Pre-load assets (Templates & Sounds) with safe fallbacks
local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
if not assetsFolder then
    warn("[NotificationManager] Assets folder missing; using generated fallback templates.")
end

local uiTemplatesFolder: Instance? = assetsFolder and assetsFolder:FindFirstChild("UITemplates")
local templatesFolder: Instance? = uiTemplatesFolder and uiTemplatesFolder:FindFirstChild("Notifications")
local soundsFolder: Instance? = assetsFolder and assetsFolder:FindFirstChild("Sounds")

-- Fallback template factory
local function createFallbackTemplate(name: string, color: Color3): TextLabel
	warn(string.format("[NotificationManager] Template '%s' not found in ReplicatedStorage.Assets.UITemplates.Notifications. A fallback is being generated.", name))
    local lbl = Instance.new("TextLabel")
    lbl.Name = name
    lbl.Size = UDim2.new(1, 0, 0, 28)
    lbl.BackgroundTransparency = 0.2
    lbl.BackgroundColor3 = color
    lbl.TextColor3 = Color3.new(1,1,1)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextScaled = true
    lbl.BorderSizePixel = 0
    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = lbl
	lbl:SetAttribute("IsFallback", true)
    return lbl
end

-- Try to fetch a child with timeout (avoids infinite yield)
local function waitForChildTimeout(parent: Instance, childName: string, timeout: number): Instance?
    local found = parent:FindFirstChild(childName)
    if found then return found end
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        found = parent:FindFirstChild(childName)
        if found then return found end
        task.wait(0.1)
    end
    return nil
end

if assetsFolder and not uiTemplatesFolder then
    uiTemplatesFolder = waitForChildTimeout(assetsFolder, "UITemplates", 2)
end
if uiTemplatesFolder and not templatesFolder then
	templatesFolder = waitForChildTimeout(uiTemplatesFolder, "Notifications", 2)
end
if assetsFolder and not soundsFolder then
    soundsFolder = waitForChildTimeout(assetsFolder, "Sounds", 2)
end

local templates: {[string]: TextLabel} = {}
do
    local normal = templatesFolder and templatesFolder:FindFirstChild("Normal")
    if normal and normal:IsA("TextLabel") then
        templates.Normal = normal
    else
        templates.Normal = createFallbackTemplate("Normal", Color3.fromRGB(40,40,40))
    end
    local green = templatesFolder and templatesFolder:FindFirstChild("Green")
    if green and green:IsA("TextLabel") then
        templates.Green = green
    else
        templates.Green = createFallbackTemplate("Green", Color3.fromRGB(34,139,34))
    end
end

local sounds: {[string]: Sound} = {}
do
    if soundsFolder then
        local purchase = soundsFolder:FindFirstChild("Purchase")
        if purchase and purchase:IsA("Sound") then
            sounds.Purchase = purchase
        end
        local note = soundsFolder:FindFirstChild("Notification")
        if note and note:IsA("Sound") then
            sounds.Notification = note
        end
    end
end

-- Remotes
local notificationsFolder = ReplicatedStorage:FindFirstChild("Notifications") or ReplicatedStorage:WaitForChild("Notifications")
local showNotificationEvent = notificationsFolder:WaitForChild("Show") :: RemoteEvent

export type NotificationPayload = { text: string, type: string, sound: string? }

local function showNotification(data: NotificationPayload)
    local template = templates[data.type]
    if not template then
        warn("[NotificationManager] Invalid notification type:", data.type)
        return
    end

    -- Play optional sound
    if data.sound and sounds[data.sound] and sounds[data.sound]:IsA("Sound") then
        local snd = sounds[data.sound]
        if not snd.IsLoaded then pcall(function() snd:Play() snd:Stop() end) end
        snd:Play()
    end

    local newLabel = template:Clone()
	-- Prepend text if this is a fallback, to make it obvious during testing
	if newLabel:GetAttribute("IsFallback") then
		newLabel.Text = "[FALLBACK] " .. data.text
		newLabel.TextColor3 = Color3.fromRGB(255, 100, 100) -- Make it stand out
	end
	newLabel.Text = data.text

	-- Set initial transparency for fade-in
	newLabel.TextTransparency = 1
	local stroke = newLabel:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 1
	end

	newLabel.LayoutOrder = os.clock() -- chronological ordering
	newLabel.Parent = notificationFrame

	-- Fade In
	local tweenInfo = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fadeInText = TweenService:Create(newLabel, tweenInfo, { TextTransparency = 0 })
	fadeInText:Play()
	if stroke then
		local fadeInStroke = TweenService:Create(stroke, tweenInfo, { Transparency = 0 })
		fadeInStroke:Play()
	end

	-- Fade Out and Destroy
	task.delay(VISIBLE_TIME, function()
		if not newLabel.Parent then return end
		local fadeOutInfo = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local fadeOutText = TweenService:Create(newLabel, fadeOutInfo, { TextTransparency = 1 })
		fadeOutText:Play()
		if stroke then
			local fadeOutStroke = TweenService:Create(stroke, fadeOutInfo, { Transparency = 1 })
			fadeOutStroke:Play()
		end
		fadeOutText.Completed:Wait()
		if newLabel and newLabel.Parent then newLabel:Destroy() end
	end)
end

showNotificationEvent.OnClientEvent:Connect(function(payload)
    local ok, err = pcall(function()
        showNotification(payload)
    end)
    if not ok then
        warn("[NotificationManager] Error displaying notification:", err)
    end
end)

print("[NotificationManager] Ready.")
