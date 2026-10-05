# The Sensor — Engineering Specification

**Document status:** Draft 0.4

**System status:** Visual and auditory reference RTL implemented; combined physical validation pending

**Scope of this revision:** Stereo visual and auditory acquisition, representation, and early-processing kernels

This document converts the sensory architecture described in the project README into testable engineering requirements. Requirements use **SHALL**, recommendations use **SHOULD**, and options use **MAY**.

# Part I — Visual subsystem

## 1. Decision summary

The visual input SHALL use a **buffered streaming architecture**:

1. Two global-shutter image sensors expose matched frames under a common hardware trigger.
2. Sensor readout is written into a paired, timestamped frame buffer.
3. A stereo pair becomes visible to processing only after both frames are complete and valid.
4. Processing reads the immutable pair as a controlled pixel stream and begins emitting results before that buffered stream finishes.
5. Ping-pong or circular buffering permits the cameras to capture the next pair while the previous pair is processed.

This intentionally adds approximately one sensor readout/frame of latency. In return, sensor timing and processing timing are separated, the two images form an atomic stereo observation, and live input uses the same processing boundary as recorded replay. A future direct sensor-to-reflex tap MAY reduce latency, but it is not part of V0.

```text
 global-shutter pair     atomic stereo pair        controlled pixel stream
┌────────┐  ┌────────┐       ┌──────────────┐       ┌──────────────────────┐
│ left   │  │ right  │──────>│ ping-pong /  │──────>│ reflex + percept +   │
│ sensor │  │ sensor │       │ ring buffer  │       │ context processing   │
└────────┘  └────────┘       └──────────────┘       └──────────────────────┘
       shared trigger             │                         │
                                  └─> triggered raw data    └─> events/state
```

## 2. Goals

The first implementation SHALL:

- acquire two image streams with known relative timing;
- operate at a useful resolution without requiring 1080p;
- process simple features as a completed stereo pair is streamed from memory;
- support deterministic recording and replay;
- emit time-aligned visual events and periodic state;
- retain raw evidence around selected events;
- permit a sensor change without redesigning every downstream processing block;
- be buildable from readily available modules and development hardware.

The first implementation SHOULD optimize for bring-up speed, observability, and iteration rather than maximum resolution or minimum board area.

## 3. Non-goals for the first implementation

- 4K acquisition or processing.
- On-board object classification.
- Photographic image quality or a full image-signal processor.
- Supporting arbitrary camera modules.
- Lossless continuous storage of every frame.
- Performing every visual algorithm without external memory.
- Custom image-sensor packaging or direct attachment of a bare CSP sensor.
- Direct sensor-clock processing or sub-frame sensor-to-event latency.

## 4. Operating modes

The visual subsystem SHALL expose at least three modes.

### 4.1 Live streaming

Both sensors capture under a common trigger and write into the current stereo-pair buffer. When both images are complete and validated, the buffer is committed atomically. Reflex and percept pipelines consume the committed pair as a stream while acquisition proceeds into another buffer.

### 4.2 Recorded replay

Previously captured pixels and timing metadata are driven through the same logical processing boundary as live sensor data. Replay SHALL be deterministic for a fixed configuration.

Replay is a first-class mode, not merely a test convenience. Every hardware transform SHALL have a software reference or recorded-vector test path.

### 4.3 Triggered capture

The system retains a configurable interval before and after a trigger. Triggers MAY originate from:

- visual reflex events;
- auditory or olfactory events;
- a downstream model or host;
- manual debugging controls;
- internal sensor-health faults.

## 5. Initial image envelope

The acquisition and buffered-processing boundaries SHALL initially support 8-bit monochrome samples from a global-shutter sensor.

The minimum useful operating point is:

| Parameter | Minimum target | Preferred first target |
| --- | ---: | ---: |
| Active resolution | 320 × 240 | 640 × 480 |
| Frame rate | 30 fps | 60 fps |
| Cameras | 2 | 2 |
| Sample depth | 8 bits | 8 bits |
| Sensor output | Raw monochrome | Raw monochrome |

The architecture SHOULD scale to 1280 × 800 at 60 fps per camera without changing the logical processing interfaces. Full 1080p is permitted but is not a first-revision requirement.

Representative active-pixel bandwidths are:

| Mode | Per camera | Stereo pair |
| --- | ---: | ---: |
| 640 × 480 × 60 fps × 8 bit | 18.4 MB/s | 36.9 MB/s |
| 1280 × 800 × 60 fps × 8 bit | 61.4 MB/s | 122.9 MB/s |
| 1920 × 1080 × 30 fps × 8 bit | 62.2 MB/s | 124.4 MB/s |

These figures exclude horizontal and vertical blanking, packet overhead, metadata, and memory readback. Internal buses and memories SHALL be budgeted using the sensor's complete timing, not only active pixels.

Buffered streaming transfers every active pixel at least twice: once from capture into memory and once from memory into processing. Ignoring overhead, the external-memory traffic is therefore at least 73.7 MB/s for stereo VGA/60, 245.8 MB/s for stereo 1280 × 800/60, and 248.8 MB/s for stereo 1080p/30. Trigger retention, stereo algorithms, display, and host export add further reads or writes. The memory controller SHALL be sized from the sum of concurrent traffic with explicit margin.

## 6. Sensor interface

### 6.1 Preferred first electrical interface

The first FPGA-facing implementation SHOULD use an 8-bit CMOS/DVP-style parallel interface where a suitable module exposes it:

- pixel clock;
- 8 data bits;
- frame-valid or vertical-sync;
- line-valid, horizontal-reference, or horizontal-sync;
- external sensor clock;
- I²C or SCCB control;
- reset and power-down;
- frame-sync or exposure-trigger input when available.

The parallel interface consumes more pins than MIPI CSI-2, but is easier to probe, generate, receive, and debug. It also avoids making a MIPI D-PHY and CSI-2 receiver a prerequisite for the first sensory experiments.

### 6.2 MIPI CSI-2

MIPI CSI-2 MAY be used for a development carrier with a proven receiver and driver stack. A custom MIPI receiver is out of scope for the first capture implementation.

If the selected sensor module exposes only MIPI, the receiver SHALL provide the same internal signals as the parallel capture block: sample, sample-valid, line boundary, frame boundary, camera identifier, error flags, and timestamp association.

### 6.3 Buffered pixel-stream contract

Downstream processing SHALL not depend on the physical camera bus or its pixel clock. The buffer reader SHALL convert a committed stereo pair into a logical stream containing at least:

```text
PixelSample {
    camera_id
    frame_id
    x
    y
    value
    valid
    start_of_line
    end_of_line
    start_of_frame
    end_of_frame
    timestamp
    stereo_pair_id
    error_flags
}
```

Coordinates and control fields MAY be represented as sideband signals rather than repeated in every physical word. The reader SHALL support pause, deterministic restart, and a processing clock independent of the sensor pixel clock.

## 7. Stereo synchronization

The two cameras SHALL be treated as one timed instrument.

- Both sensors SHALL derive their timebase from the same oscillator or from characterized related clocks.
- Both sensors SHALL accept the same hardware frame-sync or exposure-trigger signal.
- Exposure start, exposure duration, readout start, and frame identity SHALL be recorded or derivable.
- The left and right frames in a pair SHALL carry the same stereo-pair identifier.
- Dropped, repeated, corrupt, or mismatched frames SHALL be reported rather than silently paired.
- Automatic exposure and gain SHALL be lockable or jointly controlled.
- Mechanical mounting SHALL be rigid and calibration SHALL be versioned.

A global shutter is required for the stereo reference platform. A rolling-shutter sensor MAY be used only for isolated interface bring-up; data from it SHALL not be used to qualify motion, looming, optical-flow, or stereo behavior.

Software-started cameras without a shared hardware timing signal do not satisfy the final stereo synchronization requirement.

## 8. Streaming processing

### 8.1 Commit, then stream

Acquisition SHALL first commit a complete, valid stereo pair. The buffer reader SHALL then fan out a controlled stream without serializing the processing lanes:

- the reflex path consumes the current buffered pixel or line neighborhood;
- the percept path consumes line, tile, and optional frame context;
- the context path consumes feature history and optional additional frames;
- the trigger-retention manager protects selected raw buffers from overwrite.

The acquisition writer and processing reader SHALL use separate buffer ownership. Neither may access a buffer owned by the other. If processing cannot release buffers before acquisition requires them, the system SHALL expose overflow and loss rather than overwrite unread data or silently distort coordinates and timing.

### 8.2 Pixel and line operations

The first streaming pipeline SHOULD support:

- black-level or fixed-offset correction;
- optional bad-pixel masking;
- luminance normalization or local contrast;
- temporal difference against prior state;
- separable or small-kernel spatial filters;
- oriented-energy approximations;
- local motion correlation;
- thresholding, aggregation, and event generation.

Only the state necessary for the selected operation should be retained. A 3 × 3 spatial kernel, for example, requires line buffers rather than a complete frame buffer.

### 8.3 Tile operations

The active image SHALL be divisible into configurable tiles. Tile accumulation SHOULD produce:

- change energy;
- oriented energy;
- direction-selective motion energy;
- mean and variance;
- saturation or invalid-pixel counts;
- novelty relative to recent tile state.

The initial default tile size is provisional. Implementations SHOULD support at least 8 × 8 and 16 × 16 active pixels.

### 8.4 Frame and stereo operations

Every V0 algorithm receives a complete buffered stereo pair, but MAY retain additional pair-level state when its data dependency requires it. Initial examples are:

- rectification;
- stereo correspondence and disparity;
- global motion estimation;
- large-window optical flow;
- calibration and sensor-health analysis.

An algorithm SHALL be able to emit a reflex result before the buffered pair has been completely streamed through the processing fabric.

## 9. Latency lanes

Processing latency is measured from the start of buffered-pair replay. End-to-end latency is measured from the shared exposure trigger. Both SHALL be reported.

| Lane | Initial latency target | Examples |
| --- | --- | --- |
| Reflex | no more than two processing line times after its required buffered pixels are replayed | local change, direction, looming evidence |
| Percept | before the next committed pair must be processed | oriented map, local flow, disparity |
| Context | configurable; one frame to seconds | saliency history, tracks, scene motion |

End-to-end latency reports SHALL separately identify exposure, sensor readout, buffer commit, processing, queueing, and transport delays. V0 accepts the buffer-commit delay explicitly; a low replay-processing latency does not erase it.

## 10. Buffering and memory

The system distinguishes five kinds of storage:

1. **Pipeline registers** for arithmetic stages.
2. **Line buffers** for local spatial neighborhoods.
3. **Feature state** for temporal filters, motion, and adaptation.
4. **Acquisition buffers** for atomic stereo-pair handoff.
5. **Raw circular storage** for triggered capture and longer history.

At 8-bit monochrome, one stereo pair occupies:

- 614,400 bytes at 640 × 480;
- 2,048,000 bytes at 1280 × 800;
- 4,147,200 bytes at 1920 × 1080.

The acquisition-buffer capacity alone is therefore 1.23 MB for two VGA stereo-pair buffers or 4.10 MB for two 1280 × 800 stereo-pair buffers. A recommended third buffer raises those figures to 1.84 MB and 6.14 MB respectively.

On-chip memory SHOULD be reserved for deterministic pipeline and line-buffer state. External SRAM, PSRAM, SDRAM, or host memory SHOULD hold acquisition pairs and multi-frame raw retention.

The first hardware SHALL provide at least two complete stereo-pair buffers: one available to acquisition and one available to processing. A third buffer is strongly recommended to absorb timing variation. The target triggered-capture implementation SHOULD retain at least two pre-trigger and two post-trigger stereo pairs at the configured operating resolution.

## 11. Frame metadata

Each captured frame SHALL be associated with:

- device time at exposure or frame-sync;
- camera identifier and frame number;
- stereo-pair identifier;
- active width, height, crop, binning, and bit depth;
- exposure time and analogue/digital gain;
- sensor clock and nominal frame period;
- temperature, when available;
- calibration identifier;
- dropped-line, overflow, synchronization, and transport errors;
- the configuration version used by streaming transforms.

Sensor register changes affecting interpretation SHALL take effect at a known frame boundary and be reflected in metadata.

## 12. Visual outputs

The visual subsystem SHALL be able to emit:

- sparse reflex events;
- tile or region feature records;
- low-rate dense state maps;
- stereo disparity with confidence;
- sensor-health and synchronization events;
- triggered raw or lightly corrected image windows.

Outputs SHALL use the common `SensoryEvent` semantics described in the README. Visual locations SHALL declare their coordinate space: raw sensor, rectified left image, rectified right image, normalized image, bearing, or estimated 3D coordinates.

## 13. Candidate image sensors

Sensor choice is deliberately separated from the internal pixel-stream contract. The following candidates are suitable for early work as of 2026-10-04; prices and availability are snapshots, not guarantees.

### 13.1 Himax HM0360 — fastest path to a parallel prototype

**Recommended use:** low-cost electrical-interface experiments only.

- 640 × 480 at up to 60 fps.
- Monochrome and Bayer variants.
- 8-bit, 4-bit, and 1-bit CMOS-level video modes plus one-lane MIPI CSI-2.
- External frame synchronization and stereo-camera support.
- Very low power: the manufacturer specifies approximately 7 mA at VGA 60 fps.
- Available as compact camera modules with lens and FPC, avoiding direct CSP assembly.
- The HM0360-AWA device was listed active and in stock at DigiKey at approximately US$6.65 in October 2026.

The decisive reservation is shutter behavior: Himax's public product page does not advertise a global shutter. It SHALL be treated as a rolling-shutter device until module-specific documentation proves otherwise. Under the V0 global-shutter decision, HM0360 is no longer a candidate for the stereo reference platform, though it remains a convenient source for validating a parallel electrical interface.

References: [Himax HM0360 product page](https://www.himax.com.tw/products/cmos-image-sensor/always-on-vision-sensors/hm0360/), [HM0360 compact-module drawing](https://media.digikey.com/pdf/Data%20Sheets/Himax%20PDFs/HM0360-MWA-00FW703.pdf), [DigiKey image-sensor listing](https://www.digikey.com/en/products/filter/optical-sensors/image-sensors-camera/532)

### 13.2 OmniVision OV9281 — preferred stereo and motion sensor

**Recommended use:** serious stereo, motion, looming, and eventual integrated board.

- Monochrome 1280 × 800 global shutter.
- Up to 120 fps at full resolution and 180 fps at VGA.
- 8-bit or 10-bit raw output.
- DVP parallel and two-lane MIPI output variants/modes.
- Hardware frame synchronization, region of interest, binning, and subsampling.
- Strong near-infrared sensitivity.
- Listed by OmniVision as being in volume production.
- Complete MIPI camera modules are broadly available; representative Arducam modules were approximately US$30–36 in October 2026.

This is the best architectural fit. The complication is practical: common hobbyist modules expose MIPI, while the DVP capability may require sourcing a less common module or designing a sensor carrier. The complete register-level datasheet and module pinout SHALL be obtained before committing a custom PCB.

References: [OmniVision OV9281 product page](https://www.ovt.com/products/ov9281/), [OV9281 product brief](https://www.ovt.com/wp-content/uploads/2024/05/OV9281-PB-v1.4-WEB.pdf), [Arducam OV9281 module documentation](https://docs.arducam.com/Raspberry-Pi-Camera/Native-camera/Global-Shutter/1MP-OV9281-OV9282/)

### 13.3 OmniVision OV5640 — inexpensive compatibility fallback

**Recommended use:** throwaway interface bring-up or situations where modules are already on hand.

- 5-megapixel rolling-shutter color sensor.
- 1080p at 30 fps or 720p at 60 fps.
- Parallel DVP and two-lane MIPI interfaces.
- Numerous inexpensive modules and extensive community examples.
- Integrated image-processing features can provide convenient formatted output.

The OV5640 is not the reference sensor for motion-sensitive stereo. Rolling shutter, independent automatic exposure, color processing, and uncertain module-level synchronization can create false motion and disparity. If used, the pipeline SHOULD select a raw or minimally processed monochrome/luma representation and lock exposure settings where possible.

References: [OmniVision OV5640 announcement and interface summary](https://www.ovt.com/wp-content/uploads/2021/01/OV5640_PressRelease_Final.pdf), [Waveshare OV5640 DVP module](https://www.waveshare.com/product/modules/cameras-audio-video/cameras/ov5640-camera-board-a.htm)

### 13.4 Provisional selection

The V0 stereo reference sensor SHALL be the **OV9281**, subject to obtaining the complete register documentation and either:

1. two DVP modules exposing common frame synchronization; or
2. a proven dual-camera MIPI receiver platform with hardware synchronization.

HM0360 or OV5640 modules MAY be used to bring up a capture interface already in hand, but buying them is not a prerequisite and their output does not satisfy V0 visual acceptance tests.

## 14. Bring-up sequence

### Stage A — software reference

- Record synchronized or approximately synchronized stereo video.
- Commit complete stereo pairs to memory, then feed them into the reference pipeline one line at a time.
- Define pixel, line, frame, and event interfaces.
- Quantify feature latency and output bandwidth.

### Stage B — single live camera

- Configure one module over I²C/SCCB.
- Capture its pixel, line, and frame signals.
- Verify coordinates and timing with test charts and a logic analyzer.
- Compare live output against recorded replay.

### Stage C — synchronized stereo

- Drive both sensors from a common timing source.
- Write paired frames into ping-pong buffers and detect all mismatch conditions.
- Lock exposure and gain.
- Calibrate intrinsics, distortion, rotation, and baseline.

### Stage D — buffered streaming and retention

- Process one committed pair as a stream while the next pair is captured into another buffer.
- Demonstrate correct buffer ownership and loss reporting under memory congestion.
- Trigger a retained raw window from a visual event.
- Reproduce the event through deterministic replay.

## 15. Initial acceptance tests

The first visual vertical slice is complete when it can demonstrate all of the following:

1. Two live cameras produce correctly paired 640 × 480 monochrome frames at 30 fps or better.
2. Frame pairing remains correct for at least one hour, or every mismatch is detected and reported.
3. A moving high-contrast target produces a direction-selective event before the committed stereo pair has been completely replayed from memory.
4. A looming target produces increasing expansion evidence with timestamps and confidence.
5. Raw stereo images from immediately before and after the event are retained.
6. Replaying the retained input produces bit-identical fixed-point features for a fixed configuration.
7. Disconnecting or corrupting one sensor produces a health event and never silently pairs unrelated frames.
8. Exposure, calibration, configuration, and timing metadata are recoverable for every retained frame.

## 16. Open decisions

- FPGA or programmable-logic platform for the first capture pipeline.
- Exact camera connector and pinout.
- OV9281 DVP module source versus an existing CSI-2 receiver platform.
- Initial lens field of view, focus range, and stereo baseline.
- External-memory technology and triggered-history duration.
- Whether the first stereo algorithm runs in FPGA logic or host software.
- Coordinate precision and fixed-point formats for visual events.
- Whether raw Bayer support is worth carrying before color becomes a requirement.

## 17. Current recommendation

Build V0 around synchronized **OV9281 global-shutter cameras**, atomic stereo-pair buffers, and an **8-bit buffered pixel-stream contract** independent of the camera connector. Begin at VGA resolution and 30–60 fps. Use at least two stereo-pair buffers so acquisition and processing can run concurrently without sharing ownership.

This adds a deliberate frame of latency. It also gives the first physical implementation deterministic stereo, uncomplicated replay, clean clock-domain separation, and a processing pipeline that can run faster or slower than sensor readout. A direct sensor-to-reflex path remains a possible V1 optimization after the representation and algorithms are proven.

---

# Part II — Auditory subsystem

## 18. Auditory decision summary

V0 SHALL use **two identical digital MEMS microphones with PCM output over I²S**, sharing the same bit clock and word-select clock.

A digital MEMS microphone contains the acoustic transducer, analogue front end, ADC, decimation, and anti-alias filtering. The board therefore receives signed PCM samples rather than an analogue microphone voltage. No separate audio codec or ADC is required.

```text
                              shared BCLK + WS
                                     │
                         ┌───────────┴───────────┐
                         │                       │
                    ┌─────────┐             ┌─────────┐
sound ─────────────>│ left mic│             │right mic│<───────────── sound
                    │ ADC/I²S │             │ ADC/I²S │
                    └────┬────┘             └────┬────┘
                         └──────────┬────────────┘
                                    v
                         synchronized PCM capture
                                    │
                         block/ring buffer + timestamps
                                    │
                         controlled sample-stream replay
                         ┌──────────┼──────────┐
                         v          v          v
                       reflex     percept    context
```

V0 intentionally uses small buffered sample blocks rather than processing directly from the I²S pins. This creates the same deterministic live/replay boundary as vision while adding only a few milliseconds of latency. A future sample-direct onset path MAY bypass block commit.

PDM microphones and analogue microphones with a stereo ADC remain valid alternatives, but they add work that does not advance the first representation experiments:

- PDM requires matched decimation filters before ordinary audio processing.
- Analogue microphones require biasing, amplification, anti-alias filtering, and a simultaneous stereo ADC or codec.
- I²S microphones deliver usable synchronized PCM with the fewest new analogue and DSP variables.

## 19. What matters, and what does not yet matter

V0 is not an audio recorder and is not evaluated on subjective sound quality.

The following are low priority:

- perfectly flat frequency response;
- very low self-noise;
- music-grade dynamic range;
- high-fidelity reconstruction;
- sample rates above 48 kHz;
- 24 useful bits of amplitude resolution.

The following remain functional requirements:

- both microphones sample from the same clock;
- relative channel delay is fixed and measurable;
- neither channel uses independent automatic gain control;
- clipping and disconnection are detectable;
- microphone sensitivity and phase mismatch can be calibrated;
- sample loss is detected rather than silently shifting channel alignment;
- the microphone geometry is rigid and versioned;
- captured samples carry a stable relationship to the common device clock.

Poor frequency response changes the character of a spectrum. Unknown or changing inter-channel delay destroys localization. V0 accepts the former and does not accept the latter.

## 20. Audio input envelope

The preferred operating point is:

| Parameter | V0 value | Notes |
| --- | ---: | --- |
| Microphones | 2 | Identical part and mounting |
| Sample rate | 48,000 samples/s/channel | 16 kHz MAY be used for reduced-rate tests |
| Bus format | I²S | Microphones are slaves; FPGA/MCU is clock master |
| Slot width | 32 bits | Conventional stereo I²S framing |
| Delivered sample | 24-bit signed PCM | Effective precision may be lower |
| Processing sample | 16, 18, 24, or 32-bit signed | Fixed by each transform's numerical needs |
| Channels | Left and right | No independent AGC |
| Initial block | 256 samples/channel | 5.33 ms at 48 kHz |
| Initial hop | 128 samples/channel | 2.67 ms with 50% overlap |

At 48 kHz with two 32-bit stored channels, raw PCM occupies 384,000 bytes/s. Packed 24-bit stereo occupies 288,000 bytes/s and 16-bit stereo occupies 192,000 bytes/s. Even several seconds of raw history are inexpensive compared with a single stereo image pair.

The FPGA or MCU SHOULD generate a 3.072 MHz I²S bit clock for 48 kHz stereo with two 32-bit slots:

```text
48,000 samples/s × 2 channels × 32 bits = 3.072 MHz
```

The exact microphone's allowed clock range SHALL be checked before hardware selection.

## 21. I²S electrical and logical interface

### 21.1 Signals

The V0 interface SHALL contain:

- `BCLK` or `SCK`: bit clock generated by the capture device;
- `WS` or `LRCLK`: left/right word-select generated by the capture device;
- one shared `SD` line or two separate microphone data lines;
- microphone power, ground, and local decoupling;
- left/right channel-select strapping when supported;
- optional independent microphone power enables for fault isolation.

Two microphones MAY share one data line when the selected parts explicitly tri-state their output during the opposite channel slot. Separate data lines are easier to probe and isolate and are therefore preferred for the first custom board unless pin pressure dictates otherwise.

### 21.2 Clocking

The capture device SHALL be the I²S clock master. Both microphones SHALL receive the same `BCLK` and `WS` signals from matched or characterized board routes.

The audio sample clock SHOULD be derived from the same board reference oscillator used by the visual and system timebases. If it is generated by a separate oscillator or PLL, its relationship to monotonic device time SHALL be measured continuously or characterized well enough to bound drift.

Stopping and restarting audio clocks MAY place microphones into a sleep state. The resulting startup delay and invalid samples SHALL be represented explicitly; they SHALL NOT be emitted as environmental silence.

### 21.3 Sample decoding

The I²S receiver SHALL:

- support the selected part's one-bit I²S word-select delay;
- sign-extend samples correctly;
- retain left/right identity through all buffers;
- count every sample position, including invalid positions;
- detect missing clocks, stuck data, framing errors, and buffer overflow;
- associate sample zero with a device timestamp;
- avoid any unreported resampling or per-channel filtering.

The raw capture format SHOULD preserve samples in signed 32-bit containers even if only 18 or 24 bits are meaningful. Individual processing blocks MAY use narrower fixed-point representations after their error is characterized.

## 22. Audio block and stream contract

The capture layer SHALL commit synchronized audio blocks containing equal sample counts from both channels.

```text
AudioBlock {
    block_id
    first_sample_index
    first_sample_timestamp
    sample_rate
    sample_count
    left_samples[]
    right_samples[]
    valid_mask
    overrange_flags
    clock_status
    calibration_id
    configuration_id
}
```

The first-sample index SHALL be monotonically increasing across block boundaries. A missing sample SHALL create an explicit discontinuity; the receiver SHALL NOT conceal it by shifting later data.

The block reader SHALL be able to replay samples at the native rate, faster than real time, single-step, pause, and restart deterministically. Transform output SHALL be identical for live and recorded blocks with identical state and configuration.

## 23. Buffering

V0 SHALL use at least:

1. one audio block being filled by I²S capture;
2. one committed block available to processing;
3. a circular raw PCM history buffer;
4. transform state spanning block boundaries.

Three or more small capture blocks are recommended so brief processing stalls do not immediately lose samples. Buffer ownership SHALL be explicit, as with visual stereo-pair buffers.

The raw ring SHOULD initially retain at least five seconds of stereo audio. At signed 32-bit stereo and 48 kHz this requires approximately 1.92 MB. A trigger SHOULD protect configurable pre-trigger and post-trigger intervals without stopping ongoing capture.

Processing overlap is a reader behavior, not duplicated acquisition. A 256-sample committed block MAY be combined with 128 samples of retained history to produce overlapping 256-sample analysis windows with a 128-sample hop.

## 24. Microphone geometry and calibration

The microphones SHALL be mounted rigidly with a known acoustic-center separation and orientation.

The initial baseline SHOULD be between 60 mm and 120 mm. At an assumed speed of sound of 343 m/s, the largest broadside time difference is approximately:

| Baseline | Maximum interaural delay | Samples at 48 kHz |
| ---: | ---: | ---: |
| 60 mm | 175 µs | 8.4 samples |
| 100 mm | 292 µs | 14.0 samples |
| 120 mm | 350 µs | 16.8 samples |

This is why 48 kHz is useful even when speech bandwidth alone would permit 16 kHz: it provides finer native delay resolution for bearing estimates.

Calibration SHALL be able to represent:

- physical microphone coordinates;
- fixed relative sample delay;
- relative gain versus frequency or a simpler banded approximation;
- polarity;
- acoustic obstruction introduced by the enclosure;
- temperature used for the assumed speed of sound, when available;
- calibration version and date.

Automatic gain, if later required, SHALL be common to both channels or SHALL expose its exact per-channel gain history. Independent hidden AGC is prohibited.

## 25. Auditory timing lanes

| Lane | Integration scale | Initial outputs |
| --- | ---: | --- |
| Reflex | 2.7–10 ms | onset, impulsive energy, clipping, coarse left/right bias |
| Percept | 10–100 ms | filter-bank energy, spectral peaks, ITD, ILD, coarse bearing, periodicity |
| Context | 100 ms–seconds | noise floor, acoustic texture, modulation, persistent source tracks |

V0 accepts one block of acquisition latency. With a 256-sample block at 48 kHz, block commit occurs every 5.33 ms. The reflex pipeline SHOULD produce an onset or impulsive-energy event within one additional 128-sample hop after the relevant block is committed.

Latency reports SHALL separate:

- physical microphone and internal conversion/filter delay;
- block-fill delay;
- processing-window accumulation;
- transform delay;
- event queueing and transport.

## 26. Auditory processing

### 26.1 Capture conditioning

The initial pipeline SHOULD implement:

- DC removal or a simple high-pass filter;
- optional common gain or fixed scaling;
- saturation, stuck-bit, and silence detection;
- short-window energy and peak amplitude;
- a slowly adapting per-channel noise-floor estimate.

Any conditioning used before stereo localization SHALL be identical between channels or have calibrated matched phase and gain.

### 26.2 Time-domain reflex features

The reflex lane SHOULD support:

- energy derivative and onset;
- impulsiveness or crest factor;
- zero-crossing rate;
- broad-band left/right correlation;
- coarse interaural time difference;
- coarse interaural level difference;
- confidence based on signal energy and correlation sharpness.

An onset detector SHOULD emit sparse events rather than a continuous amplitude stream when the acoustic environment is stable.

### 26.3 Frequency-domain percept features

V0 MAY implement either a streaming filter bank or a windowed FFT. The reference implementation SHOULD begin with a 256- or 512-point real FFT using 50% overlap.

Candidate outputs include:

- log energy in a small fixed set of bands;
- spectral centroid and bandwidth;
- dominant spectral peaks;
- spectral flux and onset strength;
- harmonicity or periodicity confidence;
- modulation energy over slower windows;
- per-band left/right level and phase differences.

The first implementation does not need a high-resolution spectrogram. A small number of stable bands or sparse peaks is more consistent with the representation bandwidth goal.

### 26.4 Localization

V0 SHOULD estimate sound bearing from some combination of:

- time-domain cross-correlation;
- generalized cross-correlation with phase transform (GCC-PHAT);
- interaural time difference (ITD);
- interaural level difference (ILD).

Localization output SHALL include confidence and SHALL remain uncommitted when correlation is weak, reverberant, multi-modal, or inconsistent across frequency bands. Two microphones provide a bearing ambiguity rather than a unique 3D source position; the representation SHALL not overstate what was measured.

## 27. Auditory outputs

The auditory subsystem SHALL be able to emit:

- onset and offset events;
- short-window energy and novelty;
- frequency-band energy or sparse spectral peaks;
- ITD in seconds and fractional samples;
- ILD in decibels;
- coarse bearing or left/right sector with confidence;
- periodicity, pitch candidate, or harmonicity confidence;
- noise-floor and acoustic-texture state;
- clipping, clock, disconnection, and synchronization health events;
- triggered raw PCM windows.

Auditory `SensoryEvent` locations SHALL declare whether they express array-relative bearing, left/right sector, or an associated fused source. Feature records SHALL carry their integration window and centre timestamp.

## 28. Candidate microphone approaches

Candidate status and availability in this section are snapshots as of 2026-10-04.

### 28.1 PUI Audio DMM-4026-B-I2S-R — provisional V0 microphone

**Recommended use:** first custom board and simple breakout-board prototype.

- Digital I²S output with 24-bit samples, 18-bit precision, and 32-bit word slots.
- Operates from 1.5 V to 3.6 V.
- Accepts 2.048–4.096 MHz input clock, which includes the proposed 3.072 MHz clock.
- No external codec or PDM decimator is required.
- Active and broadly stocked through distribution; DigiKey listed approximately 4,700 units at US$3.36 each in October 2026.
- A small evaluation breakout is available for rapid wiring and capture testing.

This part is acoustically more than adequate. More importantly, its interface matches the simplest V0 capture architecture. The project SHALL validate whether two chosen boards or devices can share one I²S data line without contention; otherwise each microphone SHALL use its own data input.

References: [PUI Audio product page](https://puiaudio.com/product/microphones/dmm-4026-b-i2s-r), [PUI Audio datasheet](https://puiaudio.com/file/specs-DMM-4026-B-I2S-R.pdf), [PUI evaluation-board datasheet](https://api.puiaudio.com/filename/DMM-4026-B-I2S-EB-R.pdf), [DigiKey listing](https://www.digikey.com/en/products/detail/pui-audio-inc/DMM-4026-B-I2S-R/11587534)

### 28.2 Knowles SPH0645LM4H-B — I²S-compatible alternative

**Recommended use:** breakout-board experiments or an interface-compatible alternate after lifecycle verification.

- Digital I²S PCM output.
- Internal ADC, decimation, and low-pass filtering.
- Two microphones can share clocks and one data line using opposite channel-select settings.
- Established hobbyist breakout ecosystem.

The interface is a strong fit, but supply and lifecycle SHALL be checked before a production design is committed.

References: [Knowles SPH0645LM4H-B datasheet](https://www.knowles.com/docs/default-source/model-downloads/sph0645lm4h-b-datasheet-rev-c.pdf), [Knowles digital microphone design guide](https://www.knowles.com/docs/default-source/default-document-library/sisonic-design-guide.pdf)

### 28.3 Infineon IM69D130 — PDM alternative

**Recommended use:** evaluating PDM capture, matched-array behavior, or a ready-made two-microphone development board.

- One-bit PDM output from an integrated sigma-delta ADC.
- Tight sensitivity and phase matching intended for microphone arrays.
- Infineon offers a two-microphone Shield2Go board with stereo configuration and PDM/I²S board-level output options.

The microphone's acoustic performance exceeds V0 needs. Its raw PDM output requires clock generation and matched decimation, making it a useful second architecture but not the shortest custom-logic path.

References: [Infineon IM69D130 datasheet](https://www.infineon.com/assets/row/public/documents/24/49/infineon-im69d130-datasheet-en.pdf), [Infineon stereo evaluation board](https://www.infineon.com/evaluation-board/S2GO-MEMSMIC-IM69D)

### 28.4 Parts to avoid for a new production design

Popular examples and tutorials frequently use the TDK/InvenSense ICS-43434 I²S microphone and ST MP34DT06J PDM microphone. Their manufacturers currently identify them as EOL and obsolete/out of production respectively. Existing breakout boards MAY be used for experiments, but V0 SHALL NOT depend on either part.

References: [TDK ICS-43434 status](https://www.invensense.tdk.com/en-us/products/microphone/ics-43434), [ST MP34DT06J status](https://www.st.com/content/st_com/en/products/mems-and-sensors/mems-microphones/mp34dt06j.html)

## 29. Auditory bring-up sequence

### Stage A — generated and recorded PCM

- Define `AudioBlock`, sample counters, timestamps, and fixed-point conventions.
- Replay generated impulses, tones, chirps, noise, and delayed stereo pairs.
- Verify onset, spectrum, cross-correlation, ITD, and confidence calculations.
- Establish live/replay bit identity for fixed-point transforms.

### Stage B — one live microphone

- Generate I²S clocks and capture signed samples.
- Verify word alignment, polarity, silence level, clipping, and startup behavior.
- Record raw blocks and replay them through the same processing boundary.

### Stage C — synchronized stereo

- Attach two microphones to the shared clocks.
- Verify stable left/right identity and sample alignment.
- Measure fixed channel delay and gain mismatch with a centred source.
- Confirm that a missing or stalled channel produces a health event.

### Stage D — spatial features and triggered history

- Detect a transient and retain surrounding stereo PCM.
- Estimate left/right bearing for sources at several known angles.
- Compare time-domain and frequency-domain localization confidence.
- Associate audio timestamps with visual stereo-pair timestamps.

## 30. Auditory acceptance tests

The first auditory vertical slice is complete when it demonstrates all of the following:

1. Two microphones produce uninterrupted, correctly identified 48 kHz channels for at least one hour, or every discontinuity is detected.
2. A shared acoustic impulse appears in both channels with stable calibrated relative delay.
3. An onset event is emitted within one processing hop after its source block is committed.
4. Pure tones at several frequencies appear in the expected FFT or filter-bank bands.
5. A source moved from left through centre to right produces the expected signed ITD or bearing trend.
6. Five seconds of stereo history can be retained and protected around a trigger.
7. Recorded replay produces bit-identical fixed-point features for fixed state and configuration.
8. Clock removal, microphone disconnection, stuck data, clipping, and buffer overflow produce explicit health events.
9. Audio events can be placed on the same device timeline as visual exposure timestamps.

## 31. Auditory open decisions

- Exact microphone spacing and its relationship to the camera baseline.
- One shared I²S data wire versus separate data wires.
- Whether the first board stores 16-, 24-, or 32-bit PCM in external memory.
- FPGA versus MCU ownership of I²S capture and block formation.
- Exact coefficient set and state width for the selected 16-band ASIC filter bank.
- Whether GCC-PHAT belongs in FPGA logic or host/reference software initially.
- Required raw-history duration and cross-modal trigger policy.
- Temperature source for speed-of-sound correction.

## 32. Current auditory recommendation

Prototype with **two PUI DMM-4026-B-I2S evaluation boards or equivalent modules**, driven from one 3.072 MHz bit clock and one 48 kHz word-select clock. Capture signed PCM into 256-sample stereo blocks, retain raw samples in a five-second ring, and replay committed blocks into onset, spectral, and localization pipelines with a 128-sample hop.

This is intentionally ordinary digital audio plumbing. The canonical dense
representation and first ASIC experiment are specified in Part IV; recorded PCM
remains the reference evidence used to evaluate them.

---

# Part III — Visual processing and representation

## 33. Representation decision

The canonical per-frame output SHALL be a **fixed 8 × 8 spatial grid with 16 feature channels per grid cell**:

```text
8 × 8 × 16 = 1024 activation values per visual frame
```

The grid is retinotopic: every `(x, y)` cell always refers to the same calibrated region of the field of view. The channel axis contains outputs from several processing stages, including local appearance, oriented energy, temporal change, motion, stereo, grouping, looming, and salience. Flattening the tensor produces a stable 1024-dimensional vector; reshaping it restores the visual field.

```text
buffered stereo frames
          │
          v
  calibrated tile scheduler
          │
          v
 local feature transform ─────> fine intermediate feature maps
                                           │
                                spatial/temporal pooling
                                           │
                                           v
                                  8 × 8 × 16 tensor
                                     │         │
                                     │         └─> optional sparse events
                                     v
                         flatten to 1024-d model input
```

This answers the central representation question:

> The output is a fixed grid of visual “hypercolumns.” Each grid cell contains the same 16 measurements, and each channel viewed across the grid forms an 8 × 8 activity map.

The representation SHALL preserve:

- spatial topology;
- frame and exposure time;
- stable channel identity and receptive-field scale;
- signed direction or polarity;
- magnitude;
- confidence and ambiguity;
- source provenance;
- enough validity and health information to distinguish a quiet scene from a dead or disconnected sensor.

## 34. TinyTapeout design envelope

The V0 ASIC experiment assumes the same envelope as the Jane Street ASIC challenge:

- IHP 130 nm CMOS5L process;
- TinyTapeout CMOS5L Verilog template;
- maximum 6 × 4 tile allocation;
- approximately 1,000 logic cells per tile as a rough early estimate, before placement and routing overhead;
- 8 dedicated inputs, 8 dedicated outputs, and 8 bidirectional pins, in addition to clock, reset, and enable;
- 50 MHz design target until physical results justify another value;
- open-source RTL, verification, and build inputs.

References: [Jane Street competition rules](https://blog.janestreet.com/protocol-emulator-asic-competition/), [TinyTapeout IHP Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template)

These constraints make several architectural consequences non-negotiable:

- Full stereo frames SHALL remain off-chip.
- V0 SHALL NOT require an on-chip frame buffer.
- Large line buffers SHOULD remain off-chip unless synthesis proves a specific buffer affordable.
- The chip SHALL accept byte-serial work units from an external controller.
- The chip SHALL emit byte-serial state records and tokens.
- The feature arithmetic SHALL be fixed-point and deterministic.
- Synthesis, placement, routing, and timing—not a spreadsheet gate estimate—are the final authority on what fits.

## 35. System and ASIC partition

### 35.1 Off-chip responsibilities

The FPGA, MCU, or host-side acquisition system SHALL initially own:

- image-sensor configuration and shared exposure trigger;
- stereo-pair buffering and ownership;
- bad-frame rejection and metadata;
- lens correction and rectification when enabled;
- tile scheduling;
- retrieval of current, previous, left, and right patches;
- long temporal history;
- global token arbitration when the ASIC cannot retain a complete frame of candidates;
- raw trigger retention;
- representation logging and model adapters.

### 35.2 First-ASIC responsibilities

The first ASIC SHALL be a local visual transform. It SHALL:

- accept a small image patch and its metadata;
- optionally accept the corresponding previous-frame patch;
- compute deterministic local statistics and feature energy;
- emit one partial `VisualCell` record and optional local token candidates;
- expose saturation, invalid-input, and arithmetic-overflow flags;
- support exact replay and reset between independent work units.

The first ASIC SHALL NOT perform:

- full-frame storage;
- arbitrary image rectification;
- dense stereo correspondence;
- object detection or classification;
- contour tracing across a complete image;
- region tracking across a complete image;
- learned inference;
- text or language-token generation.

This partition is intentional. The ASIC tests whether selected sensory primitives are small, fast, power-efficient, and useful—not whether an entire vision system can be compressed into 24 TinyTapeout tiles.

### 35.3 First-synthesis profile: monocular temporal

The first synthesis and place-and-route attempt SHALL be monocular. It consumes the current patch and the previous patch from the same eye. It SHALL NOT contain stereo matching, binocular state, or right-eye datapath duplication.

The area and state budget avoided by omitting stereo SHALL be spent first on basic temporal computation:

1. signed current-minus-previous response;
2. separate accumulated ON and OFF energy where affordable;
3. one-delay Reichardt-like horizontal motion;
4. one-delay Reichardt-like vertical motion;
5. motion confidence or opponent ambiguity.

If the complete profile does not fit, capability SHALL be removed in this order:

1. local token-candidate generation;
2. vertical motion, retaining horizontal opponent motion;
3. diagonal orientation channels;

Signed temporal change, the byte-stream interface, deterministic replay, and saturation/error reporting SHALL not be removed merely to preserve a larger filter bank.

## 36. Visual processing pipeline

The logical pipeline consists of the following stages. A stage may run in software, FPGA logic, or ASIC logic while retaining identical fixed-point semantics.

### 36.1 Stage 0 — frame validation and calibration

Before feature extraction, the system SHALL:

- validate the left/right stereo-pair identity;
- associate the exposure timestamp and calibration identifier;
- reject or flag incomplete frames;
- apply fixed bad-pixel replacement when configured;
- apply geometric rectification when stereo disparity is requested;
- lock or record exposure and gain;
- establish the current-to-previous-frame interval.

Photometric correction SHOULD remain minimal. Hidden automatic contrast, sharpening, denoising, or local tone mapping can create false temporal and motion features.

### 36.2 Stage 1 — tile and patch scheduling

The image SHALL be divided into small processing tiles independently of the final 8 × 8 output grid. V0 begins with a 16 × 16 active-pixel processing tile unless transport modelling selects another size.

Each work unit SHALL include the active tile plus whatever halo is required by the selected local kernels. A 3 × 3 spatial kernel therefore receives an 18 × 18 patch for a 16 × 16 active tile when halo pixels are sent explicitly.

A work unit MAY contain:

- current patch from the selected eye;
- previous patch from that same eye;
- corresponding patch from the other eye in a later binocular profile;
- validity mask;
- frame, tile, timing, and configuration metadata.

The scheduler SHALL use a declared patch order and SHALL NOT make the ASIC infer frame position from uninterrupted timing. Fine tile outputs SHALL be accumulated or pooled into the corresponding final 8 × 8 grid cell.

### 36.3 Stage 2 — local normalization

The local transform SHOULD compute:

- mean luminance;
- local contrast or mean absolute deviation;
- optional fixed-offset subtraction;
- normalized signed contrast samples;
- saturation and invalid-pixel counts.

Normalization SHALL use fixed, documented arithmetic. Adaptation state, when used, SHALL be versioned and replayable. Independent hidden normalization between stereo eyes is prohibited before disparity measurement.

### 36.4 Stage 3 — oriented spatial energy

The V1-like spatial stage SHOULD compute responses for at least four orientation families:

- horizontal;
- vertical;
- rising diagonal;
- falling diagonal.

The first implementation MAY use small integer gradient or Gabor-like kernels rather than literal floating-point Gabors. Opposite-polarity responses SHOULD be combined into local orientation energy when phase invariance is useful.

The four orientation-energy channels SHALL remain available for pooling into `VisualFrame1024`. A consumer that wants a compact continuous orientation estimate MAY derive a doubled-angle vector:

```text
edge_c2 = edge_energy × cos(2 × orientation)
edge_s2 = edge_energy × sin(2 × orientation)
```

The doubled-angle form avoids the discontinuity between orientations near 0° and 180°. A downstream consumer recovers orientation as:

```text
orientation = 0.5 × atan2(edge_s2, edge_c2)
```

The ASIC does not need to compute trigonometric functions. V0 SHALL output the four non-negative orientation energies; doubled-angle conversion, when wanted for tokens or analysis, runs downstream.

### 36.5 Stage 4 — temporal ON/OFF response

Given current and previous patches, the temporal stage SHOULD compute:

- signed mean change;
- positive or ON energy;
- negative or OFF energy;
- absolute change energy;
- temporal confidence based on valid interval and exposure consistency.

The signed response SHALL preserve the distinction between appearance and disappearance. A single unsigned “difference” value is insufficient.

### 36.6 Stage 5 — local motion

The first motion stage SHOULD implement Reichardt-like or equivalent local correlation at:

- one temporal delay: the previous committed visual frame;
- one spatial displacement;
- four cardinal directions.

Diagonal direction support MAY be added if area permits. Opposed correlations SHALL be subtracted to form signed horizontal and vertical motion components.

V0 local motion is evidence, not optical-flow ground truth. Its output SHALL include confidence derived from texture energy, correlation strength, and opponent ambiguity.

### 36.7 Stage 6 — stereo disparity

Stereo disparity is part of the canonical representation but is explicitly absent from the first monocular synthesis profile.

The software reference SHALL initially estimate rectified horizontal disparity using a bounded search and report:

- signed disparity in pixels;
- match strength;
- left/right consistency;
- ambiguity between best and second-best matches;
- invalid status for textureless, occluded, or inconsistent cells.

Disparity SHALL NOT be converted to metric depth unless focal length, baseline, calibration, and uncertainty are available. A poor match SHALL remain invalid rather than becoming a confident far-away point.

### 36.8 Stage 7 — spatial and temporal pooling

V2/V4-like behavior begins as pooling, not object naming. Later system stages MAY compute:

- contour continuation;
- corners, junctions, and line endings;
- coherent motion regions;
- motion divergence and looming;
- center-surround saliency;
- stable proto-regions;
- region persistence and track association.

These stages SHALL consume and emit the same documented field/token semantics. They MAY initially run off-chip. Biological labels such as V1, V2, MT, or V4 are architectural analogies, not claims of biological equivalence.

## 37. Canonical dense representation: `VisualFrame1024`

The canonical model-facing representation is:

```text
VisualFrame1024 {
    VisualFrameHeader header;
    VisualCell cells[8][8];
}

VisualCell {
    uint8 luminance;
    uint8 contrast;
    uint8 edge_horizontal;
    uint8 edge_diag_rising;
    uint8 edge_vertical;
    uint8 edge_diag_falling;
    int8  temporal_change;
    int8  motion_x;
    int8  motion_y;
    uint8 motion_confidence;
    int8  disparity;
    uint8 depth_confidence;
    uint8 junction_energy;
    uint8 contour_coherence;
    int8  looming;
    uint8 salience;
}
```

Each `VisualCell` is 16 bytes. Sixty-four cells therefore produce exactly 1,024 activation bytes per frame.

The stable channel registry is:

| Channel | Stage analogy | Value |
| ---: | --- | --- |
| 0 | Retina/local | Mean luminance |
| 1 | Retina/local | Local contrast |
| 2 | V1-like | Horizontal oriented energy |
| 3 | V1-like | Rising-diagonal oriented energy |
| 4 | V1-like | Vertical oriented energy |
| 5 | V1-like | Falling-diagonal oriented energy |
| 6 | Temporal | Signed change: OFF negative, ON positive |
| 7 | Reichardt/MT-like | Signed horizontal motion, Q4.3 pixels/frame |
| 8 | Reichardt/MT-like | Signed vertical motion, Q4.3 pixels/frame |
| 9 | Motion | Motion confidence |
| 10 | Binocular | Signed disparity in pixels; `-128` invalid |
| 11 | Binocular | Disparity/depth confidence |
| 12 | V2-like | Junction, corner, or termination energy |
| 13 | V2/V4-like | Contour or proto-region coherence |
| 14 | Motion/context | Signed contraction/expansion or looming evidence |
| 15 | V4/attention-like | Salience and novelty |

These are functional analogies, not claims that a particular biological area contains exactly this representation.

### 37.1 Flattening

The normative flattened index is cell-major:

```text
index = ((y * 8) + x) * 16 + channel
```

where `x` and `y` are in `0..7`, `(0, 0)` is the top-left of the calibrated visual field, and `channel` is in `0..15`.

Cell-major ordering matches the tile-processing hardware: after a spatial bin is complete, its 16 output values can be emitted consecutively. A model or visualization MAY transpose the same data into channel-major `[16][8][8]` form. In channel-major form, each channel is an 8 × 8 activity bitmap.

### 37.2 Validity and confidence

The 1,024 activation values are accompanied by metadata rather than overloaded sentinel values wherever possible:

- a 16-bit implemented-channel mask;
- a 64-bit valid-cell mask;
- saturation and overflow flags;
- frame-level sensor-health state;
- explicit motion and depth confidence channels;
- `configuration_id` defining scaling and quantization.

An unimplemented channel SHALL have its implemented bit clear. It SHALL NOT masquerade as a valid zero activation.

Signed channels use two's-complement `int8`. Unsigned energy channels use `uint8`. Narrowing SHALL use documented saturation and rounding.

### 37.3 Spatial pooling

The 8 × 8 grid is independent of sensor resolution. At VGA, each final cell covers a nominal 80 × 60 pixel region; at 1280 × 800, each covers 160 × 100 pixels. Fine local filters run before this pooling, so a final grid cell aggregates many smaller receptive fields rather than applying one enormous Gabor kernel to its entire region.

Pooling MAY use mean, maximum, energy sum, opponent sum, or confidence-weighted reduction according to the channel. The reduction rule for every channel SHALL be versioned and bit-accurate.

The fixed grid makes recordings comparable across camera resolution changes. Geometric calibration SHALL define how raw pixels map into normalized grid coordinates.

### 37.4 Bandwidth

One `VisualFrame1024` activation payload is exactly 1,024 bytes. At 30 frames/s this is 30,720 bytes/s; at 60 frames/s it is 61,440 bytes/s, before headers and optional masks. V0 SHALL emit the full vector for every processed frame because this bandwidth is negligible relative to the raw sensor streams.

## 38. Optional sparse representation: `VisualToken`

The optional sparse primitive is a fixed 8-byte record scoped to a `VisualFrameHeader`:

```text
byte 0: kind[3:0] | source[1:0] | lane[1:0]
byte 1: x
byte 2: y
byte 3: scale[3:0] | flags[3:0]
byte 4: parameter_0
byte 5: parameter_1
byte 6: magnitude
byte 7: confidence
```

Field semantics:

- `kind` selects a stable primitive type.
- `source` is left, right, binocular, or fused.
- `lane` is reflex, percept, context, or diagnostic.
- `x` and `y` are normalized unsigned coordinates from 0 to 255 at the centre of the primitive.
- `scale` encodes the spatial support diameter in half-octave steps.
- `flags` carries polarity, ambiguity, saturation, or type-specific status.
- `parameter_0` and `parameter_1` are signed or unsigned according to `kind`.
- `magnitude` reports evidence strength.
- `confidence` reports the reliability of the interpretation, not a duplicate magnitude.

Initial token kinds are:

| Kind | `parameter_0` | `parameter_1` | Meaning |
| --- | --- | --- | --- |
| `EDGE` | signed `edge_c2` | signed `edge_s2` | Oriented local contrast |
| `CHANGE` | signed temporal response | integration interval code | ON/OFF temporal event |
| `MOTION` | signed Q4.3 `dx` | signed Q4.3 `dy` | Local direction-selective motion |
| `DISPARITY` | signed pixel disparity | match residual | Binocular horizontal displacement |
| `LOOM` | signed divergence | log time-to-contact code | Expansion or contraction evidence |
| `JUNCTION` | packed orientation pair | junction subtype | Corner, crossing, or termination |
| `REGION` | support width code | support height code | Unlabelled coherent proto-region |
| `HEALTH` | status code | affected source | Sensor or pipeline condition |

Unused kinds SHALL remain reserved. Meaning SHALL NOT be changed silently after data has been recorded; incompatible changes require a representation-version increment.

## 39. Frame and stream envelope

Every cell lattice and token group SHALL be associated with a logical header containing at least:

```text
VisualFrameHeader {
    representation_version
    channel_schema_id
    frame_id
    exposure_timestamp
    frame_interval
    source_mask
    raw_width
    raw_height
    cell_width
    cell_height
    lattice_columns
    lattice_rows
    implemented_channel_mask
    valid_cell_mask
    calibration_id
    configuration_id
    flags
}
```

Header flags SHALL report:

- complete or partial stereo pair;
- key state frame versus token-only frame;
- dropped input or output data;
- exposure/gain change;
- calibration or configuration change;
- buffer overflow;
- reset or state discontinuity.

The physical byte protocol MAY encode this header as multiple records. The logical fields and their meaning SHALL remain identical across files, software APIs, FPGA streams, and ASIC I/O.

## 40. State, events, and silence

Sparse events alone are insufficient. No events may mean that the world is stable, thresholds are too high, the camera is covered, or the pipeline has failed.

The normal output stream SHALL therefore contain:

1. one complete `VisualFrame1024` for every processed frame;
2. optional sparse `VisualToken` records derived from those frames;
3. explicit health and heartbeat records;
4. triggered raw stereo windows around selected events.

Initial policy:

- visual processing runs on every committed stereo pair;
- a complete 1,024-byte activation vector is emitted for every processed frame;
- token candidates MAY be evaluated every frame;
- health is emitted at least once per second and immediately on change;
- the default sparse-token budget is 32 tokens per visual frame;
- exceeding the token budget SHALL set overflow and candidate-count metadata.

Tokens SHOULD be emitted on threshold crossing, substantial change, or local non-maximum selection—not continuously merely because a feature remains present. A persistent edge belongs in the 1024-vector; the appearance, movement, or disappearance of that edge may also produce an event.

## 41. Candidate selection and token arbitration

Each local transform MAY produce zero or more token candidates. Candidate priority SHOULD combine:

- normalized feature magnitude;
- confidence;
- novelty relative to recent state;
- task-independent urgency, such as rapid looming;
- spatial non-maximum suppression;
- per-kind quotas preventing one feature family from monopolizing output.

V0 global arbitration MAY run off-chip because the first ASIC does not retain a full-frame candidate set. The ASIC SHALL expose sufficient magnitude, confidence, position, and kind information for deterministic external arbitration.

The selection algorithm and thresholds SHALL be configuration data, not undocumented constants. Recorded datasets SHALL retain the configuration identifier and candidate-overflow counts so later experiments can distinguish representation failure from selection failure.

## 42. Model-facing interpretation

The representation is intended to support two complementary adapters.

### 42.1 Frame-vector adapter

`VisualFrame1024` is simultaneously:

- a 1024-dimensional vector for a linear projection or MLP;
- an `[8][8][16]` grid for cell-oriented processing;
- a `[16][8][8]` tensor for CNN or feature-plane processing;
- 64 spatial tokens, each containing a 16-dimensional visual hypercolumn;
- 16 feature tokens, each containing an 8 × 8 activation bitmap.

A model adapter MAY choose any of these views without changing the recorded representation. The channel meanings remain physically interpretable and stable across training runs.

### 42.2 Event adapter

Each `VisualToken` becomes one temporal-model input containing embeddings of:

- kind, source, and lane;
- normalized position and scale;
- the two type-specific parameters;
- magnitude and confidence;
- frame time and elapsed time from prior token;
- calibration and configuration identity when relevant.

The model learns the embedding. The sensor board SHALL NOT stringify records into prose or invent object nouns.

### 42.3 Fusion adapter

Visual tokens share the common device timeline with auditory and olfactory events. Cross-modal association SHALL occur through time, location/bearing, confidence, and learned context. Fusion MAY create a new record, but SHALL NOT erase the visual evidence from which it was inferred.

## 43. First TinyTapeout kernel

The first tapeout candidate is deliberately narrower than the canonical representation.

The initial synthesis profile is named `MONO_TEMPORAL_V0`. Its source mask identifies one eye, and its `implemented_channel_mask` enables channels 0 through 9 only (`0x03FF`). Channels 10 through 15 remain in the stable frame schema with their implemented bits clear.

### 43.1 Input work unit

The architecture permits halo-expanded work units, but the frozen
`MONO_TEMPORAL_V0` transport uses:

- one 16 × 16 active processing tile without a transmitted halo;
- current monochrome patch from one eye;
- previous monochrome patch from the same eye;
- implicit raster order within the tile.

The host retains tile coordinate, frame interval, validity, and configuration
metadata. Boundary comparisons that require a pixel outside the active tile are
omitted. This makes every work unit self-contained and bounds the silicon line
storage; the off-chip pooling stage accounts for the slightly smaller sample count
at fine-tile boundaries.

This is exactly 512 pixel bytes plus one command byte. At VGA, there are 40 × 30 =
1,200 non-overlapping 16 × 16 processing tiles. At 30 frames/s, current/previous
transport occupies 18.43 MB/s before responses and handshake stalls. Including the
current 12-byte response and one finalization clock, the frozen schedule uses about
37.9% of a 50 MHz byte-clock budget at 30 fps and about 75.7% at 60 fps.

### 43.2 Required kernel outputs

The first monocular kernel SHOULD produce fine-tile contributions for:

- luminance;
- contrast;
- four oriented-energy channels;
- signed temporal change;
- signed horizontal and vertical motion evidence;
- motion confidence;
- saturation, invalid-input, and arithmetic-overflow flags.

An off-chip accumulator SHALL pool these contributions into the appropriate 8 × 8 final grid cells. The kernel MAY emit local `EDGE`, `CHANGE`, and `MOTION` token candidates. Disparity, salience history, looming, junctions, contour coherence, and global token arbitration are explicitly outside the first kernel.

No logic or storage SHALL be reserved for stereo merely to keep a future path convenient. A binocular successor may reuse the same byte protocol and frame schema after the monocular temporal kernel has physical area and timing results.

### 43.3 Arithmetic constraints

- Coefficients SHALL be small signed integers or powers of two where practical.
- Accumulators SHALL have analytically justified widths.
- Narrowing SHALL use documented rounding and saturation.
- Division SHOULD be avoided or implemented by bounded reciprocal approximation.
- Every fixed-point operation SHALL have a bit-accurate software reference.
- Configuration registers SHALL be minimal and reset to a documented useful mode.

### 43.4 TinyTapeout byte interface

The intended mapping is:

- `ui_in[7:0]`: input byte stream;
- `uo_out[7:0]`: output byte stream;
- selected `uio` pins: input-valid, input-ready, output-valid, output-ready, record boundary, mode/configuration, and error/interrupt signaling;
- `clk`: nominal 50 MHz processing and interface clock;
- `rst_n`: complete deterministic reset;
- `ena`: standard TinyTapeout project enable.

The `MONO_TEMPORAL_V0` allocation is frozen as follows:

| Pin | Direction | Meaning |
| --- | --- | --- |
| `uio[0]` | input | `input_valid` |
| `uio[1]` | input | `output_ready` |
| `uio[2]` | output | `input_ready` |
| `uio[3]` | output | `output_valid` |
| `uio[4]` | output | `busy` |
| `uio[5]` | output | sticky command `error` |
| `uio[6]` | output | `output_first` |
| `uio[7]` | output | `output_last` |

A work unit is command byte `0xA0`, followed by 256 raster-order repetitions of
`{current_pixel, previous_pixel}`. The response is marker `0x5A`, channels 0
through 9 in registry order, and one status byte. Status bits 0 through 3 report
saturation of temporal change, horizontal motion, vertical motion, and motion
confidence. Signed outputs use two's-complement.

With no stalls, one work unit takes 526 clocks including command, pixel pairs, one
finalization clock, and the 12-byte response. At 50 MHz, 1,200 VGA tiles take
approximately 12.6 ms, providing margin at 30 fps and a narrow but usable path to
60 fps. The separate input and output byte buses are logically full duplex, but V0
deliberately accepts a new command only after its response has been consumed.

## 44. Bandwidth examples

### 44.1 Canonical representation output

The canonical activation payload is independent of camera resolution:

- 8 × 8 spatial cells;
- 16 one-byte feature values per cell;
- 1,024 bytes per frame;
- 30,720 bytes/s at 30 frames/s;
- 61,440 bytes/s at 60 frames/s;
- optional 32 tokens/frame add 7,680 bytes/s at 30 fps;
- headers, masks, and health add comparatively little.

This is not an output-I/O problem. V0 can emit the entire activation vector for every frame and defer sparse-only operation until there is evidence that it helps.

### 44.2 ASIC work-unit input

Input bandwidth is more constraining because naïve halo patches duplicate pixels. The transport model SHALL account for:

- current and previous patches;
- halo duplication;
- metadata and framing;
- idle and handshake cycles;
- configuration traffic;
- output traffic when interfaces cannot operate concurrently.

V0 SHOULD prefer a schedule that keeps sustained byte utilization below 70% of the available interface rate, leaving margin for control, stalls, and physical timing.

## 45. Why this representation

The representation is intentionally positioned between raw pixels and semantic labels.

It is preferable to unbounded raw feature-map dumps because it:

- fixes stable physical meanings and units;
- bounds bandwidth;
- exposes uncertainty;
- supports sparse computation;
- remains inspectable and replayable;
- can be consumed by both learned and non-learned systems.

It is preferable to object labels because it:

- does not force the sensor to know the downstream ontology;
- preserves novel or ambiguous stimuli;
- allows later models to revise interpretations;
- retains motion and timing that labels usually discard;
- fits the computational scale of the proposed hardware.

It is preferable to opaque learned embeddings as the only output because it:

- remains stable as models change;
- provides a test oracle for hardware;
- permits cross-implementation comparison;
- makes sensor and calibration failures visible;
- can still be projected into learned embeddings downstream.

## 46. Visual-pipeline acceptance tests

The software reference representation is acceptable when:

1. A uniform patch produces luminance but negligible contrast, edge, temporal, and motion energy.
2. Bars at multiple angles activate the expected orientation channels and interpolate predictably between them.
3. Appearing and disappearing patterns produce opposite-signed temporal responses.
4. Translation in four directions produces correctly signed local motion components.
5. Textureless or ambiguous motion produces lower confidence than well-textured translation.
6. Rectified stereo targets produce monotonic disparity with distance and invalid results under deliberate occlusion.
7. Full frame vectors plus health metadata distinguish stable input, covered cameras, and disconnected cameras.
8. Token budgets are deterministic and overflow is explicitly reported.
9. Recorded replay reproduces bit-identical 1024-vectors and token candidates.
10. Visual timestamps align with auditory events on the common device clock.

The first ASIC kernel is acceptable when:

1. Its outputs match the bit-accurate software model over directed and randomized patches.
2. Reset, malformed records, backpressure, saturation, and arithmetic boundaries are covered.
3. The byte transport sustains the selected V0 work schedule with the required margin.
4. Synthesis fits within the 6 × 4 allocation with routing margin.
5. The placed-and-routed design meets the declared 50 MHz target at the required corners.
6. Gate-level replay produces the same committed records as RTL, allowing for documented timing.

## 47. Visual-pipeline open decisions

- Processing-tile size and pooling rule for each final-grid channel.
- Exact integer spatial kernels and coefficient widths.
- Patch transport versus row-strip transport.
- Whether current and previous monocular images are both sent as pixels or one is compressed into temporal statistics.
- Whether the first kernel emits only fine-tile contributions or also local token candidates.
- Token thresholds, per-kind quotas, and non-maximum-suppression neighborhood.
- Whether a later low-bandwidth mode may omit unchanged full vectors.
- Disparity search range and whether a later ASIC should accelerate it.
- Novelty estimator and how much history it requires.
- The smallest downstream task suite that genuinely measures representation usefulness.

## 48. Current visual-pipeline recommendation

Treat **`VisualFrame1024`—an 8 × 8 grid of 16-channel visual hypercolumns—as the ground-truth frame representation**. Flatten it when a model wants a 1024-dimensional vector; reshape it when a model or human wants feature planes. `VisualToken` records are optional attention-oriented derivatives, not the primary representation.

Emit the full 1,024-byte vector for every processed frame. Retain raw sensor windows around salient events. Use the first TinyTapeout synthesis profile only for monocular fine-tile luminance, contrast, four oriented-energy channels, signed temporal change, and horizontal/vertical motion evidence; pool those tile results into the final 8 × 8 grid off-chip. Mark stereo and higher grouping channels unimplemented.

This gives us a representation rich enough to evaluate with real downstream tasks while keeping the first silicon question small and falsifiable:

> Can a tiny deterministic visual kernel turn buffered pixels into local evidence that is more useful per byte and per joule than the pixels themselves?

---

# Part IV — Auditory processing and representation

## 49. Representation decision

The canonical dense auditory output SHALL be a fixed
**8 time slots × 16 frequency bands × 8 feature channels** tensor:

```text
8 × 16 × 8 = 1024 activation values per auditory frame
```

This is the auditory analogue of `VisualFrame1024`. A visual hypercolumn describes
several transforms at one retinal location; an auditory hypercolumn describes
several transforms at one time-frequency location. The frequency axis is ordered
low to high and the time axis is ordered oldest to newest.

At the default 48 kHz sample rate and 128-sample hop, consecutive time slots are
2.667 ms apart. One `AudioFrame1024` therefore advances every eight hops, or
21.333 ms, and contains features whose 256-sample analysis windows overlap by 50%.
The frame rate is 46.875 frames/s and the dense activation bandwidth is 48,000
bytes/s before headers. That rate is small enough to emit every frame rather than
making sparsity a correctness requirement.

```text
AudioFrame1024 {
    AudioFrameHeader header;
    AudioCell cells[8][16];
}

AudioCell {                    // 8 bytes
    uint8 left_energy;
    uint8 right_energy;
    uint8 mono_energy;
    int8  energy_delta;
    uint8 onset_strength;
    int8  level_difference;
    int8  phase_lead;
    uint8 stereo_confidence;
}
```

`AudioFrameHeader` SHALL identify at least:

- first and last source sample indices;
- centre timestamp of each time slot or an equivalent first timestamp plus fixed
  hop;
- sample rate, analysis-window length, and hop length;
- frequency-bank and channel schema identifiers;
- source, calibration, and configuration identifiers;
- implemented-channel and valid-slot masks;
- clipping, discontinuity, arithmetic-saturation, and sensor-health flags.

Flattening SHALL use:

```text
index = ((time_slot * 16) + frequency_band) * 8 + channel
```

An implementation MAY expose channel-major `[8][8][16]` or band-major views, but
the serialized ordering and channel meanings SHALL remain stable.

## 50. Auditory channel registry

| Channel | Name | Type | Meaning |
| ---: | --- | --- | --- |
| 0 | `left_energy` | `uint8` | compressed energy at the left microphone |
| 1 | `right_energy` | `uint8` | compressed energy at the right microphone |
| 2 | `mono_energy` | `uint8` | common or summed band energy |
| 3 | `energy_delta` | `int8` | signed late-half minus early-half energy |
| 4 | `onset_strength` | `uint8` | positive band-energy increase above local floor |
| 5 | `level_difference` | `int8` | signed right-minus-left band level |
| 6 | `phase_lead` | `int8` | signed right-leading versus left-leading evidence |
| 7 | `stereo_confidence` | `uint8` | validity/coherence of the stereo cues |

Positive channels 5 and 6 SHALL indicate evidence for a source toward the right
microphone. The precise companding law, full-scale reference, band edges, and
phase-lead scaling SHALL be carried by `channel_schema_id` and tested bit for bit.
Silence, clipping, invalid samples, and weak stereo evidence SHALL remain
distinguishable. A low-confidence zero phase lead SHALL not be interpreted as a
confident centred source.

The initial 16 centre frequencies SHALL be equally spaced on the ERB-number
psychoacoustic scale from 125 Hz through 8 kHz. This gives substantially more
resolution to speech, pitch, and low-frequency localization cues without spending
half the channels on the top octave. Frequencies above the highest represented
band remain available in retained PCM but need not consume a dense channel in V0.

### 50.1 Frozen V0 filter constants

`STEREO_FILTERBANK_V0` SHALL use the following constants. All three coefficients
are signed Q12 values. `resonator` is `round(2 cos(2 pi f / 48000) * 4096)`;
`cos` and `sin` reconstruct the final complex response from the last two resonator
states. These values are protocol constants, not implementation suggestions.

| Band | Centre (Hz) | Resonator | Cos | Sin |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 125 | 8191 | 4095 | 67 |
| 1 | 208 | 8189 | 4094 | 112 |
| 2 | 309 | 8185 | 4093 | 166 |
| 3 | 435 | 8179 | 4089 | 233 |
| 4 | 590 | 8168 | 4084 | 316 |
| 5 | 781 | 8149 | 4075 | 418 |
| 6 | 1,017 | 8120 | 4060 | 544 |
| 7 | 1,308 | 8072 | 4036 | 698 |
| 8 | 1,666 | 7998 | 3999 | 886 |
| 9 | 2,109 | 7882 | 3941 | 1116 |
| 10 | 2,654 | 7703 | 3851 | 1395 |
| 11 | 3,327 | 7427 | 3714 | 1728 |
| 12 | 4,157 | 7009 | 3504 | 2120 |
| 13 | 5,180 | 6380 | 3190 | 2569 |
| 14 | 6,443 | 5447 | 2724 | 3059 |
| 15 | 8,000 | 4096 | 2048 | 3547 |

The executable reference model SHALL be the source used to regenerate and verify
this table. A change to any value requires a new `channel_schema_id`.

## 51. Processing pipeline

The first reference pipeline SHALL be:

```text
synchronized signed PCM
        │
        v
DC removal / fixed common scaling / health checks
        │
        v
16-band analysis bank for left and right channels
        │
        ├── per-ear energy and early/late energy change
        ├── onset evidence
        └── stereo level, phase-lead, and confidence evidence
        │
        v
one 16 × 8 time-slot record every 128 samples
        │
        v
eight records assembled into AudioFrame1024
        │
        ├── dense model input
        └── optional onset/localization tokens
```

### 51.1 Filter-bank choice

The first ASIC SHOULD use a time-multiplexed bank of fixed-coefficient resonators
or similarly small band-pass sections rather than a general-purpose FFT. One
arithmetic engine SHALL be reused across bands and ears. This choice provides:

- stable, inspectable band identities;
- work proportional to the chosen 16 bands rather than an FFT fabric sized for
  bins that are immediately pooled away;
- natural streaming and bounded state;
- cheap early/late energy and onset measurements;
- a direct path to per-band stereo comparison;
- coefficient and state widths that can be reduced through synthesis experiments.

The software reference MAY also compute an FFT and map it into the identical 16
bands. The resonator and FFT implementations SHALL be compared at the canonical
feature boundary, not by requiring their internal states to match.

### 51.2 Stereo evidence

The ASIC SHALL emit evidence, not an overconfident bearing estimate. Per-band
right-minus-left level and phase-lead values allow a downstream process to combine
frequency bands, microphone calibration, and room context. True fractional-sample
ITD, GCC-PHAT, multi-source separation, and final bearing MAY remain in FPGA or
software for V0.

Broadband onset and localization tokens MAY be derived off-chip by pooling the
dense cells with confidence weighting. Raw PCM around selected events SHALL remain
available for reprocessing.

## 52. First auditory ASIC kernel

The first auditory synthesis profile is named `STEREO_FILTERBANK_V0`. It is
implemented alongside `MONO_TEMPORAL_V0` in the same 6 × 4 design and selected by
command byte. Passing RTL simulation and generic synthesis do not establish that
the combined design fits; combined place-and-route remains the authority.

The existing physical result provides strong motivation for the experiment:
the visual-only design used less than 8% standard-cell utilization and closed the
50 MHz target without setup, hold, DRC, LVS, antenna, or power-grid violations.
Filler cells are not useful logic, so their large count does not mean the device is
full. The combined physical flow remains the authority because an audio filter bank
may create different routing, fanout, and clock-load pressure.

### 52.1 Input contract

The ASIC does not receive analogue voltages. The acquisition device or microphone
ADC SHALL first produce two synchronized signed PCM streams. The host SHALL narrow
or saturate them to signed 16-bit samples using one documented common scale.

One independent auditory work unit is:

```text
0xB0
256 repetitions of {
    left_sample_lsb,
    left_sample_msb,
    right_sample_lsb,
    right_sample_msb
}
```

Samples are signed two's-complement little-endian. The 256-sample window is 5.333 ms
at 48 kHz. Consecutive work units begin 128 samples apart; the external scheduler
resends the overlapping half-window. This small bandwidth cost makes each work unit
self-contained and exactly replayable without requiring the ASIC to retain raw PCM
between commands. Resonator state SHALL reset at the beginning of every `0xB0`
work unit. Early/late comparison SHALL be derived entirely within that window.

The core MAY deassert `input_ready` after accepting a stereo sample while its
shared arithmetic engine updates all band/channel states. The sender SHALL hold the
next byte until ready returns. Continuous one-byte-per-clock acceptance is not
required for audio.

### 52.2 Output contract

The response is:

```text
0x5B
16 repetitions of {
    left_energy,
    right_energy,
    mono_energy,
    energy_delta,
    onset_strength,
    level_difference,
    phase_lead,
    stereo_confidence
}
status
```

Band records are emitted from lowest to highest frequency. The response is exactly
130 bytes. Status SHALL report at least input clipping, invalid input, internal
arithmetic saturation, and configuration error. `output_first` marks `0x5B` and
`output_last` marks the status byte.

Command `0xA0` SHALL retain its current visual meaning. A combined profile named
`MULTISENSE_V0` SHALL dispatch `0xA0` to the visual kernel and `0xB0` to the
auditory kernel while sharing the existing byte buses and handshake pins. V0 MAY
serialize visual and auditory work units; no simultaneous command execution is
required.

### 52.3 Physical partitioning

Visual and auditory traffic uses the same TinyTapeout byte and handshake pins, so
there are no modality-specific package pads to place. The combined physical build
SHOULD nevertheless preserve the two RTL blocks as placement groups when the flow
supports it. The auditory group SHOULD occupy the die region diagonally opposite
the dominant visual group—kitty-corner across the core—with the dispatcher and
shared interface between them. This is a locality and routing objective, not a
reason to accept congestion or timing failure. The first unconstrained combined
layout SHALL be inspected before coordinates or hard placement regions are frozen.

### 52.4 Arithmetic and state budget

The first implementation SHOULD use:

- one shared coefficient multiply or shift-add unit;
- one shared energy/cross-product unit;
- fixed band coefficients stored as constants rather than writable RAM;
- bounded signed state per ear and band;
- high-bit or block-scaled products where full precision does not improve the
  canonical byte output;
- explicit saturation at every narrowing boundary;
- no divider, square root, logarithm, or arctangent in hardware.

Energy compression MAY use leading-one position plus selected mantissa bits. Phase
lead MAY use a narrowed cross-product or state-space determinant with confidence
reported separately. Every approximation SHALL have a bit-accurate software model
and error plots against a floating-point reference.

At 48 kHz and 50 MHz, approximately 1,041 ASIC clocks elapse per new stereo sample.
Because 50% overlap causes every sample to be processed twice, the ASIC receives an
average of 96,000 stereo sample pairs/s, or about 521 clocks per transmitted pair.
Full-window stereo state plus reusable early/late half-window state requires 64
band-state updates per pair, leaving about 8 clocks per update for a shared
sequential datapath before output overhead. I/O
bandwidth is also small: overlapping 16-bit stereo windows require 384,000 input
bytes/s, and 130 bytes per hop require 48,750 output bytes/s.

## 53. Auditory token adapter

The dense tensor is primary. Optional auditory tokens SHOULD describe changes or
compact tracks, including:

- broadband or band-limited onset;
- impulsive transient;
- left/right motion or bearing change;
- persistent tonal component;
- clipping, silence, discontinuity, or loss of stereo confidence.

Tokens SHALL carry centre time, integration window, band or band range, signed
spatial evidence, magnitude, confidence, calibration identity, and source-frame
identity. They SHALL not convert acoustic evidence into words, speaker identities,
or object labels on the sensor board.

## 54. Auditory representation acceptance tests

The software representation is acceptable when:

1. Silence produces near-zero energy and explicitly low stereo confidence without
   producing a confident centred source.
2. A tone swept across the supported range moves monotonically through the expected
   frequency bands without unstable holes.
3. A rising tone burst produces positive energy delta and onset in the correct
   time-frequency cells; its disappearance produces negative delta.
4. Equal in-phase stereo input produces near-zero level and phase-lead evidence
   with high confidence above the energy floor.
5. Known level offsets produce correctly signed and monotonic channel 5 values.
6. Known sample and fractional-sample delays produce correctly signed channel 6
   values over bands where phase is unambiguous.
7. Uncorrelated stereo noise reduces stereo confidence relative to a shared source.
8. Clipping, missing samples, channel swap, polarity reversal, and a dead channel
   produce explicit health or confidence changes.
9. Recorded replay reproduces bit-identical `AudioFrame1024` values and tokens.
10. Visual and auditory records align on the common device timeline.

The auditory ASIC kernel is acceptable when:

1. Directed and randomized fixed-point tests match the software model exactly.
2. Backpressure at every byte boundary cannot corrupt left/right or sample order.
3. Processing sustains 48 kHz stereo with at least 2× cycle margin.
4. Combined visual/audio synthesis fits the 6 × 4 allocation with routing margin.
5. Combined place-and-route meets the 50 MHz target at required corners.
6. Gate-level replay matches RTL and the reference model.
7. Adding audio does not change the existing `0xA0` visual response.

## 55. Current auditory-pipeline recommendation

Treat **`AudioFrame1024`—eight short time slices of sixteen frequency-band
hypercolumns—as the ground-truth dense auditory representation**. Feed it directly
to learned adapters as a 1,024-dimensional vector or preserve its time-frequency
shape for convolution or attention. Generate sparse events from it, but do not make
events the only record of the acoustic scene.

`STEREO_FILTERBANK_V0` is now implemented behind command `0xB0`, using one shared
sequential arithmetic engine and the existing byte handshake. Its RTL is checked
bit for bit against the fixed-point model for silence and asymmetric stereo tone
inputs; the software model additionally covers impulses, tones, chirps, noise,
level offsets, and channel faults. Combined place-and-route and gate-level replay
are the next acceptance gates. Only after those close should microphone capture be
connected directly to the live pipeline.

This asks the auditory version of the same falsifiable question as vision:

> Can a tiny deterministic auditory kernel turn synchronized PCM into compact
> time-frequency and spatial evidence that is more useful per byte and per joule
> than the waveform itself?

---

# Part V — Field integration and reflex processing

## 56. Visual field kernel

`VISUAL_FIELD_V0` SHALL be selected by command `0xA1`. It consumes one implicit
8 × 8 raster of `MONO_TEMPORAL_V0` records. The host SHALL omit each record's
`0x5A` marker and send the ten feature bytes followed by its status byte, for 704
payload bytes total.

The response SHALL be exactly 18 bytes: marker `0x5C`, sixteen field features in
the order below, and a status byte formed by bitwise OR of all tile status bytes.

| Index | Feature | Type | Scaling |
| ---: | --- | --- | --- |
| 0 | mean luminance | `uint8` | sum divided by 64 |
| 1 | mean contrast | `uint8` | sum divided by 64 |
| 2–5 | four mean oriented energies | `uint8` | sum divided by 64 |
| 6 | mean temporal change | `int8` | signed sum divided by 64 |
| 7–8 | global horizontal/vertical motion | `int8` | signed sum divided by 64 |
| 9 | mean motion confidence | `uint8` | sum divided by 64 |
| 10 | expansion/contraction | `int8` | centred dot product divided by 256 |
| 11 | rotation | `int8` | centred cross product divided by 256 |
| 12–13 | horizontal/vertical saliency bias | `int8` | activity moment divided by 512 |
| 14 | mean visual activity | `uint8` | mean of saturated contrast + absolute change + confidence |
| 15 | directional-motion consistency | `uint8` | magnitude of summed motion divided by 32, saturated |

For tile coordinates `x,y` in `0..7`, define `x2 = 2x - 7` and `y2 = 2y - 7`.
With signed local motion `mx,my`:

```text
expansion = sum(x2*mx + y2*my)
rotation  = sum(x2*my - y2*mx)
```

Positive expansion is outward motion. These are bounded reflex evidences, not
calibrated optical-flow divergence or time-to-contact. Saliency uses per-tile
activity saturated to one byte before its spatial moment is accumulated.

## 57. Visual field acceptance tests

The kernel SHALL:

1. preserve means for a spatially uniform field;
2. report translation without false expansion or rotation for uniform motion;
3. report positive expansion for a centred outward field;
4. report signed rotation for a centred rotational field;
5. move saliency bias toward an isolated active tile;
6. match the bit-accurate reference for randomized records and backpressure;
7. propagate every input status bit;
8. leave `0xA0` and `0xB0` behavior bit-identical.

The next planned processing stages are normative only after their byte contracts
are frozen. Their current order and intent are recorded in `PLAN.md`.
