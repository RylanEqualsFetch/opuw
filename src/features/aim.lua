--[[ opus.cc — aim

     Three independent systems that share one target resolver:

       aimbot   moves the real camera toward a target each frame
       silent   leaves the camera alone and redirects the bullet ray inside
                Bullet:_performRaycast (see hooks.lua)
       trigger  fires when the crosshair already rests on a hostile rig

     Target scoring matches the game's own aim assist: closest to the crosshair
     wins, weighted by distance, gated on field of view and line of sight. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local gameLib = client.require("game")
local hooks = client.require("hooks")

local Workspace = util.Workspace
local RunService = util.RunService
local UserInputService = util.UserInputService

local aim = {}

local maid = util.Maid.new()

--==========================================================================--
-- state
--==========================================================================--

local toggledOn = false            -- for the Toggle activation mode
local currentTarget = nil          -- character model
local lastTargetTime = 0
local lastShot = 0

aim.target = nil

--==========================================================================--
-- fov circle
--==========================================================================--

local fovCircle
if util.hasDrawing then
    local ok, circle = pcall(Drawing.new, "Circle")
    if ok then
        circle.Visible = false
        circle.Thickness = 1
        circle.NumSides = 64
        circle.Filled = false
        circle.Transparency = 1
        fovCircle = circle
    end
end

--- The aimbot FOV is expressed in degrees of view cone; convert it to a radius
--- in pixels using the camera's actual vertical FOV so the circle matches the
--- cone at any zoom level (scoping included).
local function fovToPixels(degrees)
    local camera = Workspace.CurrentCamera
    if not camera then return 0 end
    local viewport = camera.ViewportSize
    local halfView = math.rad(camera.FieldOfView * 0.5)
    if halfView <= 0 then return 0 end
    local pixelsPerRadian = (viewport.Y * 0.5) / math.tan(halfView)
    return math.tan(math.rad(math.clamp(degrees, 0, 179) * 0.5)) * pixelsPerRadian
end

local function renderFovCircle()
    if not fovCircle then return end

    if not config.get("aim.showFov", true)
        or not (config.get("aim.enabled", false) or config.get("aim.silent", false)) then
        fovCircle.Visible = false
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        fovCircle.Visible = false
        return
    end

    local degrees = config.get("aim.enabled", false)
        and config.get("aim.fov", 90)
        or config.get("aim.silentFov", 20)

    fovCircle.Position = camera.ViewportSize * 0.5
    fovCircle.Radius = fovToPixels(degrees)
    fovCircle.Color = config.get("aim.fovColor")
    fovCircle.Visible = true
end

--==========================================================================--
-- target resolution
--==========================================================================--

local enemyBuffer = {}

--- Predicted world position of a hitbox, optionally led by target velocity.
local function aimPoint(character, mode, prediction)
    local part = gameLib.hitPart(character, mode)
    if not part then return nil, nil end

    local position = part.Position
    if prediction and prediction > 0 then
        local velocity = part.AssemblyLinearVelocity
        if velocity and velocity.Magnitude > 0.1 then
            position = position + velocity * prediction
        end
    end
    return position, part
end

--- Pick the best hostile target.
--- `opts = { fov, hitbox, visibleOnly, maxDistance, prediction }`
--- Returns character, world aim point, angular error in degrees.
local function resolve(opts)
    local camera = Workspace.CurrentCamera
    if not camera then return nil end

    local cameraCF = camera.CFrame
    local origin = cameraCF.Position
    local look = cameraCF.LookVector

    local fovLimit = math.rad(opts.fov or 90)
    local maxDistance = opts.maxDistance or 900
    local visibleOnly = opts.visibleOnly
    local prediction = opts.prediction or 0

    local bestCharacter, bestPoint, bestScore, bestAngle

    for _, record in ipairs(gameLib.enemies(enemyBuffer)) do
        local character = record.character

        local point, part = aimPoint(character, opts.hitbox or "Head", prediction)
        if point and part then
            local delta = point - origin
            local distance = delta.Magnitude

            if distance <= maxDistance and distance > 0.1 then
                local angle = math.acos(math.clamp(look:Dot(delta.Unit), -1, 1))

                if angle <= fovLimit then
                    local visible = true
                    if visibleOnly then
                        visible = gameLib.isVisible(character, point, origin)
                    end

                    if visible then
                        -- Same weighting the game uses for aim assist: prefer
                        -- close to the crosshair first, near in world second.
                        local score = (1 - angle / fovLimit) * 4 + 1 / (distance + 1)
                        if not bestScore or score > bestScore then
                            bestCharacter = character
                            bestPoint = point
                            bestScore = score
                            bestAngle = angle
                        end
                    end
                end
            end
        end
    end

    if not bestCharacter then return nil end
    return bestCharacter, bestPoint, math.deg(bestAngle)
end

aim.resolve = resolve

--==========================================================================--
-- activation
--==========================================================================--

local function activationHeld(keyPath, modePath)
    local mode = config.get(modePath, "Hold")
    if mode == "Always" then return true end

    local bind = config.get(keyPath, "None")
    if mode == "Toggle" then
        return toggledOn
    end
    return util.isKeyDown(bind)
end

maid:give(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if config.get("aim.mode", "Hold") ~= "Toggle" then return end
    if util.matchesKey(config.get("aim.key", "MB2"), input) then
        toggledOn = not toggledOn
    end
end))

function aim.isActive()
    return config.get("aim.enabled", false)
        and activationHeld("aim.key", "aim.mode")
        and gameLib.localAlive()
end

--==========================================================================--
-- aimbot
--==========================================================================--

local function stepAimbot(dt)
    renderFovCircle()

    if not aim.isActive() then
        currentTarget = nil
        aim.target = nil
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    local character, point = resolve({
        fov = config.get("aim.fov", 90),
        hitbox = config.get("aim.target", "Head"),
        visibleOnly = config.get("aim.visibleOnly", true),
        maxDistance = config.get("aim.maxDistance", 900),
        prediction = config.get("aim.prediction", 0),
    })

    -- Stickiness: keep tracking a target that briefly leaves the cone or dips
    -- behind cover, so the aim does not snap away on a corner peek.
    local now = os.clock()
    if character then
        currentTarget = character
        lastTargetTime = now
    elseif currentTarget then
        if now - lastTargetTime > config.get("aim.stickiness", 0.25)
            or not gameLib.isAlive(currentTarget) then
            currentTarget = nil
        else
            point = select(1, aimPoint(currentTarget,
                config.get("aim.target", "Head"),
                config.get("aim.prediction", 0)))
            character = currentTarget
        end
    end

    aim.target = character
    if not character or not point then return end

    local origin = camera.CFrame.Position
    local goal = CFrame.lookAt(origin, point)
    local smoothing = config.get("aim.smoothing", 22)

    if smoothing >= 100 then
        camera.CFrame = goal
    else
        -- Exponential approach keeps the pull rate identical at any frame rate.
        local alpha = 1 - math.exp(-math.max(smoothing, 0.1) * dt)
        camera.CFrame = camera.CFrame:Lerp(goal, math.clamp(alpha, 0, 1))
    end

    if config.get("aim.autoFire", false) then
        local look = camera.CFrame.LookVector
        local delta = (point - origin)
        if delta.Magnitude > 0.1 then
            local error_ = math.deg(math.acos(math.clamp(look:Dot(delta.Unit), -1, 1)))
            if error_ <= config.get("aim.autoFireFov", 4) then
                if now - lastShot >= 0.05 then
                    lastShot = now
                    util.click()
                end
            end
        end
    end
end

--==========================================================================--
-- silent aim
--
-- The resolver runs inside the bullet raycast hook rather than on a frame
-- boundary, so the redirect always uses the position the target occupies at the
-- exact moment the shot resolves.
--==========================================================================--

hooks.state.silentResolver = function()
    if not config.get("aim.silent", false) then return nil end
    if not gameLib.localAlive() then return nil end

    local chance = config.get("aim.silentHitChance", 100)
    if chance < 100 and math.random(1, 100) > chance then
        return nil
    end

    local _, point = resolve({
        fov = config.get("aim.silentFov", 20),
        hitbox = config.get("aim.silentTarget", "Head"),
        visibleOnly = config.get("aim.silentVisibleOnly", true),
        maxDistance = config.get("aim.maxDistance", 900),
        prediction = 0,     -- hitscan: the ray resolves this instant, no lead
    })
    return point
end

--==========================================================================--
-- trigger bot
--==========================================================================--

local triggerArmedAt = nil

local function stepTrigger()
    if not config.get("aim.trigger", false) or not gameLib.localAlive() then
        triggerArmedAt = nil
        return
    end

    if config.get("aim.triggerMode", "Always") == "Hold" then
        if not util.isKeyDown(config.get("aim.triggerKey", "None")) then
            triggerArmedAt = nil
            return
        end
    end

    local now = os.clock()
    if now - lastShot < config.get("aim.triggerRefire", 0.08) then return end

    local result = gameLib.crosshairCast(config.get("aim.maxDistance", 900))
    if not result or not result.Instance then
        triggerArmedAt = nil
        return
    end

    local player, character = gameLib.ownerOfPart(result.Instance)
    if not player or not character or not gameLib.isEnemy(player) or not gameLib.isAlive(character) then
        triggerArmedAt = nil
        return
    end

    -- Arm on first contact, fire once the configured delay has elapsed while
    -- the crosshair stayed on target. Resetting on loss prevents firing into
    -- the space a target just left.
    if not triggerArmedAt then
        triggerArmedAt = now
        return
    end

    if now - triggerArmedAt >= config.get("aim.triggerDelay", 0.02) then
        lastShot = now
        triggerArmedAt = nil
        util.click()
    end
end

--==========================================================================--
-- driver
--==========================================================================--

maid:give(RunService.RenderStepped:Connect(util.guard("aim", function(dt)
    stepAimbot(dt)
    stepTrigger()
end)))

--==========================================================================--
-- ui
--==========================================================================--

local HITBOXES = { "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart", "Nearest" }

function aim.build(tab, ui)
    local bot = tab:section("Aimbot", "left")
    bot:toggle("Enabled", "aim.enabled")
    bot:keybind("Aim key", "aim.key")
    bot:dropdown("Activation", "aim.mode", { "Hold", "Toggle", "Always" })
    bot:dropdown("Hitbox", "aim.target", HITBOXES)
    bot:slider("Field of view", "aim.fov", { min = 1, max = 180, step = 1, suffix = "°" })
    bot:slider("Smoothing", "aim.smoothing", { min = 1, max = 100, step = 1 })
    bot:slider("Max distance", "aim.maxDistance", { min = 50, max = 2000, step = 25 })
    bot:slider("Target stickiness", "aim.stickiness", { min = 0, max = 1, step = 0.05, suffix = "s" })
    bot:slider("Velocity lead", "aim.prediction", { min = 0, max = 0.5, step = 0.01, suffix = "s" })
    bot:toggle("Visible only", "aim.visibleOnly")
    bot:divider()
    bot:toggle("Auto fire", "aim.autoFire")
    bot:slider("Auto fire cone", "aim.autoFireFov", { min = 0.5, max = 20, step = 0.5, suffix = "°" })

    local fov = tab:section("FOV circle", "left")
    fov:toggle("Show circle", "aim.showFov")
    fov:colorpicker("Circle colour", "aim.fovColor")

    local silent = tab:section("Silent aim", "right")
    silent:label("Redirects the bullet ray without moving the camera.")
    silent:toggle("Enabled", "aim.silent")
    silent:dropdown("Hitbox", "aim.silentTarget", HITBOXES)
    silent:slider("Field of view", "aim.silentFov", { min = 1, max = 180, step = 1, suffix = "°" })
    silent:slider("Hit chance", "aim.silentHitChance", { min = 0, max = 100, step = 1, suffix = "%" })
    silent:toggle("Visible only", "aim.silentVisibleOnly")

    local trigger = tab:section("Trigger bot", "right")
    trigger:toggle("Enabled", "aim.trigger")
    trigger:dropdown("Activation", "aim.triggerMode", { "Always", "Hold" })
    trigger:keybind("Trigger key", "aim.triggerKey")
    trigger:slider("Delay", "aim.triggerDelay", { min = 0, max = 0.5, step = 0.01, suffix = "s" })
    trigger:slider("Refire", "aim.triggerRefire", { min = 0.02, max = 1, step = 0.01, suffix = "s" })

    if ui then
        ui.trackKeybind("Aimbot", "aim.key", function()
            return aim.isActive()
        end)
        ui.trackKeybind("Trigger", "aim.triggerKey", function()
            return config.get("aim.trigger", false)
                and util.isKeyDown(config.get("aim.triggerKey", "None"))
        end)
    end

    if not util.env.mouse1click and not util.env.mouse1press then
        local warning = tab:section("Notice", "right")
        warning:label("This executor exposes no mouse input function. Auto fire "
            .. "and the trigger bot will fall back to VirtualInputManager, which "
            .. "some executors block.")
    end
end

client.onUnload(function()
    hooks.state.silentResolver = nil
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    maid:clean()
end)

return aim
