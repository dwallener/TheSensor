# The Sensor — Engineering Specification

**Document status:** Draft 0.3  
**System status:** Architecture definition  
**Scope of this revision:** Stereo visual and auditory acquisition and early processing

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
- FFT versus streaming filter bank for the first hardware percept path.
- Number and spacing of output frequency bands.
- Whether GCC-PHAT belongs in FPGA logic or host/reference software initially.
- Required raw-history duration and cross-modal trigger policy.
- Temperature source for speed-of-sound correction.

## 32. Current auditory recommendation

Prototype with **two PUI DMM-4026-B-I2S evaluation boards or equivalent modules**, driven from one 3.072 MHz bit clock and one 48 kHz word-select clock. Capture signed PCM into 256-sample stereo blocks, retain raw samples in a five-second ring, and replay committed blocks into onset, spectral, and localization pipelines with a 128-sample hop.

This is intentionally ordinary digital audio plumbing. The novel work begins after capture: deciding which fast and slow auditory representations are compact, stable, and useful to a downstream learner.
