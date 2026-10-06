## How it works

The Sensor contains command-selected local visual, auditory, and visual-field
feature extractors on one shared byte-stream interface. Work units are serialized.

### Visual command `A0`

The visual kernel processes one current and one previous 16x16 monochrome image
tile. It computes luminance, contrast, four oriented edge energies, signed temporal
change, horizontal and vertical Reichardt-like motion, and motion confidence. Only
two 16-pixel line buffers are retained, so pixels are consumed as a stream rather
than stored as a complete frame.

The host sends command `A0`, then 256 interleaved pairs of `current, previous`
pixels in raster order. The core returns 12 bytes:

1. `5A` response marker
2. luminance
3. contrast
4. horizontal edge energy
5. rising-diagonal edge energy
6. vertical edge energy
7. falling-diagonal edge energy
8. signed temporal change
9. signed horizontal motion
10. signed vertical motion
11. motion confidence
12. saturation-status flags

Signed values use two's-complement. Status bits 0 through 3 report saturation of
temporal change, horizontal motion, vertical motion, and confidence respectively.

### Visual-field command `A1`

Send 64 raster-order tile records. Each record is the eleven bytes after the `5A`
marker in an `A0` response: ten feature bytes followed by status. The core returns
18 bytes:

1. `5C` response marker
2. mean luminance and contrast
3. mean horizontal, rising-diagonal, vertical, and falling-diagonal edge energy
4. signed mean temporal change
5. signed global horizontal and vertical motion
6. mean motion confidence
7. signed expansion/contraction and rotation evidence
8. signed horizontal and vertical saliency bias
9. mean visual activity and directional-motion consistency
10. bitwise OR of all input status bytes

The 8 × 8 tile coordinates are implicit in raster order. Positive expansion means
outward motion; positive rotation follows the image-coordinate convention defined
by the fixed-point reference model.

### Auditory command `B0`

Send 128 signed PCM8 left samples followed by the matching 128 signed PCM8 right
samples. The core returns 130 bytes:

1. `5B` response marker
2. sixteen low-to-high frequency-band records, each containing eight bytes:
   left energy, right energy, mono energy, signed energy delta, onset strength,
   signed right-minus-left level, signed phase lead, and conservative stereo confidence
3. status byte

The fixed ERB-spaced bands run from 125 Hz through 8 kHz. Status bit 0 reports an
exact full-scale input sample, bit 2 reports internal state saturation, and bit 3
reports a command/configuration error. Other status bits are reserved as zero.

Unlike the other commands, `B0` output is fire-and-forget. Its 130 bytes advance
on consecutive valid clocks regardless of `output_ready`; missed bytes are
dropped and are not retried. The receiver must reject an incomplete record and
resynchronize at the next asserted `output_first` carrying a `5B` marker.

### Auditory-field command `B1`

Send eight oldest-to-newest auditory slots. Each slot contains the 128 feature
bytes after the `5B` marker in a `B0` response, followed by that response's status
byte. The core returns 18 bytes:

1. `5D` response marker
2. total, low-band, mid-band, and high-band energy
3. spectral centroid and spread
4. onset and offset activity
5. strongest frequency band
6. impulsiveness and short-term modulation
7. signed confidence-weighted level and phase evidence
8. signed early-to-late lateral movement
9. mean stereo confidence
10. novelty against the retained slowly adapting sixteen-band baseline
11. bitwise OR of all eight input status bytes

The retained baseline resets only with `rst_n`, not between `B1` commands. This is
the first implemented context path whose output depends on earlier work units.

## How to test

Set `ena` high. Present the input byte on `ui_in`, assert `uio_in[0]`, and wait for
`uio_out[2]` (`input_ready`). To consume output, assert `uio_in[1]`
(`output_ready`). `B0` is the exception and ignores this input while transmitting.
`uio_out[3]` marks a valid byte; `uio_out[6]` and `uio_out[7]`
mark the first and last response bytes. `uio_out[4]` reports busy and `uio_out[5]`
reports an invalid command.

Run `make test` from the repository root for bit-accurate cocotb tests.

## External hardware

A controller or FPGA must buffer image-sensor frames, divide them into 16x16 tiles,
and stream current/previous tile pairs to the ASIC. It can feed the returned tile
records to `A1` for field-level evidence. It must likewise acquire and
synchronize the microphone ADC streams, decimate the 48 kHz acquisition stream to
24 kHz, construct overlapping 128-sample windows,
and assemble eight returned slots for `B1`. Sensor acquisition and raw buffering
are intentionally outside this TinyTapeout block.
