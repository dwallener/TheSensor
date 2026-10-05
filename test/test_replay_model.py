"""Tests for framebuffer tiling and canonical visual-cell pooling."""

from sim.run_reference import CELL_GRID, TILE_GRID, _pool_visual_tiles


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
