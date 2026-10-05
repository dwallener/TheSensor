# The Sensor — Processing Roadmap

This plan extends the proven local visual and auditory kernels into a small
hierarchy. Existing commands remain frozen so each new layer can be evaluated
against the current physical baseline.

## Principles

- Preserve `MONO_TEMPORAL_V0` (`0xA0`) and `STEREO_FILTERBANK_V0` (`0xB0`).
- Add integration layers as new commands rather than silently changing existing
  representations.
- Keep dense, inspectable evidence alongside short reflex summaries.
- Add state only where it creates temporal or field-level information unavailable
  from one local work unit.
- Require bit-accurate reference models, RTL tests, synthesis, place-and-route,
  timing closure, and gate-level replay at every stage.

## Stage 1 — Visual field integration

Implement `VISUAL_FIELD_V0` behind command `0xA1`.

Input is one raster-ordered 8 × 8 field of the eleven payload/status bytes emitted
by `MONO_TEMPORAL_V0`; response markers are not resent. Output is a compact
frame-level vector containing:

1. mean luminance;
2. mean contrast;
3. mean horizontal edge energy;
4. mean rising-diagonal edge energy;
5. mean vertical edge energy;
6. mean falling-diagonal edge energy;
7. signed mean temporal change;
8. signed global horizontal motion;
9. signed global vertical motion;
10. mean motion confidence;
11. signed expansion/contraction evidence;
12. signed rotation evidence;
13. signed horizontal saliency bias;
14. signed vertical saliency bias;
15. mean visual activity;
16. directional-motion consistency.

Tile coordinates are implicit in raster order. Expansion and rotation use centred
integer coordinates, so they require only small signed products and accumulators.
The layer emits evidence, not an object label or collision decision.

Acceptance gates:

- bit-exact RTL/reference agreement for neutral, translating, expanding, rotating,
  and localized-saliency fields;
- backpressure and reset coverage;
- no change to `0xA0` or `0xB0` responses;
- combined physical closure at 50 MHz.

## Stage 2 — Auditory temporal integration

Implement `AUDITORY_FIELD_V0` behind command `0xB1`. It consumes eight consecutive
16 × 8 auditory slots and emits a compact summary of broadband and low/mid/high
energy, spectral centroid and width, onset/offset, persistence, modulation,
confidence-weighted spatial evidence, apparent lateral movement, and novelty.

The first version should operate on `STEREO_FILTERBANK_V0` records rather than add
more PCM-rate arithmetic. This tests the same local-to-global hierarchy as the
visual field integrator.

## Stage 3 — Common reflex record

Define a shared 16- or 32-byte reflex schema for visual, auditory, and later
olfactory summaries. It should carry modality, activity, novelty, location or
bearing, motion, approach/retreat, onset, persistence, confidence, and health.
Detailed dense records remain available in parallel.

## Stage 4 — Olfactory kernel

Implement `NOSE_V0` behind command `0xC0` for nine sensor channels. Retain adaptive
baselines and emit normalized response, derivative, aggregate concentration,
rise/decay/persistence, novelty, fragrance-space coordinates, saturation, and
sensor-health evidence.

## Interface evolution

The TinyTapeout shared byte bus is an experiment harness, not the final board
architecture. A later sensor board should give acquisition engines independently
clocked ingress FIFOs, timestamps, and arbitration onto an internal packet or
stream fabric. Stable command payloads and representations should survive that
transport change.
