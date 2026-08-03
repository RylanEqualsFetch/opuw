--[[ opus.cc — menu

     Assembles the UI from every feature module and owns the settings tab.
     Loaded last so each feature has already installed its runtime hooks by the
     time its controls are built. ]]

local client = ...
local util = client.require("util")
local config = client.require("config")
local ui = client.require("ui")

local esp = client.require("features/esp")
local aim = client.require("features/aim")
local weapon = client.require("features/weapon")
local movement = client.require("features/movement")
local visuals = client.require("features/visuals")
local misc = client.require("features/misc")

local menu = {}

--==========================================================================--
-- tabs
--==========================================================================--

local aimTab = ui.tab("Aim")
aim.build(aimTab, ui)

local espTab = ui.tab("Visuals")
esp.build(espTab)

local weaponTab = ui.tab("Weapon")
weapon.build(weaponTab)

local worldTab = ui.tab("World")
visuals.build(worldTab)

local movementTab = ui.tab("Movement")
movement.build(movementTab, ui)

local miscTab = ui.tab("Misc")
misc.build(miscTab)

--==========================================================================--
-- settings
--==========================================================================--

local settingsTab = ui.tab("Settings")

local interface = settingsTab:section("Interface", "left")
interface:keybind("Menu key", "menu.key")
interface:colorpicker("Accent colour", "menu.accent")
interface:toggle("Watermark", "menu.watermark")
interface:toggle("Watermark FPS", "menu.watermarkFps")
interface:toggle("Watermark ping", "menu.watermarkPing")
interface:toggle("Keybind list", "menu.keybindList")
interface:toggle("Notifications", "menu.notifications")

--==========================================================================--
-- config manager
--==========================================================================--

local configSection = settingsTab:section("Configs", "right")

local selectedName = "default"

local nameBox = configSection:textbox("Config name", "default", function(text)
    selectedName = (text ~= "" and text) or "default"
end)
nameBox:set("default")

local statusLine = configSection:label("")

local function refreshStatus()
    local names = config.list()
    if #names == 0 then
        statusLine:set("No saved configs.")
    else
        statusLine:set(("Saved: %s"):format(table.concat(names, ", ")))
    end
end

configSection:button("Save", function()
    local ok, err = config.save(selectedName)
    if ok then
        ui.notify(("Saved config '%s'"):format(selectedName))
    else
        ui.notify(("Save failed: %s"):format(tostring(err)), 5)
    end
    refreshStatus()
end)

configSection:button("Load", function()
    local ok, err = config.load(selectedName)
    if ok then
        ui.notify(("Loaded config '%s'"):format(selectedName))
    else
        ui.notify(("Load failed: %s"):format(tostring(err)), 5)
    end
end)

configSection:button("Delete", function()
    local ok = config.delete(selectedName)
    ui.notify(ok and ("Deleted '%s'"):format(selectedName) or "Delete failed")
    refreshStatus()
end)

configSection:button("Set as autoload", function()
    if config.setAutoload(selectedName) then
        ui.notify(("'%s' will load on next inject"):format(selectedName))
    else
        ui.notify("Autoload unavailable on this executor", 5)
    end
end)

configSection:button("Reset to defaults", function()
    config.reset()
    ui.notify("Settings reset")
end)

refreshStatus()

--==========================================================================--
-- session
--==========================================================================--

local sessionSection = settingsTab:section("Client", "left")
sessionSection:label(("opus.cc v%s  ·  branch %s"):format(client.version, client.branch))
sessionSection:button("Unload", function()
    ui.notify("Unloading…", 2)
    task.defer(function()
        client.unload()
    end)
end)

--==========================================================================--
-- autoload
--
-- Applied after every control exists so each one re-renders from the loaded
-- values through its config.onChange subscription.
--==========================================================================--

task.defer(function()
    local autoload = config.getAutoload()
    if not autoload or autoload == "" then return end

    local ok = config.load(autoload)
    if ok then
        selectedName = autoload
        nameBox:set(autoload)
        ui.notify(("Autoloaded '%s'"):format(autoload))
    end
end)

ui.notify(("opus.cc v%s ready"):format(client.version), 4)

return menu
