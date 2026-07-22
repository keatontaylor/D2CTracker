---
title: D2C Tracker Privacy Policy
---

# D2C Tracker Privacy Policy

**Effective date: July 21, 2026**

D2C Tracker does not collect, transmit to the developer, sell, or store personal information on a developer-operated server. The app has no accounts, advertising, analytics, tracking SDKs, or developer-operated backend.

## Information processed on the device

When permitted by the user, D2C Tracker processes location, altitude, heading, and device orientation on the iPhone to calculate satellite geometry and direction. This information is not included in orbital-data, terrain, or connectivity-test requests and is not sent to the developer.

Background location is optional and begins only after the user enables background satellite tracking. It is used to keep the user-initiated Live Activity and satellite calculations current while the app is in the background.

## Information stored on the device

App settings, validated orbital-data caches, optional terrain downloads, optional connectivity history, and generated terrain-horizon profiles are stored locally on the user's device. Terrain and diagnostic history can be removed from the app, and all local app data can be removed by deleting the app.

Privacy-scrubbed diagnostic reports are generated locally and leave the device only when the user explicitly chooses to share them. These reports omit location, IP and device identifiers, satellite names and identifiers, headings, phone orientation, absolute sample timestamps, and raw error descriptions.

## Third-party network requests

The app retrieves public orbital data from CelesTrak, state boundaries from the U.S. Census Bureau, and optional terrain tiles from the Registry of Open Data on AWS. Optional link diagnostics send a zero-payload HTTPS request to Cloudflare's Speed Test service. As with ordinary Internet requests, those providers may receive network metadata such as the user's public IP address and are governed by their own policies.

- [CelesTrak](https://celestrak.org/)
- [U.S. Census Bureau](https://www.census.gov/about/policies/privacy.html)
- [Amazon Web Services Privacy Notice](https://aws.amazon.com/privacy/)
- [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/)

## Contact

Questions about this policy or the app can be submitted through the [D2C Tracker support page](index.md) or [GitHub issue tracker](https://github.com/keatontaylor/D2CTracker/issues).

This policy may be updated when the app's behavior or legal requirements change. Material changes will be reflected by updating the effective date above.
