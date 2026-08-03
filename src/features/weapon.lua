--[[ opus.cc — weapon

     Thin control surface over the two hooks installed in hooks.lua. The heavy
     lifting is there; this module only translates UI percentages into the
     scalars the hooks read, and drives the instant-scope helper. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local gameLib = client.require("game")
local hooks = client.require("hooks")

local RunService = util.RunService

local weapon = {}

local maid = util.Maid.new()

--==========================================================================--
-- hook state sync
--
-- Both scalars are nil while their feature is off so the hooks pass the
-- original values straight through with no arithmetic at all.
--==========================================================================--

local function syncRecoil()
    if config.get("weapon.recoilEnabled", false) then
        hooks.state.recoilScale = math.clamp(config.get("weapon.recoilScale", 0), 0, 100) / 100
    else
        hooks.state.recoilScale = nil
    end
end

local function syncSpread()
    if config.get("weapon.spreadEnabled", false) then
        hooks.state.spreadScale = math.clamp(config.get("weapon.spreadScale", 0), 0, 100) / 100
    else
        hooks.state.spreadScale = nil
    end
end

maid:give(config.onChange("weapon.recoilEnabled", syncRecoil))
maid:give(config.onChange("weapon.recoilScale", syncRecoil))
maid:give(config.onChange("weapon.spreadEnabled", syncSpread))
maid:give(config.onChange("weapon.spreadScale", syncSpread))

syncRecoil()
syncSpread()

--==========================================================================--
-- instant scope
--
-- Snipers ramp their scoped spread down over a short settle window. Nudging the
-- weapon's spread spring straight to its minimum once the scope is up removes
-- that wait without touching the scope animation itself.
--==========================================================================--

local function stepInstantScope()
    if not config.get("weapon.instantScope", false) then return end

    local held = gameLib.equippedWeapon()
    if not held or not held.IsAiming then return end

    local bullet = held.Bullet
    if not bullet then return end

    local ok = pcall(function()
        local spreadConfig = bullet.ActiveSpreadConfig or (bullet.Properties and bullet.Properties.Spread)
        if not spreadConfig or not spreadConfig.Range then return end
        if bullet.Spread and bullet.Spread.reset then
            bullet.Spread:reset(spreadConfig.Range.Min)
            bullet.Spread:setGoal(spreadConfig.Range.Min)
        end
    end)

    if not ok then
        -- A structural change in the weapon module should disable the feature
        -- rather than spam the console every frame.
        config.set("weapon.instantScope", false)
        warn("[opus.cc] instant scope unavailable on this game build; disabled")
    end
end

maid:give(RunService.Heartbeat:Connect(util.guard("weapon", stepInstantScope)))

--==========================================================================--
-- ui
--==========================================================================--

function weapon.build(tab)
    local recoil = tab:section("Recoil", "left")
    recoil:label("Scales the camera kick the weapon applies. 0% removes it.")
    recoil:toggle("Enabled", "weapon.recoilEnabled")
    recoil:slider("Recoil", "weapon.recoilScale", { min = 0, max = 100, step = 1, suffix = "%" })

    local spread = tab:section("Spread", "left")
    spread:label("Scales the random cone applied to each bullet. 0% removes it.")
    spread:toggle("Enabled", "weapon.spreadEnabled")
    spread:slider("Spread", "weapon.spreadScale", { min = 0, max = 100, step = 1, suffix = "%" })

    local misc = tab:section("Scope", "right")
    misc:toggle("Instant scope accuracy", "weapon.instantScope")

    local status = tab:section("Status", "right")
    local line = status:label("Waiting for the game's weapon modules to load…")

    -- Poll rather than push: hooks.install retries on its own schedule and has
    -- no completion signal to subscribe to.
    maid:give(task.spawn(function()
        while not hooks.ready do
            task.wait(0.5)
        end
        line:set("Weapon hooks attached.")
    end))
end

client.onUnload(function()
    hooks.state.recoilScale = nil
    hooks.state.spreadScale = nil
    maid:clean()
end)

return weapon
