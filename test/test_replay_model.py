"""Tests for framebuffer replay encoding and canonical visual-cell pooling."""

import base64
import struct

from sim.run_reference import (
    CELL_GRID,
    FRAME_SIZE,
    TILE_GRID,
    _frame_png,
    _pool_visual_tiles,
    _visual_vector,
)


def test_pool_visual_tiles_averages_unsigned_and_signed_channels() -> None:
    records = []
    for y in range(TILE_GRID):
        for x in range(TILE_GRID):
            signed_value = x - 8
            records.append([
                x + y,
                40,
                12,
                16,
                20,
                24,
                signed_value & 0xFF,
                (-signed_value) & 0xFF,
                4,
                80,
                1 << ((x + y) & 3),
            ])

    cells = _pool_visual_tiles(records)

    assert len(cells) == CELL_GRID * CELL_GRID
    assert cells[0][0] == 1
    assert cells[0][6] == ((-8 + -7 + -8 + -7) // 4) & 0xFF
    assert cells[0][7] == ((8 + 7 + 8 + 7) // 4) & 0xFF
    assert cells[0][10] == 0x07


def test_full_frame_png_has_sensor_dimensions() -> None:
    uri = _frame_png([73] * (FRAME_SIZE * FRAME_SIZE))
    prefix = "data:image/png;base64,"
    assert uri.startswith(prefix)
    png = base64.b64decode(uri[len(prefix) :])
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", png[16:24])
    assert (width, height) == (FRAME_SIZE, FRAME_SIZE)


def test_dense_and_compatibility_vectors_are_cell_major() -> None:
    record = [10, 20, 30, 40, 50, 60, 0xFE, 2, 3, 90, 0]
    dense = base64.b64decode(_visual_vector([record] * (TILE_GRID * TILE_GRID)))
    compatibility = base64.b64decode(_visual_vector([record] * (CELL_GRID * CELL_GRID)))
    expected_cell = bytes(record[:10] + [0] * 6)
    assert len(dense) == 4096
    assert len(compatibility) == 1024
    assert dense[:16] == expected_cell
    assert dense[16:32] == expected_cell
