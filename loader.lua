--[[
    opus.cc — loader
    Bloxstrike / Frog (CS2)

    Usage:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/RylanEqualsFetch/opuw/main/loader.lua"))()

    Optional overrides, set before running the loadstring:
        getgenv().opuscc_config = {
            branch  = "main",       -- github branch to pull from
            dev     = false,        -- read modules from `devPath` on disk instead of HTTP
            devPath = "opuscc/src", -- workspace-relative source root for dev mode
            silent  = false,        -- suppress load notifications
        }
]]

local REPO = "RylanEqualsFetch/opuw"
local VERSION = "1.0.0"

local cfg = (type(getgenv) == "function" and getgenv().opuscc_config) or {}
local BRANCH = cfg.branch or "main"
local DEV = cfg.dev == true
local DEV_PATH = cfg.devPath or "opuscc/src"
local SILENT = cfg.silent == true

local BASE = ("https://raw.githubusercontent.com/%s/%s/"):format(REPO, BRANCH)

--==========================================================================--
-- environment probing
--==========================================================================--

local httpGet = (syn and syn.request and function(url)
    local res = syn.request({ Url = url, Method = "GET" })
    if res.StatusCode ~= 200 then
        error(("HTTP %d for %s"):format(res.StatusCode, url), 0)
    end
    return res.Body
end) or function(url)
    return game:HttpGet(url, true)
end

local function env(name)
    local fn = rawget(getfenv(), name)
    if fn ~= nil then return fn end
    if type(getgenv) == "function" then return getgenv()[name] end
    return nil
end

--==========================================================================--
-- unload any previously running instance
--==========================================================================--

if type(getgenv) == "function" and getgenv().opuscc then
    local prev = getgenv().opuscc
    local ok, err = pcall(function()
        if prev.unload then prev.unload() end
    end)
    if not ok then
        warn("[opus.cc] previous instance failed to unload cleanly: " .. tostring(err))
    end
    getgenv().opuscc = nil
end

--==========================================================================--
-- module graph
--
-- Ordering below is load order for side-effect-free definition only; modules
-- resolve each other lazily through `client.require`, so a cycle in *usage*
-- (esp asking game for enemies while game is still defining) is fine — only a
-- cycle at definition time would deadlock, and there are none.
--==========================================================================--

local MODULES = {
    "src/util.lua",
    "src/config.lua",
    "src/game.lua",
    "src/hooks.lua",
    "src/ui.lua",
    "src/features/esp.lua",
    "src/features/aim.lua",
    "src/features/weapon.lua",
    "src/features/movement.lua",
    "src/features/visuals.lua",
    "src/features/misc.lua",
    "src/menu.lua",
}

--==========================================================================--
-- client table — the shared environment every module receives
--==========================================================================--

local client = {
    version = VERSION,
    repo = REPO,
    branch = BRANCH,
    base = BASE,
    dev = DEV,
    silent = SILENT,
    modules = {},   -- path -> return value
    sources = {},   -- path -> source string
    loaded = false,
    unloading = false,
}

local readfile_ = env("readfile")
local isfile_ = env("isfile")

local function fetch(path)
    if DEV then
        local diskPath = DEV_PATH .. "/" .. path:gsub("^src/", "")
        if isfile_ and readfile_ and isfile_(diskPath) then
            return readfile_(diskPath)
        end
        warn(("[opus.cc] dev file missing (%s), falling back to HTTP"):format(diskPath))
    end

    -- cache-bust: raw.githubusercontent caches aggressively and a stale module
    -- is far more confusing than a slightly slower load.
    local url = BASE .. path .. "?v=" .. tostring(tick())

    local lastErr
    for attempt = 1, 3 do
        local ok, body = pcall(httpGet, url)
        if ok and type(body) == "string" and #body > 0 then
            return body
        end
        lastErr = body
        task.wait(0.35 * attempt)
    end
    error(("failed to fetch %s: %s"):format(path, tostring(lastErr)), 0)
end

--- Load a module by path, compiling and running it at most once.
function client.require(path)
    if not path:match("%.lua$") then
        path = path .. ".lua"
    end
    if not path:match("^src/") and path ~= "loader.lua" then
        path = "src/" .. path
    end

    local cached = client.modules[path]
    if cached ~= nil then
        return cached
    end

    local source = client.sources[path]
    if not source then
        source = fetch(path)
        client.sources[path] = source
    end

    local chunk, compileErr = loadstring(source, "=opus.cc/" .. path)
    if not chunk then
        error(("compile error in %s: %s"):format(path, tostring(compileErr)), 0)
    end

    local result = chunk(client)
    if result == nil then
        result = true -- allow side-effect-only modules without breaking the cache
    end
    client.modules[path] = result
    return result
end

--==========================================================================--
-- teardown
--==========================================================================--

local teardown = {}

--- Register a function to run on unload. Called by every module that touches
--- global state (connections, instances, engine hooks).
function client.onUnload(fn)
    table.insert(teardown, fn)
end

function client.unload()
    if client.unloading then return end
    client.unloading = true

    -- Reverse order so hooks installed last are removed first; restoring an
    -- engine hook under a still-live feature would otherwise fight it.
    for i = #teardown, 1, -1 do
        local ok, err = pcall(teardown[i])
        if not ok then
            warn("[opus.cc] teardown error: " .. tostring(err))
        end
    end

    table.clear(teardown)
    table.clear(client.modules)
    table.clear(client.sources)
    client.loaded = false

    if type(getgenv) == "function" then
        getgenv().opuscc = nil
    end
end

--==========================================================================--
-- boot
--==========================================================================--

if type(getgenv) == "function" then
    getgenv().opuscc = client
end

local function notify(title, text, duration)
    if SILENT then return end
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 4,
        })
    end)
end

local t0 = os.clock()

-- Prefetch every module in parallel-ish fashion before executing any of them.
-- A half-loaded client with three of twelve modules live is worse than a clean
-- failure, so all network IO happens before the first chunk runs.
local fetchOk, fetchErr = pcall(function()
    for _, path in ipairs(MODULES) do
        if client.sources[path] == nil then
            client.sources[path] = fetch(path)
        end
    end
end)

if not fetchOk then
    notify("opus.cc", "Download failed — see console", 6)
    client.unload()
    error("[opus.cc] " .. tostring(fetchErr), 0)
end

local runOk, runErr = pcall(function()
    for _, path in ipairs(MODULES) do
        client.require(path)
    end
end)

if not runOk then
    notify("opus.cc", "Load failed — see console", 6)
    warn("[opus.cc] load error: " .. tostring(runErr))
    client.unload()
    error("[opus.cc] " .. tostring(runErr), 0)
end

client.loaded = true

local elapsed = math.floor((os.clock() - t0) * 1000)
notify("opus.cc", ("v%s loaded in %dms — Insert to toggle"):format(VERSION, elapsed), 5)
print(("[opus.cc] v%s loaded in %dms (%d modules)"):format(VERSION, elapsed, #MODULES))

return client
