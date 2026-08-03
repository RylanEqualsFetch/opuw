--[[ opus.cc — game bindings

     Everything Bloxstrike-specific lives here so the feature modules stay
     generic. Derived from the client code:

       * Characters are parented to workspace.Characters.<Team>, not workspace.
       * Team is a player attribute: "Terrorists" / "Counter-Terrorists".
       * In Deathmatch every other player is hostile regardless of team.
       * Rig is stock R15; the game's own aim assist targets `Head`.
       * A character is dead when Humanoid.Health <= 0 OR the model carries the
         `Dead` attribute (set before the humanoid actually zeroes out).
       * Bullet rays originate from the camera centre and honour the ignore list
         built by ReplicatedStorage.Components.Common.GetRayIgnore. ]]

local client = ...
local util = client.require("util")

local Players = util.Players
local Workspace = util.Workspace
local ReplicatedStorage = util.ReplicatedStorage
local LocalPlayer = util.LocalPlayer

local game_ = {}

local TEAMS = {
    ["Terrorists"] = true,
    ["Counter-Terrorists"] = true,
}
game_.TEAMS = TEAMS

--==========================================================================--
-- module cache access
--
-- require() on an already-required ModuleScript returns the *same* table the
-- game is using, which is what makes the hook module able to patch behaviour
-- in place. Every lookup is pcall-wrapped: modules load asynchronously and a
-- missing one must degrade the feature, not error the frame.
--==========================================================================--

local moduleCache = {}

local function requireGame(path)
    local cached = moduleCache[path]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local node = ReplicatedStorage
    for segment in path:gmatch("[^%.]+") do
        node = node and node:FindFirstChild(segment)
        if not node then break end
    end

    if not node or not node:IsA("ModuleScript") then
        moduleCache[path] = false
        return nil
    end

    local ok, result = pcall(require, node)
    if not ok or type(result) ~= "table" then
        moduleCache[path] = false
        return nil
    end

    moduleCache[path] = result
    return result
end

game_.requireGame = requireGame

function game_.clearModuleCache()
    table.clear(moduleCache)
end

--- Class table for client-side bullets. Hook target for spread and silent aim.
function game_.bulletClass()
    return requireGame("Components.Weapon.Classes.Bullet")
end

--- Weapon component class table.
function game_.weaponClass()
    return requireGame("Components.Weapon")
end

--- Camera controller; owns recoil application and field of view.
function game_.cameraController()
    return requireGame("Controllers.CameraController")
end

function game_.inventoryController()
    return requireGame("Controllers.InventoryController")
end

--- The weapon component instance currently held by the local player, or nil.
function game_.equippedWeapon()
    local inventory = game_.inventoryController()
    if not inventory or type(inventory.getCurrentEquipped) ~= "function" then
        return nil
    end
    local ok, weapon = pcall(inventory.getCurrentEquipped)
    if not ok then return nil end
    return weapon
end

function game_.equippedWeaponName()
    local weapon = game_.equippedWeapon()
    if not weapon then return nil end
    local ok, name = pcall(function()
        return weapon.Name or (weapon.Properties and weapon.Properties.Name)
    end)
    if ok then return name end
    return nil
end

--==========================================================================--
-- world containers
--==========================================================================--

function game_.charactersFolder()
    return Workspace:FindFirstChild("Characters")
end

function game_.debrisFolder()
    return Workspace:FindFirstChild("Debris")
end

function game_.mapFolder()
    return Workspace:FindFirstChild("Map")
end

function game_.gamemode()
    return Workspace:GetAttribute("Gamemode")
end

function game_.gameState()
    return Workspace:GetAttribute("GameState")
end

function game_.isDeathmatch()
    return game_.gamemode() == "Deathmatch"
end

function game_.scores()
    return Workspace:GetAttribute("CTScore") or 0, Workspace:GetAttribute("TScore") or 0
end

--==========================================================================--
-- teams
--==========================================================================--

function game_.teamOf(player)
    if not player then return nil end
    return player:GetAttribute("Team")
end

function game_.localTeam()
    return game_.teamOf(LocalPlayer)
end

--- Mirrors the game's own `isEnemyValid`: both sides must be on a playable
--- team, and in Deathmatch team equality is ignored.
function game_.isEnemy(player)
    if not player or player == LocalPlayer then return false end
    local mine = game_.teamOf(LocalPlayer)
    local theirs = game_.teamOf(player)
    if not mine or not theirs then return false end
    if not TEAMS[mine] or not TEAMS[theirs] then return false end
    if game_.isDeathmatch() then return true end
    return mine ~= theirs
end

function game_.isTeammate(player)
    if not player or player == LocalPlayer then return false end
    local mine = game_.teamOf(LocalPlayer)
    local theirs = game_.teamOf(player)
    if not mine or not theirs then return false end
    if not TEAMS[mine] or not TEAMS[theirs] then return false end
    if game_.isDeathmatch() then return false end
    return mine == theirs
end

--==========================================================================--
-- characters
--==========================================================================--

function game_.isAlive(character)
    if not character or not character.Parent then return false end
    if character:GetAttribute("Dead") == true then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    return true
end

function game_.humanoidOf(character)
    if not character then return nil end
    return character:FindFirstChildOfClass("Humanoid")
end

function game_.healthOf(character)
    local humanoid = game_.humanoidOf(character)
    if not humanoid then return 0, 100 end
    return humanoid.Health, (humanoid.MaxHealth > 0 and humanoid.MaxHealth or 100)
end

function game_.rootOf(character)
    if not character then return nil end
    return character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
end

function game_.localCharacter()
    local character = LocalPlayer.Character
    if character and character.Parent then return character end
    return nil
end

function game_.localRoot()
    return game_.rootOf(game_.localCharacter())
end

function game_.localAlive()
    return game_.isAlive(game_.localCharacter())
end

--==========================================================================--
-- hitboxes
--==========================================================================--

local HITBOX_FALLBACK = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso" }

--- Resolve a named hitbox on a character, falling back through the rig when the
--- requested part is missing (ragdolls and streamed-in rigs drop parts).
--- `"Nearest"` picks the part closest to the crosshair in screen space.
function game_.hitPart(character, mode)
    if not character then return nil end

    if mode == "Nearest" then
        local camera = Workspace.CurrentCamera
        if not camera then return game_.rootOf(character) end
        local centre = camera.ViewportSize * 0.5
        local best, bestDistance

        for _, part in ipairs(character:GetChildren()) do
            if part:IsA("BasePart") and part.Name ~= "CollisionCapsule" then
                local point, onScreen = camera:WorldToViewportPoint(part.Position)
                if onScreen and point.Z > 0 then
                    local delta = (Vector2.new(point.X, point.Y) - centre).Magnitude
                    if not bestDistance or delta < bestDistance then
                        best, bestDistance = part, delta
                    end
                end
            end
        end
        if best then return best end
        return game_.rootOf(character)
    end

    local part = character:FindFirstChild(mode)
    if part and part:IsA("BasePart") then return part end

    for _, name in ipairs(HITBOX_FALLBACK) do
        part = character:FindFirstChild(name)
        if part and part:IsA("BasePart") then return part end
    end
    return game_.rootOf(character)
end

--==========================================================================--
-- raycasting
--==========================================================================--

--- Rebuild the game's ignore list. Calling the game's own GetRayIgnore keeps us
--- consistent with what its bullets actually collide with; the manual list is
--- only used if that module is unavailable.
local function ignoreList()
    local getRayIgnore = requireGame("Components.Common.GetRayIgnore")
    if type(getRayIgnore) == "function" then
        local ok, list = pcall(getRayIgnore)
        if ok and type(list) == "table" then return list end
    end

    local list = {}
    local debris = game_.debrisFolder()
    if debris then table.insert(list, debris) end
    table.insert(list, Workspace.CurrentCamera)

    local map = game_.mapFolder()
    if map then
        for _, name in ipairs({ "Cameras", "Barriers", "Ambience" }) do
            local child = map:FindFirstChild(name)
            if child then table.insert(list, child) end
        end
        local zones = map:FindFirstChild("Zones")
        if zones then
            for _, name in ipairs({ "Spawns", "Sites" }) do
                local child = zones:FindFirstChild(name)
                if child then table.insert(list, child) end
            end
        end
    end

    local character = game_.localCharacter()
    if character and character:IsDescendantOf(Workspace) then
        table.insert(list, character)
    end
    return list
end

game_.ignoreList = ignoreList

local visionParams = RaycastParams.new()
visionParams.FilterType = Enum.RaycastFilterType.Exclude
visionParams.RespectCanCollide = true
visionParams.IgnoreWater = true

--- Line of sight from the camera to `target`, treating `character` as the goal.
--- Returns true when nothing except the target's own rig blocks the ray.
function game_.isVisible(character, targetPosition, origin)
    local camera = Workspace.CurrentCamera
    if not camera then return false end

    origin = origin or camera.CFrame.Position
    local delta = targetPosition - origin
    local distance = delta.Magnitude
    if distance < 0.05 then return true end

    local filter = ignoreList()
    if character then table.insert(filter, character) end
    visionParams.FilterDescendantsInstances = filter

    local hit = Workspace:Raycast(origin, delta.Unit * distance, visionParams)
    return hit == nil
end

--- Cast straight through the crosshair and return the raycast result. Used by
--- the trigger bot, which must see exactly what a bullet would see.
function game_.crosshairCast(range)
    local camera = Workspace.CurrentCamera
    if not camera then return nil end

    local centre = camera.ViewportSize * 0.5
    local ray = camera:ViewportPointToRay(centre.X, centre.Y)

    visionParams.FilterDescendantsInstances = ignoreList()
    return Workspace:Raycast(ray.Origin, ray.Direction * (range or 500), visionParams)
end

--- Walk up from a hit part to the owning character model and player.
function game_.ownerOfPart(part)
    if not part then return nil, nil end

    local node = part
    for _ = 1, 6 do
        if not node or node == Workspace then break end
        local player = Players:GetPlayerFromCharacter(node)
        if player then return player, node end
        node = node.Parent
    end

    -- Characters live under workspace.Characters.<Team>; a rig whose owner has
    -- already left still needs to resolve to a model for ESP cleanup.
    node = part
    for _ = 1, 6 do
        if not node or node == Workspace then break end
        if node:IsA("Model") and node:FindFirstChildOfClass("Humanoid") then
            return Players:GetPlayerFromCharacter(node), node
        end
        node = node.Parent
    end
    return nil, nil
end

--==========================================================================--
-- iteration
--==========================================================================--

--- Iterate live, hostile players. `out` is reused by callers to avoid churn.
function game_.enemies(out)
    out = out or {}
    table.clear(out)

    for _, player in ipairs(Players:GetPlayers()) do
        if game_.isEnemy(player) then
            local character = player.Character
            if character and game_.isAlive(character) then
                table.insert(out, { player = player, character = character })
            end
        end
    end
    return out
end

--- Every live player except the local one, tagged with hostility.
function game_.others(out)
    out = out or {}
    table.clear(out)

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local character = player.Character
            if character and game_.isAlive(character) then
                table.insert(out, {
                    player = player,
                    character = character,
                    enemy = game_.isEnemy(player),
                })
            end
        end
    end
    return out
end

--==========================================================================--
-- misc world queries
--==========================================================================--

--- Planted C4, if any. The bomb model is tagged by the game with the `C4`
--- collection tag once planted; fall back to a name scan.
function game_.plantedBomb()
    local CollectionService = game:GetService("CollectionService")
    local ok, tagged = pcall(CollectionService.GetTagged, CollectionService, "C4")
    if ok and tagged then
        for _, instance in ipairs(tagged) do
            if instance:IsDescendantOf(Workspace) then return instance end
        end
    end

    local map = game_.mapFolder()
    if map then
        local bomb = map:FindFirstChild("C4", true)
        if bomb then return bomb end
    end
    return nil
end

--- Weapons lying on the ground. They are parented under workspace.Debris with
--- a `_Weapon` suffixed name and use the WeaponDropped collision group.
function game_.droppedWeapons(out)
    out = out or {}
    table.clear(out)

    local debris = game_.debrisFolder()
    if not debris then return out end

    for _, child in ipairs(debris:GetChildren()) do
        if child:IsA("Model") and child.Name:match("_Weapon$") then
            local primary = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
            if primary then
                table.insert(out, { model = child, part = primary })
            end
        end
    end
    return out
end

return game_
