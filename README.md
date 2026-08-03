# opus.cc

Client for **Bloxstrike / Frog** (the Roblox CS2 clone). Modular, loaded through a
single `loadstring`.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/RylanEqualsFetch/opuw/main/loader.lua"))()
```

Press **Insert** to toggle the menu.

---

## Layout

```
loader.lua              bootstrap: fetch, compile, wire, teardown
src/
  util.lua              services, math, projection, Maid, executor probing
  config.lua            dotted-path settings store + JSON persistence
  game.lua              Bloxstrike bindings: teams, rigs, visibility, remotes
  hooks.lua             patches on the game's bullet and camera classes
  ui.lua                menu toolkit (no external library, no assets)
  menu.lua              assembles tabs, owns the settings tab
  features/
    esp.lua             boxes, health, skeleton, chams, tracers, world markers
    aim.lua             aimbot, silent aim, trigger bot
    weapon.lua          recoil and spread scaling, instant scope
    movement.lua        bunny hop, movement constant overrides
    visuals.lua         lighting, FOV, crosshair, hit marker, flash/smoke
    misc.lua            radar, spectator list, FPS cap, automation
```

The loader downloads every module before executing any of them, so a failed
download produces a clean error instead of a half-live client. Modules resolve
each other through `client.require(path)`, which caches by path.

---

## How the weapon features work

The game computes its own bullets on the client. `Bullet:_performRaycast(spread)`
reads `CurrentCamera:ViewportPointToRay(centre)`, perturbs that direction by a
random cone of `spread` degrees, casts, and returns `{Origin, Direction, Hits}`.
Recoil is a camera kick pushed through `CameraController.setWeaponRecoil`, which
feeds back into that same ray.

`require()` on an already-loaded `ModuleScript` returns the exact table the game
is using, so `hooks.lua` replaces two methods in place — no metatable work, and
every existing weapon instance picks the change up immediately:

| Feature | Mechanism |
| --- | --- |
| Spread | Scale the cone argument before the original runs. |
| Silent aim | Swap `Camera.CFrame` around the original call, then restore. |
| Recoil | Scale the kick vector on its way to the camera. |

The camera swap is safe because `_performRaycast` reads the camera
synchronously and the original CFrame is restored before returning — no render
step observes the intermediate value, so the view never visibly moves. The body
is `pcall`ed so an error mid-swap cannot strand the camera on the target.

Both scalars sit at `nil` while their feature is off, so the hooks pass original
values straight through with no arithmetic.

---

## Game specifics this is built against

- Characters live under `workspace.Characters.<Team>`, not `workspace`.
- Team is a player attribute: `Terrorists` / `Counter-Terrorists`.
- In Deathmatch every other player is hostile regardless of team.
- Death is `Humanoid.Health <= 0` **or** the `Dead` attribute on the model — the
  attribute is set first, so checking only health tracks corpses for a moment.
- Stock R15 rig. The game's own aim assist targets `Head`.
- Jump goes through `CharacterController.jump()`, which owns the stamina cost,
  the air-time gate and the animation. Writing `Humanoid.Jump` skips all of it
  and the movement controller ignores the result.
- Movement tuning is read from `SV_ACCELERATE` / `SV_FRICTION` / `SV_STOPSPEED`
  attributes on the LocalPlayer, written once at spawn if absent.
- Ray ignores come from `Components.Common.GetRayIgnore`, called directly so
  visibility checks match what bullets actually collide with.

---

## Configs

Saved to `opuscc/configs/<name>.json` via the executor filesystem API. Colours
round-trip as hex. Loading merges over defaults, so a config saved by an older
build keeps sane values for keys added since.

Set an autoload config in **Settings → Configs** to have it applied on inject.

---

## Executor requirements

| Capability | Needed for | Degrades to |
| --- | --- | --- |
| `Drawing` | ESP, FOV circle, crosshair, radar | chams still work |
| `mouse1click` / `mouse1press` | auto fire, trigger bot | `VirtualInputManager` |
| `writefile` / `readfile` | configs | in-memory only |
| `gethui` | hidden menu parent | CoreGui, then PlayerGui |
| `setfpscap` | frame rate unlock | toggle reports unavailable |

Missing capabilities disable the affected control and say so in the menu rather
than erroring.

---

## Overrides

Set before running the loadstring:

```lua
getgenv().opuscc_config = {
    branch  = "main",
    dev     = false,          -- read from disk instead of HTTP
    devPath = "opuscc/src",   -- workspace-relative source root
    silent  = false,
}
```

Dev mode reads each module from `devPath`, falling back to HTTP per file, so a
single module can be iterated on locally without republishing.

---

## Unloading

`getgenv().opuscc.unload()`, or **Settings → Client → Unload**. Teardown runs in
reverse registration order: engine hooks are restored before the features that
depend on them are torn down. Lighting, FOV and movement constants are written
back to the values captured at load.

Re-running the loadstring unloads the previous instance first.
