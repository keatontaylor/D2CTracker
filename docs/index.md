---
title: D2C Tracker Support
---

# D2C Tracker Support

D2C Tracker is an independent iPhone app for visualizing Direct-to-Cell satellite candidates using public orbital data and on-device calculations.

## Get help

For bug reports, questions, and feature requests, [open a support request on GitHub](https://github.com/keatontaylor/D2CTracker/issues/new/choose).

Please include the app version, iOS version, and a short description of what happened. The privacy-scrubbed diagnostic report under **More → Internet Link Diagnostics** may also be attached when relevant. Do not include an exact location or other personal information in a public issue.

## Common checks

- Confirm that Location access is enabled if the app is waiting for GPS.
- Refresh orbital data only when the app indicates that a request is allowed.
- Terrain downloads require sufficient storage and a regular Wi-Fi, Ethernet, or cellular connection; they are blocked on constrained satellite paths.
- Background satellite tracking and link diagnostics are optional and must be enabled by the user.

[Privacy Policy](privacy.md) · [Source Code](https://github.com/keatontaylor/D2CTracker)
