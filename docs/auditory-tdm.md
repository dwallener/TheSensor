# Auditory channel-major TDM

## Decision

`STEREO_FILTERBANK_V0` processes the two microphones sequentially through one
physical sixteen-band resonator bank. A B0 work unit is serialized as:

```text
0xB0
128 signed PCM8 left samples, oldest to newest
128 signed PCM8 right samples, oldest to newest
```

The two channel blocks describe the same 128 sample times. At 24 kHz the complete
window spans 5.333 ms. Consecutive windows use a 64-sample hop and therefore
overlap by 50%.

The acquisition controller must retain the complete 256-byte stereo work unit
before transmission. This buffer is deliberately outside the ASIC; it is tiny
compared with an image framebuffer and permits deterministic live or recorded
replay.

## Why

The first interleaved implementation retained independent full-window and
half-window resonator state for both ears, along with three forty-bit correlation
accumulators per band. B0 accounted for roughly 6,865 of the complete design's
8,583 flip-flops and drove the first four-core physical build to 90.8% utilization
before repair. Detailed placement failed after clock and reset repair exhausted
the remaining legal sites.

Stereo input was already time-multiplexed on the byte bus and the channels already
shared the arithmetic unit. The remaining duplication was persistent per-ear
filter state. Channel-major ordering makes that state reusable: process the left
block, retain compact summaries, clear the bank, and process the matching right
block.

Generic synthesis reports approximately 4,367 B0 flip-flops after this change, a
reduction of about 2,500 flip-flops or 36%. All sixteen frequency bands and the
existing 130-byte response remain intact.

## Retained state and outputs

After the left block, B0 retains per band:

- the compressed full-window left level;
- the left full-window real and imaginary phasor components;
- compressed early-half and late-half left levels.

During the right block it retains the corresponding early-half level and computes
the right full and late summaries. These values preserve:

- left, right, and phase-sensitive summed energy;
- signed early-to-late energy change and onset;
- signed right-minus-left level difference;
- signed phasor-derived phase lead.

## Deliberate tradeoff

Channel-major processing cannot retain exact sample-by-sample cross-correlation
without buffering or replaying a filtered channel. `stereo_confidence` is therefore
not described as measured coherence in this profile. It is conservatively capped
and derived from signal level and inter-ear level balance.

Downstream software must not interpret zero phase with low confidence as a
confident centred source. Applications that require measured coherence, GCC-PHAT,
fractional-sample delay, or robust multi-source localization should use the raw
audio retained by the acquisition controller.

## Invariants

- Left and right blocks must describe identical sample indices.
- Channel order is always left then right.
- A new B0 command resets resonator and retained-summary state.
- Output remains marker `0x5B`, sixteen eight-byte band records, then status.
- Bands remain ERB-spaced from 125 Hz through 8 kHz.
- Backpressure may occur after every accepted sample or output byte.

## Verification

The fixed-point reference model uses the same channel-major computation as RTL.
Directed tests cover silence, tones, level asymmetry, phase lead, onset/offset,
summary confidence, output backpressure, and integration with B1. Physical
place-and-route remains the authority for final area, routing, and timing closure.
