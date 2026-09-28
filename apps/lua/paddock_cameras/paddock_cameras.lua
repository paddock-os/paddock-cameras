--[[
  Paddock Cameras — camera views of the focused car, each one an OBS Studio source.

  Every camera is registered through CSP's OBS integration (`shared/utils/obs`)
  and shows up in OBS as "Paddock OS: <camera name>". CSP only renders a camera
  while OBS is actually using its texture, so registering all of them costs
  nothing for the ones that are not in a scene.

  A camera in CAMS is one of:
   - STATIC: `offset`, `forward` and `up` in the car's local space. Transformed
     to world space every frame with the car's transform.
   - DYNAMIC: a `dynamic = function(car, sim)` that returns world-space
     `position, forward, up[, fov]` itself. For cameras that depend on the
     driver's head, g-forces, VR, or that fly on their own.

  To add a camera, add an entry to CAMS and reload the script (CSP's Lua Debug
  app → Reload, or restart the session). The Stream camera picks it up by name
  once it is added to one of its pools (see STREAM_CAM).

  Coordinates: the car's local space is Y-up, Z+ forward (Assetto Corsa's own).
]]--

local obs = require('shared/utils/obs')

-- ===================== SETTINGS =====================

-- Which car every camera follows. Assetto Corsa follows ac.focusCar(); these
-- modes set it from here:
--   'off'     → leave it alone (change car by hand, F1–F12 or the replay UI)
--   'leader'  → the race leader (racePosition == 1)
--   'cycle'   → every car in turn, AUTO_CYCLE_INTERVAL seconds each
--   'battle'  → the closest pair on track (under AUTO_BATTLE_RANGE metres);
--               the leader when nobody is that close
local AUTO_MODE           = 'off'
local AUTO_CYCLE_INTERVAL = 12   -- seconds per car in 'cycle'
local AUTO_BATTLE_RANGE   = 30   -- metres between two cars to call it a battle

-- With a dozen cameras rendering at once, adaptive auto-exposure can pump
-- between them. When CSP exposes auto-exposure control to apps, this freezes
-- it while the app runs. That is a setting of the whole scene, the game's own
-- camera included — turn it off if you drive with this app loaded.
local FREEZE_AUTO_EXPOSURE = true

-- Group the sources appear under in OBS: "<group>: <camera name>". CSP limits
-- the whole name to 46 characters.
local OBS_GROUP = 'Paddock OS'

-- ===================== EDITABLE CONFIGURATION (paddock_cameras.ini) =====================
-- The defaults are below; paddock_cameras.ini, beside this script, overrides
-- them. The web editor (web/editor.html) writes that file, and the app reloads
-- it by itself when it is saved: no restart of AC or OBS. The exception is the
-- render options (mips, shadows…), which only apply when a source is created
-- (restart the session, or resize the source in OBS).
local CONFIG_FILE = ac.getFolder(ac.FolderID.ScriptOrigin) .. '/paddock_cameras.ini'

-- Names cameras had before, still read from an older paddock_cameras.ini (or
-- from a copied rsr_cameras.ini).
local CAM_ALIASES = { ['SC Chase Aerea'] = 'SC Chase Aerial' }

-- The dynamic cameras' parameters, by the names of their tunables.
local PARAMS = {}
PARAMS['Drone Cam'] = { HEIGHT = 50, STIFFNESS = 0.2, DAMPING = 0.9, MAX_SPEED = 90, MAX_DIST = 110, LOOKAHEAD = 0.15, OUTSIDE_BIAS = 35, YAW_FLIP = -1, YAW_SMOOTH = 1.2, FOV_FAST = 28, FOV_SLOW = 20, SPEED_FAST = 75, SPEED_SLOW = 25, FOV_SMOOTH = 1.5 }
PARAMS['Helicopter Cam'] = { HEIGHT = 90, BACK = 70, SIDE = 25, STIFFNESS = 0.06, DAMPING = 0.4, MAX_SPEED = 75, SOFT_DIST = 130, HARD_DIST = 380, SPEED_BOOST = 0.28, FOV_BASE = 18, FOV_TIGHT = 9, FOV_SMOOTH = 1 }
PARAMS['Pit Cam'] = { SIDE = -4, UP = 2, FWD = 2 }
PARAMS['Circuit Cam'] = { HEIGHT = 65, SPEED = 95, LOOK_AHEAD = 80, FOV_STRAIGHT = 32, FOV_CURVE = 44, FOV_SMOOTH = 1.2 }
PARAMS['SC Chase Aerial'] = { HEIGHT = 18, BACK = 22, STIFFNESS = 0.18, DAMPING = 0.85, LOOKAHEAD = 0.1 }
PARAMS['SC Side Pack'] = { SIDE = 30, BACK = 6, HEIGHT = 3.5, STIFFNESS = 0.22, DAMPING = 0.9 }

-- The Stream camera's director. Speeds in m/s (25 m/s = 90 km/h). Rules are
-- checked in order and the first that holds picks the pool it cuts between;
-- a condition left out is not checked.
local DIRECTOR = {
  minTime = 8.0,                       -- minimum seconds per shot
  urgent  = { ['Pit Cam'] = true },    -- cameras that cut at once, cooldown or not
  rules   = {
    { name = 'Pit lane',     inPit = true,                                  pool = { 'Pit Cam' } },
    { name = 'Heavy braking', brakeMin = 0.6, speedMin = 25,                pool = { 'Helmet Cam', 'Onboard Side', 'T-Cam' } },
    { name = 'Cornering',    steerMin = 0.35, speedMin = 15,                pool = { 'Onboard Side', 'Helmet Cam', 'Halo POV', 'T-Cam' } },
    { name = 'Flat out',     speedMin = 55, gasMin = 0.85, steerMax = 0.10, pool = { 'Nose Cam', 'T-Cam', 'Helicopter Cam' } },
    { name = 'Medium speed', speedMin = 15,                                 pool = { 'Helicopter Cam', 'Drone Cam', 'T-Cam', 'Onboard Side' } },
    { name = 'Slow',                                                        pool = { 'Helicopter Cam', 'Drone Cam', 'Pit Cam' } },
  },
}

-- ===================== CAMERAS =====================
-- Every camera renders through YEBIS with the user's active PP filter: the
-- same tonemap, exposure curve, colour grading, bloom and DOF as the game's
-- own camera, whatever filter CSP or Pure has loaded. To override one
-- camera's exposure add `exposure = <value>` (YEBIS exposure, photographic
-- scale: negative darkens); leave it out to use the scene's.
local CAMS = {
  {
    name     = 'T-Cam',
    fov      = 40,

    offset   = vec3(0.015, 0.9, 0),
    forward  = vec3(-0.017453, -0.28749, 0.95763),
    up       = vec3(-5.8953e-007, 0.95777, 0.28753),
    nearClip = 0.05,
  },
  {
    name     = 'Halo POV',
    fov      = 55,

    offset   = vec3(0, 0.85, 0.15),
    forward  = vec3(0, -0.15, 1),
    up       = vec3(0, 1, 0.05),
    nearClip = 0.05,
  },
  {
    name     = 'Helmet Cam',
    fov      = 80,

    nearClip = 0.05,
    -- Position: the driver's eyes, as AC animates them (g-forces, looking into
    -- the corner). Direction: AC's main camera, which is the headset in VR and
    -- the look direction with g-force offset on a monitor. Only right while AC
    -- is in the cockpit view.
    dynamic = function(car, sim)
      local worldPos = car.transform:transformPoint(car.driverEyesPosition)
      return worldPos, sim.cameraLook, sim.cameraUp
    end,
  },
  {
    name     = 'Nose Cam',
    fov      = 70,

    offset   = vec3(0, 0.25, 2.6),
    forward  = vec3(0, -0.05, 1),
    up       = vec3(0, 1, 0.05),
    nearClip = 0.05,
    -- If the tarmac looks too bright this close, add `exposure = -0.3`.
  },
  {
    name     = 'Onboard Side',
    fov      = 45,

    offset   = vec3(0.35, 0.65, -0.10),
    forward  = vec3(-0.20, -0.05, 0.98),
    up       = vec3(0, 1, 0.05),
    nearClip = 0.05,
  },
  {
    name     = 'Rear Cam',
    fov      = 45,

    -- From the back of the car, looking backwards: Z+ is the car's front, so
    -- forward = (0, 0, -1) looks behind.
    offset   = vec3(0, 0.8, -0.8),
    forward  = vec3(0, -0.10, -1),
    up       = vec3(0, 1, -0.10),
    nearClip = 0.05,
  },
  {
    name           = 'Drone Cam',
    fov            = 35,

    nearClip       = 1.0,
    fakeShadows    = false,  -- at this height the shadow plane draws a visible line
    mips           = 4,      -- mipmaps against aliasing on the distant track
    opaqueAlphaFix = true,   -- fixes opaque materials that look wrong from above
    altShadows     = true,   -- alternative shadow set: no cascade transition line
    -- A cinematic drone: a very stable 3-axis gimbal, a little look-ahead
    -- (it aims where the car is going) and a near-critical spring that
    -- reaches its ideal quickly. No perceived mass — it moves as if piloted.
    -- For the weight of a real broadcast helicopter (more inertia, a long
    -- lens, no anticipation) use "Helicopter Cam".
    dynamic = (function()
      -- The drone's state, kept between frames.
      local dronePos  = nil
      local droneVel  = vec3(0, 0, 0)
      local smoothYaw = 0     -- smoothed yaw rate (no jumps in the lateral ideal)
      local smoothFov = nil   -- smoothed FOV (zoom follows speed)
      return function(car, sim)
        if not car.transform or not car.transform.position then return nil end

        -- ---- Tunables (PARAMS, overridden by paddock_cameras.ini) ----
        local P = PARAMS['Drone Cam']
        local HEIGHT       = P.HEIGHT        -- target height above the car (m)
        local STIFFNESS    = P.STIFFNESS     -- spring strength (lower = lazier sideways)
        local DAMPING      = P.DAMPING       -- damping (~2*sqrt(STIFFNESS) is critical)
        local MAX_SPEED    = P.MAX_SPEED     -- top speed of the drone (m/s)
        local MAX_DIST     = P.MAX_DIST      -- never let the car get further than this (m)
        local LOOKAHEAD    = P.LOOKAHEAD     -- a little anticipation keeps the car centred
        local OUTSIDE_BIAS = P.OUTSIDE_BIAS  -- metres towards the outside of the corner per rad/s of yaw
        local YAW_FLIP     = P.YAW_FLIP      -- if it drifts to the INSIDE of corners instead, set +1
        local YAW_SMOOTH   = P.YAW_SMOOTH    -- seconds of yaw smoothing, so corner entry and exit do not jump
        -- Dynamic zoom: the FOV closes in when the car is slow (corners,
        -- braking) and opens up flat out on the straights.
        local FOV_FAST     = P.FOV_FAST      -- FOV at SPEED_FAST and above (tighter = does not drift as far)
        local FOV_SLOW     = P.FOV_SLOW      -- FOV at SPEED_SLOW and below (slow corner, heavy braking)
        local SPEED_FAST   = P.SPEED_FAST    -- m/s (75 ≈ 270 km/h)
        local SPEED_SLOW   = P.SPEED_SLOW    -- m/s (25 ≈ 90 km/h)
        local FOV_SMOOTH   = P.FOV_SMOOTH    -- seconds of zoom smoothing
        -- -------------------

        local dt     = sim.dt or 1/60
        local carPos = car.transform.position
        local vel    = car.velocity
        local speed  = vel:length()

        -- Horizontal direction of travel, to tell the sides apart.
        local moveDir
        if speed > 1.0 then
          moveDir = vel:clone():normalize()
        else
          moveDir = car.transform.look
        end

        -- "Right" of the direction of travel, on the horizontal plane.
        local rightDir = vec3(0, 1, 0):cross(moveDir)
        local rl = rightDir:length()
        if rl > 0.001 then rightDir:scale(1 / rl) else rightDir = vec3(1, 0, 0) end

        -- The car's yaw rate says it is turning, and which way. Smoothed
        -- exponentially, so the lateral ideal grows and shrinks with the
        -- corner instead of jumping when the car turns in or out sharply.
        local localAng    = car.localAngularVelocity
        local rawYaw      = (localAng and localAng.y) or 0
        local yawAlpha    = 1.0 - math.exp(-dt / YAW_SMOOTH)
        smoothYaw         = smoothYaw + (rawYaw - smoothYaw) * yawAlpha
        local outsideOffset = rightDir * (smoothYaw * OUTSIDE_BIAS * YAW_FLIP)

        -- IDEAL: above the car, moved to the outside of the corner by the yaw.
        -- On a straight (yaw ≈ 0) it sits straight above; in a corner it moves
        -- out, so the drone swings to that side instead of chasing behind.
        local idealPos = vec3(carPos.x, carPos.y + HEIGHT, carPos.z) + outsideOffset

        -- Car stopped → freeze the drone. Otherwise the residual velocity and
        -- a non-zero smoothYaw make it drift and the camera pans for no reason.
        if speed < 0.5 then
          if not dronePos then dronePos = idealPos:clone() end
          droneVel = vec3(0, 0, 0)
          smoothYaw = smoothYaw * 0.85  -- let the residual yaw decay quickly
          local lookDir = (carPos - dronePos):normalize()
          -- smoothFov stays where it is, so the zoom does not jump when the car
          -- stops or pulls away. Before it is set it is nil, and the camera
          -- falls back to its static FOV.
          return dronePos, lookDir, vec3(0, 1, 0), smoothFov
        end

        if not dronePos then
          dronePos = idealPos:clone()
        else
          -- Spring-damper: the spring pulls towards the ideal, the damping
          -- brakes. The result is a smooth, organic path.
          local err   = idealPos - dronePos
          local accel = err * STIFFNESS - droneVel * DAMPING
          droneVel = droneVel + accel * dt

          -- Speed cap. On long straights at 340 km/h the car pulls away,
          -- which is what the distance clamp below is for.
          local s = droneVel:length()
          if s > MAX_SPEED then
            droneVel:setScaled(droneVel, MAX_SPEED / s)
          end

          dronePos = dronePos + droneVel * dt

          -- Distance clamp: if the car got further than MAX_DIST away (a very
          -- long straight), pull the drone to the ideal and bleed its speed
          -- so it does not bounce.
          local toIdeal = idealPos - dronePos
          local d = toIdeal:length()
          if d > MAX_DIST then
            dronePos = idealPos - toIdeal * (MAX_DIST / d)
            droneVel:setScaled(droneVel, 0.3)
          end
        end

        -- The gimbal is quick: it aims where the car will be in LOOKAHEAD
        -- seconds. With the drone's inertia that reads as "anticipating the corner".
        local lookTarget = carPos + vel * LOOKAHEAD
        local lookDir    = (lookTarget - dronePos):normalize()

        -- FOV from speed, between FOV_SLOW and FOV_FAST across
        -- [SPEED_SLOW, SPEED_FAST], smoothed over frames.
        local fovT      = math.clamp((speed - SPEED_SLOW) / (SPEED_FAST - SPEED_SLOW), 0, 1)
        local targetFov = FOV_SLOW + fovT * (FOV_FAST - FOV_SLOW)
        if not smoothFov then
          smoothFov = targetFov
        else
          local fovAlpha = 1.0 - math.exp(-dt / FOV_SMOOTH)
          smoothFov = smoothFov + (targetFov - smoothFov) * fovAlpha
        end

        return dronePos, lookDir, vec3(0, 1, 0), smoothFov
      end
    end)(),
  },
  {
    name           = 'Helicopter Cam',
    fov            = 18,           -- a broadcast long lens (~200 mm equivalent)
    nearClip       = 1.0,
    fakeShadows    = false,
    mips           = 4,
    opaqueAlphaFix = true,
    altShadows     = true,
    -- A broadcast helicopter:
    --   - high and behind the car, with a fixed lateral offset;
    --   - a long lens (FOV 18°) for the flattened "grandstand" look;
    --   - a lot of inertia (low STIFFNESS): it does not anticipate the car;
    --   - a limited cruise speed (~270 km/h): on long straights the car pulls
    --     away, as it does on television.
    dynamic = (function()
      local heliPos   = nil
      local heliVel   = vec3(0, 0, 0)
      local smoothFov = nil
      return function(car, sim)
        if not car.transform or not car.transform.position then return nil end

        -- ---- Tunables (PARAMS, overridden by paddock_cameras.ini) ----
        local P = PARAMS['Helicopter Cam']
        local HEIGHT       = P.HEIGHT       -- height above the car (m); broadcast is ~80–120 m
        local BACK         = P.BACK         -- distance behind the car (m, along its travel)
        local SIDE         = P.SIDE         -- lateral offset (m); negative for the other side
        local STIFFNESS    = P.STIFFNESS    -- a very loose spring → perceived mass
        local DAMPING      = P.DAMPING      -- close to critical, so it does not oscillate
        local MAX_SPEED    = P.MAX_SPEED    -- m/s, the helicopter's cruise speed (75 ≈ 270 km/h)

        -- "Rescue" when the car gets away: from SOFT_DIST the helicopter opens
        -- the throttle progressively (a speed boost) AND the operator closes
        -- the zoom (a smaller FOV) to keep the car a visible size. Both at
        -- once read as one organic move, with no teleport and no sudden
        -- acceleration. At HARD_DIST both are at their maximum.
        local SOFT_DIST    = P.SOFT_DIST    -- m, where the rescue starts
        local HARD_DIST    = P.HARD_DIST    -- m, where it is at its maximum
        local SPEED_BOOST  = P.SPEED_BOOST  -- over cruise (0.28 = +28%)
        local FOV_BASE     = P.FOV_BASE     -- FOV in normal conditions (close to the car)
        local FOV_TIGHT    = P.FOV_TIGHT    -- FOV at full zoom (far from the car)
        local FOV_SMOOTH   = P.FOV_SMOOTH   -- seconds of zoom smoothing
        -- -------------------

        local dt     = sim.dt or 1/60
        local carPos = car.transform.position
        local vel    = car.velocity
        local speed  = vel:length()

        -- Horizontal direction of travel (always a clone: never mutate a reference).
        local moveDir
        if speed > 1.0 then
          moveDir = vel:clone()
        else
          moveDir = car.transform.look:clone()
        end
        moveDir.y = 0
        local mdLen = moveDir:length()
        if mdLen > 0.001 then
          moveDir:scale(1 / mdLen)
        else
          moveDir = vec3(0, 0, 1)
        end

        -- Horizontal right of the direction of travel, for the lateral offset.
        local rightDir = vec3(0, 1, 0):cross(moveDir)
        local rl = rightDir:length()
        if rl > 0.001 then
          rightDir:scale(1 / rl)
        else
          rightDir = vec3(1, 0, 0)
        end

        -- IDEAL: behind, above and to the side. No yaw bias (unlike the
        -- drone): the inertia does the repositioning.
        local idealPos = carPos
          - moveDir  * BACK
          + rightDir * SIDE
          + vec3(0, HEIGHT, 0)

        -- Car stopped → freeze the helicopter at the ideal.
        if speed < 0.5 then
          if not heliPos then heliPos = idealPos:clone() end
          heliVel = vec3(0, 0, 0)
          local toCar = carPos - heliPos
          local tcLen = toCar:length()
          if tcLen < 0.001 then return nil end
          toCar:scale(1 / tcLen)
          if not smoothFov then smoothFov = FOV_BASE end
          return heliPos, toCar, vec3(0, 1, 0), smoothFov
        end

        -- How far the helicopter is from where it should be: how far behind it
        -- has fallen. It drives the rescue, progressively.
        local distError
        if not heliPos then
          heliPos = idealPos:clone()
          distError = 0
        else
          distError = (idealPos - heliPos):length()
        end

        -- Rescue ratio: 0 = normal, 1 = boost and zoom at their maximum.
        local rescue = math.clamp((distError - SOFT_DIST) / (HARD_DIST - SOFT_DIST), 0, 1)

        -- Spring-damper. The speed cap grows with the rescue: the helicopter
        -- "opens the throttle" when it falls behind, without teleporting.
        local err   = idealPos - heliPos
        local accel = err * STIFFNESS - heliVel * DAMPING
        heliVel = heliVel + accel * dt

        local effectiveMaxSpeed = MAX_SPEED * (1 + rescue * SPEED_BOOST)
        local s = heliVel:length()
        if s > effectiveMaxSpeed then
          heliVel:scale(effectiveMaxSpeed / s)
        end

        heliPos = heliPos + heliVel * dt

        -- Adaptive FOV: the operator closes the zoom as the car gets away, to
        -- keep it a visible size — smoothed, like a cameraman on the lens.
        local targetFov = FOV_BASE - rescue * (FOV_BASE - FOV_TIGHT)
        if not smoothFov then
          smoothFov = targetFov
        else
          local fovAlpha = 1.0 - math.exp(-dt / FOV_SMOOTH)
          smoothFov = smoothFov + (targetFov - smoothFov) * fovAlpha
        end

        -- Straight at the car: no look-ahead, no extra smoothing.
        local lookDir = carPos - heliPos
        local ldLen = lookDir:length()
        if ldLen < 0.001 then return nil end
        lookDir:scale(1 / ldLen)

        return heliPos, lookDir, vec3(0, 1, 0), smoothFov
      end
    end)(),
  },
  {
    name     = 'Pit Cam',
    fov      = 50,

    nearClip = 0.5,
    -- From above the garage, looking down on the car's pit box.
    -- car.pitTransform gives the box's position/side/up/look in world space.
    -- Reframe with the three offsets:
    --   SIDE = metres towards the inside of the garage (if it ends up over the
    --          pit lane, flip the sign);
    --   UP   = height above the box;
    --   FWD  = along the box (0 = centred).
    dynamic = function(car, sim)
      local pt = car.pitTransform
      if not pt or not pt.position then return nil end

      local P = PARAMS['Pit Cam']
      local SIDE, UP, FWD = P.SIDE, P.UP, P.FWD
      local camPos = pt.position
        + pt.side * SIDE
        + pt.up   * UP
        + pt.look * FWD
      local lookDir = (pt.position - camPos):normalize()
      return camPos, lookDir, vec3(0, 1, 0)
    end,
  },
  {
    name           = 'Circuit Cam',
    fov            = 38,

    nearClip       = 1.0,
    fakeShadows    = false,
    mips           = 4,
    opaqueAlphaFix = true,
    altShadows     = true,
    -- An aerial tour of the circuit: it flies along the track's AI line
    -- (ac.trackProgressToWorldCoordinate), high up, looking at the track
    -- ahead. On a track with no AI line it circles the focused car high up
    -- instead, so it always shows something.
    dynamic = (function()
      local progress  = 0       -- 0..1 along the AI line, or an angle in orbit
      local smoothFov = nil

      -- Both calls are CSP's documented track API; an older CSP without them
      -- gets the orbit.
      local function hasAILine()
        return type(ac.hasTrackSpline) == 'function'
          and type(ac.trackProgressToWorldCoordinate) == 'function'
          and ac.hasTrackSpline()
      end

      return function(car, sim)
        local dt = sim.dt or 1/60

        -- ============ ORBIT (no AI line) ============
        -- A slow orbit high above the focused car. Always works, and at the
        -- start of a session shows the grid, where every car is.
        if not hasAILine() then
          if not car or not car.transform or not car.transform.position then return nil end
          progress = (progress + dt * 0.05) % (math.pi * 2)  -- ~125 s per revolution
          local R, H = 280, 150
          local cx = car.transform.position.x + math.cos(progress) * R
          local cz = car.transform.position.z + math.sin(progress) * R
          local camPos = vec3(cx, car.transform.position.y + H, cz)
          local lookDir = car.transform.position - camPos
          local ld = lookDir:length()
          if ld < 0.001 then return nil end
          lookDir:scale(1 / ld)
          return camPos, lookDir, vec3(0, 1, 0), 35
        end

        -- ============ ALONG THE AI LINE ============
        local P = PARAMS['Circuit Cam']
        local HEIGHT       = P.HEIGHT
        local SPEED        = P.SPEED        -- m/s
        local LOOK_AHEAD   = P.LOOK_AHEAD   -- m
        local FOV_STRAIGHT = P.FOV_STRAIGHT
        local FOV_CURVE    = P.FOV_CURVE
        local FOV_SMOOTH   = P.FOV_SMOOTH

        local length = sim.trackLengthM
        if type(length) ~= 'number' or length < 100 then length = 5000 end
        local function at(t) return ac.trackProgressToWorldCoordinate(t % 1) end

        progress = (progress + (SPEED * dt) / length) % 1

        local p0     = at(progress)
        local pAhead = at(progress + LOOK_AHEAD / length)
        if not p0 or not pAhead then return nil end

        local camPos  = vec3(p0.x, p0.y + HEIGHT, p0.z)
        local lookDir = pAhead - camPos
        local ldLen   = lookDir:length()
        if ldLen < 0.001 then return nil end
        lookDir:scale(1 / ldLen)

        -- How much the line bends here, for the zoom: wider in the corners.
        local pBack     = at(progress - 0.002 + 1.0)
        local curvature = 0
        if pBack then
          local fwd  = vec3(pAhead.x - p0.x, 0, pAhead.z - p0.z)
          local prev = vec3(p0.x - pBack.x, 0, p0.z - pBack.z)
          local fl, pl = fwd:length(), prev:length()
          if fl > 0.001 and pl > 0.001 then
            fwd:scale(1/fl); prev:scale(1/pl)
            local dot = math.clamp(fwd.x * prev.x + fwd.z * prev.z, -1, 1)
            curvature = 1 - dot
          end
        end
        local curveT    = math.clamp(curvature / 0.3, 0, 1)
        local targetFov = FOV_STRAIGHT + curveT * (FOV_CURVE - FOV_STRAIGHT)
        if not smoothFov then
          smoothFov = targetFov
        else
          local fovAlpha = 1.0 - math.exp(-dt / FOV_SMOOTH)
          smoothFov = smoothFov + (targetFov - smoothFov) * fovAlpha
        end

        return camPos, lookDir, vec3(0, 1, 0), smoothFov
      end
    end)(),
  },
  {
    name     = 'SC Roof Rear',
    fov      = 55,

    nearClip = 0.05,
    -- On the Safety Car's roof, looking back: its tail lights in the
    -- foreground, the pack following it behind. Meant for when the focused
    -- car is the Safety Car; on any other car it is a generic rear-facing
    -- onboard. If the roof sits at another height, adjust the offset's Y
    -- (1.55 ≈ a saloon or SUV roof).
    offset   = vec3(0, 1.55, -0.30),
    forward  = vec3(0, -0.10, -1),
    up       = vec3(0, 1, -0.10),
  },
  {
    name     = 'SC Front Hood',
    fov      = 65,

    nearClip = 0.05,
    -- On the Safety Car's bonnet, looking forward: the classic roof onboard,
    -- with the nose in the bottom third. Works on any car; adjust the
    -- offset's Z if the bonnet is out of frame.
    offset   = vec3(0, 1.30, 1.50),
    forward  = vec3(0, -0.08, 1),
    up       = vec3(0, 1, 0.08),
  },
  {
    name           = 'SC Chase Aerial',
    fov            = 45,

    nearClip       = 1.0,
    fakeShadows    = false,
    mips           = 4,
    opaqueAlphaFix = true,
    altShadows     = true,
    -- A low aerial following the Safety Car from behind: the Safety Car
    -- leading and the pack in line behind it. Unlike the Helicopter Cam (a
    -- distant long lens) this is close and low, to show the "snake" of cars
    -- behind the Safety Car.
    dynamic = (function()
      local camPos = nil
      local camVel = vec3(0, 0, 0)
      return function(car, sim)
        if not car.transform or not car.transform.position then return nil end

        -- ---- Tunables (PARAMS, overridden by paddock_cameras.ini) ----
        local P = PARAMS['SC Chase Aerial']
        local HEIGHT    = P.HEIGHT      -- low → the pack is compressed behind the Safety Car
        local BACK      = P.BACK        -- distance behind the Safety Car along its travel
        local STIFFNESS = P.STIFFNESS
        local DAMPING   = P.DAMPING
        local LOOKAHEAD = P.LOOKAHEAD   -- seconds of anticipation → its nose high in the frame
        -- -------------------

        local dt     = sim.dt or 1/60
        local carPos = car.transform.position
        local vel    = car.velocity
        local speed  = vel:length()

        local fwd
        if speed > 1.0 then
          fwd = vec3(vel.x, 0, vel.z)
        else
          fwd = vec3(car.transform.look.x, 0, car.transform.look.z)
        end
        local fl = fwd:length()
        if fl > 0.001 then fwd:scale(1 / fl) else fwd = vec3(0, 0, 1) end

        local idealPos = carPos - fwd * BACK + vec3(0, HEIGHT, 0)

        if speed < 0.5 then
          if not camPos then camPos = idealPos:clone() end
          camVel = vec3(0, 0, 0)
        else
          if not camPos then
            camPos = idealPos:clone()
          else
            local err = idealPos - camPos
            camVel = camVel + (err * STIFFNESS - camVel * DAMPING) * dt
            camPos = camPos + camVel * dt
          end
        end

        local lookTarget = carPos + vel * LOOKAHEAD
        local lookDir = lookTarget - camPos
        local ldLen = lookDir:length()
        if ldLen < 0.001 then return nil end
        lookDir:scale(1 / ldLen)

        return camPos, lookDir, vec3(0, 1, 0)
      end
    end)(),
  },
  {
    name           = 'SC Side Pack',
    fov            = 28,

    nearClip       = 0.5,
    fakeShadows    = false,
    mips           = 2,
    opaqueAlphaFix = true,
    -- From the side, on a medium long lens (FOV 28°), following the Safety
    -- Car: the compressed perspective stacks the pack in single file behind
    -- it. A grandstand or fixed trackside shot. For the other side, make
    -- SIDE negative.
    dynamic = (function()
      local camPos = nil
      local camVel = vec3(0, 0, 0)
      return function(car, sim)
        if not car.transform or not car.transform.position then return nil end

        -- ---- Tunables (PARAMS, overridden by paddock_cameras.ini) ----
        local P = PARAMS['SC Side Pack']
        local SIDE      = P.SIDE        -- m to the Safety Car's right (negative = left)
        local BACK      = P.BACK        -- m behind it → it sits towards the left of the frame
        local HEIGHT    = P.HEIGHT      -- height above the tarmac (m) — almost at ground level
        local STIFFNESS = P.STIFFNESS
        local DAMPING   = P.DAMPING
        -- -------------------

        local dt     = sim.dt or 1/60
        local carPos = car.transform.position
        local vel    = car.velocity
        local speed  = vel:length()

        local fwd
        if speed > 1.0 then
          fwd = vec3(vel.x, 0, vel.z)
        else
          fwd = vec3(car.transform.look.x, 0, car.transform.look.z)
        end
        local fl = fwd:length()
        if fl > 0.001 then fwd:scale(1 / fl) else fwd = vec3(0, 0, 1) end

        local right = vec3(0, 1, 0):cross(fwd)
        local rl = right:length()
        if rl > 0.001 then right:scale(1 / rl) else right = vec3(1, 0, 0) end

        local idealPos = carPos + right * SIDE - fwd * BACK + vec3(0, HEIGHT, 0)

        if not camPos then
          camPos = idealPos:clone()
        else
          local err = idealPos - camPos
          camVel = camVel + (err * STIFFNESS - camVel * DAMPING) * dt
          camPos = camPos + camVel * dt
        end

        local lookDir = carPos - camPos
        local ldLen = lookDir:length()
        if ldLen < 0.001 then return nil end
        lookDir:scale(1 / ldLen)

        return camPos, lookDir, vec3(0, 1, 0)
      end
    end)(),
  },
}

-- ===================== ONE SOLUTION PER TICK =====================
-- A dynamic camera keeps state between frames (a spring's position and
-- velocity, a smoothed zoom, a progress along the track), so it must be
-- advanced exactly once per simulation tick. Two things ask for it: its own
-- OBS source and the Stream camera, which evaluates every camera to keep them
-- all warm. Calling the function from both advanced it twice whenever both
-- were on screen — double speed, and a spring integrated with the wrong step.
-- So every camera is solved once per tick and the answer shared.
local tick = 0
local solved = {}   -- camera name → { tick, pos, forward, up, fov }

local function solve(cfg, car, sim)
  local cached = solved[cfg.name]
  if cached and cached[1] == tick then
    return cached[2], cached[3], cached[4], cached[5]
  end
  local pos, fwd, up, fov
  if cfg.dynamic then
    pos, fwd, up, fov = cfg.dynamic(car, sim)
  else
    pos = car.transform:transformPoint(cfg.offset)
    fwd = car.transform:transformVector(cfg.forwardN)
    up  = car.transform:transformVector(cfg.upN)
  end
  solved[cfg.name] = { tick, pos, fwd, up, fov }
  return pos, fwd, up, fov
end

-- ===================== STREAM (A VIRTUAL DIRECTOR) =====================
-- Defined after CAMS because it needs the whole list, and appended to it just
-- before the cameras are registered.
--
-- It cuts between the other cameras on what the car is doing, by the rules in
-- DIRECTOR (paddock_cameras.ini: [DIRECTOR] and [RULE_n]), with at least
-- DIRECTOR.minTime seconds per shot except for the urgent cameras. The
-- defaults, by priority:
--   1. In the pit lane → Pit Cam (an immediate cut, no cooldown).
--   2. Heavy braking   → Helmet / Onboard Side / T-Cam (immersive).
--   3. Cornering       → Onboard Side / Helmet / Halo POV / T-Cam.
--   4. Flat out        → Nose Cam / T-Cam / Helicopter (a wide shot).
--   5. Medium speed    → Helicopter / Drone / T-Cam / Onboard Side.
--   6. Slow            → Helicopter / Drone / Pit (a transition, a wide shot).
--
-- Within each pool it avoids repeating the current camera and prefers the one
-- that has gone longest unused: variety without randomness.
local STREAM_CAM = {
  name           = 'Stream',
  fov            = 35,           -- placeholder: each camera it cuts to brings its own FOV

  nearClip       = 0.05,
  -- A superset of the other cameras' shot settings. High mips and the opaque
  -- alpha fix do no harm to the cockpit cameras and the aerials need them.
  -- fakeShadows stays on (the default) so the cockpit cameras keep a shadow
  -- under the car; the transition line on the aerial shots is accepted.
  mips           = 4,
  opaqueAlphaFix = true,
  altShadows     = true,
  dynamic = (function()
    local currentCam = nil
    local timeInCam  = 0
    local elapsed    = 0          -- its own clock (independent of sim.time)
    local lastUsed   = {}         -- name → when it was last on air

    -- Leave out the current camera, then pick the one unused the longest.
    local function rotate(options)
      local filtered = {}
      for _, n in ipairs(options) do
        if n ~= currentCam then filtered[#filtered + 1] = n end
      end
      if #filtered == 0 then return options[1] end
      table.sort(filtered, function(a, b)
        return (lastUsed[a] or -1e9) < (lastUsed[b] or -1e9)
      end)
      return filtered[1]
    end

    -- Whether a rule holds for the car's state; a condition left out is not checked.
    local function ruleMatches(r, st)
      if r.inPit ~= nil and r.inPit ~= st.inPit then return false end
      if r.brakeMin and not (st.brake > r.brakeMin) then return false end
      if r.gasMin   and not (st.gas > r.gasMin) then return false end
      if r.speedMin and not (st.speed > r.speedMin) then return false end
      if r.speedMax and not (st.speed < r.speedMax) then return false end
      if r.steerMin and not (st.steer > r.steerMin) then return false end
      if r.steerMax and not (st.steer < r.steerMax) then return false end
      return true
    end

    -- The director's call: the first rule that holds, rotating within its
    -- pool. With none holding it stays on the current camera.
    local function pickCamera(car)
      local st = {
        steer = math.abs(car.steer or 0),
        speed = car.velocity and car.velocity:length() or 0,
        brake = car.brake or 0,
        gas   = car.gas or 0,
        inPit = (car.isInPitlane or car.isInPit) and true or false,
      }
      for _, r in ipairs(DIRECTOR.rules) do
        if r.pool and #r.pool > 0 and ruleMatches(r, st) then return rotate(r.pool) end
      end
      return currentCam
    end

    return function(car, sim)
      if not car or not car.transform or not car.transform.position then return nil end

      local dt = sim.dt or 1/60
      elapsed = elapsed + dt
      timeInCam = timeInCam + dt

      -- Every camera is solved every tick (which keeps the dynamic ones warm:
      -- no jump when the director cuts back to one after a while). `solve`
      -- makes that the only evaluation of the tick, shared with the camera's
      -- own OBS source. Negligible next to the rendering.
      local results = {}
      for _, cfg in ipairs(CAMS) do
        if cfg.name ~= 'Stream' then
          local pos, fwd, up, fov = solve(cfg, car, sim)
          if pos then
            results[cfg.name] = { pos, fwd, up, fov or cfg.fov }
          end
        end
      end

      -- The call, with its cooldown. An urgent camera cuts at once.
      local desired = pickCamera(car)
      local urgent  = desired and DIRECTOR.urgent[desired] and desired ~= currentCam
      local canSwitch = not currentCam
                     or urgent
                     or (timeInCam >= DIRECTOR.minTime and desired ~= currentCam)
      if canSwitch and desired and results[desired] then
        currentCam = desired
        timeInCam  = 0
        lastUsed[desired] = elapsed
      end

      -- If the current camera had no answer this tick (the helicopter on its
      -- very first frame), skip the frame rather than show something broken.
      if not currentCam then return nil end
      local r = results[currentCam]
      if not r then return nil end
      return r[1], r[2], r[3], r[4]
    end
  end)(),
}
CAMS[#CAMS + 1] = STREAM_CAM

-- A static camera's vectors, normalised once — again whenever the ini moves it.
local function prepare(cfg)
  cfg.forwardN = cfg.forward and cfg.forward:clone():normalize() or nil
  cfg.upN      = cfg.up      and cfg.up:clone():normalize()      or nil
end

-- ===================== LOADING AND RELOADING paddock_cameras.ini =====================
local function iniParse(text)
  local out, cur = {}, nil
  for line in (text .. '\n'):gmatch('([^\r\n]*)\r?\n') do
    line = line:gsub('^%s+', ''):gsub('%s+$', '')
    local sec = line:match('^%[(.+)%]$')
    if sec then
      cur = {}
      out[#out + 1] = { name = sec, kv = cur }
    elseif cur and line ~= '' and not line:find('^;') then
      local k, v = line:match('^([^=]+)=(.*)$')
      if k then cur[(k:gsub('%s+$', ''))] = (v:gsub('^%s+', '')) end
    end
  end
  return out
end
local function iniVec(s)
  local t = {}
  for n in tostring(s):gmatch('[-%d%.eE+]+') do t[#t + 1] = tonumber(n) end
  if #t < 3 then return nil end
  return vec3(t[1], t[2], t[3])
end
local function camName(name) return CAM_ALIASES[name] or name end
local function iniList(s)
  local t = {}
  for part in tostring(s or ''):gmatch('[^|]+') do
    part = part:gsub('^%s+', ''):gsub('%s+$', '')
    if part ~= '' then t[#t + 1] = camName(part) end
  end
  return t
end
local function iniNum(s) if s == nil or s == '' then return nil end return tonumber((tostring(s):gsub(',', '.'))) end

local function loadConfig()
  local text = io.load(CONFIG_FILE)
  if not text then return false end
  local byName = {}
  for _, cfg in ipairs(CAMS) do byName[cfg.name] = cfg end
  local rules = {}
  for _, sec in ipairs(iniParse(text)) do
    local kv = sec.kv
    local name = sec.name:match('^CAM:(.+)$')
    name = name and camName(name)
    if name and byName[name] then
      local cfg = byName[name]
      cfg.fov      = iniNum(kv.FOV) or cfg.fov
      cfg.nearClip = iniNum(kv.NEAR) or cfg.nearClip
      if cfg.offset then
        cfg.offset  = iniVec(kv.OFFSET) or cfg.offset
        cfg.forward = iniVec(kv.FORWARD) or cfg.forward
        cfg.up      = iniVec(kv.UP) or cfg.up
        prepare(cfg)
      end
      local p = PARAMS[name]
      if p then for k in pairs(p) do local v = iniNum(kv[k]); if v then p[k] = v end end end
    elseif sec.name == 'DIRECTOR' then
      DIRECTOR.minTime = iniNum(kv.MIN_TIME) or DIRECTOR.minTime
      if kv.URGENT ~= nil then
        DIRECTOR.urgent = {}
        for _, n in ipairs(iniList(kv.URGENT)) do DIRECTOR.urgent[n] = true end
      end
    elseif sec.name:match('^RULE_%d+$') then
      local pit = kv.IN_PIT
      rules[#rules + 1] = {
        order    = tonumber(sec.name:match('%d+')),
        name     = kv.NAME,
        inPit    = (pit == '1' and true) or (pit == '0' and false) or nil,
        brakeMin = iniNum(kv.BRAKE_MIN), gasMin = iniNum(kv.GAS_MIN),
        speedMin = iniNum(kv.SPEED_MIN), speedMax = iniNum(kv.SPEED_MAX),
        steerMin = iniNum(kv.STEER_MIN), steerMax = iniNum(kv.STEER_MAX),
        pool     = iniList(kv.POOL),
      }
    end
  end
  if #rules > 0 then
    table.sort(rules, function(a, b) return a.order < b.order end)
    DIRECTOR.rules = rules
  end
  pcall(ac.log, '[Paddock Cameras] paddock_cameras.ini loaded (' .. #DIRECTOR.rules .. ' director rules)')
  return true
end

loadConfig()
pcall(function()
  ac.onFileChanged(CONFIG_FILE, function()
    local ok, err = pcall(loadConfig)
    if not ok then pcall(ac.warn, '[Paddock Cameras] could not reload paddock_cameras.ini: ' .. tostring(err)) end
  end)
end)

-- ===================== FOLLOWING A CAR =====================

-- Every car on track, by race position.
local function getSortedCars(sim)
  local cars = {}
  for i = 0, (sim and sim.carsCount or 0) - 1 do
    local c = ac.getCar(i)
    if c and c.transform and c.transform.position then
      local pos = c.racePosition or 999
      cars[#cars + 1] = { index = i, car = c, racePosition = pos }
    end
  end
  table.sort(cars, function(a, b) return a.racePosition < b.racePosition end)
  return cars
end

-- 'leader': the car in P1.
local function autoPickLeader(sim)
  local cars = getSortedCars(sim)
  return #cars > 0 and cars[1].index or (sim and sim.focusedCar or 0)
end

-- 'battle': the closest pair (out of the pit lane); the leader if none is close.
local function autoPickBattle(sim)
  local bestDist = AUTO_BATTLE_RANGE + 1
  local bestIndex = sim and sim.focusedCar or 0
  local cars = getSortedCars(sim)
  for i = 1, #cars - 1 do
    local a, b = cars[i].car, cars[i + 1].car
    if not a.isInPitlane and not b.isInPitlane then
      local dist = (a.transform.position - b.transform.position):length()
      if dist < bestDist then
        bestDist = dist
        bestIndex = cars[i + 1].index
      end
    end
  end
  if bestDist > AUTO_BATTLE_RANGE then return autoPickLeader(sim) end
  return bestIndex
end

-- 'cycle': every car in turn.
local cycleTimer = 0
local cycleCarIndex = 0
local cycleCarList = {}

local function autoPickCycle(sim, dt)
  local cars = getSortedCars(sim)
  if #cars ~= #cycleCarList then
    cycleCarList = {}
    for _, c in ipairs(cars) do
      cycleCarList[#cycleCarList + 1] = c.index
    end
    cycleCarIndex = 0
    cycleTimer = 0
  end
  if #cycleCarList == 0 then return sim and sim.focusedCar or 0 end

  cycleTimer = cycleTimer + (dt or 0)
  if cycleTimer >= AUTO_CYCLE_INTERVAL then
    cycleTimer = 0
    cycleCarIndex = cycleCarIndex + 1
    if cycleCarIndex > #cycleCarList then cycleCarIndex = 1 end
  end
  if cycleCarIndex < 1 then cycleCarIndex = 1 end
  return cycleCarList[cycleCarIndex]
end

-- ===================== RENDERING TO OBS =====================

-- A passthrough: YEBIS already returns the LDR image with the game's PP
-- applied, so it is copied to the OBS canvas untouched (no second tonemap, no
-- grading).
local SHADER_PASSTHROUGH = [[
  float4 main(PS_IN pin){
    return float4(txInput.Sample(samLinear, pin.Tex).rgb, 1);
  }
]]

local function configureShot(shot, cfg)
  shot:setClippingPlanes(cfg.nearClip or 0.05, cfg.farClip or 5e3)
  shot:setShadersType(render.ShadersType.Main)
  shot:setMaxLayer(5)
  -- Particles with YEBIS have a known bug (HDR colours into an LDR texture),
  -- so they are off on these cameras; the PP filter's bloom and volumetrics
  -- make up for it on the surfaces.
  shot:setParticles(false)
  shot:setFakeCarShadows(cfg.fakeShadows ~= false)
  shot:setOriginalLighting(true)
  shot:setSky(true)
  shot:setTransparentPass(true)
  if cfg.opaqueAlphaFix then shot:setOpaqueAlphaFix(true) end
  if cfg.altShadows    then shot:setAlternativeShadowsSet('area') end
  -- The camera's own exposure, when it has one. The settings above promised
  -- it and nothing applied it.
  if cfg.exposure then shot:setExposure(cfg.exposure) end
end

local function registerCamera(cfg)
  -- Static cameras' vectors are normalised here and on every reload of the
  -- ini; dynamic cameras return world-space vectors every frame.
  prepare(cfg)
  local camShot

  return obs.register(OBS_GROUP, cfg.name,
    obs.Flags.ManualUpdate + obs.Flags.ApplyCMAA + obs.Flags.UserSize,
    function(size)
      if camShot then camShot:dispose() end
      camShot = ac.GeometryShot(
        ac.findNodes('sceneRoot:yes'),
        size, cfg.mips or 1, false,
        render.AntialiasingMode.YEBIS,
        render.TextureFormat.R16G16B16A16.Float
      )
      configureShot(camShot, cfg)
    end,
    function(canvas)
      local sim = ac.getSim()
      local car = ac.getCar(sim and sim.focusedCar or 0)
      if not camShot or not car then return end

      local worldPos, worldForward, worldUp, dynFov = solve(cfg, car, sim)
      if not worldPos then return end

      camShot:update(worldPos, worldForward, worldUp, dynFov or cfg.fov)
      canvas:updateWithShader({
        textures = { txInput = camShot },
        shader   = SHADER_PASSTHROUGH,
      })
    end
  )
end

local handles = {}
for _, cfg in ipairs(CAMS) do
  handles[#handles + 1] = registerCamera(cfg)
end

-- Auto-exposure control belongs to CSP's weather scripts; an app may not have
-- it. Look once and say so, instead of failing silently every frame.
local canFreezeExposure = FREEZE_AUTO_EXPOSURE
  and type(ac.setAutoExposureActive) == 'function'
if FREEZE_AUTO_EXPOSURE and not canFreezeExposure and ac.log then
  ac.log('[Paddock Cameras] auto-exposure control is not available to apps in this CSP; FREEZE_AUTO_EXPOSURE has no effect')
end

-- Frames are pushed to OBS from [SIM_CALLBACKS] UPDATE (manifest.ini), in step
-- with AC's simulation. The followed car is chosen first, so every camera
-- follows the same one.
function script.simUpdate(dt)
  local sim = ac.getSim()
  if not sim then return end
  tick = tick + 1

  if canFreezeExposure then
    pcall(ac.setAutoExposureActive, false)
    if type(ac.setAutoExposureLimits) == 'function' then pcall(ac.setAutoExposureLimits, 0.95, 1.05) end
  end

  if AUTO_MODE == 'leader' then
    ac.focusCar(autoPickLeader(sim))
  elseif AUTO_MODE == 'battle' then
    ac.focusCar(autoPickBattle(sim))
  elseif AUTO_MODE == 'cycle' then
    ac.focusCar(autoPickCycle(sim, dt))
  end

  for i = 1, #handles do
    handles[i]:update()
  end
end
