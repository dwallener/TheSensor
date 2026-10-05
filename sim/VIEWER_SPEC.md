# Perception oscilloscope specification

## Purpose

The visualizer is the primary integration surface for The Sensor. It makes raw
input, local representations, integrated reflex state, timing, health, and
reference/RTL agreement visible on one deterministic timeline. It is both a
perception microscope and a verification instrument, rather than a decorative
dashboard.

## Required views

### Visual path

- The complete current 256 x 256 buffered image, formed by aspect-preserving
  vertical scaling followed by a central square crop, with its 8 x 8 emitted-cell
  grid. A 32 x 32 thumbnail may accompany it but is never the primary display.
- A selectable 16 x 16 primary `VisualFrame4096` map and 8 x 8 pooled
  `VisualFrame1024` compatibility map. The primary map is selected by default.
- Stable replay-wide 99th-percentile display gain for weak natural-image
  responses, with a raw-byte-scale switch and unmodified numeric labels.
- A1 translation, expansion, rotation, saliency, activity, confidence, and
  consistency.
- Status, saturation, and error indications.

### Auditory path

- The synchronized stereo waveform around the selected instant.
- A selectable 8 x 16 B0 time-frequency map.
- Confidence-weighted lateral evidence across the eight input records.
- B1 spectrum, onset, offset, impulse, modulation, lateral motion, confidence,
  and novelty.
- Status, saturation, and error indications.

### Shared timeline

- Play, pause, scrub, speed selection, and single-record stepping.
- Actual visual and auditory centre times, without implying that the two streams
  have the same sample cadence.
- Error, saturation, and reference/RTL mismatch markers.
- One common cursor which selects the nearest record in each modality.

## Replay contract

`THE_SENSOR_REFERENCE_REPLAY_V0` contains:

- metadata describing the replay and sample timing;
- downsampled image and waveform previews for display;
- a compressed full-resolution grayscale frame for the primary visual display;
- 256 fine A0 tile records, a 4,096-byte primary dense vector, 64 pooled
  compatibility-cell records, a 1,024-byte compatibility vector, and one A1
  field record for each visual frame;
- eight B0 filterbank records and one B1 field record for each auditory update;
- an optional `rtl_field` beside a reference field record.

When `rtl_field` is present, the visualizer performs an exact byte comparison,
reports the first mismatch, and marks the corresponding timeline record. Future
recorded-input and RTL runners must emit this same schema so that the display is
independent of the producer.

## Planned increments

1. Synthetic reference replay and synchronized viewer — implemented.
2. Synchronized media adapter for monochrome framebuffers and stereo PCM — implemented.
3. RTL byte-stream replay with reference-versus-RTL differences.
4. Event annotations and end-to-end latency overlays.
5. Session export as deterministic regression fixtures.
