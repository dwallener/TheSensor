"""Floating-point and bit-accurate fixed-point auditory reference models.

The model implements one STEREO_FILTERBANK_V0 work unit: a 256-sample signed
stereo window becomes sixteen eight-byte auditory cells. Eight consecutive slots
can be packed into the 1024-byte dense auditory-frame payload specified in
SPEC.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import cos, log10, pi, sin, sqrt
from typing import Sequence

SAMPLE_RATE = 48_000
WINDOW_SIZE = 256
HOP_SIZE = 128
BAND_COUNT = 16
CHANNEL_COUNT = 8

# Sixteen equal steps on the ERB-number scale from 125 Hz through 8 kHz.
CENTER_FREQUENCIES = (
    125,
    208,
    309,
    435,
    590,
    781,
    1_017,
    1_308,
    1_666,
    2_109,
    2_654,
    3_327,
    4_157,
    5_180,
    6_443,
    8_000,
)

INPUT_SHIFT = 4  # signed PCM16 -> signed 12-bit processing sample
COEFFICIENT_FRACTION_BITS = 12
STATE_BITS = 26
CORRELATION_SHIFT = 12
CORRELATION_SAMPLE_BITS = 12
DELTA_GAIN = 4


def _erb_number(frequency: float) -> float:
    return 21.4 * log10(1.0 + 0.00437 * frequency)


def design_erb_centres(
    low_hz: float = 125.0,
    high_hz: float = 8_000.0,
    count: int = BAND_COUNT,
) -> tuple[int, ...]:
    """Return rounded frequencies equally spaced on the ERB-number scale."""
    low = _erb_number(low_hz)
    high = _erb_number(high_hz)
    result = []
    for index in range(count):
        erb = low + index * (high - low) / (count - 1)
        frequency = (10 ** (erb / 21.4) - 1.0) / 0.00437
        result.append(round(frequency))
    return tuple(result)


def _quantize(value: float) -> int:
    return round(value * (1 << COEFFICIENT_FRACTION_BITS))


RESONATOR_COEFFICIENTS = tuple(
    _quantize(2.0 * cos(2.0 * pi * frequency / SAMPLE_RATE))
    for frequency in CENTER_FREQUENCIES
)
COSINE_COEFFICIENTS = tuple(
    _quantize(cos(2.0 * pi * frequency / SAMPLE_RATE))
    for frequency in CENTER_FREQUENCIES
)
SINE_COEFFICIENTS = tuple(
    _quantize(sin(2.0 * pi * frequency / SAMPLE_RATE))
    for frequency in CENTER_FREQUENCIES
)


@dataclass(frozen=True)
class AudioCell:
    left_energy: int
    right_energy: int
    mono_energy: int
    energy_delta: int
    onset_strength: int
    level_difference: int
    phase_lead: int
    stereo_confidence: int

    def as_bytes(self) -> bytes:
        values = (
            self.left_energy,
            self.right_energy,
            self.mono_energy,
            self.energy_delta,
            self.onset_strength,
            self.level_difference,
            self.phase_lead,
            self.stereo_confidence,
        )
        return bytes(value & 0xFF for value in values)


def _validate_window(left: Sequence[int], right: Sequence[int]) -> None:
    if len(left) != WINDOW_SIZE or len(right) != WINDOW_SIZE:
        raise ValueError(f"each channel must contain exactly {WINDOW_SIZE} samples")
    if any(sample < -32_768 or sample > 32_767 for sample in (*left, *right)):
        raise ValueError("input samples must be signed 16-bit values")


def _saturate_signed(value: int, bits: int) -> int:
    low = -(1 << (bits - 1))
    high = (1 << (bits - 1)) - 1
    return max(low, min(high, value))


def _saturate_u8(value: int) -> int:
    return max(0, min(255, value))


def _saturate_s8(value: int) -> int:
    return max(-128, min(127, value))


def _log_compress(value: int | float) -> int:
    """Hardware-friendly five-bit exponent plus three-bit mantissa."""
    integer = max(0, int(value))
    if integer == 0:
        return 0
    exponent = integer.bit_length() - 1
    if exponent >= 3:
        mantissa = (integer >> (exponent - 3)) & 0x7
    else:
        mantissa = (integer << (3 - exponent)) & 0x7
    return _saturate_u8(exponent * 8 + mantissa)


def _normalize_signed(numerator: int, companion: int) -> int:
    """Normalize a signed vector component using only leading-bit scaling."""
    scale_source = max(abs(numerator), abs(companion))
    if scale_source == 0:
        return 0
    shift = scale_source.bit_length() - 7
    value = numerator >> shift if shift >= 0 else numerator << -shift
    return _saturate_s8(value)


def _fixed_coherence(cross: int, left_square: int, right_square: int) -> int:
    if left_square <= 0 or right_square <= 0:
        return 0
    # Power-of-two approximation to sqrt(left_square * right_square).
    exponent = ((left_square.bit_length() - 1) + (right_square.bit_length() - 1)) // 2
    denominator = 1 << exponent
    return _saturate_u8((abs(cross) << 8) // denominator)


def _signal_gate(left_level: int, right_level: int) -> int:
    return _saturate_u8((min(left_level, right_level) - 40) * 4)


def process_window_fixed(left: Sequence[int], right: Sequence[int]) -> list[AudioCell]:
    """Process one stereo window using the proposed integer ASIC arithmetic."""
    _validate_window(left, right)
    cells = []
    q = COEFFICIENT_FRACTION_BITS

    for coefficient, cosine, sine in zip(
        RESONATOR_COEFFICIENTS, COSINE_COEFFICIENTS, SINE_COEFFICIENTS
    ):
        left_s1 = left_s2 = right_s1 = right_s2 = 0
        left_half_s1 = left_half_s2 = right_half_s1 = right_half_s2 = 0
        early_level = 0
        cross_acc = left_square = right_square = 0

        for index, (left_pcm, right_pcm) in enumerate(zip(left, right)):
            if index == WINDOW_SIZE // 2:
                left_half_s1 = left_half_s2 = right_half_s1 = right_half_s2 = 0
            left_input = left_pcm >> INPUT_SHIFT
            right_input = right_pcm >> INPUT_SHIFT
            left_state = _saturate_signed(
                left_input + ((coefficient * left_s1) >> q) - left_s2,
                STATE_BITS,
            )
            right_state = _saturate_signed(
                right_input + ((coefficient * right_s1) >> q) - right_s2,
                STATE_BITS,
            )
            left_s2, left_s1 = left_s1, left_state
            right_s2, right_s1 = right_s1, right_state
            left_half_state = _saturate_signed(
                left_input + ((coefficient * left_half_s1) >> q) - left_half_s2,
                STATE_BITS,
            )
            right_half_state = _saturate_signed(
                right_input + ((coefficient * right_half_s1) >> q) - right_half_s2,
                STATE_BITS,
            )
            left_half_s2, left_half_s1 = left_half_s1, left_half_state
            right_half_s2, right_half_s1 = right_half_s1, right_half_state

            if index == WINDOW_SIZE // 2 - 1:
                left_half_real = left_half_s1 - ((cosine * left_half_s2) >> q)
                left_half_imag = (sine * left_half_s2) >> q
                right_half_real = right_half_s1 - ((cosine * right_half_s2) >> q)
                right_half_imag = (sine * right_half_s2) >> q
                early_level = _log_compress(
                    (
                        abs(left_half_real + right_half_real)
                        + abs(left_half_imag + right_half_imag)
                    )
                    >> 1
                )

            left_narrow = _saturate_signed(
                left_state >> CORRELATION_SHIFT, CORRELATION_SAMPLE_BITS
            )
            right_narrow = _saturate_signed(
                right_state >> CORRELATION_SHIFT, CORRELATION_SAMPLE_BITS
            )
            cross_acc += left_narrow * right_narrow
            left_square += left_narrow * left_narrow
            right_square += right_narrow * right_narrow

        left_real = left_s1 - ((cosine * left_s2) >> q)
        left_imag = (sine * left_s2) >> q
        right_real = right_s1 - ((cosine * right_s2) >> q)
        right_imag = (sine * right_s2) >> q

        left_level = _log_compress(abs(left_real) + abs(left_imag))
        right_level = _log_compress(abs(right_real) + abs(right_imag))
        mono_level = _log_compress(
            (abs(left_real + right_real) + abs(left_imag + right_imag)) >> 1
        )
        left_half_real = left_half_s1 - ((cosine * left_half_s2) >> q)
        left_half_imag = (sine * left_half_s2) >> q
        right_half_real = right_half_s1 - ((cosine * right_half_s2) >> q)
        right_half_imag = (sine * right_half_s2) >> q
        late_level = _log_compress(
            (
                abs(left_half_real + right_half_real)
                + abs(left_half_imag + right_half_imag)
            )
            >> 1
        )
        delta = _saturate_s8((late_level - early_level) * DELTA_GAIN)

        # Positive means the right channel leads the left channel.
        phase_cross = left_real * right_imag - left_imag * right_real
        phase_dot = left_real * right_real + left_imag * right_imag
        phase_lead = _normalize_signed(phase_cross, phase_dot)
        coherence = _fixed_coherence(cross_acc, left_square, right_square)

        cells.append(
            AudioCell(
                left_energy=left_level,
                right_energy=right_level,
                mono_energy=mono_level,
                energy_delta=delta,
                onset_strength=max(0, delta),
                level_difference=_saturate_s8(right_level - left_level),
                phase_lead=phase_lead,
                stereo_confidence=min(coherence, _signal_gate(left_level, right_level)),
            )
        )
    return cells


def process_window_float(left: Sequence[int], right: Sequence[int]) -> list[AudioCell]:
    """Process one window without coefficient/state quantization.

    Byte companding is retained so outputs can be compared at the canonical
    representation boundary.
    """
    _validate_window(left, right)
    cells = []

    for frequency in CENTER_FREQUENCIES:
        omega = 2.0 * pi * frequency / SAMPLE_RATE
        coefficient = 2.0 * cos(omega)
        cosine = cos(omega)
        sine = sin(omega)
        left_s1 = left_s2 = right_s1 = right_s2 = 0.0
        left_half_s1 = left_half_s2 = right_half_s1 = right_half_s2 = 0.0
        early_level = 0
        cross_acc = left_square = right_square = 0.0

        for index, (left_pcm, right_pcm) in enumerate(zip(left, right)):
            if index == WINDOW_SIZE // 2:
                left_half_s1 = left_half_s2 = right_half_s1 = right_half_s2 = 0.0
            left_input = left_pcm / (1 << INPUT_SHIFT)
            right_input = right_pcm / (1 << INPUT_SHIFT)
            left_state = left_input + coefficient * left_s1 - left_s2
            right_state = right_input + coefficient * right_s1 - right_s2
            left_s2, left_s1 = left_s1, left_state
            right_s2, right_s1 = right_s1, right_state
            left_half_state = left_input + coefficient * left_half_s1 - left_half_s2
            right_half_state = right_input + coefficient * right_half_s1 - right_half_s2
            left_half_s2, left_half_s1 = left_half_s1, left_half_state
            right_half_s2, right_half_s1 = right_half_s1, right_half_state
            if index == WINDOW_SIZE // 2 - 1:
                left_half_real = left_half_s1 - cosine * left_half_s2
                left_half_imag = sine * left_half_s2
                right_half_real = right_half_s1 - cosine * right_half_s2
                right_half_imag = sine * right_half_s2
                early_level = _log_compress(
                    (
                        abs(left_half_real + right_half_real)
                        + abs(left_half_imag + right_half_imag)
                    )
                    / 2.0
                )
            cross_acc += left_state * right_state
            left_square += left_state * left_state
            right_square += right_state * right_state

        left_real = left_s1 - cosine * left_s2
        left_imag = sine * left_s2
        right_real = right_s1 - cosine * right_s2
        right_imag = sine * right_s2
        left_level = _log_compress(abs(left_real) + abs(left_imag))
        right_level = _log_compress(abs(right_real) + abs(right_imag))
        mono_level = _log_compress(
            (abs(left_real + right_real) + abs(left_imag + right_imag)) / 2.0
        )
        left_half_real = left_half_s1 - cosine * left_half_s2
        left_half_imag = sine * left_half_s2
        right_half_real = right_half_s1 - cosine * right_half_s2
        right_half_imag = sine * right_half_s2
        late_level = _log_compress(
            (
                abs(left_half_real + right_half_real)
                + abs(left_half_imag + right_half_imag)
            )
            / 2.0
        )
        delta = _saturate_s8((late_level - early_level) * DELTA_GAIN)
        phase_cross = left_real * right_imag - left_imag * right_real
        phase_dot = left_real * right_real + left_imag * right_imag
        phase_lead = _normalize_signed(round(phase_cross), round(phase_dot))
        denominator = sqrt(left_square * right_square)
        coherence = 0 if denominator == 0 else _saturate_u8(round(255 * abs(cross_acc) / denominator))

        cells.append(
            AudioCell(
                left_energy=left_level,
                right_energy=right_level,
                mono_energy=mono_level,
                energy_delta=delta,
                onset_strength=max(0, delta),
                level_difference=_saturate_s8(right_level - left_level),
                phase_lead=phase_lead,
                stereo_confidence=min(coherence, _signal_gate(left_level, right_level)),
            )
        )
    return cells


def pack_time_slot(cells: Sequence[AudioCell]) -> bytes:
    if len(cells) != BAND_COUNT:
        raise ValueError(f"a time slot must contain exactly {BAND_COUNT} cells")
    return b"".join(cell.as_bytes() for cell in cells)


def assemble_frame(slots: Sequence[Sequence[AudioCell]]) -> bytes:
    """Flatten eight oldest-to-newest slots into the 1024-byte payload."""
    if len(slots) != 8:
        raise ValueError("an auditory frame must contain exactly eight time slots")
    payload = b"".join(pack_time_slot(slot) for slot in slots)
    assert len(payload) == 1024
    return payload


def coefficient_table() -> tuple[tuple[int, int, int, int], ...]:
    """Return (frequency, resonator, cosine, sine) integer constants."""
    return tuple(
        zip(
            CENTER_FREQUENCIES,
            RESONATOR_COEFFICIENTS,
            COSINE_COEFFICIENTS,
            SINE_COEFFICIENTS,
        )
    )
