"""Bit-accurate stateful model for the AUDITORY_FIELD_V0 kernel."""

from __future__ import annotations

COMMAND = 0xB1
RESPONSE = 0x5D
SLOT_COUNT = 8
BAND_COUNT = 16
CHANNEL_COUNT = 8


def _signed(value: int) -> int:
    return value - 256 if value & 0x80 else value


def _s8(value: int) -> int:
    return max(-128, min(127, value)) & 0xFF


def _u8(value: int) -> int:
    return max(0, min(255, value))


def _power_two_ratio(numerator: int, denominator: int, scale_bits: int = 0) -> int:
    if denominator <= 0:
        return 0
    shift = denominator.bit_length() - 1
    return (numerator << scale_bits) >> shift


class AuditoryFieldModel:
    """Retains the same slowly adapting sixteen-band baseline as the RTL."""

    def __init__(self) -> None:
        self.baseline = [0] * BAND_COUNT

    def process(self, slots: list[tuple[list[list[int]], int]]) -> list[int]:
        if len(slots) != SLOT_COUNT:
            raise ValueError(f"an auditory field must contain {SLOT_COUNT} slots")

        total = low = middle = high = 0
        weighted_band = weighted_spread = 0
        onset = offset = confidence_sum = 0
        weighted_level = weighted_phase = 0
        early_level = late_level = 0
        band_sums = [0] * BAND_COUNT
        slot_totals = []
        status = 0

        for slot_index, (bands, slot_status) in enumerate(slots):
            if len(bands) != BAND_COUNT:
                raise ValueError("each slot must contain sixteen band records")
            slot_total = 0
            for band_index, record in enumerate(bands):
                if len(record) != CHANNEL_COUNT:
                    raise ValueError("each band record must contain eight bytes")
                if any(not 0 <= value <= 255 for value in record):
                    raise ValueError("band records must contain unsigned bytes")
                mono = record[2]
                delta = _signed(record[3])
                level = _signed(record[5])
                phase = _signed(record[6])
                confidence = record[7]
                total += mono
                slot_total += mono
                band_sums[band_index] += mono
                if band_index < 4:
                    low += mono
                elif band_index < 12:
                    middle += mono
                else:
                    high += mono
                weighted_band += band_index * mono
                weighted_spread += abs(2 * band_index - 15) * mono
                onset += record[4]
                if delta < 0:
                    offset += -delta
                confidence_sum += confidence
                weighted_level += level * confidence
                weighted_phase += phase * confidence
                if slot_index < 4:
                    early_level += level
                else:
                    late_level += level
            slot_totals.append(slot_total)
            status |= slot_status

        strongest_band = max(range(BAND_COUNT), key=band_sums.__getitem__)
        novelty = 0
        for band, band_sum in enumerate(band_sums):
            current = band_sum >> 3
            novelty += abs(current - self.baseline[band])
            self.baseline[band] += (current - self.baseline[band]) >> 3

        peak_slot = max(slot_totals)
        mean_slot = total >> 3
        impulsiveness = max(0, peak_slot - mean_slot) >> 4
        modulation = sum(
            abs(now - before) for before, now in zip(slot_totals, slot_totals[1:])
        ) >> 7
        centroid = _power_two_ratio(weighted_band, total, 4)
        spread = _power_two_ratio(weighted_spread, total, 4)
        level = _power_two_ratio(weighted_level, confidence_sum)
        phase = _power_two_ratio(weighted_phase, confidence_sum)
        lateral_motion = (late_level - early_level) >> 6

        payload = [
            total >> 7,
            low >> 5,
            middle >> 6,
            high >> 5,
            _u8(centroid),
            _u8(spread),
            _u8(onset >> 7),
            _u8(offset >> 7),
            strongest_band * 17,
            _u8(impulsiveness),
            _u8(modulation),
            _s8(level),
            _s8(phase),
            _s8(lateral_motion),
            confidence_sum >> 7,
            novelty >> 4,
        ]
        return [RESPONSE, *payload, status]
