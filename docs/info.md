## How it works

The Sensor is a streaming visual feature extractor. This first ASIC profile processes
one current and one previous 16x16 monochrome image tile. It computes luminance,
contrast, four oriented edge energies, signed temporal change, horizontal and
vertical Reichardt-like motion, and motion confidence. Only two 16-pixel line
buffers are retained (eight-bit current pixels and four-bit previous pixels), so
pixels are consumed as a stream rather than stored as a complete frame.

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

## How to test

Set `ena` high. Present the input byte on `ui_in`, assert `uio_in[0]`, and wait for
`uio_out[2]` (`input_ready`). To consume output, assert `uio_in[1]`
(`output_ready`). `uio_out[3]` marks a valid byte; `uio_out[6]` and `uio_out[7]`
mark the first and last response bytes. `uio_out[4]` reports busy and `uio_out[5]`
reports an invalid command.

Run `make test` from the repository root for bit-accurate cocotb tests.

## External hardware

A controller or FPGA must buffer image-sensor frames, divide them into 16x16 tiles,
and stream current/previous tile pairs to the ASIC. Image capture and frame storage
are intentionally outside this TinyTapeout block.
