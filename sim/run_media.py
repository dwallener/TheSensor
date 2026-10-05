#!/usr/bin/env python3
"""Convert a synchronized media segment into a perception-oscilloscope replay."""

from __future__ import annotations

import argparse
import json
import random
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from reference.audio_model import SAMPLE_RATE  # noqa: E402
from sim.run_reference import FRAME_SIZE, _preview, process_audio_stream, process_frame  # noqa: E402


def _run(command: list[str]) -> bytes:
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"media command failed ({result.returncode}): {detail}")
    return result.stdout


def probe(path: Path) -> dict[str, object]:
    output = _run([
        "ffprobe", "-v", "error", "-show_entries",
        "format=duration:stream=codec_type,width,height,r_frame_rate,sample_rate,channels",
        "-of", "json", str(path),
    ])
    return json.loads(output)


def choose_start(source_duration: float, duration: float, seed: int) -> float:
    """Choose a deterministic segment with a small guard at each end."""
    maximum = max(0.0, source_duration - duration)
    if maximum == 0:
        return 0.0
    guard = min(2.0, maximum / 4)
    return random.Random(seed).uniform(guard, max(guard, maximum - guard))


def decode_frames(
    path: Path,
    start: float,
    duration: float,
    frame_rate: int,
    fit: str,
) -> list[list[int]]:
    if fit == "crop":
        geometry = (
            f"scale={FRAME_SIZE}:{FRAME_SIZE}:force_original_aspect_ratio=increase,"
            f"crop={FRAME_SIZE}:{FRAME_SIZE}"
        )
    else:
        geometry = (
            f"scale={FRAME_SIZE}:{FRAME_SIZE}:force_original_aspect_ratio=decrease,"
            f"pad={FRAME_SIZE}:{FRAME_SIZE}:(ow-iw)/2:(oh-ih)/2:color=black"
        )
    raw = _run([
        "ffmpeg", "-v", "error", "-ss", f"{start:.6f}", "-i", str(path),
        "-t", f"{duration:.6f}", "-an", "-vf", f"fps={frame_rate},{geometry}",
        "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1",
    ])
    frame_bytes = FRAME_SIZE * FRAME_SIZE
    if len(raw) % frame_bytes:
        raise RuntimeError("decoded video ended with an incomplete grayscale frame")
    return [list(raw[offset : offset + frame_bytes]) for offset in range(0, len(raw), frame_bytes)]


def decode_audio(path: Path, start: float, duration: float) -> tuple[list[int], list[int]]:
    raw = _run([
        "ffmpeg", "-v", "error", "-ss", f"{start:.6f}", "-i", str(path),
        "-t", f"{duration:.6f}", "-vn", "-ac", "2", "-ar", str(SAMPLE_RATE),
        "-acodec", "pcm_s16le", "-f", "s16le", "pipe:1",
    ])
    if len(raw) % 4:
        raise RuntimeError("decoded audio ended with an incomplete stereo sample")
    pairs = struct.iter_unpack("<hh", raw)
    left, right = zip(*pairs) if raw else ((), ())
    return list(left), list(right)


def generate(
    path: Path,
    start: float,
    duration: float,
    frame_rate: int,
    fit: str,
) -> dict[str, object]:
    metadata = probe(path)
    frames = decode_frames(path, start, duration, frame_rate, fit)
    if len(frames) < 2:
        raise RuntimeError("segment must decode to at least two video frames")

    visual = []
    for index in range(1, len(frames)):
        records, field = process_frame(frames[index], frames[index - 1])
        visual.append({
            "time": index / frame_rate,
            "preview": _preview(frames[index]),
            "tiles": records,
            "field": field,
        })

    left, right = decode_audio(path, start, duration)
    audio = process_audio_stream(left, right)
    waveform_stride = max(1, SAMPLE_RATE // 300)
    waveform = [
        [index / SAMPLE_RATE, left[index], right[index]]
        for index in range(0, len(left), waveform_stride)
    ]
    actual_duration = min(len(frames) / frame_rate, len(left) / SAMPLE_RATE)
    return {
        "schema": "THE_SENSOR_REFERENCE_REPLAY_V0",
        "duration": actual_duration,
        "frame_size": FRAME_SIZE,
        "preview_size": 32,
        "frame_rate": frame_rate,
        "sample_rate": SAMPLE_RATE,
        "source": {
            "file": path.name,
            "segment_start": start,
            "segment_duration": duration,
            "fit": fit,
            "probe": metadata,
        },
        "visual": visual,
        "audio": audio,
        "waveform": waveform,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--start", type=float, help="segment start in seconds")
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument("--seed", type=int, default=20261005)
    parser.add_argument("--frame-rate", type=int, default=24)
    parser.add_argument("--fit", choices=("crop", "letterbox"), default="crop")
    args = parser.parse_args()

    if not args.input.is_file():
        parser.error(f"input does not exist: {args.input}")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        parser.error("ffmpeg and ffprobe must be installed")
    if args.duration <= 0 or args.frame_rate <= 0:
        parser.error("duration and frame rate must be positive")

    metadata = probe(args.input)
    source_duration = float(metadata["format"]["duration"])
    duration = min(args.duration, source_duration)
    start = args.start if args.start is not None else choose_start(source_duration, duration, args.seed)
    if start < 0 or start + duration > source_duration + 0.001:
        parser.error(f"segment {start:.3f}..{start + duration:.3f}s exceeds {source_duration:.3f}s source")

    output = args.output or ROOT / "sim" / "replays" / f"{args.input.stem}-{start:.3f}-{duration:.3f}.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    data = generate(args.input, start, duration, args.frame_rate, args.fit)
    output.write_text(json.dumps(data, separators=(",", ":")))
    print(
        f"wrote {output} ({output.stat().st_size} bytes; "
        f"{len(data['visual'])} visual, {len(data['audio'])} auditory records; "
        f"source {start:.3f}..{start + duration:.3f}s)"
    )


if __name__ == "__main__":
    main()
