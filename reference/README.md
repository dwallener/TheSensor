# Reference models

`visual_tile_model.py` is the bit-accurate oracle for `MONO_TEMPORAL_V0`.
`audio_model.py` defines the floating-point and ASIC fixed-point versions of
`STEREO_FILTERBANK_V0`. `visual_field_model.py` is the bit-accurate oracle for
`VISUAL_FIELD_V0`, which pools 64 local tile records into one field-level reflex
vector.
`auditory_field_model.py` is a stateful bit-accurate oracle for
`AUDITORY_FIELD_V0`; its sixteen retained baseline bytes model the RTL's slowly
adapting per-band acoustic context.

The fixed model uses:

- canonical signed PCM8 input, sign-extended without rescaling;
- 16 ERB-spaced bands from 125 Hz to 8 kHz;
- Q12 resonator, sine, and cosine constants;
- saturating signed 26-bit resonator state;
- one full-window and one half-window resonator bank reused between ears;
- retained left-ear phasors plus per-ear early/late levels;
- summary-based stereo confidence without a sample-by-sample cross accumulator;
- leading-one plus three-bit-mantissa amplitude compression;
- power-of-two normalization for phase evidence.

The centre frequencies and coefficient tuples are frozen in `SPEC.md`; the tests
verify that the generated values remain bit-for-bit identical. The model
deliberately contains no NumPy dependency so it can serve as a compact, literal
hardware oracle. Run all tests from the repository root:

```sh
make test
```
