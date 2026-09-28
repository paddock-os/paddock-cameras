# Paddock Cameras

**Broadcast camera views for Assetto Corsa, each one a source in OBS Studio.**

An Assetto Corsa Lua app for [Custom Shaders Patch](https://acstuff.club/patch/)
that renders fourteen views of the car you are following — onboards, aerials,
the pit box, the Safety Car — plus a virtual director that cuts between them,
and hands every one to OBS as its own source. Put the Helicopter in one scene,
the T-Cam in another and switch like a TV gallery, or add the Stream source
and let it direct itself.

Every camera renders through the game's own post-processing (YEBIS with your
active PP filter): the same tonemap, colour grading, bloom and depth of field
as the main view, whatever filter you run.

> Maintained by the [Paddock OS](https://github.com/paddock-os) team, alongside
> [acokit](https://github.com/paddock-os/paddock-acokit) for the overlays. It
> stands on its own: nothing here needs Paddock OS.

## Requirements

- **Assetto Corsa** with **Custom Shaders Patch** (the Lua app API, `ac.*`,
  `render.*`, `vec3`, comes from CSP).
- CSP's **OBS integration** turned on: *Content Manager → Settings → Custom
  Shaders Patch → Small Tweaks → OBS integration*, and the OBS plugin for AC
  that it offers there installed in OBS Studio. The app uses CSP's own
  `shared/utils/obs` library for this; there is nothing else to install.

## Install

Copy the `apps` folder of this repository into your Assetto Corsa folder, so
that you end up with:

```
assettocorsa/apps/lua/paddock_cameras/manifest.ini
assettocorsa/apps/lua/paddock_cameras/paddock_cameras.lua
```

The app loads by itself (`LAZY = NONE`): there is nothing to open in game.
Start a session, open OBS, add a source from the AC plugin and the cameras are
listed as **`Paddock OS: <camera>`**.

CSP only renders a camera while OBS is using it, so the ones that are not in a
scene cost nothing.

## The cameras

| Camera | Kind | What it shows |
|---|---|---|
| T-Cam | onboard | Above and behind the driver's head, looking down the nose |
| Halo POV | onboard | The driver's-eye view from just above the cockpit |
| Helmet Cam | onboard | The driver's eyes as AC animates them (g-forces, look-into-corner; the headset in VR). Needs AC in the cockpit view |
| Nose Cam | onboard | Low on the nose, looking forward |
| Onboard Side | onboard | Beside the cockpit, looking forward along the car |
| Rear Cam | onboard | At the back of the car, looking behind |
| Drone Cam | aerial | A stable drone 50 m up, drifting to the outside of corners, zooming with speed |
| Helicopter Cam | aerial | A broadcast helicopter: high, behind, on a long lens, with real inertia; it opens the throttle and closes the zoom when the car gets away |
| Pit Cam | fixed | Above the car's own pit box, looking down |
| Circuit Cam | aerial | Flies the track's AI line high up, looking at the track ahead; circles the car on a track without one |
| SC Roof Rear | onboard | On the roof, looking back at the pack — made for the Safety Car |
| SC Front Hood | onboard | On the bonnet, looking forward |
| SC Chase Aerial | aerial | Low and close behind, showing the train of cars |
| SC Side Pack | trackside | From the side on a long lens, stacking the pack in single file |
| **Stream** | director | Cuts between the others on what the car is doing — pit lane, braking, cornering, flat out — with at least 8 s per shot (the pit lane cuts at once) |

Every camera follows the car Assetto Corsa is focused on.

## Settings

At the top of `paddock_cameras.lua`:

| Setting | Default | |
|---|---|---|
| `AUTO_MODE` | `'off'` | Which car to follow: `'off'` (change it yourself), `'leader'`, `'cycle'` (every car in turn), `'battle'` (the closest pair on track, else the leader) |
| `AUTO_CYCLE_INTERVAL` | `12` | Seconds per car in `'cycle'` |
| `AUTO_BATTLE_RANGE` | `30` | Metres between two cars to call it a battle |
| `FREEZE_AUTO_EXPOSURE` | `true` | Freeze adaptive auto-exposure while the app runs, so a dozen cameras do not make it pump. It is a setting of the whole scene, the game's own view included, and only works where CSP gives apps that control — the app logs it when it does not |
| `OBS_GROUP` | `'Paddock OS'` | The prefix of the source names in OBS |

Each camera in the `CAMS` table has its own tunables — position, field of
view, and for the aerials height, spring stiffness, top speed and zoom — with
a comment on what each one does. Add `exposure = <value>` to a camera to give
it its own exposure (YEBIS, photographic scale: negative is darker).

After editing, reload the app: CSP's *Lua Debug* app → Reload, or restart the
session.

## Adding a camera

Add an entry to `CAMS`:

- a **static** camera gives `offset`, `forward` and `up` in the car's local
  space (Y up, Z forward);
- a **dynamic** camera gives `dynamic = function(car, sim)` returning
  world-space `position, forward, up` and optionally a `fov`.

A dynamic camera may keep state between frames (see the Drone or the
Helicopter); the app guarantees it is advanced once per simulation tick, even
when the Stream director is evaluating it too. To have the director cut to it,
add its name to one of the pools in `STREAM_CAM`.

## Licence

MIT — see [LICENSE](LICENSE).
