--[[ opus.cc — movement

     Bloxstrike runs a Source-style movement controller on the client and reads
     its tuning from attributes on the LocalPlayer (SV_ACCELERATE, SV_FRICTION,
     SV_STOPSPEED — set once at character spawn if absent). Writing those
     attributes is the supported way to change movement feel; the controller
     picks the new values up on its next tick.

     Bunny hop re-triggers the jump input on landing instead of writing to the
     humanoid state, so the controller's own jump handling stays authoritative
     and the movement animations do not desync. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local gameLib = client.require("game")

local RunService = util.RunService
local LocalPlayer = util.LocalPlayer

local movement = {}

local maid = util.Maid.new()

--==========================================================================--
-- movement tuning
--==========================================================================--

local DEFAULTS = {
    SV_ACCELERATE = 6,
    SV_STOPSPEED = 5,
    SV_FRICTION = 6,
}

local function applyTuning()
    if not config.get("movement.overrideMovement", false) then
        return
    end
    LocalPlayer:SetAttribute("SV_ACCELERATE", config.get("movement.accelerate", 6))
    LocalPlayer:SetAttribute("SV_STOPSPEED", config.get("movement.stopSpeed", 5))
    LocalPlayer:SetAttribute("SV_FRICTION", config.get("movement.friction", 6))
end

local function restoreTuning()
    for name, value in pairs(DEFAULTS) do
        LocalPlayer:SetAttribute(name, value)
    end
end

maid:give(config.onChange("movement.accelerate", applyTuning))
maid:give(config.onChange("movement.stopSpeed", applyTuning))
maid:give(config.onChange("movement.friction", applyTuning))
maid:give(config.onChange("movement.overrideMovement", function(enabled)
    if enabled then applyTuning() else restoreTuning() end
end))

--==========================================================================--
-- bunny hop
--==========================================================================--

local JUMP_STATES = {
    [Enum.HumanoidStateType.Landed] = true,
    [Enum.HumanoidStateType.Running] = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
}

local lastJump = 0

--- Jump through the game's own entry point.
---
--- CharacterController.jump() sets IsJumpRequested and calls Character:Jump(),
--- which is where the stamina cost, the 0.15s air-time gate and the jump
--- animation live. Writing Humanoid.Jump directly skips all of that and the
--- movement controller simply ignores the resulting state change.
local function requestJump()
    local controller = gameLib.requireGame("Controllers.CharacterController")
    if controller and type(controller.jump) == "function" then
        local ok = pcall(controller.jump)
        if ok then return true end
    end

    -- Fallback for a build where the controller moved: synthesise the key the
    -- Jump input action is bound to.
    return util.tapKey(Enum.KeyCode.Space)
end

local function stepBhop()
    if not config.get("movement.bhop", false) then return end
    if not util.isKeyDown(config.get("movement.bhopKey", "Space")) then return end

    local character = gameLib.localCharacter()
    if not character then return end

    local humanoid = gameLib.humanoidOf(character)
    if not humanoid then return end

    -- Only re-jump on ground contact. Spamming in the air fights the
    -- controller's air-acceleration and kills speed.
    local state = humanoid:GetState()
    if not JUMP_STATES[state] then return end

    local now = os.clock()
    if now - lastJump < 0.05 then return end
    lastJump = now

    requestJump()
end

--==========================================================================--
-- driver
--==========================================================================--

maid:give(RunService.Heartbeat:Connect(util.guard("movement", stepBhop)))

-- Re-apply tuning on respawn: the character setup writes the defaults back
-- whenever the attributes are missing, and a fresh character clears them.
maid:give(LocalPlayer.CharacterAdded:Connect(function()
    task.delay(0.5, applyTuning)
end))

applyTuning()

--==========================================================================--
-- ui
--==========================================================================--

function movement.build(tab, ui)
    local bhop = tab:section("Bunny hop", "left")
    bhop:toggle("Enabled", "movement.bhop")
    bhop:keybind("Hold key", "movement.bhopKey")
    bhop:label("Re-jumps the frame you land while the key is held.")

    local tuning = tab:section("Movement tuning", "right")
    tuning:label("Overrides the client movement constants the game sets on spawn.")
    tuning:toggle("Override", "movement.overrideMovement")
    tuning:slider("Acceleration", "movement.accelerate", { min = 1, max = 30, step = 0.5 })
    tuning:slider("Friction", "movement.friction", { min = 0, max = 20, step = 0.5 })
    tuning:slider("Stop speed", "movement.stopSpeed", { min = 0, max = 20, step = 0.5 })
    tuning:button("Reset to game defaults", function()
        config.set("movement.accelerate", DEFAULTS.SV_ACCELERATE)
        config.set("movement.friction", DEFAULTS.SV_FRICTION)
        config.set("movement.stopSpeed", DEFAULTS.SV_STOPSPEED)
        restoreTuning()
    end)

    if ui then
        ui.trackKeybind("Bunny hop", "movement.bhopKey", function()
            return config.get("movement.bhop", false)
                and util.isKeyDown(config.get("movement.bhopKey", "Space"))
        end)
    end
end

client.onUnload(function()
    restoreTuning()
    maid:clean()
end)

return movement
