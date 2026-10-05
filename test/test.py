import math
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from model import COMMAND, process_tile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from reference.audio_model import (  # noqa: E402
    CENTER_FREQUENCIES,
    SAMPLE_RATE,
    WINDOW_SIZE,
    pack_time_slot,
    process_window_fixed,
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
    for left_sample, right_sample in zip(left, right):
        left_word = left_sample & 0xFFFF
        right_word = right_sample & 0xFFFF
        await send_byte(dut, left_word & 0xFF)
        await send_byte(dut, left_word >> 8)
        await send_byte(dut, right_word & 0xFF)
        await send_byte(dut, right_word >> 8)
    return await receive_response(dut, length=130, stall=stall)


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
        round(8_000 * math.sin(2 * math.pi * frequency * n / SAMPLE_RATE))
        for n in range(WINDOW_SIZE)
    ]
    right = [
        round(12_000 * math.sin(
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
