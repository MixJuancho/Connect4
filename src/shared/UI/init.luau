--!strict
-- UI init module (formerly UIAnimations)
-- Exposes: attachHoverClick, open, close, toggle, and nested modules (e.g., CoinsDisplay)

local TweenService = game:GetService("TweenService")

export type HoverClickOptions = {
	hoverScale: number?,
	clickScale: number?,
	hoverTweenInfo: TweenInfo?,
	returnTweenInfo: TweenInfo?,
	clickTweenInfo: TweenInfo?,
	respectMouseLeaveDuringClick: boolean?,
}

export type OpenCloseOptions = {
	tweenInfo: TweenInfo?,
	startOffset: UDim2?,
	targetPosition: UDim2?,
	closeOffset: UDim2?,
}

local UI = {}

-- (Fade logic removed per request; transparency animations no longer applied)

function UI.attachHoverClick(button: GuiButton, opts: HoverClickOptions?)
	assert(button and button:IsA("GuiButton"), "attachHoverClick expects a GuiButton")
	local o = opts or {}
	local hoverScale = o.hoverScale or 1.05
	local clickScale = o.clickScale or 1.1
	local hoverTI = o.hoverTweenInfo or TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local returnTI = o.returnTweenInfo or hoverTI
	local clickTI = o.clickTweenInfo or TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	local baseSize: UDim2 = button.Size
	local hovering = false
	local activeTween: Tween? = nil

	local function scaleUDim2(sz: UDim2, factor: number): UDim2
		return UDim2.new(
			sz.X.Scale * factor, math.round(sz.X.Offset * factor),
			sz.Y.Scale * factor, math.round(sz.Y.Offset * factor)
		)
	end

	local function tweenSize(target: UDim2, ti: TweenInfo)
		if activeTween then activeTween:Cancel() end
		activeTween = TweenService:Create(button, ti, { Size = target })
		activeTween:Play()
	end

	local function hoverOn()
		tweenSize(scaleUDim2(baseSize, hoverScale), hoverTI)
	end

	local function hoverOff()
		tweenSize(baseSize, returnTI)
	end

	local conns = {}
	conns[#conns+1] = button.MouseEnter:Connect(function()
		hovering = true
		hoverOn()
	end)
	conns[#conns+1] = button.MouseLeave:Connect(function()
		hovering = false
		hoverOff()
	end)
	conns[#conns+1] = button.Activated:Connect(function()
		if activeTween then activeTween:Cancel() end
		local clickTween = TweenService:Create(button, clickTI, { Size = scaleUDim2(baseSize, clickScale) })
		clickTween:Play()
		clickTween.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed then return end
			if hovering and not o.respectMouseLeaveDuringClick then
				hoverOn()
			else
				hoverOff()
			end
		end)
	end)

	return {
		Destroy = function()
			for _, c in ipairs(conns) do c:Disconnect() end
			if activeTween then activeTween:Cancel() end
			-- Restore base size to avoid stuck scaled state on destroy
			button.Size = baseSize
		end
	}
end

function UI.open(frame: GuiObject, opts: OpenCloseOptions?)
	local o = opts or {}
	local tweenInfo = o.tweenInfo or TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local startOffset = o.startOffset or UDim2.fromScale(0, 0.1)
	local targetPos = o.targetPosition or frame:GetAttribute("_UI_TargetPos") or frame.Position
	frame:SetAttribute("_UI_TargetPos", targetPos)
	if frame:GetAttribute("_UI_State") == "Open" then return end
	frame:SetAttribute("_UI_State", "Opening")
	frame.Visible = true
	frame.Position = targetPos + startOffset
	-- No fade setup
	local moveTween = TweenService:Create(frame, tweenInfo, { Position = targetPos })
	moveTween:Play()
	-- No fade tween
	moveTween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then frame:SetAttribute("_UI_State", "Open") end
	end)
end

function UI.close(frame: GuiObject, opts: OpenCloseOptions?)
	local o = opts or {}
	local tweenInfo = o.tweenInfo or TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local startOffset = o.closeOffset or o.startOffset or UDim2.fromScale(0, 0.1)
	local targetPos = frame:GetAttribute("_UI_TargetPos") or frame.Position
	if frame:GetAttribute("_UI_State") == "Closed" or not frame.Visible then return end
	frame:SetAttribute("_UI_State", "Closing")
	local moveTween = TweenService:Create(frame, tweenInfo, { Position = targetPos + startOffset })
	moveTween:Play()
	-- No fade tween
	moveTween.Completed:Connect(function()
		frame.Visible = false
		frame:SetAttribute("_UI_State", "Closed")
	end)
end

function UI.toggle(frame: GuiObject, opts: OpenCloseOptions?)
	if frame.Visible and frame:GetAttribute("_UI_State") ~= "Opening" then
		UI.close(frame, opts)
	else
		UI.open(frame, opts)
	end
end

return UI
