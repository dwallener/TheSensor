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

- signed PCM16 input narrowed to 12 bits;
- 16 ERB-spaced bands from 125 Hz to 8 kHz;
- Q12 resonator, sine, and cosine constants;
- saturating signed 26-bit resonator state;
- full-window stereo state plus reusable half-window state for true early/late
  comparison;
- 12-bit correlation samples;
- leading-one plus three-bit-mantissa amplitude compression;
- power-of-two normalization for phase and coherence evidence.

The centre frequencies and coefficient tuples are frozen in `SPEC.md`; the tests
verify that the generated values remain bit-for-bit identical. The model
deliberately contains no NumPy dependency so it can serve as a compact, literal
hardware oracle. Run all tests from the repository root:

```sh
make test
```
