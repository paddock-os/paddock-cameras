# Changelog

## 1.0.0 — the first release from its own repository

Paddock Cameras was developed as a league's in-house app (`RSR_Cameras`) and
is published here for the first time.

**Changed**
- Named for Paddock OS: the app is `paddock_cameras` and its OBS sources are
  listed as `Paddock OS: <camera>`. OBS scenes built on the in-house version
  (`RSR_Camera: …`) need their sources picked again.
- `SC Chase Aerea` is `SC Chase Aerial`.
- Comments and documentation in English.

**Fixed**
- A dynamic camera was advanced twice per tick whenever the Stream director
  and that camera's own source were both in use: its spring integrated with
  the wrong step and it moved at double speed. Every camera is now solved once
  per tick and the answer shared.
- A camera's `exposure` setting was documented and never applied; it is now
  (`GeometryShot:setExposure`).
- The Circuit Cam probed a dozen guessed API names for the track's AI line
  and dumped `ac.*` to the log to find one. It uses CSP's documented
  `ac.hasTrackSpline()` / `ac.trackProgressToWorldCoordinate()` and the
  session's `trackLengthM`, and still circles the car on a track without an AI
  line.
- Freezing auto-exposure failed silently where CSP does not give apps that
  control. It is now a setting (`FREEZE_AUTO_EXPOSURE`), checked once, and
  logged when it has no effect.
