import math
import random

from reference.audio_model import (
    BAND_COUNT,
    CENTER_FREQUENCIES,
    RESONATOR_COEFFICIENTS,
    SAMPLE_RATE,
    WINDOW_SIZE,
    assemble_frame,
    coefficient_table,
    design_erb_centres,
    pack_time_slot,
    process_window_fixed,
    process_window_float,
)


def tone(frequency, amplitude=12_000, phase=0.0):
    return [
        round(amplitude * math.sin(2 * math.pi * frequency * n / SAMPLE_RATE + phase))
        for n in range(WINDOW_SIZE)
    ]


def peak_band(cells):
    return max(range(BAND_COUNT), key=lambda index: cells[index].mono_energy)


def test_erb_centres_and_coefficients_are_frozen():
    assert design_erb_centres() == CENTER_FREQUENCIES
    assert CENTER_FREQUENCIES == (
        125, 208, 309, 435, 590, 781, 1017, 1308,
        1666, 2109, 2654, 3327, 4157, 5180, 6443, 8000,
    )
    assert RESONATOR_COEFFICIENTS == (
        8188, 8180, 8165, 8139, 8094, 8021, 7903, 7716,
        7425, 6975, 6293, 5276, 3801, 1745, -948, -4096,
    )
    assert coefficient_table() == (
        (125, 8188, 4094, 134),
        (208, 8180, 4090, 223),
        (309, 8165, 4083, 331),
        (435, 8139, 4069, 465),
        (590, 8094, 4047, 630),
        (781, 8021, 4011, 832),
        (1017, 7903, 3952, 1078),
        (1308, 7716, 3858, 1375),
        (1666, 7425, 3713, 1730),
        (2109, 6975, 3487, 2148),
        (2654, 6293, 3146, 2622),
        (3327, 5276, 2638, 3133),
        (4157, 3801, 1901, 3628),
        (5180, 1745, 873, 4002),
        (6443, -948, -474, 4068),
        (8000, -4096, -2048, 3547),
    )


def test_silence_is_quiet_and_unlocalized():
    cells = process_window_fixed([0] * WINDOW_SIZE, [0] * WINDOW_SIZE)
    for cell in cells:
        assert cell.left_energy == 0
        assert cell.right_energy == 0
        assert cell.mono_energy == 0
        assert cell.energy_delta == 0
        assert cell.phase_lead == 0
        assert cell.stereo_confidence == 0


def test_tones_peak_in_the_expected_bands_and_float_agrees():
    for expected in (2, 6, 10, 14):
        samples = tone(CENTER_FREQUENCIES[expected])
        fixed = process_window_fixed(samples, samples)
        floating = process_window_float(samples, samples)
        assert abs(peak_band(fixed) - expected) <= 1
        assert abs(peak_band(floating) - expected) <= 1
        assert abs(peak_band(fixed) - peak_band(floating)) <= 1


def test_level_difference_sign_points_toward_louder_ear():
    frequency = CENTER_FREQUENCIES[8]
    quiet = tone(frequency, amplitude=4_000)
    loud = tone(frequency, amplitude=16_000)
    band = 8
    assert process_window_fixed(quiet, loud)[band].level_difference > 0
    assert process_window_fixed(loud, quiet)[band].level_difference < 0


def test_right_lead_has_positive_phase_evidence():
    band = 7
    frequency = CENTER_FREQUENCIES[band]
    omega = 2 * math.pi * frequency / SAMPLE_RATE
    left = tone(frequency)
    right_leading = tone(frequency, phase=omega)
    right_lagging = tone(frequency, phase=-omega)
    assert process_window_fixed(left, right_leading)[band].phase_lead > 0
    assert process_window_fixed(left, right_lagging)[band].phase_lead < 0


def test_onset_and_offset_have_opposite_delta():
    frequency = CENTER_FREQUENCIES[9]
    wave = tone(frequency)
    half = WINDOW_SIZE // 2
    onset = [sample // 8 for sample in wave[:half]] + wave[half:]
    offset = wave[:half] + [sample // 8 for sample in wave[half:]]
    assert process_window_fixed(onset, onset)[9].energy_delta > 0
    assert process_window_fixed(onset, onset)[9].onset_strength > 0
    assert process_window_fixed(offset, offset)[9].energy_delta < 0
    assert process_window_fixed(offset, offset)[9].onset_strength == 0


def test_uncorrelated_noise_reduces_stereo_confidence():
    rng = random.Random(0xA0D10)
    left = [rng.randrange(-12_000, 12_001) for _ in range(WINDOW_SIZE)]
    unrelated = [rng.randrange(-12_000, 12_001) for _ in range(WINDOW_SIZE)]
    coherent = process_window_fixed(left, left)
    incoherent = process_window_fixed(left, unrelated)
    coherent_mean = sum(cell.stereo_confidence for cell in coherent) / BAND_COUNT
    incoherent_mean = sum(cell.stereo_confidence for cell in incoherent) / BAND_COUNT
    assert coherent_mean > incoherent_mean + 20


def test_slot_and_frame_packing_are_canonical_size():
    samples = tone(CENTER_FREQUENCIES[5])
    slot = process_window_fixed(samples, samples)
    assert len(pack_time_slot(slot)) == 128
    frame = assemble_frame([slot] * 8)
    assert len(frame) == 1024
    assert frame[:128] == frame[128:256]
