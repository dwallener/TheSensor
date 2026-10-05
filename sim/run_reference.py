#!/usr/bin/env python3
"""Generate a deterministic multimodal reference-pipeline replay for the viewer."""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from reference.audio_model import (  # noqa: E402
    HOP_SIZE,
    SAMPLE_RATE,
    WINDOW_SIZE,
    process_window_fixed,
)
from reference.auditory_field_model import AuditoryFieldModel  # noqa: E402
from reference.visual_field_model import process_visual_field  # noqa: E402
from reference.visual_tile_model import TILE_SIZE, process_tile  # noqa: E402

FRAME_SIZE = 256
FRAME_RATE = 30
TILE_GRID = FRAME_SIZE // TILE_SIZE
CELL_GRID = 8
POOL_SIZE = TILE_GRID // CELL_GRID


def _preview(frame: list[int], size: int = 32) -> list[int]:
    stride = FRAME_SIZE // size
    return [
        frame[(y * stride) * FRAME_SIZE + x * stride]
        for y in range(size)
        for x in range(size)
    ]


def _pool_visual_tiles(records: list[list[int]]) -> list[list[int]]:
    """Pool a 16x16 raster of A0 records into the canonical 8x8 cells."""
    if len(records) != TILE_GRID * TILE_GRID:
        raise ValueError(f"expected {TILE_GRID * TILE_GRID} fine tile records")
    signed_channels = {6, 7, 8}
    cells = []
    for cell_y in range(CELL_GRID):
        for cell_x in range(CELL_GRID):
            members = [
                records[(cell_y * POOL_SIZE + dy) * TILE_GRID + cell_x * POOL_SIZE + dx]
                for dy in range(POOL_SIZE)
                for dx in range(POOL_SIZE)
            ]
            cell = []
            for channel in range(10):
                values = [
                    (record[channel] - 256 if record[channel] & 0x80 else record[channel])
                    if channel in signed_channels else record[channel]
                    for record in members
                ]
                cell.append((sum(values) // len(values)) & 0xFF)
            cell.append(members[0][10] | members[1][10] | members[2][10] | members[3][10])
            cells.append(cell)
    return cells


def process_frame(
    current: list[int], previous: list[int]
) -> tuple[list[list[int]], list[list[int]], list[int]]:
    """Run one 256x256 framebuffer pair through A0, 2x2 pooling, and A1."""
    expected = FRAME_SIZE * FRAME_SIZE
    if len(current) != expected or len(previous) != expected:
        raise ValueError(f"frames must contain exactly {expected} grayscale bytes")
    records = []
    for tile_y in range(TILE_GRID):
        for tile_x in range(TILE_GRID):
            now = []
            before = []
            origin_x = tile_x * TILE_SIZE
            origin_y = tile_y * TILE_SIZE
            for y in range(TILE_SIZE):
                start = (origin_y + y) * FRAME_SIZE + origin_x
                now.extend(current[start : start + TILE_SIZE])
                before.extend(previous[start : start + TILE_SIZE])
            records.append(process_tile(now, before)[1:])
    cells = _pool_visual_tiles(records)
    return records, cells, process_visual_field(cells)


def process_audio_stream(left: list[int], right: list[int]) -> list[dict[str, object]]:
    """Run synchronized PCM through B0 windows and stateful B1 groups."""
    if len(left) != len(right):
        raise ValueError("left and right streams must have equal length")
    slots = []
    output = []
    field_model = AuditoryFieldModel()
    for start in range(0, len(left) - WINDOW_SIZE + 1, HOP_SIZE):
        left_window = left[start : start + WINDOW_SIZE]
        right_window = right[start : start + WINDOW_SIZE]
        cells = process_window_fixed(left_window, right_window)
        records = [list(cell.as_bytes()) for cell in cells]
        clipping = int(any(abs(value) >= 32767 for value in (*left_window, *right_window)))
        slots.append((records, clipping))
        if len(slots) == 8:
            response = field_model.process(slots)
            centre_sample = start - 3 * HOP_SIZE + WINDOW_SIZE // 2
            output.append({
                "time": centre_sample / SAMPLE_RATE,
                "slots": slots,
                "field": response,
            })
            slots = []
    return output


def synthetic_frame(index: int) -> list[int]:
    """Textured scene with a right-moving, gradually looming bright target."""
    frame = [0] * (FRAME_SIZE * FRAME_SIZE)
    centre_x = 24 + index * 3
    centre_y = 64 + round(12 * math.sin(index * 0.25))
    half = 6 + index // 3
    for y in range(FRAME_SIZE):
        for x in range(FRAME_SIZE):
            background = 28 + (((x // 8) ^ (y // 8)) & 1) * 18
            if abs(x - centre_x) <= half and abs(y - centre_y) <= half:
                background = 210 + (((x // 3) ^ (y // 3)) & 1) * 35
            frame[y * FRAME_SIZE + x] = min(255, background)
    return frame


def synthetic_audio(duration: float) -> tuple[list[int], list[int]]:
    """Tone onset, lateral sweep, modulation, and a short broadband click."""
    count = round(duration * SAMPLE_RATE)
    left = []
    right = []
    for sample in range(count):
        time = sample / SAMPLE_RATE
        active = 1.0 if time >= 0.12 else 0.0
        modulation = 0.55 + 0.45 * math.sin(2 * math.pi * 5 * time)
        pan = math.sin(2 * math.pi * 0.7 * time)
        phase = pan * 0.8
        carrier = 2 * math.pi * (650 + 900 * time / duration) * time
        left_gain = active * modulation * (0.72 - 0.25 * pan)
        right_gain = active * modulation * (0.72 + 0.25 * pan)
        left_sample = round(11_000 * left_gain * math.sin(carrier))
        right_sample = round(11_000 * right_gain * math.sin(carrier + phase))
        if abs(time - 0.48) < 0.0003:
            impulse = 22_000 if sample & 1 else -22_000
            left_sample += impulse
            right_sample -= impulse
        left.append(max(-32768, min(32767, left_sample)))
        right.append(max(-32768, min(32767, right_sample)))
    return left, right


def generate(duration: float) -> dict[str, object]:
    frame_count = max(2, round(duration * FRAME_RATE))
    frames = [synthetic_frame(index) for index in range(frame_count)]
    visual = []
    for index in range(1, frame_count):
        records, cells, field = process_frame(frames[index], frames[index - 1])
        visual.append({
            "time": index / FRAME_RATE,
            "preview": _preview(frames[index]),
            "tiles": records,
            "cells": cells,
            "field": field,
        })

    left, right = synthetic_audio(duration)
    audio = process_audio_stream(left, right)
    waveform_stride = 160
    waveform = [
        [index / SAMPLE_RATE, left[index], right[index]]
        for index in range(0, len(left), waveform_stride)
    ]
    return {
        "schema": "THE_SENSOR_REFERENCE_REPLAY_V0",
        "duration": duration,
        "frame_size": FRAME_SIZE,
        "preview_size": 32,
        "tile_grid": TILE_GRID,
        "cell_grid": CELL_GRID,
        "frame_rate": FRAME_RATE,
        "sample_rate": SAMPLE_RATE,
        "visual": visual,
        "audio": audio,
        "waveform": waveform,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=0.8)
    parser.add_argument("--output", type=Path, default=ROOT / "sim" / "demo_data.json")
    args = parser.parse_args()
    data = generate(args.duration)
    args.output.write_text(json.dumps(data, separators=(",", ":")))
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
