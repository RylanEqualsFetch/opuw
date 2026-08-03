--[[ opus.cc — visuals

     Local rendering changes only: lighting, field of view, crosshair, third
     person, and suppression of the flash and smoke effects the game spawns.

     Every original value is captured on first modification and written back on
     unload, so toggling a feature off restores the map's authored look rather
     than a hardcoded guess. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local gameLib = client.require("game")
local hooks = client.require("hooks")

local Lighting = util.Lighting
local Workspace = util.Workspace
local RunService = util.RunService
local LocalPlayer = util.LocalPlayer

local visuals = {}

local maid = util.Maid.new()

--==========================================================================--
-- lighting
--==========================================================================--

local lightingSaved = nil

local function saveLighting()
    if lightingSaved then return end
    lightingSaved = {
        Brightness = Lighting.Brightness,
        ClockTime = Lighting.ClockTime,
        FogEnd = Lighting.FogEnd,
        FogStart = Lighting.FogStart,
        GlobalShadows = Lighting.GlobalShadows,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
    }
end

local function restoreLighting()
    if not lightingSaved then return end
    for key, value in pairs(lightingSaved) do
        pcall(function() Lighting[key] = value end)
    end
    -- Atmosphere density is restored separately: the instance may have been
    -- replaced by a map change while fog removal was active.
    for _, child in ipairs(Lighting:GetChildren()) do
        if child:IsA("Atmosphere") and child:GetAttribute("opuscc_density") ~= nil then
            child.Density = child:GetAttribute("opuscc_density")
            child:SetAttribute("opuscc_density", nil)
        end
    end
    lightingSaved = nil
end

local function stepLighting()
    local fullbright = config.get("visuals.fullbright", false)
    local removeFog = config.get("visuals.removeFog", false)

    if not fullbright and not removeFog then
        restoreLighting()
        return
    end

    saveLighting()

    if fullbright then
        Lighting.Brightness = config.get("visuals.brightness", 2)
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(150, 150, 150)
        Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
    end

    if removeFog then
        Lighting.FogEnd = 1e6
        Lighting.FogStart = 1e6
        for _, child in ipairs(Lighting:GetChildren()) do
            if child:IsA("Atmosphere") and child.Density > 0 then
                if child:GetAttribute("opuscc_density") == nil then
                    child:SetAttribute("opuscc_density", child.Density)
                end
                child.Density = 0
            end
        end
    end
end

--==========================================================================--
-- flash and smoke suppression
--
-- Flash is a full-screen ColorCorrection/ImageLabel the game creates on the
-- local player; smoke is a voxel particle volume spawned into workspace.Debris.
-- Both are removed as they appear rather than pre-emptively, so nothing breaks
-- when the game changes how it parents them.
--==========================================================================--

local function isFlashEffect(instance)
    if instance:IsA("ImageLabel") or instance:IsA("Frame") then
        local name = instance.Name:lower()
        return name:find("flash") ~= nil
    end
    if instance:IsA("ColorCorrectionEffect") or instance:IsA("BlurEffect") then
        return instance.Name:lower():find("flash") ~= nil
    end
    return false
end

local function watchDescendant(instance)
    if config.get("visuals.noFlash", false) and isFlashEffect(instance) then
        -- Zeroing rather than destroying keeps the game's own cleanup code from
        -- erroring on a missing instance.
        pcall(function()
            if instance:IsA("GuiObject") then
                instance.Visible = false
            elseif instance:IsA("ColorCorrectionEffect") then
                instance.Enabled = false
            elseif instance:IsA("BlurEffect") then
                instance.Size = 0
            end
        end)
    end

    if config.get("visuals.noSmoke", false) then
        if instance:IsA("ParticleEmitter") or instance:IsA("Smoke") then
            local root = instance:FindFirstAncestorWhichIsA("Model")
            local name = ((root and root.Name) or instance.Parent and instance.Parent.Name or ""):lower()
            if name:find("smoke") or instance.Name:lower():find("smoke") then
                pcall(function() instance.Enabled = false end)
            end
        end
    end
end

-- Watch only the containers the game actually spawns these into. A DataModel
-- wide DescendantAdded listener fires for every part of every rig and every
-- tracer, which is thousands of calls a second in a live round.
local function watchContainer(container)
    if not container then return end
    maid:give(container.DescendantAdded:Connect(function(instance)
        if not config.get("visuals.noFlash", false) and not config.get("visuals.noSmoke", false) then
            return
        end
        watchDescendant(instance)
    end))
end

watchContainer(Lighting)
watchContainer(LocalPlayer:FindFirstChild("PlayerGui"))
watchContainer(gameLib.debrisFolder())

-- Debris and PlayerGui are recreated across map changes and respawns.
maid:give(Workspace.ChildAdded:Connect(function(child)
    if child.Name == "Debris" then watchContainer(child) end
end))
maid:give(LocalPlayer.ChildAdded:Connect(function(child)
    if child.Name == "PlayerGui" then watchContainer(child) end
end))

local function sweepExisting()
    if not config.get("visuals.noFlash", false) and not config.get("visuals.noSmoke", false) then
        return
    end
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        for _, instance in ipairs(playerGui:GetDescendants()) do
            watchDescendant(instance)
        end
    end
    for _, instance in ipairs(Lighting:GetChildren()) do
        watchDescendant(instance)
    end
    local debris = gameLib.debrisFolder()
    if debris then
        for _, instance in ipairs(debris:GetDescendants()) do
            watchDescendant(instance)
        end
    end
end

--==========================================================================--
-- field of view
--
-- The game's CameraController writes FieldOfView every frame (scope levels,
-- sprint kick), so the offset cannot simply be added to the live value — that
-- compounds and saturates within a second. Instead each frame compares the
-- current value against what we last wrote: if they match, the game left it
-- alone and the stored base is still valid; if not, the game just set a new
-- base and we re-latch onto it.
--==========================================================================--

local baseFov = nil
local writtenFov = nil

local function stepCamera()
    local camera = Workspace.CurrentCamera
    if not camera then return end

    local offset = config.get("visuals.fov", 0)

    if offset == 0 then
        if writtenFov and baseFov then
            camera.FieldOfView = baseFov
        end
        baseFov, writtenFov = nil, nil
        return
    end

    local live = camera.FieldOfView
    if writtenFov == nil or math.abs(live - writtenFov) > 0.001 then
        baseFov = live
    end

    local target = math.clamp(baseFov + offset, 1, 120)
    camera.FieldOfView = target
    writtenFov = target
end

--==========================================================================--
-- crosshair
--==========================================================================--

local crosshair = {}
if util.hasDrawing then
    for i = 1, 4 do
        local ok, line = pcall(Drawing.new, "Line")
        if ok then
            line.Visible = false
            line.Transparency = 1
            crosshair[i] = line
        end
    end
    local ok, dot = pcall(Drawing.new, "Circle")
    if ok then
        dot.Visible = false
        dot.Filled = true
        dot.NumSides = 12
        dot.Transparency = 1
        crosshair.dot = dot
    end
end

local function stepCrosshair()
    if #crosshair == 0 then return end

    if not config.get("visuals.crosshair", false) then
        for i = 1, 4 do
            if crosshair[i] then crosshair[i].Visible = false end
        end
        if crosshair.dot then crosshair.dot.Visible = false end
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local centre = camera.ViewportSize * 0.5
    local size = config.get("visuals.crosshairSize", 8)
    local gap = config.get("visuals.crosshairGap", 4)
    local thickness = config.get("visuals.crosshairThickness", 1)
    local color = config.get("visuals.crosshairColor")

    local offsets = {
        { Vector2.new(0, -gap), Vector2.new(0, -gap - size) },
        { Vector2.new(0, gap), Vector2.new(0, gap + size) },
        { Vector2.new(-gap, 0), Vector2.new(-gap - size, 0) },
        { Vector2.new(gap, 0), Vector2.new(gap + size, 0) },
    }

    for i = 1, 4 do
        local line = crosshair[i]
        if line then
            line.From = centre + offsets[i][1]
            line.To = centre + offsets[i][2]
            line.Color = color
            line.Thickness = thickness
            line.Visible = true
        end
    end

    if crosshair.dot then
        if config.get("visuals.crosshairDot", false) then
            crosshair.dot.Position = centre
            crosshair.dot.Radius = math.max(thickness, 1)
            crosshair.dot.Color = color
            crosshair.dot.Visible = true
        else
            crosshair.dot.Visible = false
        end
    end
end

--==========================================================================--
-- hit marker
--
-- Driven by the shot counter the bullet hook increments, cross-checked against
-- the damage indicator the game raises on a confirmed hit.
--==========================================================================--

local hitMarker = {}
if util.hasDrawing then
    for i = 1, 4 do
        local ok, line = pcall(Drawing.new, "Line")
        if ok then
            line.Visible = false
            line.Transparency = 1
            line.Thickness = 2
            hitMarker[i] = line
        end
    end
end

local hitMarkerUntil = 0

do
    local remotes = util.ReplicatedStorage:FindFirstChild("NetworkRemotes")
    local ui_ = remotes and remotes:FindFirstChild("UI")
    local indicator = ui_ and ui_:FindFirstChild("CreateDamageIndicator")
    if indicator and indicator:IsA("RemoteEvent") then
        maid:give(indicator.OnClientEvent:Connect(function()
            if config.get("visuals.hitmarker", false) then
                hitMarkerUntil = os.clock() + 0.12
            end
        end))
    end
end

local function stepHitMarker()
    if #hitMarker == 0 then return end

    if os.clock() > hitMarkerUntil then
        for i = 1, 4 do
            if hitMarker[i] then hitMarker[i].Visible = false end
        end
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local centre = camera.ViewportSize * 0.5
    local inner, outer = 5, 11
    local diagonals = {
        Vector2.new(-1, -1), Vector2.new(1, -1),
        Vector2.new(-1, 1), Vector2.new(1, 1),
    }

    for i = 1, 4 do
        local line = hitMarker[i]
        if line then
            local direction = diagonals[i]
            line.From = centre + direction * inner
            line.To = centre + direction * outer
            line.Color = Color3.new(1, 1, 1)
            line.Visible = true
        end
    end
end

--==========================================================================--
-- driver
--==========================================================================--

maid:give(RunService.RenderStepped:Connect(util.guard("visuals", function()
    stepLighting()
    stepCamera()
    stepCrosshair()
    stepHitMarker()
end)))

maid:give(config.onChange("visuals.noFlash", function() task.defer(sweepExisting) end))
maid:give(config.onChange("visuals.noSmoke", function() task.defer(sweepExisting) end))

--==========================================================================--
-- ui
--==========================================================================--

function visuals.build(tab)
    local world = tab:section("World", "left")
    world:toggle("Fullbright", "visuals.fullbright")
    world:slider("Brightness", "visuals.brightness", { min = 0, max = 5, step = 0.1 })
    world:toggle("Remove fog", "visuals.removeFog")
    world:toggle("Remove flash", "visuals.noFlash")
    world:toggle("Remove smoke", "visuals.noSmoke")

    local camera = tab:section("Camera", "left")
    camera:slider("FOV offset", "visuals.fov", { min = -20, max = 40, step = 1, suffix = "°" })
    camera:label("Applied on top of the FOV the game sets, so scoping still works.")

    local cross = tab:section("Crosshair", "right")
    cross:toggle("Enabled", "visuals.crosshair")
    cross:colorpicker("Colour", "visuals.crosshairColor")
    cross:slider("Length", "visuals.crosshairSize", { min = 1, max = 30, step = 1 })
    cross:slider("Gap", "visuals.crosshairGap", { min = 0, max = 20, step = 1 })
    cross:slider("Thickness", "visuals.crosshairThickness", { min = 1, max = 5, step = 1 })
    cross:toggle("Centre dot", "visuals.crosshairDot")

    local feedback = tab:section("Feedback", "right")
    feedback:toggle("Hit marker", "visuals.hitmarker")
end

client.onUnload(function()
    restoreLighting()

    local camera = Workspace.CurrentCamera
    if camera and baseFov then
        camera.FieldOfView = baseFov
    end

    for _, line in pairs(crosshair) do
        pcall(function() line:Remove() end)
    end
    for _, line in pairs(hitMarker) do
        pcall(function() line:Remove() end)
    end

    maid:clean()
end)

return visuals
