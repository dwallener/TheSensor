"""Bit-accurate reference model for the VISUAL_FIELD_V0 integration kernel."""

from __future__ import annotations

COMMAND = 0xA1
RESPONSE = 0x5C
GRID_SIZE = 8
TILE_COUNT = GRID_SIZE * GRID_SIZE
TILE_RECORD_BYTES = 11


def _signed(value: int) -> int:
    return value - 256 if value & 0x80 else value


def _signed_byte(value: int) -> int:
    return max(-128, min(127, value)) & 0xFF


def _unsigned_byte(value: int) -> int:
    return max(0, min(255, value))


def process_visual_field(records: list[list[int]]) -> list[int]:
    """Pool 64 MONO_TEMPORAL_V0 payload records into one reflex vector.

    Each record contains the ten feature bytes and status byte, excluding the
    leading 0x5A response marker.
    """
    if len(records) != TILE_COUNT:
        raise ValueError(f"a visual field must contain {TILE_COUNT} tile records")
    if any(len(record) != TILE_RECORD_BYTES for record in records):
        raise ValueError(f"each tile record must contain {TILE_RECORD_BYTES} bytes")
    if any(not 0 <= value <= 255 for record in records for value in record):
        raise ValueError("tile records must contain unsigned bytes")

    unsigned_sums = [0] * 6
    temporal_sum = motion_x_sum = motion_y_sum = 0
    confidence_sum = 0
    expansion_sum = rotation_sum = 0
    saliency_x_sum = saliency_y_sum = 0
    activity_sum = 0
    status = 0

    for tile_index, record in enumerate(records):
        x = tile_index & 7
        y = tile_index >> 3
        x2 = 2 * x - 7
        y2 = 2 * y - 7
        for channel in range(6):
            unsigned_sums[channel] += record[channel]
        temporal = _signed(record[6])
        motion_x = _signed(record[7])
        motion_y = _signed(record[8])
        confidence = record[9]
        activity = min(255, record[1] + abs(temporal) + confidence)

        temporal_sum += temporal
        motion_x_sum += motion_x
        motion_y_sum += motion_y
        confidence_sum += confidence
        expansion_sum += x2 * motion_x + y2 * motion_y
        rotation_sum += x2 * motion_y - y2 * motion_x
        saliency_x_sum += x2 * activity
        saliency_y_sum += y2 * activity
        activity_sum += activity
        status |= record[10]

    directional = (abs(motion_x_sum) + abs(motion_y_sum)) >> 5
    payload = [value >> 6 for value in unsigned_sums]
    payload.extend(
        [
            _signed_byte(temporal_sum >> 6),
            _signed_byte(motion_x_sum >> 6),
            _signed_byte(motion_y_sum >> 6),
            confidence_sum >> 6,
            _signed_byte(expansion_sum >> 8),
            _signed_byte(rotation_sum >> 8),
            _signed_byte(saliency_x_sum >> 9),
            _signed_byte(saliency_y_sum >> 9),
            activity_sum >> 6,
            _unsigned_byte(directional),
        ]
    )
    return [RESPONSE, *payload, status]
