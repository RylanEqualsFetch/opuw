--[[ opus.cc — engine hooks

     The client computes its own bullets: `Bullet:_performRaycast(spread)` reads
     `CurrentCamera:ViewportPointToRay(centre)`, perturbs that direction by a
     random cone of `spread` degrees, casts, and returns {Origin, Direction,
     Hits}. Recoil is a camera kick pushed through
     `CameraController.setWeaponRecoil`, so it feeds back into the same ray.

     That gives three clean patch points on the *class tables* — require() on an
     already-loaded ModuleScript hands back the exact table the game is using,
     so replacing a method affects every existing weapon instance immediately
     and no metatable work is needed:

       spread   -> clamp the cone argument before the original runs
       aim      -> swap the camera CFrame around the original call
       recoil   -> scale the kick vector on its way to the camera

     The camera swap is safe because `_performRaycast` reads the camera
     synchronously and we restore before returning: no render step can observe
     the intermediate CFrame, so the view never visibly moves. ]]

local client = ...
local util = client.require("util")
local gameLib = client.require("game")

local hooks = {}

--==========================================================================--
-- state written by the feature modules
--==========================================================================--

hooks.state = {
    -- Multiplier applied to the bullet spread cone. 0 removes it entirely.
    spreadScale = nil,      -- nil = untouched

    -- Multiplier applied to recoil camera kick. 0 removes it entirely.
    recoilScale = nil,      -- nil = untouched

    -- Set to a Vector3 to redirect the next bullet at that world point.
    -- Consumed by whichever raycast happens next, then cleared by the provider.
    silentTarget = nil,

    -- Called immediately before each bullet is cast, so the aim module can
    -- resolve a target at exactly the right instant rather than one frame late.
    silentResolver = nil,

    -- Incremented on every bullet the client fires; used by the hit marker.
    shotCounter = 0,
}

--==========================================================================--
-- patch bookkeeping
--==========================================================================--

local installed = {}

local function patch(tableRef, key, replacement)
    if not tableRef then return false end
    local original = rawget(tableRef, key)
    if type(original) ~= "function" then return false end

    table.insert(installed, { target = tableRef, key = key, original = original })
    tableRef[key] = replacement
    return true
end

function hooks.restore()
    for i = #installed, 1, -1 do
        local entry = installed[i]
        local ok, err = pcall(function()
            entry.target[entry.key] = entry.original
        end)
        if not ok then
            warn("[opus.cc] failed to restore hook " .. tostring(entry.key) .. ": " .. tostring(err))
        end
    end
    table.clear(installed)
    hooks.ready = false
end

--==========================================================================--
-- bullet raycast
--==========================================================================--

local function installBulletHook()
    local Bullet = gameLib.bulletClass()
    if not Bullet then return false end

    local original = rawget(Bullet, "_performRaycast")
    if type(original) ~= "function" then return false end

    local state = hooks.state
    local Workspace = util.Workspace

    return patch(Bullet, "_performRaycast", function(self, spread)
        state.shotCounter += 1

        local scale = state.spreadScale
        if scale then
            spread = (tonumber(spread) or 0) * scale
        end

        -- Ask the aim module for a redirect target for *this* bullet.
        local target = state.silentTarget
        if not target and state.silentResolver then
            local ok, resolved = pcall(state.silentResolver)
            if ok then target = resolved end
        end
        state.silentTarget = nil

        if typeof(target) ~= "Vector3" then
            return original(self, spread)
        end

        local camera = Workspace.CurrentCamera
        if not camera then
            return original(self, spread)
        end

        local saved = camera.CFrame
        local origin = saved.Position
        if (target - origin).Magnitude < 0.1 then
            return original(self, spread)
        end

        -- pcall the body so a mid-swap error can never leave the player's
        -- camera pointing at the target.
        camera.CFrame = CFrame.lookAt(origin, target)
        local ok, result = pcall(original, self, spread)
        camera.CFrame = saved

        if not ok then
            error(result, 0)
        end
        return result
    end)
end

--==========================================================================--
-- recoil
--==========================================================================--

local function installRecoilHook()
    local CameraController = gameLib.cameraController()
    if not CameraController then return false end

    local original = rawget(CameraController, "setWeaponRecoil")
    if type(original) ~= "function" then return false end

    local state = hooks.state

    return patch(CameraController, "setWeaponRecoil", function(recoil, cameraScale, ...)
        local scale = state.recoilScale
        if not scale then
            return original(recoil, cameraScale, ...)
        end

        if scale <= 0 then
            -- Zeroing the value rather than skipping the call keeps the
            -- controller's internal spring in sync, so releasing the hook
            -- does not snap the view.
            if type(recoil) == "table" then
                local patched = table.clone(recoil)
                patched.Value = Vector3.zero
                return original(patched, 0, ...)
            end
            return original(recoil, 0, ...)
        end

        if type(recoil) == "table" and typeof(recoil.Value) == "Vector3" then
            local patched = table.clone(recoil)
            patched.Value = recoil.Value * scale
            return original(patched, (cameraScale or 0) * scale, ...)
        end

        return original(recoil, cameraScale, ...)
    end)
end

--==========================================================================--
-- installation
--
-- The weapon modules are required lazily by the game, so a hook attempt at load
-- time can legitimately find nothing. Retry on a slow poll until each lands.
--==========================================================================--

hooks.ready = false

local maid = util.Maid.new()
local pending = {
    bullet = installBulletHook,
    recoil = installRecoilHook,
}

function hooks.install()
    local remaining = 0
    for name, installer in pairs(pending) do
        local ok, result = pcall(installer)
        if ok and result then
            pending[name] = nil
        else
            remaining += 1
        end
    end

    hooks.ready = (next(pending) == nil)
    return remaining
end

-- First attempt now, then retry until everything is attached. Modules are
-- required within the first seconds of joining, so this settles quickly.
hooks.install()

if not hooks.ready then
    maid:give(task.spawn(function()
        for _ = 1, 120 do
            task.wait(0.5)
            hooks.install()
            if hooks.ready then break end
        end
        if not hooks.ready then
            local missing = {}
            for name in pairs(pending) do table.insert(missing, name) end
            warn("[opus.cc] hooks not attached: " .. table.concat(missing, ", "))
        end
    end))
end

client.onUnload(function()
    hooks.state.spreadScale = nil
    hooks.state.recoilScale = nil
    hooks.state.silentTarget = nil
    hooks.state.silentResolver = nil
    hooks.restore()
    maid:clean()
end)

return hooks
