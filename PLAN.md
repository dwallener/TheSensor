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
energy, spectral centroid and spread, onset/offset, impulsiveness, modulation,
confidence-weighted spatial evidence, apparent lateral movement, and novelty.

Each input slot contains the 128 feature bytes plus status emitted by one `0xB0`
work unit; the `0x5B` marker is omitted. The proposed 16-byte output is:

1. total mean energy;
2. low-band energy, bands 0–3;
3. mid-band energy, bands 4–11;
4. high-band energy, bands 12–15;
5. energy-weighted spectral centroid;
6. energy-weighted spectral spread about the bank centre;
7. onset activity;
8. offset activity;
9. strongest band;
10. impulsiveness;
11. short-term modulation;
12. confidence-weighted level difference;
13. confidence-weighted phase lead;
14. early-to-late lateral movement;
15. mean stereo confidence;
16. novelty against a slowly adapting per-band baseline.

The first version should operate on `STEREO_FILTERBANK_V0` records rather than add
more PCM-rate arithmetic. This tests the same local-to-global hierarchy as the
visual field integrator.

## Simulation milestone — watch the magic wiggle

Build a deterministic end-to-end simulation harness with two synchronized input
paths:

- an image framebuffer supplying current/previous monochrome frames, tiled through
  `A0` and pooled through `A1`;
- a stereo PCM stream windowed through `B0` and pooled through `B1`.

The harness shall display a shared timeline with raw or downsampled image/audio
context, local feature records, visual translation/expansion/rotation/saliency,
auditory spectrum/onset/spatial movement/novelty, command occupancy, and status.
The primary visual model output is the 16 × 16 × 16 `VisualFrame4096`; the earlier
8 × 8 × 16 `VisualFrame1024` remains available as a compatibility and reflex
representation. Visual processing is capped at 30 frames/s in V0.
Recorded replay must be deterministic. Synthetic scenes should include moving and
looming visual targets, tones, clicks, amplitude modulation, and laterally moving
sound so every major channel has an obvious expected motion.

This simulator is the primary integration target before direct sensor interfaces.
It should support both the fast Python reference models and byte-for-byte RTL
replay, allowing the same dashboard to compare expected and implemented behavior.
The concrete display and replay contract is documented in
[`sim/VIEWER_SPEC.md`](sim/VIEWER_SPEC.md).

## Physical-fit checkpoint

The first four-core 6 × 4 build reached global placement but failed detailed
placement. Synthesis produced 48,700 standard cells and 8,583 flip-flops; the
mapped design occupied 90.8% of the core before repair. B0 accounts for roughly
6,865 flip-flops, so the limiting resource is persistent auditory state rather
than the visual frame representation assembled by the host.

The first conservative experiment keeps the sixteen-band response format but
decimates the B0 input from 48 kHz to 24 kHz and changes its work unit from 256 to
128 samples, retaining a 5.33 ms window and 50% overlap. The canonical B0 sample
is also reduced from signed 16-bit to signed 8-bit PCM, supplied directly in the
required scale. This improves cycle margin and quarters ingress bandwidth. It is
not expected to materially reduce placement area because resonator state is per
band, not per sample. If physical
closure still fails, the next low-disruption area experiment is eight physical
frequency bands; deeper state sharing remains deferred until those measurements
are available.

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
