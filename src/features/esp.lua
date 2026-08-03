--[[ opus.cc — ESP

     Drawing-API overlay plus Highlight-based chams. Every drawing object is
     pooled per player and only ever hidden, never destroyed, while that player
     is in the server — allocation churn on the executor's drawing list is the
     main cost of a naive implementation. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local gameLib = client.require("game")

local Players = util.Players
local Workspace = util.Workspace
local RunService = util.RunService
local LocalPlayer = util.LocalPlayer

local esp = {}

local maid = util.Maid.new()

--==========================================================================--
-- rig topology
--==========================================================================--

local SKELETON = {
    { "Head", "UpperTorso" },
    { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" },
    { "LeftUpperArm", "LeftLowerArm" },
    { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" },
    { "RightUpperArm", "RightLowerArm" },
    { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" },
    { "LeftUpperLeg", "LeftLowerLeg" },
    { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" },
    { "RightUpperLeg", "RightLowerLeg" },
    { "RightLowerLeg", "RightFoot" },
}

--==========================================================================--
-- per-player drawing set
--==========================================================================--

local Entry = {}
Entry.__index = Entry

local function makeLine(props)
    local ok, line = pcall(Drawing.new, "Line")
    if not ok then return nil end
    line.Visible = false
    line.Thickness = props and props.thickness or 1
    line.Transparency = 1
    return line
end

local function makeSquare(filled)
    local ok, square = pcall(Drawing.new, "Square")
    if not ok then return nil end
    square.Visible = false
    square.Filled = filled or false
    square.Thickness = 1
    square.Transparency = 1
    return square
end

local function makeText(size)
    local ok, text = pcall(Drawing.new, "Text")
    if not ok then return nil end
    text.Visible = false
    text.Size = size or 13
    text.Center = true
    text.Outline = true
    text.OutlineColor = Color3.new(0, 0, 0)
    text.Transparency = 1
    return text
end

function Entry.new()
    local self = setmetatable({}, Entry)

    self.boxOutline = makeSquare(false)
    self.box = makeSquare(false)

    self.corners = {}
    for i = 1, 16 do
        self.corners[i] = makeLine()
    end

    self.healthBg = makeSquare(true)
    self.healthFill = makeSquare(true)
    self.healthText = makeText(11)
    if self.healthText then self.healthText.Center = false end

    self.name = makeText(13)
    self.info = makeText(12)     -- distance
    self.weapon = makeText(12)

    self.headDot = (function()
        local ok, circle = pcall(Drawing.new, "Circle")
        if not ok then return nil end
        circle.Visible = false
        circle.Thickness = 1
        circle.NumSides = 16
        circle.Filled = false
        circle.Transparency = 1
        return circle
    end)()

    self.tracer = makeLine()

    self.bones = {}
    for i = 1, #SKELETON do
        self.bones[i] = makeLine()
    end

    self.arrow = (function()
        local ok, triangle = pcall(Drawing.new, "Triangle")
        if not ok then return nil end
        triangle.Visible = false
        triangle.Filled = true
        triangle.Thickness = 1
        triangle.Transparency = 1
        return triangle
    end)()

    self.highlight = nil
    return self
end

local function hide(object)
    if object then
        pcall(function() object.Visible = false end)
    end
end

function Entry:hideAll()
    hide(self.box)
    hide(self.boxOutline)
    for _, line in ipairs(self.corners) do hide(line) end
    hide(self.healthBg)
    hide(self.healthFill)
    hide(self.healthText)
    hide(self.name)
    hide(self.info)
    hide(self.weapon)
    hide(self.headDot)
    hide(self.tracer)
    hide(self.arrow)
    for _, bone in ipairs(self.bones) do hide(bone) end
end

function Entry:destroy()
    local function remove(object)
        if object then pcall(function() object:Remove() end) end
    end

    remove(self.box)
    remove(self.boxOutline)
    for _, line in ipairs(self.corners) do remove(line) end
    remove(self.healthBg)
    remove(self.healthFill)
    remove(self.healthText)
    remove(self.name)
    remove(self.info)
    remove(self.weapon)
    remove(self.headDot)
    remove(self.tracer)
    remove(self.arrow)
    for _, bone in ipairs(self.bones) do remove(bone) end

    if self.highlight then
        pcall(function() self.highlight:Destroy() end)
        self.highlight = nil
    end
end

--==========================================================================--
-- entry registry
--==========================================================================--

local entries = {}

local function entryFor(player)
    local entry = entries[player]
    if not entry then
        if not util.hasDrawing then return nil end
        entry = Entry.new()
        entries[player] = entry
    end
    return entry
end

local function releasePlayer(player)
    local entry = entries[player]
    if entry then
        entry:destroy()
        entries[player] = nil
    end
end

maid:give(Players.PlayerRemoving:Connect(releasePlayer))

--==========================================================================--
-- chams
--==========================================================================--

local function applyChams(entry, character, color)
    local highlight = entry.highlight

    if not config.get("esp.chams", false) then
        if highlight then
            highlight:Destroy()
            entry.highlight = nil
        end
        return
    end

    if not highlight or not highlight.Parent then
        if highlight then highlight:Destroy() end
        highlight = Instance.new("Highlight")
        highlight.Name = "\0"
        highlight.Adornee = character
        highlight.Parent = character
        entry.highlight = highlight
    elseif highlight.Adornee ~= character then
        highlight.Adornee = character
        highlight.Parent = character
    end

    highlight.FillColor = color or config.get("esp.chamsFill")
    highlight.OutlineColor = config.get("esp.chamsOutline")
    highlight.FillTransparency = config.get("esp.chamsTransparency", 0.5)
    highlight.OutlineTransparency = 0
    highlight.DepthMode = config.get("esp.chamsThroughWalls", true)
        and Enum.HighlightDepthMode.AlwaysOnTop
        or Enum.HighlightDepthMode.Occluded
end

--==========================================================================--
-- drawing helpers
--==========================================================================--

--- Eight corner brackets, each one third the length of the box side it sits on.
local function drawCorners(entry, box, color, visible)
    local lines = entry.corners
    local lengthX = math.min(box.w * 0.3, 14)
    local lengthY = math.min(box.h * 0.22, 14)

    local x1, y1 = box.x, box.y
    local x2, y2 = box.x + box.w, box.y + box.h

    local segments = {
        { Vector2.new(x1, y1), Vector2.new(x1 + lengthX, y1) },
        { Vector2.new(x1, y1), Vector2.new(x1, y1 + lengthY) },
        { Vector2.new(x2, y1), Vector2.new(x2 - lengthX, y1) },
        { Vector2.new(x2, y1), Vector2.new(x2, y1 + lengthY) },
        { Vector2.new(x1, y2), Vector2.new(x1 + lengthX, y2) },
        { Vector2.new(x1, y2), Vector2.new(x1, y2 - lengthY) },
        { Vector2.new(x2, y2), Vector2.new(x2 - lengthX, y2) },
        { Vector2.new(x2, y2), Vector2.new(x2, y2 - lengthY) },
    }

    local outline = config.get("esp.boxOutline", true)

    for index, segment in ipairs(segments) do
        -- Outline pass draws the same geometry one pixel thicker underneath.
        local shadow = lines[index + 8]
        if shadow then
            if outline and visible then
                shadow.From = segment[1]
                shadow.To = segment[2]
                shadow.Color = Color3.new(0, 0, 0)
                shadow.Thickness = 3
                shadow.Visible = true
            else
                shadow.Visible = false
            end
        end

        local line = lines[index]
        if line then
            if visible then
                line.From = segment[1]
                line.To = segment[2]
                line.Color = color
                line.Thickness = 1
                line.Visible = true
            else
                line.Visible = false
            end
        end
    end
end

local function drawBox(entry, box, color)
    local style = config.get("esp.boxStyle", "Corner")
    local enabled = config.get("esp.box", true)

    if not enabled then
        hide(entry.box)
        hide(entry.boxOutline)
        drawCorners(entry, box, color, false)
        return
    end

    if style == "Corner" then
        hide(entry.box)
        hide(entry.boxOutline)
        drawCorners(entry, box, color, true)
        return
    end

    drawCorners(entry, box, color, false)

    if entry.boxOutline and config.get("esp.boxOutline", true) then
        entry.boxOutline.Position = Vector2.new(box.x - 1, box.y - 1)
        entry.boxOutline.Size = Vector2.new(box.w + 2, box.h + 2)
        entry.boxOutline.Color = Color3.new(0, 0, 0)
        entry.boxOutline.Thickness = 1
        entry.boxOutline.Visible = true
    else
        hide(entry.boxOutline)
    end

    if entry.box then
        entry.box.Position = Vector2.new(box.x, box.y)
        entry.box.Size = Vector2.new(box.w, box.h)
        entry.box.Color = color
        entry.box.Thickness = 1
        entry.box.Visible = true
    end
end

local function drawHealth(entry, box, health, maxHealth)
    if not config.get("esp.health", true) then
        hide(entry.healthBg)
        hide(entry.healthFill)
        hide(entry.healthText)
        return
    end

    local alpha = math.clamp(health / math.max(maxHealth, 1), 0, 1)
    local barX = box.x - 6
    local barHeight = box.h * alpha

    if entry.healthBg then
        entry.healthBg.Position = Vector2.new(barX - 1, box.y - 1)
        entry.healthBg.Size = Vector2.new(4, box.h + 2)
        entry.healthBg.Color = Color3.new(0, 0, 0)
        entry.healthBg.Visible = true
    end

    if entry.healthFill then
        entry.healthFill.Position = Vector2.new(barX, box.y + (box.h - barHeight))
        entry.healthFill.Size = Vector2.new(2, barHeight)
        entry.healthFill.Color = util.healthColor(alpha)
        entry.healthFill.Visible = true
    end

    if entry.healthText then
        if config.get("esp.healthText", false) and alpha < 1 then
            entry.healthText.Position = Vector2.new(barX - 22, box.y + (box.h - barHeight) - 6)
            entry.healthText.Text = tostring(math.floor(health + 0.5))
            entry.healthText.Color = util.healthColor(alpha)
            entry.healthText.Size = config.get("esp.textSize", 13) - 2
            entry.healthText.Visible = true
        else
            entry.healthText.Visible = false
        end
    end
end

local function drawSkeleton(entry, character, color)
    if not config.get("esp.skeleton", false) then
        for _, bone in ipairs(entry.bones) do hide(bone) end
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    for index, pair in ipairs(SKELETON) do
        local line = entry.bones[index]
        if line then
            local a = character:FindFirstChild(pair[1])
            local b = character:FindFirstChild(pair[2])
            if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
                local pointA, onA = camera:WorldToViewportPoint(a.Position)
                local pointB, onB = camera:WorldToViewportPoint(b.Position)
                if pointA.Z > 0 and pointB.Z > 0 and (onA or onB) then
                    line.From = Vector2.new(pointA.X, pointA.Y)
                    line.To = Vector2.new(pointB.X, pointB.Y)
                    line.Color = color
                    line.Visible = true
                else
                    line.Visible = false
                end
            else
                line.Visible = false
            end
        end
    end
end

local function drawTracer(entry, box, color)
    if not config.get("esp.tracer", false) or not entry.tracer then
        hide(entry.tracer)
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local viewport = camera.ViewportSize
    local origin
    local mode = config.get("esp.tracerOrigin", "Bottom")

    if mode == "Center" then
        origin = viewport * 0.5
    elseif mode == "Mouse" then
        local mouse = util.UserInputService:GetMouseLocation()
        origin = Vector2.new(mouse.X, mouse.Y)
    else
        origin = Vector2.new(viewport.X * 0.5, viewport.Y)
    end

    entry.tracer.From = origin
    entry.tracer.To = Vector2.new(box.x + box.w * 0.5, box.y + box.h)
    entry.tracer.Color = color
    entry.tracer.Visible = true
end

local function drawArrow(entry, worldPosition, color)
    if not config.get("esp.offScreenArrows", false) or not entry.arrow then
        hide(entry.arrow)
        return false
    end

    local camera = Workspace.CurrentCamera
    if not camera then return false end

    local centre = camera.ViewportSize * 0.5
    local cf = camera.CFrame
    local relative = cf:PointToObjectSpace(worldPosition)

    -- Behind the camera the projected point mirrors; flip it so the arrow
    -- points the way the player must actually turn.
    local direction = Vector2.new(relative.X, relative.Z)
    if direction.Magnitude < 0.001 then return false end
    direction = direction.Unit

    local radius = config.get("esp.arrowRadius", 180)
    local position = centre + Vector2.new(direction.X, direction.Y) * radius
    local angle = math.atan2(direction.Y, direction.X)

    local size = 9
    local tip = position + Vector2.new(math.cos(angle), math.sin(angle)) * size
    local left = position + Vector2.new(math.cos(angle + 2.5), math.sin(angle + 2.5)) * size
    local right = position + Vector2.new(math.cos(angle - 2.5), math.sin(angle - 2.5)) * size

    entry.arrow.PointA = tip
    entry.arrow.PointB = left
    entry.arrow.PointC = right
    entry.arrow.Color = color
    entry.arrow.Visible = true
    return true
end

--==========================================================================--
-- dropped weapons and bomb
--==========================================================================--

local worldPool = util.Pool.new()
local droppedBuffer = {}

local function renderWorldMarkers()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local index = 0

    if config.get("esp.dropped", false) then
        local color = config.get("esp.droppedColor")
        local origin = gameLib.localRoot()

        for _, dropped in ipairs(gameLib.droppedWeapons(droppedBuffer)) do
            index += 1
            local text = worldPool:get("dropped" .. index, "Text")
            if text then
                local point, onScreen = camera:WorldToViewportPoint(dropped.part.Position)
                if onScreen and point.Z > 0 and point.Z < 300 then
                    local name = dropped.model.Name:gsub("_Weapon$", "")
                    if origin then
                        local distance = (dropped.part.Position - origin.Position).Magnitude
                        name = ("%s [%dm]"):format(name, math.floor(distance / 3 + 0.5))
                    end
                    text.Position = Vector2.new(point.X, point.Y)
                    text.Text = name
                    text.Color = color
                    text.Size = config.get("esp.textSize", 13) - 2
                    text.Center = true
                    text.Outline = true
                    text.Visible = true
                else
                    text.Visible = false
                end
            end
        end
    end

    -- Hide any pooled markers left over from a frame with more pickups.
    local slot = index + 1
    while worldPool.items["dropped" .. slot] do
        worldPool.items["dropped" .. slot].Visible = false
        slot += 1
    end

    local bombText = worldPool:get("bomb", "Text")
    if bombText then
        if config.get("esp.bomb", false) then
            local bomb = gameLib.plantedBomb()
            local part = bomb and (bomb:IsA("BasePart") and bomb
                or bomb:FindFirstChildWhichIsA("BasePart", true))
            if part then
                local point, onScreen = camera:WorldToViewportPoint(part.Position)
                if onScreen and point.Z > 0 then
                    bombText.Position = Vector2.new(point.X, point.Y)
                    bombText.Text = "C4"
                    bombText.Color = config.get("esp.bombColor")
                    bombText.Size = config.get("esp.textSize", 13)
                    bombText.Center = true
                    bombText.Outline = true
                    bombText.Visible = true
                else
                    bombText.Visible = false
                end
            else
                bombText.Visible = false
            end
        else
            bombText.Visible = false
        end
    end
end

--==========================================================================--
-- per-frame render
--==========================================================================--

local playerBuffer = {}

local function render()
    if not config.get("esp.enabled", false) or not util.hasDrawing then
        for _, entry in pairs(entries) do
            entry:hideAll()
            if entry.highlight then
                entry.highlight:Destroy()
                entry.highlight = nil
            end
        end
        worldPool:hideAll()
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local origin = gameLib.localRoot()
    local originPosition = origin and origin.Position or camera.CFrame.Position

    local maxDistance = config.get("esp.maxDistance", 1200)
    local showTeammates = config.get("esp.teammates", false)
    local useVisibility = config.get("esp.useVisibilityColor", true)
    local textSize = config.get("esp.textSize", 13)

    local seen = {}

    for _, record in ipairs(gameLib.others(playerBuffer)) do
        local player = record.player
        local character = record.character

        if record.enemy or (showTeammates and gameLib.isTeammate(player)) then
            local entry = entryFor(player)
            if entry then
                seen[player] = true

                local root = gameLib.rootOf(character)
                local distance = root and (root.Position - originPosition).Magnitude or math.huge

                if distance <= maxDistance then
                    local visible = false
                    if useVisibility and root then
                        visible = gameLib.isVisible(character, root.Position)
                    end

                    local color
                    if useVisibility then
                        color = visible and config.get("esp.visibleColor") or config.get("esp.hiddenColor")
                    else
                        color = config.get("esp.boxColor")
                    end

                    applyChams(entry, character, config.get("esp.chams", false)
                        and (useVisibility and color or config.get("esp.chamsFill")) or nil)

                    local box = util.modelBox(character)
                    if box then
                        drawBox(entry, box, color)

                        local health, maxHealth = gameLib.healthOf(character)
                        drawHealth(entry, box, health, maxHealth)
                        drawSkeleton(entry, character, config.get("esp.skeletonColor"))
                        drawTracer(entry, box, config.get("esp.tracerColor"))
                        hide(entry.arrow)

                        -- name above the box
                        if entry.name then
                            if config.get("esp.name", true) then
                                entry.name.Position = Vector2.new(box.x + box.w * 0.5, box.y - textSize - 2)
                                entry.name.Text = util.truncate(player.DisplayName or player.Name, 18)
                                entry.name.Color = config.get("esp.nameColor")
                                entry.name.Size = textSize
                                entry.name.Visible = true
                            else
                                entry.name.Visible = false
                            end
                        end

                        -- distance below the box
                        if entry.info then
                            if config.get("esp.distance", true) then
                                entry.info.Position = Vector2.new(box.x + box.w * 0.5, box.y + box.h + 2)
                                entry.info.Text = ("%dm"):format(math.floor(distance / 3 + 0.5))
                                entry.info.Color = config.get("esp.nameColor")
                                entry.info.Size = textSize - 2
                                entry.info.Visible = true
                            else
                                entry.info.Visible = false
                            end
                        end

                        -- equipped weapon under the distance line
                        if entry.weapon then
                            if config.get("esp.weapon", true) then
                                local weaponName = player:GetAttribute("EquippedWeapon")
                                if not weaponName then
                                    local slot = player:GetAttribute("Slot1")
                                    weaponName = type(slot) == "string"
                                        and slot:match('"Name"%s*:%s*"([^"]+)"') or nil
                                end
                                if weaponName then
                                    local offset = config.get("esp.distance", true) and (textSize + 2) or 2
                                    entry.weapon.Position = Vector2.new(box.x + box.w * 0.5, box.y + box.h + offset)
                                    entry.weapon.Text = util.truncate(weaponName, 16)
                                    entry.weapon.Color = config.get("esp.nameColor")
                                    entry.weapon.Size = textSize - 2
                                    entry.weapon.Visible = true
                                else
                                    entry.weapon.Visible = false
                                end
                            else
                                entry.weapon.Visible = false
                            end
                        end

                        -- head dot
                        if entry.headDot then
                            local head = character:FindFirstChild("Head")
                            if config.get("esp.headDot", false) and head then
                                local point, onScreen = camera:WorldToViewportPoint(head.Position)
                                if onScreen and point.Z > 0 then
                                    entry.headDot.Position = Vector2.new(point.X, point.Y)
                                    entry.headDot.Radius = math.clamp(box.w * 0.12, 2, 10)
                                    entry.headDot.Color = color
                                    entry.headDot.Visible = true
                                else
                                    entry.headDot.Visible = false
                                end
                            else
                                entry.headDot.Visible = false
                            end
                        end
                    else
                        -- off screen: box projection failed
                        entry:hideAll()
                        if root then
                            drawArrow(entry, root.Position, config.get("esp.arrowColor"))
                        end
                    end
                else
                    entry:hideAll()
                    if entry.highlight then
                        entry.highlight:Destroy()
                        entry.highlight = nil
                    end
                end
            end
        end
    end

    for player, entry in pairs(entries) do
        if not seen[player] then
            entry:hideAll()
            if entry.highlight then
                entry.highlight:Destroy()
                entry.highlight = nil
            end
        end
    end

    renderWorldMarkers()
end

maid:give(RunService.RenderStepped:Connect(util.guard("esp", render)))

--==========================================================================--
-- ui
--==========================================================================--

function esp.build(tab)
    local main = tab:section("Players", "left")
    main:toggle("Enabled", "esp.enabled")
    main:toggle("Show teammates", "esp.teammates")
    main:slider("Max distance", "esp.maxDistance", { min = 100, max = 3000, step = 50, suffix = "" })
    main:divider()
    main:toggle("Box", "esp.box")
    main:dropdown("Box style", "esp.boxStyle", { "Corner", "Full" })
    main:toggle("Box outline", "esp.boxOutline")
    main:toggle("Health bar", "esp.health")
    main:toggle("Health number", "esp.healthText")
    main:toggle("Name", "esp.name")
    main:toggle("Distance", "esp.distance")
    main:toggle("Weapon", "esp.weapon")
    main:toggle("Head dot", "esp.headDot")
    main:toggle("Skeleton", "esp.skeleton")
    main:slider("Text size", "esp.textSize", { min = 9, max = 20, step = 1 })

    local tracers = tab:section("Tracers", "left")
    tracers:toggle("Enabled", "esp.tracer")
    tracers:dropdown("Origin", "esp.tracerOrigin", { "Bottom", "Center", "Mouse" })
    tracers:colorpicker("Colour", "esp.tracerColor")

    local chams = tab:section("Chams", "right")
    chams:toggle("Enabled", "esp.chams")
    chams:toggle("Through walls", "esp.chamsThroughWalls")
    chams:colorpicker("Fill", "esp.chamsFill")
    chams:colorpicker("Outline", "esp.chamsOutline")
    chams:slider("Fill transparency", "esp.chamsTransparency", { min = 0, max = 1, step = 0.05 })

    local colors = tab:section("Colours", "right")
    colors:toggle("Colour by visibility", "esp.useVisibilityColor")
    colors:colorpicker("Visible", "esp.visibleColor")
    colors:colorpicker("Hidden", "esp.hiddenColor")
    colors:colorpicker("Box", "esp.boxColor")
    colors:colorpicker("Name", "esp.nameColor")
    colors:colorpicker("Skeleton", "esp.skeletonColor")

    local world = tab:section("World", "right")
    world:toggle("Dropped weapons", "esp.dropped")
    world:colorpicker("Dropped colour", "esp.droppedColor")
    world:toggle("Planted C4", "esp.bomb")
    world:colorpicker("C4 colour", "esp.bombColor")
    world:divider()
    world:toggle("Off-screen arrows", "esp.offScreenArrows")
    world:slider("Arrow radius", "esp.arrowRadius", { min = 80, max = 400, step = 10 })
    world:colorpicker("Arrow colour", "esp.arrowColor")

    if not util.hasDrawing then
        local warning = tab:section("Notice", "left")
        warning:label("This executor has no Drawing API. Chams still work; boxes, "
            .. "text and tracers are unavailable.")
    end
end

client.onUnload(function()
    maid:clean()
    for player in pairs(entries) do
        releasePlayer(player)
    end
    worldPool:destroy()
end)

return esp
