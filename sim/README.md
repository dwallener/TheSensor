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
The synthetic scene contains a textured moving/looming target. The audio contains
a swept, amplitude-modulated, laterally moving tone and a short opposed-polarity
click.

The next input adapters should read recorded monochrome framebuffers and stereo
WAV without changing `process_frame()` or `process_audio_stream()`. A later RTL
mode will replace each reference-model call with byte-stream replay while keeping
the JSON schema and viewer unchanged.
