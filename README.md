# The Sensor

**A multi-modal sensory front end for machines that need to perceive and act in the physical world.**

The Sensor sits between raw physical sensors and an intelligent system. It accepts stereo vision, stereo audio, and an electronic nose; extracts useful structure at several timescales; and emits compact, synchronized representations suitable for models, training pipelines, logging, and fast control loops.

This is not intended to be another camera board with a microphone attached. The central idea is that perception has more than one clock.

A looming object may need a response before it has a name. A voice can be localized before the words are understood. A new odor may appear quickly, while its identity and concentration emerge over seconds. Biological systems preserve these different paths instead of forcing every signal through one large, uniform inference pipeline.

The Sensor aims to do the same.

> **Sense continuously. React quickly. Understand over time.**

## Documentation

- [Engineering specification](SPEC.md) — normative requirements and current implementation decisions
- [ASIC protocol and pinout](docs/info.md) — `MONO_TEMPORAL_V0` byte-stream interface

## Current implementation

The first synthesizable target is `MONO_TEMPORAL_V0`: a TinyTapeout/IHP CMOS5L
streaming kernel that turns current and previous 16x16 monochrome tiles into ten
visual features. A host assembles 64 tile results into the first ten channels of
the specified 8x8x16 (1024-byte) visual frame.

The RTL is Verilog 2005. With Icarus Verilog, Verilator, Yosys, and the Python
packages in `test/requirements.txt` installed (activate `.venv` first if using the
repository-local environment):

```sh
make test
make lint
make synth
```

## The problem

Raw sensors produce too much data and too little meaning.

- Two cameras produce redundant streams of pixels.
- Two microphones produce pressure samples with timing information hidden inside them.
- A chemical sensor array produces slow, drifting, cross-sensitive signals rather than neat odor labels.
- General-purpose models should not need to relearn sensor physics, denoising, calibration, and basic motion or onset detection from scratch.

At the same time, reducing every input to a single label throws away the ambiguity, timing, and novelty that make real-world perception useful.

The Sensor therefore produces **representations, not conclusions**: structured evidence that downstream systems can inspect, combine, learn from, and reinterpret.

## Inputs

The initial package has three paired or array-based senses:

| Modality | Physical input | Important native structure |
| --- | --- | --- |
| Vision | Stereo image sensors | Space, motion, edges, disparity, flicker |
| Audition | Stereo microphones | Frequency, onset, rhythm, interaural time and level differences |
| Olfaction | Multi-element electronic nose | Chemical response pattern, concentration, novelty, rise and decay |

Touch is deliberately out of scope for the first version. The architecture should leave room for it without pretending we understand the right interface yet.

## One sensor, several timescales

The fly connectome makes an important fact difficult to ignore: the path from stimulus to action is not singular. Some pathways are short and fast; others integrate, contextualize, and modulate over much longer periods.

The Sensor organizes processing into three timing lanes:

| Lane | Typical latency | Purpose | Example outputs |
| --- | --- | --- | --- |
| **Reflex** | microseconds to milliseconds | Detect urgent change with minimal interpretation | looming, collision vector, sharp onset, acoustic bearing |
| **Percept** | milliseconds to hundreds of milliseconds | Form stable local features and objects of attention | motion field, disparity, spectral peaks, sound source track |
| **Context** | hundreds of milliseconds to minutes | Integrate history, baseline, drift, and cross-modal evidence | scene state, acoustic texture, odor family and persistence |

These are not three copies of the same pipeline. Each lane may use different sampling rates, state, precision, and hardware. A fast path should be allowed to remain simple. A slow path should be allowed to remember.

## Modality pipelines

### Vision

Stereo image streams are transformed into sparse spatial and temporal evidence. Candidate primitives include:

- luminance and local contrast;
- Gabor-like oriented energy at multiple scales;
- Reichardt-style motion correlation and direction selectivity;
- temporal change, flicker, and onset/offset events;
- stereo correspondence, disparity, and confidence;
- looming, expansion, and coarse time-to-contact;
- compact saliency or region proposals.

The goal is not to reproduce a conventional vision accelerator. It is to expose the early computations that are broadly useful before object recognition: what changed, where it moved, how close it may be, and how certain the evidence is.

### Audition

Audio has close analogues to early visual processing, but frequency replaces one spatial axis and precise timing becomes especially valuable.

Candidate primitives include:

- windowed FFT or, preferably, a streaming cochlear-style filter bank;
- log-energy and adaptive noise-floor estimates per frequency band;
- onset, offset, modulation, rhythm, and transient detection;
- interaural time difference (ITD) and interaural level difference (ILD);
- cross-correlation and coarse source bearing;
- harmonicity, spectral centroid, bandwidth, and confidence;
- compact time-frequency events rather than continuous spectrogram images.

The reflex path may report a transient and its direction almost immediately. Slower paths can integrate it into a source track or an acoustic scene description.

### Olfaction

The electronic nose uses a cross-sensitive sensor array. No single element is expected to identify a molecule. Meaning comes from the spatial pattern across the array and its behavior through time.

The initial design assumes a nine-element array mapped into a learned or calibrated odor space, with a fragrance-wheel-style projection available for interpretation.

Candidate primitives include:

- normalized response and baseline-relative change per element;
- response derivative, onset, peak, recovery, and persistence;
- temperature and humidity compensation;
- array pattern embedding and distance from known exemplars;
- odor-family coordinates, concentration estimate, and confidence;
- novelty, mixture change, sensor saturation, and drift indicators.

Olfaction is intrinsically slower than light or sound, but its onset derivative can still support a relatively fast signal: *the chemical environment just changed*. Identification and source tracking belong to slower lanes.

## A common representation bus

Every output should answer the same basic questions:

- **When** was it observed?
- **Which sense and channel** produced it?
- **Where** did it originate, if the modality supports location?
- **What feature** was measured?
- **How strong, novel, and reliable** is the evidence?
- **Over what interval or scale** was it integrated?

The proposed logical unit is a timestamped sensory event:

```text
SensoryEvent {
    timestamp       // monotonic device time
    modality        // vision | audio | olfaction
    lane            // reflex | percept | context
    source          // sensor, eye/ear, channel, or fused source ID
    feature         // stable feature identifier
    location        // optional position, bearing, disparity, or region
    value[]         // scalar or short vector, quantized where practical
    confidence      // quality of this observation
    novelty         // distance from recent expectation or baseline
    duration        // integration window or event lifetime
    calibration_id  // calibration/provenance reference
}
```

This is a semantic contract, not yet a wire format. Hardware may emit fixed-width packets; software may expose tensors, columnar logs, or token-like records. The representation must remain:

- **time-aligned** across modalities;
- **sparse when the world is quiet**;
- **bounded in bandwidth and memory**;
- **explicit about uncertainty and calibration**;
- **reconstructable enough** to debug why an event was emitted;
- **stable enough** to become a training-data interface.

Periodic dense snapshots can complement events when a model needs complete state. A useful downstream input will likely combine an event stream with low-rate modality summaries.

## Making it useful to models

“LLM-ready” does not mean converting every pixel or FFT bin into text.

The board should preserve useful numerical structure and let the consuming model choose its own tokenizer or adapter. Expected output modes include:

1. **Event packets** for online agents and low-latency control.
2. **Synchronized feature tensors** for multimodal model training and inference.
3. **Low-rate summaries** for language-model context and telemetry.
4. **Raw or lightly processed capture windows** triggered around surprising events for debugging and future learning.

The last mode matters. A fixed front end will sometimes be wrong. Retaining short, selectively triggered raw windows allows representations to be audited and improved without recording every sensor continuously.

## Cross-modal processing

The first milestone keeps each modality legible on its own. Once clocks, calibration, and representations are stable, cross-modal circuits can add substantial value:

- visual motion corroborated by an acoustic bearing;
- a tracked object associated with a sound source;
- odor changes correlated with airflow, motion, or location;
- cross-modal novelty when senses disagree;
- attention signals that temporarily increase resolution or retention in another modality.

Fusion should add evidence without erasing provenance. A downstream system must be able to distinguish “the microphones localized something at 20°” from “the fused tracker inferred that the visible object is speaking.”

## Hardware partitioning

The long-term package will likely contain several kinds of compute:

```text
 stereo cameras ─┐
                  ├─> acquisition + timestamping ─> modality front ends ─┐
 stereo mics ─────┤                                                        ├─> event/state bus
                  │                 fast paths ────────────────────────────┤
 9-element nose ──┘                 slow state + calibration ─────────────┘
                                                                            │
                                      host / logger / controller / model <──┘
```

- **TinyTapeout ASIC experiments** can validate small, always-on primitives: filters, correlators, event detectors, feature encoders, arbitration, and packetization.
- **FPGA or programmable logic** can host evolving streaming pipelines and deterministic timing.
- **A microcontroller** can manage sensors, calibration, slow olfactory processing, configuration, and transport.
- **A host interface** can provide recorded datasets, visualization, firmware updates, and model adapters.

TinyTapeout is a proving ground for the computational atoms, not a claim that full stereo vision, audio, and olfaction will fit in one shuttle tile.

## Design principles

1. **Events before frames.** Continuous sampling may happen internally, but unchanged input should not consume full output bandwidth.
2. **Fast paths stay short.** Urgent signals must not wait for high-level interpretation.
3. **Slow paths retain state.** Baselines, adaptation, drift, and context are first-class computations.
4. **Time is part of the data.** All modalities share a clock and expose their integration windows.
5. **Uncertainty survives.** Confidence and sensor health are outputs, not hidden implementation details.
6. **Provenance survives fusion.** Derived features remain traceable to sensors and transforms.
7. **Representations stay learnable.** Hand-designed primitives provide a useful starting point without freezing the final model interface.
8. **Raw evidence is selectively recoverable.** Triggered capture makes the system debuggable and lets future models revisit surprising inputs.
9. **Power and bandwidth are budgets.** The system should spend both in proportion to novelty and task demand.
10. **Every block can be tested alone.** Recorded input and deterministic replay are part of the architecture.

## First build

The first useful system is a development board and software harness, not custom silicon.

### Phase 0 — representation lab

- Define the event schema, clock model, and feature registry.
- Replay recorded stereo video, stereo audio, and nose traces through software reference models.
- Visualize fast and slow outputs on a shared timeline.
- Measure bandwidth, latency, stability, and information loss.

### Phase 1 — live sensor board

- Acquire and timestamp all three modalities from a common clock.
- Implement a minimal feature set for each modality.
- Stream events, periodic state snapshots, and triggered raw windows to a host.
- Build calibration, recording, replay, and inspection tools.

### Phase 2 — hardware acceleration

- Move the highest-rate deterministic blocks into FPGA logic.
- Compare fixed-point implementations against the software reference.
- Establish latency, power, area, and bandwidth budgets from real workloads.

### Phase 3 — TinyTapeout primitives

- Tape out one or more small sensory kernels.
- Exercise them in the live pipeline rather than only with synthetic test vectors.
- Use measured results to decide which always-on functions deserve dedicated silicon.

### Phase 4 — learned adapters and fusion

- Train compact adapters from sensory events and state into model embeddings.
- Evaluate fast-path utility for embodied control.
- Add cross-modal attention and association while retaining per-modality evidence.

## Proposed minimum feature set

An intentionally small vertical slice:

| Modality | Reflex output | Percept output | Context output |
| --- | --- | --- | --- |
| Vision | local change, motion direction, looming | oriented energy, flow, disparity | saliency map, tracked regions, scene motion |
| Audio | transient, band, coarse bearing | band energy, onset tracks, pitch/harmonicity | source tracks, acoustic texture, noise baseline |
| Olfaction | response derivative, novelty | normalized array pattern | odor-space embedding, persistence, baseline/drift |

The success criterion is not classification accuracy. It is whether these outputs let a downstream learner acquire useful behaviors with less data, compute, and latency than raw sensor streams alone.

## Questions we need to answer

- What should the physical and logical sensor interfaces be?
- How much raw history can be buffered around a trigger?
- Which features deserve stable identifiers, and which should remain learned vectors?
- What is the common clock resolution, and how is sensor latency calibrated?
- Where do adaptation and automatic gain control live without hiding meaningful change?
- Which fast signals may directly reach actuators, and what safety envelope governs them?
- What bandwidth and power targets define success?
- Which datasets can test all three modalities with meaningful synchronization?
- How do we evaluate whether a representation is genuinely useful to a downstream model?
- Which primitive is small, novel, and measurable enough for the first TinyTapeout experiment?

## Non-goals, for now

- Building a complete robot brain.
- Performing final object, speech, or odor classification on the board.
- Treating language tokens as the only valid representation.
- Hiding all raw evidence behind opaque learned embeddings.
- Adding touch before the core timing and representation architecture is sound.

## Status

The first visual ASIC kernel has an RTL implementation and bit-accurate test
model. The auditory path now has paired floating-point and proposed ASIC
fixed-point reference models, with a frozen 16-band ERB filter bank and canonical
1024-byte packing. The next implementation step is the time-multiplexed auditory
RTL kernel, followed by combined synthesis and place-and-route.

---

**Working name:** The Sensor  
**Stage:** concept / architecture  
**North star:** a compact sensory layer that gives machines reflexes, perceptions, and context without making them ingest the world from scratch.
