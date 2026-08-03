--[[ opus.cc — config
     Flat, dotted-path settings store with JSON persistence.

     Every feature reads live values through `cfg.get("path.to.key")` and the UI
     writes through `cfg.set`, so nothing has to be re-plumbed when a control
     changes. Colours are serialised as hex strings and revived on load. ]]

local client = ...
local util = client.require("util")

local config = {}

local ROOT = "opuscc"
local CONFIG_DIR = ROOT .. "/configs"
local AUTOLOAD_FILE = ROOT .. "/autoload.txt"

--==========================================================================--
-- defaults
--==========================================================================--

config.defaults = {
    menu = {
        key = "Insert",
        open = true,
        accent = Color3.fromRGB(214, 148, 60),
        watermark = true,
        watermarkFps = true,
        watermarkPing = true,
        keybindList = true,
        notifications = true,
    },

    aim = {
        enabled = false,
        key = "MB2",
        mode = "Hold",              -- Hold | Toggle | Always
        target = "Head",            -- Head | UpperTorso | LowerTorso | HumanoidRootPart | Nearest
        fov = 90,
        showFov = true,
        fovColor = Color3.fromRGB(214, 148, 60),
        smoothing = 22,             -- higher converges faster
        maxDistance = 900,
        visibleOnly = true,
        ignoreDowned = true,
        autoWall = false,           -- allow targets behind penetrable geometry
        prediction = 0,             -- velocity lead multiplier
        autoFire = false,
        autoFireFov = 4,            -- degrees of crosshair error tolerated
        stickiness = 0.25,          -- seconds a lost target is retained

        silent = false,
        silentTarget = "Head",
        silentFov = 20,
        silentVisibleOnly = true,
        silentHitChance = 100,

        trigger = false,
        triggerKey = "None",
        triggerMode = "Always",     -- Always | Hold
        triggerDelay = 0.02,
        triggerRefire = 0.08,
        triggerVisibleOnly = true,
    },

    esp = {
        enabled = false,
        teammates = false,
        maxDistance = 1200,
        box = true,
        boxStyle = "Corner",        -- Full | Corner
        boxColor = Color3.fromRGB(235, 235, 235),
        boxOutline = true,
        health = true,
        healthText = false,
        name = true,
        nameColor = Color3.fromRGB(235, 235, 235),
        distance = true,
        weapon = true,
        skeleton = false,
        skeletonColor = Color3.fromRGB(190, 190, 190),
        headDot = false,
        tracer = false,
        tracerOrigin = "Bottom",    -- Bottom | Center | Mouse
        tracerColor = Color3.fromRGB(214, 148, 60),
        visibleColor = Color3.fromRGB(120, 220, 120),
        hiddenColor = Color3.fromRGB(225, 95, 95),
        useVisibilityColor = true,
        textSize = 13,
        chams = false,
        chamsFill = Color3.fromRGB(214, 148, 60),
        chamsOutline = Color3.fromRGB(255, 255, 255),
        chamsTransparency = 0.55,
        chamsThroughWalls = true,
        offScreenArrows = false,
        arrowRadius = 180,
        arrowColor = Color3.fromRGB(214, 148, 60),
        dropped = false,            -- dropped weapon pickups
        droppedColor = Color3.fromRGB(150, 190, 240),
        bomb = false,
        bombColor = Color3.fromRGB(255, 120, 60),
    },

    weapon = {
        recoilEnabled = false,
        recoilScale = 0,            -- 0 = fully suppressed, 100 = untouched
        spreadEnabled = false,
        spreadScale = 0,
        instantScope = false,
    },

    movement = {
        bhop = false,
        bhopKey = "Space",
        accelerate = 6,
        friction = 6,
        stopSpeed = 5,
        overrideMovement = false,
    },

    visuals = {
        fullbright = false,
        brightness = 2,
        removeFog = false,
        noFlash = false,
        noSmoke = false,
        fov = 0,                    -- additive field-of-view offset
        crosshair = false,
        crosshairColor = Color3.fromRGB(0, 255, 0),
        crosshairSize = 8,
        crosshairGap = 4,
        crosshairThickness = 1,
        crosshairDot = false,
        hitmarker = false,
        removeCameraShake = false,
    },

    misc = {
        spectatorList = false,
        radar = false,
        radarSize = 170,
        radarRange = 220,
        fpsUnlock = false,
        autoAcceptMapVote = false,
    },
}

--==========================================================================--
-- live store
--==========================================================================--

local function deepCopy(source)
    local out = {}
    for key, value in pairs(source) do
        if type(value) == "table" then
            out[key] = deepCopy(value)
        else
            out[key] = value
        end
    end
    return out
end

config.values = deepCopy(config.defaults)

local listeners = {}

local function resolve(path, create)
    local node = config.values
    local last
    local key
    for segment in path:gmatch("[^%.]+") do
        last = node
        key = segment
        local nextNode = node[segment]
        if nextNode == nil and create then
            nextNode = {}
            node[segment] = nextNode
        end
        if type(nextNode) == "table" then
            node = nextNode
        else
            node = nil
        end
    end
    return last, key
end

function config.get(path, fallback)
    local parent, key = resolve(path)
    if parent == nil or key == nil then return fallback end
    local value = parent[key]
    if value == nil then return fallback end
    return value
end

function config.set(path, value)
    local parent, key = resolve(path, true)
    if parent == nil or key == nil then return end
    local previous = parent[key]
    if previous == value then return end
    parent[key] = value

    local bucket = listeners[path]
    if bucket then
        for _, fn in ipairs(bucket) do
            local ok, err = pcall(fn, value, previous)
            if not ok then
                warn(("[opus.cc] config listener for %s: %s"):format(path, tostring(err)))
            end
        end
    end
end

--- Subscribe to changes on a single path. Returns an unsubscribe function.
function config.onChange(path, fn)
    local bucket = listeners[path]
    if not bucket then
        bucket = {}
        listeners[path] = bucket
    end
    table.insert(bucket, fn)
    return function()
        for i, candidate in ipairs(bucket) do
            if candidate == fn then
                table.remove(bucket, i)
                break
            end
        end
    end
end

function config.reset()
    config.values = deepCopy(config.defaults)
    for path, bucket in pairs(listeners) do
        local value = config.get(path)
        for _, fn in ipairs(bucket) do
            pcall(fn, value, nil)
        end
    end
end

--==========================================================================--
-- serialisation
--
-- Color3 has no JSON representation, so it round-trips through a tagged table.
-- Everything else is already JSON-native.
--==========================================================================--

local function encode(node)
    local out = {}
    for key, value in pairs(node) do
        if typeof(value) == "Color3" then
            out[key] = { __color = util.toHex(value) }
        elseif type(value) == "table" then
            out[key] = encode(value)
        else
            out[key] = value
        end
    end
    return out
end

local function decode(node, into)
    for key, value in pairs(node) do
        if type(value) == "table" then
            if value.__color then
                into[key] = util.hex(value.__color)
            else
                if type(into[key]) ~= "table" then into[key] = {} end
                decode(value, into[key])
            end
        else
            into[key] = value
        end
    end
end

--==========================================================================--
-- persistence
--==========================================================================--

local function fsReady()
    return util.env.writefile ~= nil and util.env.readfile ~= nil and util.env.isfile ~= nil
end

function config.list()
    local names = {}
    if not util.env.listfiles or not util.env.isfolder then return names end
    if not util.env.isfolder(CONFIG_DIR) then return names end
    local ok, files = pcall(util.env.listfiles, CONFIG_DIR)
    if not ok then return names end
    for _, file in ipairs(files) do
        local name = tostring(file):match("([^/\\]+)%.json$")
        if name then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

function config.save(name)
    if not fsReady() then
        return false, "executor has no filesystem API"
    end
    name = (name or "default"):gsub("[^%w_%-]", "")
    if name == "" then return false, "invalid name" end

    util.ensureFolder(CONFIG_DIR)
    local ok, payload = pcall(util.HttpService.JSONEncode, util.HttpService, encode(config.values))
    if not ok then return false, "encode failed" end

    local wrote = pcall(util.env.writefile, CONFIG_DIR .. "/" .. name .. ".json", payload)
    if not wrote then return false, "write failed" end
    return true
end

function config.load(name)
    if not fsReady() then
        return false, "executor has no filesystem API"
    end
    name = (name or "default"):gsub("[^%w_%-]", "")
    local path = CONFIG_DIR .. "/" .. name .. ".json"
    if not util.env.isfile(path) then return false, "config not found" end

    local ok, payload = pcall(util.env.readfile, path)
    if not ok then return false, "read failed" end

    local decoded
    ok, decoded = pcall(util.HttpService.JSONDecode, util.HttpService, payload)
    if not ok or type(decoded) ~= "table" then return false, "corrupt config" end

    -- Merge over defaults rather than replacing: a config saved by an older
    -- build is missing keys added since, and those must keep their defaults.
    local merged = deepCopy(config.defaults)
    decode(decoded, merged)
    config.values = merged

    for path_, bucket in pairs(listeners) do
        local value = config.get(path_)
        for _, fn in ipairs(bucket) do
            pcall(fn, value, nil)
        end
    end
    return true
end

function config.delete(name)
    if not util.env.delfile then return false, "unsupported" end
    name = (name or ""):gsub("[^%w_%-]", "")
    local path = CONFIG_DIR .. "/" .. name .. ".json"
    if util.env.isfile and not util.env.isfile(path) then return false, "not found" end
    local ok = pcall(util.env.delfile, path)
    return ok
end

function config.setAutoload(name)
    if not fsReady() then return false end
    util.ensureFolder(ROOT)
    return pcall(util.env.writefile, AUTOLOAD_FILE, tostring(name or ""))
end

function config.getAutoload()
    if not fsReady() then return nil end
    if not util.env.isfile(AUTOLOAD_FILE) then return nil end
    local ok, name = pcall(util.env.readfile, AUTOLOAD_FILE)
    if ok and name and #name > 0 then return name end
    return nil
end

return config
