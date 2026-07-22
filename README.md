# D2C Tracker

D2C Tracker is an independent, offline-first SwiftUI app for exploring Direct-to-Cell satellite candidates from an iPhone. It downloads public orbital elements, propagates them locally with SGP4, combines RF geometry with optional offline terrain, and estimates the satellite most likely to be serving the observer.

The app deliberately says **likely serving satellite**. Public iOS APIs do not expose a modem-confirmed serving spacecraft identity.

## Features

- Live 3D globe with constellation, observer, ground track, borders, and shared satellite selection.
- Local sky dome and level horizon views with selectable satellites and static clear-sky uplink reference rings.
- Serving-candidate scoring using elevation, slant range, off-nadir scan loss, free-space path loss, Doppler, remaining dwell, terrain clearance, location accuracy, TLE age, phone orientation, and handoff hysteresis.
- Current Direct-to-Cell GP data from CelesTrak with validation, atomic caching, conditional requests, and a persistent two-hour request floor.
- Optional state-wide AWS Skadi terrain packs with storage preflight, resumable tile downloads, and on-device horizon generation.
- Optional background location and Live Activity for user-initiated continuous tracking.
- Optional minimal-traffic connectivity diagnostics for ultra-constrained paths, including a privacy-scrubbed JSON support export.
- Explicit TLE epoch, terrain coverage, and serving-estimate health indicators.
- GPS-first setup with optional manual observer location.

## Screens

The app has four primary tabs:

1. **Tracking** — likely serving candidate, live geometry, RF diagnostics, connectivity history, and background tracking.
2. **Sky** — dome and horizon visualizations.
3. **Globe** — interactive 3D Earth and Direct-to-Cell constellation.
4. **More** — orbital data, location, terrain, link diagnostics, attribution, and legal settings.

## Architecture

```text
D2CTracker (SwiftUI iOS app)
├── AppModel and lifecycle coordination
├── Core Location, Core Motion, Network.framework, and ActivityKit services
├── SceneKit globe and SwiftUI sky/horizon renderers
├── Terrain download and local line-of-sight service
├── Optional URLSession connectivity probes
└── D2CTrackerCore (Swift package)
    ├── GP JSON and checked TLE parsing
    ├── Atomic catalog storage and refresh policy
    ├── SatelliteKit SGP4 propagation
    ├── Coordinate transforms, passes, and ground tracks
    ├── RF geometry and phone-uplink budget
    ├── Terrain models
    └── Serving-candidate scoring and hysteresis
```

The application target supports iOS 17 and newer. Newer constrained-network APIs are guarded with availability checks.

## Orbital data and classification

Production orbital data comes from CelesTrak's GP JSON endpoint:

```text
https://celestrak.org/NORAD/elements/gp.php?NAME=%5BDTC%5D&FORMAT=JSON
```

CelesTrak currently tags Starlink Direct-to-Cell names with a token-bounded `[DTC]` suffix. The app does not infer Direct-to-Cell capability from a generic `STARLINK-*` name. The bundled sample catalog is synthetic and exists only for tests, previews, and offline bootstrap behavior.

Catalog downloads are validated before atomic replacement. ETag and Last-Modified values are persisted, and every attempted CelesTrak request—automatic, manual, successful, unchanged, or failed—is subject to the same two-hour minimum interval.

## Serving estimate

The serving model ranks only classified Direct-to-Cell candidates that satisfy the terrain and link envelope. It incorporates:

- elevation, range, and remaining visibility;
- free-space loss, off-nadir steering, scan loss, and estimated phone uplink margin;
- Doppler and Doppler rate;
- optional terrain/RF clearance;
- TLE epoch age and observer accuracy;
- operational metadata when available;
- continuity and sustained-advantage handoff rules.

Phone orientation contributes to the serving-quality estimate, while the Sky screen intentionally uses static clear-sky reference rings so the visualization does not move with phone posture.

This is an inference system, not carrier telemetry, modem signal strength, or proof of a satellite connection.

## Terrain

Optional state packs use approximately 30-meter AWS Skadi HGT cells covering the selected state plus the modeled service-range margin. Downloads:

- are stored compressed and excluded from backup;
- resume from completed cells across pauses and relaunches;
- perform a remaining-space preflight with a safety reserve;
- warn before regular cellular use;
- are blocked on constrained and ultra-constrained paths.

Terrain modeling includes topography and Earth curvature. It does not model buildings, trees, weather, diffraction, or carrier-side beam scheduling.

## Connectivity diagnostics

Diagnostics are disabled by default and run only on an ultra-constrained path or when the user enables diagnostic mode. A probe requests:

```text
https://speed.cloudflare.com/__down?bytes=0
```

The zero-payload request measures availability, DNS, TCP, TLS, time to first byte, total duration, and request/response overhead without a bandwidth-test body. It does not measure sustained throughput.

The optional TestFlight report uses elapsed sample times and omits location, IP and device identifiers, satellite IDs and names, headings, phone orientation, absolute sample timestamps, and raw transport errors.

## Privacy

D2C Tracker has no accounts, advertising, analytics, tracking SDKs, or developer-operated backend. Location and orientation remain on the device. App settings, orbital caches, optional terrain, and optional diagnostic history are local app data.

See the published [Privacy Policy](https://keatontaylor.github.io/D2CTracker/privacy.html) and [Support page](https://keatontaylor.github.io/D2CTracker/).

## Build

Requirements:

- Xcode 26 or newer
- iOS 17 or newer deployment target
- Network access for the first Swift Package Manager resolution

Open `D2CTracker.xcodeproj`, select the `D2CTracker` scheme, and run on an iPhone or simulator.

Command-line build:

```sh
xcodebuild \
  -project D2CTracker.xcodeproj \
  -scheme D2CTracker \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Core tests:

```sh
swift test
```

The current suite contains 55 deterministic parser, policy, cache, geometry, terrain, RF, serving, and SGP4 tests.

## Data sources and dependencies

- [CelesTrak](https://celestrak.org/) — General Perturbations orbital data.
- [AWS Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) — Skadi elevation tiles derived from public USGS/SRTM sources.
- [U.S. Census Bureau TIGERweb](https://tigerweb.geo.census.gov/tigerwebmain/TIGERweb_apps.html) — state boundaries used for terrain planning.
- [Natural Earth](https://www.naturalearthdata.com/) — public-domain globe land and administrative boundaries.
- [SatelliteKit](https://github.com/gavineadie/SatelliteKit) 2.1.0 — MIT-licensed SGP4/SDP4 implementation.
- [Cloudflare Speed Test](https://github.com/cloudflare/speedtest) — optional zero-payload connectivity endpoint.

Third-party data and hosted services remain subject to their providers' terms and availability.

## Independent project

D2C Tracker is not affiliated with, endorsed by, or sponsored by Space Exploration Technologies Corp., SpaceX, Starlink, any wireless carrier, CelesTrak, or the listed data providers. STARLINK and SPACEX are trademarks of Space Exploration Technologies Corp. Their names are used only for identification and technical context.

Do not use D2C Tracker for navigation, emergency response, or any safety-critical decision.

## Contributing and support

Bug reports and focused pull requests are welcome. Please use the [issue tracker](https://github.com/keatontaylor/D2CTracker/issues) and do not post exact locations or personal information in public issues.

## License

The project source code is available under the [MIT License](LICENSE). Third-party software and data retain their respective licenses and terms.
