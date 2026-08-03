--[[ opus.cc — util
     Services, math helpers, lifetime management, and thin wrappers over the
     executor-provided APIs that are not uniformly available. ]]

local client = ...

local util = {}

--==========================================================================--
-- services
--==========================================================================--

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local CoreGui = game:GetService("CoreGui")
local Stats = game:GetService("Stats")

util.Players = Players
util.RunService = RunService
util.UserInputService = UserInputService
util.Workspace = Workspace
util.Lighting = Lighting
util.ReplicatedStorage = ReplicatedStorage
util.TweenService = TweenService
util.HttpService = HttpService
util.StarterGui = StarterGui
util.CoreGui = CoreGui
util.Stats = Stats

util.LocalPlayer = Players.LocalPlayer

function util.camera()
    return Workspace.CurrentCamera
end

--==========================================================================--
-- executor capability probing
--
-- Feature availability varies wildly between executors. Everything optional is
-- probed once here and exposed as a nil-able field so callers can degrade
-- instead of erroring on an undefined global.
--==========================================================================--

local function global(name)
    local ok, value = pcall(function()
        local direct = getfenv()[name]
        if direct ~= nil then return direct end
        if type(getgenv) == "function" then return getgenv()[name] end
        return nil
    end)
    return ok and value or nil
end

util.env = {
    setclipboard = global("setclipboard"),
    writefile = global("writefile"),
    readfile = global("readfile"),
    isfile = global("isfile"),
    isfolder = global("isfolder"),
    makefolder = global("makefolder"),
    listfiles = global("listfiles"),
    delfile = global("delfile"),
    mouse1click = global("mouse1click"),
    mouse1press = global("mouse1press"),
    mouse1release = global("mouse1release"),
    mousemoverel = global("mousemoverel"),
    gethui = global("gethui"),
    protectgui = global("protectgui") or global("syn") and global("syn").protect_gui,
    getconnections = global("getconnections"),
    hookmetamethod = global("hookmetamethod"),
    getrawmetatable = global("getrawmetatable"),
    setreadonly = global("setreadonly"),
    identifyexecutor = global("identifyexecutor"),
}

util.hasDrawing = (typeof(Drawing) == "table" or typeof(Drawing) == "userdata") and pcall(function()
    local probe = Drawing.new("Line")
    probe:Remove()
end)

function util.executorName()
    if util.env.identifyexecutor then
        local ok, name = pcall(util.env.identifyexecutor)
        if ok and name then return tostring(name) end
    end
    return "unknown"
end

--==========================================================================--
-- gui parenting
--
-- gethui() gives a container the game cannot enumerate; fall back to CoreGui,
-- then PlayerGui, so the menu still shows on limited executors.
--==========================================================================--

function util.guiParent()
    if util.env.gethui then
        local ok, parent = pcall(util.env.gethui)
        if ok and parent then return parent end
    end
    local ok, parent = pcall(function()
        -- Touching CoreGui throws on low-identity executors.
        local _ = CoreGui.Name
        return CoreGui
    end)
    if ok and parent then return parent end
    return util.LocalPlayer:WaitForChild("PlayerGui")
end

function util.protect(gui)
    if util.env.protectgui then
        pcall(util.env.protectgui, gui)
    end
end

--==========================================================================--
-- math
--==========================================================================--

local clamp, min, max, floor, abs = math.clamp, math.min, math.max, math.floor, math.abs

util.clamp = clamp

function util.lerp(a, b, t)
    return a + (b - a) * t
end

--- Frame-rate independent exponential smoothing.
--- `factor` is the fraction of remaining distance covered per second.
function util.damp(current, goal, factor, dt)
    if factor <= 0 then return goal end
    return util.lerp(goal, current, math.exp(-factor * dt))
end

function util.round(n, places)
    local mult = 10 ^ (places or 0)
    return floor(n * mult + 0.5) / mult
end

--- Shortest signed difference between two angles, in radians.
function util.angleDelta(a, b)
    local d = (b - a) % (math.pi * 2)
    if d > math.pi then d = d - math.pi * 2 end
    return d
end

--==========================================================================--
-- screen projection
--==========================================================================--

--- Project a world position. Returns Vector2 screen point, onScreen, depth.
function util.worldToScreen(position)
    local cam = Workspace.CurrentCamera
    if not cam then return Vector2.zero, false, 0 end
    local point, onScreen = cam:WorldToViewportPoint(position)
    return Vector2.new(point.X, point.Y), onScreen and point.Z > 0, point.Z
end

--- Screen-space AABB of a model, from its 8 bounding-box corners.
--- Returns nil when the model is fully behind the camera.
--- Corner projection (rather than a fixed-height box off the root) keeps the
--- box tight while crouching, on ladders, and mid-ragdoll.
local CORNERS = {
    Vector3.new(1, 1, 1), Vector3.new(1, 1, -1),
    Vector3.new(1, -1, 1), Vector3.new(1, -1, -1),
    Vector3.new(-1, 1, 1), Vector3.new(-1, 1, -1),
    Vector3.new(-1, -1, 1), Vector3.new(-1, -1, -1),
}

function util.modelBox(model)
    local ok, cf, size = pcall(model.GetBoundingBox, model)
    if not ok or not cf then return nil end

    local half = size * 0.5
    local cam = Workspace.CurrentCamera
    if not cam then return nil end

    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    local anyVisible = false
    local nearestDepth = math.huge

    for i = 1, 8 do
        local corner = CORNERS[i]
        local world = cf * CFrame.new(half.X * corner.X, half.Y * corner.Y, half.Z * corner.Z)
        local point, onScreen = cam:WorldToViewportPoint(world.Position)
        if point.Z > 0 then
            anyVisible = true
            if point.X < minX then minX = point.X end
            if point.Y < minY then minY = point.Y end
            if point.X > maxX then maxX = point.X end
            if point.Y > maxY then maxY = point.Y end
            if point.Z < nearestDepth then nearestDepth = point.Z end
        end
        if onScreen then anyVisible = true end
    end

    if not anyVisible or minX == math.huge then return nil end

    return {
        x = minX,
        y = minY,
        w = maxX - minX,
        h = maxY - minY,
        depth = nearestDepth,
    }
end

--==========================================================================--
-- colour
--==========================================================================--

function util.hex(str)
    str = str:gsub("#", "")
    return Color3.fromRGB(
        tonumber(str:sub(1, 2), 16),
        tonumber(str:sub(3, 4), 16),
        tonumber(str:sub(5, 6), 16)
    )
end

function util.toHex(color)
    return ("#%02X%02X%02X"):format(
        floor(color.R * 255 + 0.5),
        floor(color.G * 255 + 0.5),
        floor(color.B * 255 + 0.5)
    )
end

--- Green -> yellow -> red across a 0..1 range. Used for health bars.
function util.healthColor(alpha)
    alpha = clamp(alpha, 0, 1)
    return Color3.fromRGB(
        floor(255 * (1 - alpha) + 0.5),
        floor(255 * alpha + 0.5),
        40
    )
end

--==========================================================================--
-- Maid — connection / instance lifetime
--==========================================================================--

local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({ _tasks = {} }, Maid)
end

function Maid:give(item)
    table.insert(self._tasks, item)
    return item
end

function Maid:giveDrawing(item)
    table.insert(self._tasks, { __drawing = item })
    return item
end

local function disposeOne(item)
    local kind = typeof(item)
    if kind == "RBXScriptConnection" then
        item:Disconnect()
    elseif kind == "Instance" then
        item:Destroy()
    elseif kind == "function" then
        item()
    elseif kind == "thread" then
        -- cancel is the only safe way to stop a task.spawn'd coroutine that may
        -- be parked inside task.wait
        pcall(task.cancel, item)
    elseif kind == "table" then
        if item.__drawing then
            pcall(function() item.__drawing:Remove() end)
        elseif item.Destroy then
            item:Destroy()
        elseif item.Disconnect then
            item:Disconnect()
        end
    end
end

function Maid:clean()
    local tasks = self._tasks
    self._tasks = {}
    for i = #tasks, 1, -1 do
        local ok, err = pcall(disposeOne, tasks[i])
        if not ok then
            warn("[opus.cc] maid dispose error: " .. tostring(err))
        end
    end
end

Maid.Destroy = Maid.clean
util.Maid = Maid

--==========================================================================--
-- drawing pool
--
-- Drawing objects are comparatively expensive to allocate and are not garbage
-- collected by the executor, so ESP recycles them per player instead of
-- creating and removing them every frame.
--==========================================================================--

local Pool = {}
Pool.__index = Pool

function Pool.new()
    return setmetatable({ items = {} }, Pool)
end

function Pool:get(key, class, props)
    local item = self.items[key]
    if not item then
        if not util.hasDrawing then return nil end
        local ok, created = pcall(Drawing.new, class)
        if not ok then return nil end
        item = created
        if props then
            for k, v in pairs(props) do
                pcall(function() item[k] = v end)
            end
        end
        self.items[key] = item
    end
    return item
end

function Pool:hideAll()
    for _, item in pairs(self.items) do
        pcall(function() item.Visible = false end)
    end
end

function Pool:destroy()
    for key, item in pairs(self.items) do
        pcall(function() item:Remove() end)
        self.items[key] = nil
    end
end

util.Pool = Pool

--==========================================================================--
-- input simulation
--==========================================================================--

local VirtualInput
do
    local ok, service = pcall(function()
        return game:GetService("VirtualInputManager")
    end)
    if ok then VirtualInput = service end
end

--- Single left click. Returns false when no viable input path exists.
function util.click()
    if util.env.mouse1click then
        local ok = pcall(util.env.mouse1click)
        if ok then return true end
    end
    if util.env.mouse1press and util.env.mouse1release then
        local ok = pcall(function()
            util.env.mouse1press()
            task.wait()
            util.env.mouse1release()
        end)
        if ok then return true end
    end
    if VirtualInput then
        local ok = pcall(function()
            local pos = UserInputService:GetMouseLocation()
            VirtualInput:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
            VirtualInput:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
        end)
        if ok then return true end
    end
    return false
end

function util.setMouseDown(down)
    if down then
        if util.env.mouse1press then
            return pcall(util.env.mouse1press)
        end
    else
        if util.env.mouse1release then
            return pcall(util.env.mouse1release)
        end
    end
    if VirtualInput then
        return pcall(function()
            local pos = UserInputService:GetMouseLocation()
            VirtualInput:SendMouseButtonEvent(pos.X, pos.Y, 0, down, game, 1)
        end)
    end
    return false
end

--- Press and release a keyboard key. Used by bunny hop.
function util.tapKey(keyCode)
    if VirtualInput then
        return pcall(function()
            VirtualInput:SendKeyEvent(true, keyCode, false, game)
            VirtualInput:SendKeyEvent(false, keyCode, false, game)
        end)
    end
    return false
end

--==========================================================================--
-- keybind parsing
--==========================================================================--

local MOUSE_NAMES = {
    [Enum.UserInputType.MouseButton1] = "MB1",
    [Enum.UserInputType.MouseButton2] = "MB2",
    [Enum.UserInputType.MouseButton3] = "MB3",
}

--- Human-readable label for a stored keybind ("E", "MB2", "None").
function util.keyName(bind)
    if bind == nil then return "None" end
    if typeof(bind) == "EnumItem" then
        if MOUSE_NAMES[bind] then return MOUSE_NAMES[bind] end
        return bind.Name
    end
    if type(bind) == "string" then
        if bind == "" or bind == "None" then return "None" end
        return bind
    end
    return "None"
end

--- Store binds as plain strings so config serialisation stays trivial.
function util.encodeKey(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        return input.KeyCode.Name
    end
    return MOUSE_NAMES[input.UserInputType] or nil
end

function util.isKeyDown(bind)
    if bind == nil or bind == "None" or bind == "" then return false end
    if bind == "MB1" then
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    elseif bind == "MB2" then
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
    elseif bind == "MB3" then
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3)
    end
    local keyCode = Enum.KeyCode[bind]
    if not keyCode then return false end
    return UserInputService:IsKeyDown(keyCode)
end

--- True when an input event corresponds to a stored bind.
function util.matchesKey(bind, input)
    if bind == nil or bind == "None" or bind == "" then return false end
    return util.encodeKey(input) == bind
end

--==========================================================================--
-- filesystem
--==========================================================================--

function util.ensureFolder(path)
    if not util.env.makefolder or not util.env.isfolder then return false end
    local parts = {}
    for segment in path:gmatch("[^/]+") do
        table.insert(parts, segment)
        local partial = table.concat(parts, "/")
        if not util.env.isfolder(partial) then
            pcall(util.env.makefolder, partial)
        end
    end
    return true
end

--==========================================================================--
-- misc
--==========================================================================--

function util.notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 4,
        })
    end)
end

function util.truncate(str, limit)
    str = tostring(str)
    if #str <= limit then return str end
    return str:sub(1, limit - 1) .. "…"
end

function util.ping()
    local ok, value = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and value then return value end
    return 0
end

--- Wrap a per-frame callback so a single error does not kill the connection.
--- Repeated failures are logged once per second rather than every frame.
function util.guard(name, fn)
    local lastWarn = 0
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            local now = os.clock()
            if now - lastWarn > 1 then
                lastWarn = now
                warn(("[opus.cc] %s: %s"):format(name, tostring(err)))
            end
        end
    end
end

return util
