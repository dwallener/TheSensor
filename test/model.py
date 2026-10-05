"""Bit-accurate reference model for the MONO_TEMPORAL_V0 tile kernel."""

TILE_SIZE = 16
COMMAND = 0xA0
RESPONSE = 0x5A


def _signed_byte(value: int) -> tuple[int, bool]:
    saturated = value > 127 or value < -128
    return max(-128, min(127, value)) & 0xFF, saturated


def process_tile(current: list[int], previous: list[int]) -> list[int]:
    """Return the twelve-byte RTL response for two raster-order 16x16 tiles."""
    if len(current) != 256 or len(previous) != 256:
        raise ValueError("current and previous tiles must each contain 256 pixels")
    if any(not 0 <= pixel <= 255 for pixel in current + previous):
        raise ValueError("pixels must be unsigned bytes")

    luminance_sum = sum(current)
    horizontal = rising = vertical = falling = 0
    temporal = 0
    motion_x = motion_y = confidence = 0

    for y in range(TILE_SIZE):
        for x in range(TILE_SIZE):
            index = y * TILE_SIZE + x
            now = current[index]
            before = previous[index]
            temporal += now - before

            if x:
                left = index - 1
                vertical += abs(now - current[left])
                correlation = ((previous[left] >> 4) * (now >> 4)) - (
                    (current[left] >> 4) * (before >> 4)
                )
                motion_x += correlation
                confidence += abs(correlation)

            if y:
                up = index - TILE_SIZE
                horizontal += abs(now - current[up])
                correlation = ((previous[up] >> 4) * (now >> 4)) - (
                    (current[up] >> 4) * (before >> 4)
                )
                motion_y += correlation
                confidence += abs(correlation)
                if x:
                    rising += abs(now - current[up - 1])
                if x != TILE_SIZE - 1:
                    falling += abs(now - current[up + 1])

    temporal_byte, temporal_sat = _signed_byte(temporal >> 8)
    motion_x_byte, motion_x_sat = _signed_byte(motion_x >> 8)
    motion_y_byte, motion_y_sat = _signed_byte(motion_y >> 8)
    confidence_value = confidence >> 9
    confidence_sat = confidence_value > 255
    status = temporal_sat | (motion_x_sat << 1) | (motion_y_sat << 2) | (confidence_sat << 3)

    return [
        RESPONSE,
        luminance_sum >> 8,
        max(current) - min(current),
        horizontal >> 8,
        rising >> 8,
        vertical >> 8,
        falling >> 8,
        temporal_byte,
        motion_x_byte,
        motion_y_byte,
        min(255, confidence_value),
        status,
    ]
