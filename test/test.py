import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from reference.visual_tile_model import COMMAND, process_tile  # noqa: E402

from reference.audio_model import (  # noqa: E402
    CENTER_FREQUENCIES,
    SAMPLE_RATE,
    WINDOW_SIZE,
    pack_time_slot,
    process_window_fixed,
)
from reference.visual_field_model import (  # noqa: E402
    COMMAND as FIELD_COMMAND,
    process_visual_field,
)
from reference.auditory_field_model import (  # noqa: E402
    AuditoryFieldModel,
    COMMAND as AUDIO_FIELD_COMMAND,
)


def _pin(value, bit):
    return (int(value) >> bit) & 1


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_byte(dut, value):
    """Drive one input byte, holding valid until the core accepts it."""
    dut.ui_in.value = value
    dut.uio_in.value = 0b01
    await Timer(1, unit="ns")
    while not _pin(dut.uio_out.value, 2):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ns")
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.uio_in.value = 0


async def receive_response(dut, length=12, stall=False):
    result = []
    cycle = 0
    while len(result) < length:
        ready = not stall or cycle % 3 != 1
        dut.uio_in.value = 0b10 if ready else 0
        await Timer(1, unit="ns")
        valid = _pin(dut.uio_out.value, 3)
        if valid and ready:
            assert _pin(dut.uio_out.value, 6) == (len(result) == 0)
            assert _pin(dut.uio_out.value, 7) == (len(result) == length - 1)
            result.append(int(dut.uo_out.value))
        cycle += 1
        assert cycle < length * 8
        await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    return result


async def process(dut, current, previous, stall=False):
    await send_byte(dut, COMMAND)
    for now, before in zip(current, previous):
        await send_byte(dut, now)
        await send_byte(dut, before)
    return await receive_response(dut, stall=stall)


async def process_audio(dut, left, right, stall=False):
    await send_byte(dut, 0xB0)
    for left_sample in left:
        await send_byte(dut, left_sample & 0xFF)
    for right_sample in right:
        await send_byte(dut, right_sample & 0xFF)
    return await receive_response(dut, length=130, stall=stall)


async def process_field(dut, records, stall=False):
    await send_byte(dut, FIELD_COMMAND)
    for record in records:
        for value in record:
            await send_byte(dut, value)
    return await receive_response(dut, length=18, stall=stall)


async def process_audio_field(dut, slots, stall=False):
    await send_byte(dut, AUDIO_FIELD_COMMAND)
    for bands, status in slots:
        for record in bands:
            for value in record:
                await send_byte(dut, value)
        await send_byte(dut, status)
    return await receive_response(dut, length=18, stall=stall)


@cocotb.test()
async def test_feature_kernel(dut):
    """Exercise flat, oriented, temporal, motion, random, and backpressure cases."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    flat = [73] * 256
    cases = [(flat, flat)]
    horizontal_bars = [255 if (i // 16) & 1 else 0 for i in range(256)]
    vertical_bars = [255 if (i % 16) & 1 else 0 for i in range(256)]
    diagonal = [255 if ((i // 16) + (i % 16)) & 1 else 0 for i in range(256)]
    cases.extend([
        (horizontal_bars, horizontal_bars),
        (vertical_bars, vertical_bars),
        (diagonal, diagonal),
        ([255] * 256, [0] * 256),
        ([0] * 256, [255] * 256),
    ])

    moving_previous = [0] * 256
    moving_current = [0] * 256
    for y in range(4, 12):
        for x in range(3, 8):
            moving_previous[y * 16 + x] = 224
            moving_current[y * 16 + x + 1] = 224
    cases.append((moving_current, moving_previous))

    rng = random.Random(0x5E1150)
    for _ in range(3):
        cases.append((
            [rng.randrange(256) for _ in range(256)],
            [rng.randrange(256) for _ in range(256)],
        ))

    for index, (current, previous) in enumerate(cases):
        actual = await process(dut, current, previous, stall=(index % 2 == 1))
        expected = process_tile(current, previous)
        assert actual == expected, f"case {index}: {actual} != {expected}"

    await send_byte(dut, 0x00)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert _pin(dut.uio_out.value, 5), "invalid command must set error"

    await Timer(1, unit="ns")
    await send_byte(dut, COMMAND)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert not _pin(dut.uio_out.value, 5), "valid command must clear error"


@cocotb.test()
async def test_full_scale_temporal_step_from_reset(dut):
    """Isolate the full-scale temporal step from all preceding work units."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    current = [255] * 256
    previous = [0] * 256
    actual = await process(dut, current, previous)
    expected = process_tile(current, previous)
    assert actual == expected, f"full-scale step: {actual} != {expected}"


@cocotb.test()
async def test_stereo_filterbank(dut):
    """Match silence and a spatially asymmetric tone against the fixed model."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    cases = [([0] * WINDOW_SIZE, [0] * WINDOW_SIZE)]
    frequency = CENTER_FREQUENCIES[8]
    left = [
        round(31 * math.sin(2 * math.pi * frequency * n / SAMPLE_RATE))
        for n in range(WINDOW_SIZE)
    ]
    right = [
        round(47 * math.sin(
            2 * math.pi * frequency * n / SAMPLE_RATE
            + 2 * math.pi * frequency / SAMPLE_RATE
        ))
        for n in range(WINDOW_SIZE)
    ]
    cases.append((left, right))

    for index, (left_samples, right_samples) in enumerate(cases):
        actual = await process_audio(
            dut, left_samples, right_samples, stall=(index == 1)
        )
        payload = list(pack_time_slot(
            process_window_fixed(left_samples, right_samples)
        ))
        expected = [0x5B, *payload, 0]
        if actual != expected:
            mismatch = next(
                offset
                for offset, (got, wanted) in enumerate(zip(actual, expected))
                if got != wanted
            )
            raise AssertionError(
                f"audio case {index} byte {mismatch}: "
                f"got {actual[mismatch]:#04x}, expected {expected[mismatch]:#04x}; "
                f"actual={actual}, expected={expected}"
            )


@cocotb.test()
async def test_visual_field(dut):
    """Pool local records into translation, expansion, rotation, and saliency."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    neutral = [[64, 10, 20, 21, 22, 23, 0, 0, 0, 0, 0] for _ in range(64)]
    translation = [
        [64, 20, 30, 31, 32, 33, 0, 20, 0, 40, 0] for _ in range(64)
    ]
    expansion = []
    rotation = []
    for tile in range(64):
        x2 = 2 * (tile & 7) - 7
        y2 = 2 * (tile >> 3) - 7
        expansion.append([
            80, 24, 30, 30, 30, 30, 0,
            (x2 * 8) & 0xFF, (y2 * 8) & 0xFF, 100, 0,
        ])
        rotation.append([
            80, 24, 30, 30, 30, 30, 0,
            (-y2 * 8) & 0xFF, (x2 * 8) & 0xFF, 100, 0,
        ])
    localized = [[0] * 11 for _ in range(64)]
    localized[63] = [90, 200, 0, 0, 0, 0, 40, 0, 0, 55, 0x08]

    rng = random.Random(0xA1F13D)
    randomized = [
        [rng.randrange(256) for _ in range(11)] for _ in range(64)
    ]
    cases = [neutral, translation, expansion, rotation, localized, randomized]

    for index, records in enumerate(cases):
        actual = await process_field(dut, records, stall=(index & 1) == 1)
        expected = process_visual_field(records)
        assert actual == expected, (
            f"visual field case {index}: actual={actual}, expected={expected}"
        )


@cocotb.test()
async def test_auditory_field(dut):
    """Integrate auditory slots across frequency, time, and stereo evidence."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)
    model = AuditoryFieldModel()

    def blank_slots():
        return [([[0] * 8 for _ in range(16)], 0) for _ in range(8)]

    silence = blank_slots()

    steady = blank_slots()
    for slot, (bands, _) in enumerate(steady):
        bands[5] = [100, 100, 100, 0, 80 if slot == 0 else 0, 20, 10, 200]

    transient = blank_slots()
    transient[0][0][10] = [200, 200, 200, 127, 200, -25 & 0xFF, -12 & 0xFF, 180]
    transient[1][0][10] = [0, 0, 0, -100 & 0xFF, 0, -10 & 0xFF, -5 & 0xFF, 80]
    transient[3] = (transient[3][0], 0x04)

    moving = blank_slots()
    for slot, (bands, _) in enumerate(moving):
        level = -36 + slot * 12
        bands[7] = [90, 90, 90, 0, 0, level & 0xFF, (level // 2) & 0xFF, 190]

    rng = random.Random(0xB1F13D)
    randomized = []
    for slot in range(8):
        bands = [[rng.randrange(256) for _ in range(8)] for _ in range(16)]
        randomized.append((bands, 1 << (slot & 3)))

    cases = [silence, steady, steady, transient, moving, randomized]
    novelty_outputs = []
    for index, slots in enumerate(cases):
        actual = await process_audio_field(dut, slots, stall=(index & 1) == 1)
        expected = model.process(slots)
        assert actual == expected, (
            f"auditory field case {index}: actual={actual}, expected={expected}"
        )
        novelty_outputs.append(actual[16])
    assert novelty_outputs[2] < novelty_outputs[1], (
        "a repeated stationary spectrum must become less novel"
    )
