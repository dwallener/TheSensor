# Multimodal reference replay

This is the first integration harness for the “watch the magic wiggle” milestone.
It drives a 128 × 128 current/previous framebuffer through the `A0` and `A1`
reference models and a synchronized stereo PCM stream through the `B0` and `B1`
models, then places both field vectors on one timeline.

Generate the deterministic synthetic replay:

```sh
python3 sim/run_reference.py
```

Open `sim/viewer.html`, choose the generated `sim/demo_data.json`, and press Play.
The perception oscilloscope keeps both paths on one cursor and shows:

- the buffered image, local A0 feature plane, motion field, and A1 reflex state;
- the stereo waveform, selectable B0 cochlear plane, lateral evidence, and B1
  contextual state;
- status and saturation on a shared visual/audio timeline; and
- exact reference-versus-RTL comparison when records include `rtl_field`.

The synthetic scene contains a textured moving/looming target. The audio contains
a swept, amplitude-modulated, laterally moving tone and a short opposed-polarity
click. See [VIEWER_SPEC.md](VIEWER_SPEC.md) for the display and replay contract.

The next input adapters should read recorded monochrome framebuffers and stereo
WAV without changing `process_frame()` or `process_audio_stream()`. A later RTL
mode will replace each reference-model call with byte-stream replay while keeping
the JSON schema and viewer unchanged.

## Recorded media

Keep source media under the ignored `sim/input/` directory. Convert a chosen
segment with FFmpeg plus the bit-accurate reference models:

```sh
python3 sim/run_media.py sim/input/example.mp4 \
  --start 12 --duration 8 --output sim/replays/example.json
```

Omit `--start` to choose a deterministic pseudo-random segment; `--seed` changes
that choice. The default `vertical-crop` policy scales the source to 256 pixels
high while preserving its aspect ratio, then takes the central 256 × 256 crop.
This retains the complete vertical field, discards equal portions of the left and
right sides, and introduces no geometric distortion. `--fit native-crop` retains
one source pixel per sensor pixel; `--fit letterbox` retains the complete field of
view. The resulting 256 × 256 frame becomes a 16 × 16 raster of fine A0 tiles,
which is pooled 2 × 2 into the canonical 8 × 8 emitted cells. Audio is converted
to 48 kHz signed stereo PCM. Source name, exact interval, fit policy, and probe
metadata are embedded in every replay.
