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
        8191, 8189, 8185, 8179, 8168, 8149, 8120, 8072,
        7998, 7882, 7703, 7427, 7009, 6380, 5447, 4096,
    )
    assert coefficient_table() == (
        (125, 8191, 4095, 67),
        (208, 8189, 4094, 112),
        (309, 8185, 4093, 166),
        (435, 8179, 4089, 233),
        (590, 8168, 4084, 316),
        (781, 8149, 4075, 418),
        (1017, 8120, 4060, 544),
        (1308, 8072, 4036, 698),
        (1666, 7998, 3999, 886),
        (2109, 7882, 3941, 1116),
        (2654, 7703, 3851, 1395),
        (3327, 7427, 3714, 1728),
        (4157, 7009, 3504, 2120),
        (5180, 6380, 3190, 2569),
        (6443, 5447, 2724, 3059),
        (8000, 4096, 2048, 3547),
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
    onset = [sample // 8 for sample in wave[:128]] + wave[128:]
    offset = wave[:128] + [sample // 8 for sample in wave[128:]]
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
