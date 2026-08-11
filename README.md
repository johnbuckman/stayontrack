# Stay on Track

**A minimal, fully-offline hiking companion that keeps you on your intended trail.**

You load a planned hike as a GPX file, and Stay on Track guides you along it — warning you *out loud* at every point where another path joins yours, so you never take the wrong fork. It works entirely offline on the trail (put your phone in airplane mode for all-day battery), and it keeps your phone in your pocket: the important cues are **audio**.

<p align="center">
  <img src="docs/screenshot.jpg" alt="Stay on Track — following a hike near Pommerol, France" width="320">
</p>

---

## Why this exists

Most hiking apps show you a map and leave you to stare at it. On a real trail the moment you get lost is a **decision point** — a junction where another path branches off and you confidently walk down the wrong one. Stay on Track focuses on exactly that moment:

- It knows where the real trail junctions are (from OpenStreetMap), matched onto your route.
- As you approach one, a **posh British voice** simply says **"Left"**, **"Right"**, or **"Straight"** — how to stay on your intended path.
- If you drift off the trail, a **Geiger-counter-style tone** rises in pitch the further you stray, so you can course-correct without looking.

Everything needed for the hike is downloaded once (map, trails, elevation) when you import the route. After that it's fully offline.

## Features

**Following your route**
- **Import a GPX** via the share sheet, Files, or "open in".
- **Offline OpenStreetMap tiles** — a corridor around your route is downloaded and disk-cached at import, so the map works in airplane mode.
- **1 km distance markers** and a **green START / red STOP** sign at the route ends.
- **Reverse** toggle to walk the route the other way (markers, junctions and turns all flip).
- **Faint breadcrumb** of where you've actually walked.

**Junction guidance (the core feature)**
- **Decision-point detection** from the OSM trail network (via Overpass): nodes where **three or more trail segments meet**, matched to within 40 m of your route (GPS-error tolerant).
- **Voice cue** — "Left / Right / Straight" spoken ~50 m before and again at each junction, using a **high-quality offline voice** ([Kokoro](https://github.com/hexgrad/kokoro), British female "Emma"), pre-rendered and bundled.
- **On-map arrows** — a discreet arrow at each junction pointing the actual compass direction to continue.
- **Top HUD** showing the next junction's maneuver and a live distance countdown.
- Junctions are **cached per route**, so re-opening the same hike needs no network.

**Off-trail alert**
- Silent within 100 m of the route; beyond that a **continuous tone whose pitch rises with distance** (with hysteresis so it doesn't chatter at the boundary).

**Live stats & ETA**
- Elapsed time, **distance walked** and **elevation gained** (from your actual track), and current off-trail distance.
- Two ETAs: a grade-adjusted **Calculated ETA** (Tobler's hiking function over the route's elevation profile) and a **Your-pace ETA** (from your measured pace, after 10 minutes), plus a **pace-vs-calculated %**.
- If the GPX has no elevation, it's fetched from a DEM ([Open-Meteo](https://open-meteo.com/)) at import — used for the ETA math only.

**On the move**
- **Auto-recenter** on your position during a real walk (your zoom level is never changed); a **Recenter** button appears if you pan away.
- **Navigate to start** — hand the trailhead coordinate to Apple Maps, Google Maps, Waze, or the share sheet (Tesla, etc.) to drive there.
- **Live status** — an iPhone **Live Activity** (Lock Screen + Dynamic Island) showing the next junction and distance. (On the Mac Catalyst dev build this is shown as notifications for testing.)

**Recording**
- Records your actual track and **exports it as GPX** to share to another app when you stop.

**Testing**
- A **drag-to-walk simulation**: drag the position marker and the whole app behaves as if you're walking there — directions, off-trail tone, stats, recording — so it can be developed and demoed without leaving your desk.

## Install (sideload)

[![One-tap install for iPhone / iPad via SideStep](https://img.shields.io/badge/⬇_One--tap_install_(iPhone_%2F_iPad)-via_SideStep-0a84ff?style=for-the-badge&logo=apple)](https://github.com/johnbuckman/stayontrack/releases/latest/download/stayontrack-installer.zip)

Stay on Track isn't on the App Store. The one-tap installer above (run it on a Mac) downloads [**SideStep**](https://github.com/johnbuckman/SideStep) and installs Stay on Track onto your iPhone/iPad, signed with your own Apple ID. Or grab the raw **[release IPA](https://github.com/johnbuckman/stayontrack/releases/latest)** and sideload it yourself — it's also listed in SideStep's built-in app catalog. Requires iOS 17.

## How it works

- **SwiftUI** app; **MapKit** with a custom `MKTileOverlay` serving cached OSM raster tiles; **CoreLocation** for tracking; **AVFoundation** for the tone (synthesised sine) and the bundled voice clips.
- Trail junctions come from the **Overpass API**; the app builds the trail graph and keeps nodes of degree ≥ 3 near the route.
- Turn direction at each junction is computed from the route's own geometry; the off-trail distance uses a windowed nearest-point search so loops and switchbacks don't confuse it.
- Built for **iPhone**, with a **Mac Catalyst** build used for development (the window is pinned to iPhone size).

## Building

Requires Xcode and [XcodeGen](https://github.com/yonsm/XcodeGen):

```bash
brew install xcodegen
git clone https://github.com/johnbuckman/stayontrack.git
cd stayontrack
xcodegen generate
open StayOnTrack.xcodeproj
```

Or build the Mac Catalyst app from the command line:

```bash
xcodegen generate
xcodebuild -project StayOnTrack.xcodeproj -scheme StayOnTrack \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

The Xcode project is generated from `project.yml` and is not checked in.

## Data sources & attribution

- **Map tiles & trail data:** © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors. Trail junctions are queried via the [Overpass API](https://overpass-api.de/). ⚠️ The default tile source is OSM's own servers, which is fine for personal use but **not** for a widely-distributed app — see the [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/) and point the app at your own tile server or a provider before shipping to many users.
- **Elevation:** [Open-Meteo](https://open-meteo.com/) elevation API (Copernicus DEM), used when a GPX lacks elevation.
- **Voice:** [Kokoro-82M](https://github.com/hexgrad/kokoro) (Apache-2.0) — the "Left/Right/Straight" clips are pre-rendered and bundled so the app stays offline.
- **Pace model:** Tobler's hiking function.

## Status

Actively developed. Working today (verified on the Mac Catalyst build): import, offline tiles, junction detection + voice + arrows, off-trail tone, stats, dual ETA, recording/export, navigate-to-start, drag-to-walk simulation. The iPhone Live Activity UI (widget extension) is the next piece to wire up on a device build.

## License

[GNU General Public License v3.0](LICENSE) © John Buckman.
