# AGENTS.md — Paddock Cameras

An Assetto Corsa Lua app (for Custom Shaders Patch) that renders camera views
of the focused car and exposes each one as an OBS Studio source, listed as
`Paddock OS: <camera>`.

## Layout

- `apps/lua/paddock_cameras/manifest.ini` — the AC app manifest.
  `SIM_CALLBACKS.UPDATE = simUpdate`; `LAZY = NONE` loads it immediately.
- `apps/lua/paddock_cameras/paddock_cameras.lua` — everything. Top to bottom:
  settings, `PARAMS` and `DIRECTOR` (the defaults the `.ini` overrides), the
  `CAMS` table, `solve()` (one evaluation per tick), the Stream director, the
  `.ini` loader and its live reload (`ac.onFileChanged`), the car-following
  modes, OBS registration, `script.simUpdate`.
- `apps/lua/paddock_cameras/paddock_cameras.ini` — the shipped settings: one
  `[CAM:<name>]` per camera, `[DIRECTOR]`, `[RULE_n]`. Its keys are the
  script's: `FOV`, `NEAR`, `OFFSET`/`FORWARD`/`UP` for onboard cameras, the
  `PARAMS` names for dynamic ones, `MIN_TIME`/`URGENT`, and
  `IN_PIT`/`BRAKE_MIN`/`GAS_MIN`/`SPEED_MIN`/`SPEED_MAX`/`STEER_MIN`/`STEER_MAX`/`POOL`.
- `apps/lua/paddock_cameras/web/editor.html` — a single-file editor for the
  `.ini` (File System Access API; no build). Its parser and serialiser mirror
  the Lua loader: a key added to one is added to the other.

The repository mirrors the AC install path: its `apps` folder is copied into
the `assettocorsa` folder as it is.

## Dependencies

- **Custom Shaders Patch** — the Lua API (`ac.*`, `render.*`, `vec3`…). Its
  documented API is the SDK under
  `assettocorsa/extension/internal/lua-sdk/ac_apps/lib.lua`; check a call there
  before relying on it. Auto-exposure control (`ac.setAutoExposureActive`) is
  documented for weather scripts (`ac_wfx_impl`), not apps, which is why the
  app tests for it.
- **`shared/utils/obs`** — CSP's own OBS glue
  (`extension/internal/lua-shared/utils/obs.lua`), not a separate mod. It only
  calls a texture's content callback while OBS is using that texture, and caps
  `"<group>: <name>"` at 46 characters.
- **OBS Studio** with the AC plugin CSP offers in its Small Tweaks.

## How a frame is made

1. `script.simUpdate(dt)` runs every simulation tick: it bumps `tick`, applies
   the car-following mode (`ac.focusCar`), then calls every source's
   `:update()`.
2. A source OBS is using runs its draw callback: `solve(cfg, car, sim)` gives
   the camera's world transform (cached per tick), `GeometryShot:update()`
   renders the scene through YEBIS, and a passthrough shader copies it to the
   OBS canvas.
3. Textures are `R16G16B16A16.Float`; the passthrough writes RGB with alpha 1.

## The one rule for dynamic cameras

A dynamic camera's closure keeps state (spring position and velocity, smoothed
FOV, progress along the track), so it must run **once per tick**. Always go
through `solve()` — never call `cfg.dynamic` directly. The Stream director
evaluates every camera each tick to keep them warm, and a camera's own source
may be drawing too; calling the closure from both is what used to double-step
them.

## Adding a camera

Add an entry to `CAMS` (static: `offset`/`forward`/`up` in car-local space,
Y up, Z forward; dynamic: `dynamic = function(car, sim)` returning world-space
`pos, forward, up[, fov]`, reading its tunables from `PARAMS[<name>]`). Keep
the name short enough for OBS (see above). Add its `[CAM:<name>]` section to
the shipped `.ini` so the editor lists it, and to a rule's pool in `DIRECTOR`
(and the `.ini`) to have the director use it. A renamed camera goes into
`CAM_ALIASES` so older files keep working. Reload in AC (Lua Debug app →
Reload) to test.

## No build, no tests, no lint

It is a game mod: edit, reload in AC, look. CSP's Lua Debug app is the only
in-game tool. A syntax check outside the game is possible with any Lua 5.1
parser (for instance Python's `luaparser`), which catches typos but knows
nothing of CSP's API.
