# Direct-to-Cell serving-satellite inference

Model version: `spacex-d2c-v1`

D2C Tracker cannot read the iPhone baseband's serving satellite, LTE timing advance,
beam identifier, payload load, or scheduler state. The result is therefore an inferred
relative probability, never a confirmed connection.

## Physics-based calculations

The following values come from the observer location and SGP4-propagated satellite state:

- Elevation, azimuth, slant range, pass rise/culmination/set, and remaining dwell.
- Range rate and elevation rate, calculated with centered finite differences around the
  observation epoch.
- Satellite off-nadir steering angle: the angle between the spacecraft-to-Earth-center
  vector and the spacecraft-to-observer line of sight. This places footprint elongation
  in the incidence plane rather than assuming it follows the ground track.
- Raw classical Doppler at the midpoint of PCS G Block: 1912.5 MHz uplink and
  1992.5 MHz downlink. Positive Doppler denotes an approaching satellite.
- Downlink Doppler rate from the centered second derivative of slant range.
- Free-space path loss from slant range and the downlink center frequency.
- TLE age from the orbital-element epoch, catalog age, and Core Location horizontal
  accuracy when available.

The raw Doppler values are diagnostic geometry. SpaceX performs network-side timing and
Doppler compensation, so they are not predictions of the residual shift visible to the
phone.

## Heuristic SpaceX scheduling assumptions

The following are explicit, configurable assumptions rather than published scheduler
behavior:

- An electronically steered D2C beam can remain on an Earth-fixed cell while its serving
  satellite moves and changes steering angle.
- Large off-nadir angles are less favorable. Estimated phased-array scan loss uses a
  configurable `cos^n(theta)` projected-aperture model; v1 uses `n = 1.6`.
- Range/path loss, off-nadir geometry, scan loss, remaining dwell, and rising/setting
  state jointly matter. Elevation alone carries only 0.11 of the model weight.
- The incumbent receives a modest continuity term. A challenger must be materially
  better for 20 seconds and normally have at least 90 seconds of remaining dwell.
- Poor incumbent elevation, steering, or remaining dwell reduces the required margin and
  confirmation time. Loss of usable geometry causes an immediate handoff.
- A 30-second cooldown suppresses reverse handoffs unless incumbent geometry becomes poor.

All thresholds and weights live in `D2CServingModelConfiguration`, which is versioned so
future tuning can be compared and migrated deliberately.

## Relative probabilities and confidence

Candidate suitability values are converted together with a softmax normalization. The UI
shows those relative probabilities, not the weighted suitability value as a percentage.
The selected candidate's probability includes a small tracker-persistence term representing
the stateful handoff prior.

Confidence is reduced when candidates are nearly equal, the TLE or catalog is stale,
location accuracy is poor, or D2C classification confidence is weak. Unknown active-beam
allocation, payload capacity, frequency reuse, and interference prevent this model from
confirming the serving satellite even when geometric confidence is high.
