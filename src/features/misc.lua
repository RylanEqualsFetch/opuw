--[[ opus.cc — misc

     Spectator list, minimap radar, frame rate cap removal, and the small
     quality-of-life automations that do not warrant their own module. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local gameLib = client.require("game")

local Players = util.Players
local Workspace = util.Workspace
local RunService = util.RunService
local LocalPlayer = util.LocalPlayer

local misc = {}

local maid = util.Maid.new()

--==========================================================================--
-- spectator list
--
-- Bloxstrike keeps the spectate target client-side: SpectateController drives
-- the camera locally and only tells the server through Spectate.SpectatePlayer,
-- which is a send-only packet. No attribute or replicated value says who is
-- watching whom, so "who is spectating me" is not answerable from this client.
--
-- `IsSpectating` *is* a replicated player attribute, so what this list can show
-- honestly is every player currently in spectator mode.
--==========================================================================--

local spectatorGui = Instance.new("ScreenGui")
spectatorGui.Name = "\0"
spectatorGui.ResetOnSpawn = false
spectatorGui.IgnoreGuiInset = true
spectatorGui.DisplayOrder = 9998
util.protect(spectatorGui)
spectatorGui.Parent = util.guiParent()
maid:give(spectatorGui)

local spectatorFrame = Instance.new("Frame")
spectatorFrame.AnchorPoint = Vector2.new(1, 0)
spectatorFrame.Position = UDim2.new(1, -16, 0, 16)
spectatorFrame.Size = UDim2.fromOffset(160, 0)
spectatorFrame.AutomaticSize = Enum.AutomaticSize.Y
spectatorFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 27)
spectatorFrame.BackgroundTransparency = 0.1
spectatorFrame.BorderSizePixel = 0
spectatorFrame.Visible = false
spectatorFrame.Parent = spectatorGui

do
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = spectatorFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(48, 48, 54)
    stroke.Parent = spectatorFrame

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = spectatorFrame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = spectatorFrame
end

local spectatorHeader = Instance.new("TextLabel")
spectatorHeader.BackgroundTransparency = 1
spectatorHeader.Font = Enum.Font.GothamBold
spectatorHeader.Text = "SPECTATING"
spectatorHeader.TextSize = 10
spectatorHeader.TextColor3 = Color3.fromRGB(96, 96, 104)
spectatorHeader.TextXAlignment = Enum.TextXAlignment.Left
spectatorHeader.Size = UDim2.new(1, 0, 0, 14)
spectatorHeader.LayoutOrder = 0
spectatorHeader.Parent = spectatorFrame

local spectatorRows = {}

local spectatorBuffer = {}

local function playersSpectating()
    table.clear(spectatorBuffer)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player:GetAttribute("IsSpectating") then
            table.insert(spectatorBuffer, player)
        end
    end
    return spectatorBuffer
end

local function stepSpectators()
    local enabled = config.get("misc.spectatorList", false)
    if not enabled then
        spectatorFrame.Visible = false
        return
    end

    local watchers = playersSpectating()
    spectatorFrame.Visible = true

    for index = 1, math.max(#watchers, #spectatorRows) do
        local row = spectatorRows[index]
        if not row then
            row = Instance.new("TextLabel")
            row.BackgroundTransparency = 1
            row.Font = Enum.Font.Gotham
            row.TextSize = 11
            row.TextColor3 = Color3.fromRGB(226, 226, 230)
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Size = UDim2.new(1, 0, 0, 14)
            row.LayoutOrder = index
            row.Parent = spectatorFrame
            spectatorRows[index] = row
        end

        local watcher = watchers[index]
        if watcher then
            row.Text = util.truncate(watcher.DisplayName or watcher.Name, 20)
            row.Visible = true
        else
            row.Visible = false
        end
    end

    spectatorHeader.Text = ("SPECTATING  ·  %d"):format(#watchers)
end

--==========================================================================--
-- radar
--==========================================================================--

local radarPool = util.Pool.new()
local radarBuffer = {}

local function stepRadar()
    if not config.get("misc.radar", false) or not util.hasDrawing then
        radarPool:hideAll()
        return
    end

    local camera = Workspace.CurrentCamera
    local root = gameLib.localRoot()
    if not camera or not root then
        radarPool:hideAll()
        return
    end

    local size = config.get("misc.radarSize", 170)
    local range = config.get("misc.radarRange", 220)
    local origin = Vector2.new(20 + size * 0.5, camera.ViewportSize.Y * 0.5)

    local background = radarPool:get("bg", "Square")
    if background then
        background.Position = origin - Vector2.new(size * 0.5, size * 0.5)
        background.Size = Vector2.new(size, size)
        background.Color = Color3.fromRGB(10, 10, 12)
        background.Filled = true
        background.Transparency = 0.45
        background.Visible = true
    end

    local border = radarPool:get("border", "Square")
    if border then
        border.Position = origin - Vector2.new(size * 0.5, size * 0.5)
        border.Size = Vector2.new(size, size)
        border.Color = Color3.fromRGB(48, 48, 54)
        border.Filled = false
        border.Thickness = 1
        border.Transparency = 1
        border.Visible = true
    end

    local centreDot = radarPool:get("self", "Circle")
    if centreDot then
        centreDot.Position = origin
        centreDot.Radius = 2
        centreDot.Filled = true
        centreDot.Color = Color3.fromRGB(255, 255, 255)
        centreDot.Transparency = 1
        centreDot.Visible = true
    end

    -- Rotate world offsets into camera space so the radar is heading-relative,
    -- which is what a player reading it mid-fight expects.
    local cameraCF = camera.CFrame
    local forward = Vector3.new(cameraCF.LookVector.X, 0, cameraCF.LookVector.Z)
    if forward.Magnitude < 0.001 then
        forward = Vector3.new(0, 0, -1)
    end
    forward = forward.Unit
    local right = Vector3.new(forward.Z, 0, -forward.X)

    local index = 0
    for _, record in ipairs(gameLib.others(radarBuffer)) do
        index += 1
        local dot = radarPool:get("dot" .. index, "Circle")
        if dot then
            local targetRoot = gameLib.rootOf(record.character)
            if targetRoot then
                local offset = targetRoot.Position - root.Position
                local x = offset:Dot(right)
                local y = offset:Dot(forward)
                local scale = (size * 0.5) / math.max(range, 1)
                local point = origin + Vector2.new(x * scale, -y * scale)

                local half = size * 0.5 - 3
                if math.abs(point.X - origin.X) <= half and math.abs(point.Y - origin.Y) <= half then
                    dot.Position = point
                    dot.Radius = 2.5
                    dot.Filled = true
                    dot.Transparency = 1
                    dot.Color = record.enemy
                        and Color3.fromRGB(225, 95, 95)
                        or Color3.fromRGB(120, 200, 255)
                    dot.Visible = true
                else
                    dot.Visible = false
                end
            else
                dot.Visible = false
            end
        end
    end

    local slot = index + 1
    while radarPool.items["dot" .. slot] do
        radarPool.items["dot" .. slot].Visible = false
        slot += 1
    end
end

--==========================================================================--
-- frame rate cap
--==========================================================================--

local savedFpsCap = nil

local function applyFpsCap()
    local setfpscap = rawget(getfenv(), "setfpscap")
        or (type(getgenv) == "function" and getgenv().setfpscap)

    if not setfpscap then return false end

    if config.get("misc.fpsUnlock", false) then
        if savedFpsCap == nil then savedFpsCap = 60 end
        pcall(setfpscap, 999)
    elseif savedFpsCap ~= nil then
        pcall(setfpscap, savedFpsCap)
        savedFpsCap = nil
    end
    return true
end

maid:give(config.onChange("misc.fpsUnlock", applyFpsCap))

--==========================================================================--
-- auto map vote
--==========================================================================--

do
    local remotes = util.ReplicatedStorage:FindFirstChild("NetworkRemotes")
    local mapNamespace = remotes and remotes:FindFirstChild("Map")
    local startVote = mapNamespace and mapNamespace:FindFirstChild("StartMapVote")

    if startVote and startVote:IsA("RemoteEvent") then
        maid:give(startVote.OnClientEvent:Connect(function(payload)
            if not config.get("misc.autoAcceptMapVote", false) then return end

            local submit = mapNamespace:FindFirstChild("SubmitMapVote")
            if not submit or not submit:IsA("RemoteEvent") then return end

            -- Vote for the first option the server offered. The payload shape is
            -- not documented in the client, so only act on a plain array.
            local choice
            if type(payload) == "table" then
                choice = payload[1]
                if type(choice) == "table" then
                    choice = choice.Name or choice.Map or choice[1]
                end
            end
            if choice == nil then return end

            task.delay(1, function()
                pcall(function() submit:FireServer(choice) end)
            end)
        end))
    end
end

--==========================================================================--
-- driver
--==========================================================================--

maid:give(RunService.RenderStepped:Connect(util.guard("misc", function()
    stepSpectators()
    stepRadar()
end)))

--==========================================================================--
-- ui
--==========================================================================--

function misc.build(tab)
    local hud = tab:section("HUD", "left")
    hud:toggle("Spectating players", "misc.spectatorList")
    hud:label("Lists players in spectator mode. The game keeps spectate targets "
        .. "client-side, so who is watching you is not visible from here.")
    hud:toggle("Radar", "misc.radar")
    hud:slider("Radar size", "misc.radarSize", { min = 100, max = 300, step = 10 })
    hud:slider("Radar range", "misc.radarRange", { min = 50, max = 600, step = 10 })

    local performance = tab:section("Performance", "left")
    local capable = applyFpsCap()
    performance:toggle("Unlock frame rate", "misc.fpsUnlock")
    if not capable then
        performance:label("This executor does not expose setfpscap.")
    end

    local automation = tab:section("Automation", "right")
    automation:toggle("Auto vote first map", "misc.autoAcceptMapVote")

    local session = tab:section("Session", "right")
    session:label(("Executor: %s"):format(util.executorName()))
    session:label(("Drawing API: %s"):format(util.hasDrawing and "available" or "missing"))
    session:button("Copy join link", function()
        if util.env.setclipboard then
            util.env.setclipboard(("https://www.roblox.com/games/%d"):format(game.PlaceId))
        end
    end)
    session:button("Rejoin server", function()
        local TeleportService = game:GetService("TeleportService")
        pcall(function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
    end)
end

client.onUnload(function()
    if savedFpsCap ~= nil then
        local setfpscap = rawget(getfenv(), "setfpscap")
            or (type(getgenv) == "function" and getgenv().setfpscap)
        if setfpscap then pcall(setfpscap, savedFpsCap) end
    end
    radarPool:destroy()
    maid:clean()
end)

return misc
