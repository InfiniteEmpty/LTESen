import unittest

import numpy as np

from ltesen.ltephy import OfdmParameters, demodulate_full
from ltesen.ltetracking.csi_tracker import _estimate_phase_slope_fft


class PhyAndTrackingHelperTests(unittest.TestCase):
    def test_ofdm_helpers_live_in_ltephy(self):
        self.assertEqual(OfdmParameters.__module__, "ltesen.ltephy.ofdm")

    def test_full_ofdm_demodulation_retains_all_bins(self):
        params = OfdmParameters(16, 16_000.0, (2, 1))
        symbols = np.array(
            [
                np.arange(1, 17),
                np.arange(8, -8, -1),
                np.tile([0, 1], 8),
            ],
            dtype=np.complex128,
        )
        waveform = np.concatenate(
            [
                np.concatenate((row[-cp:], row))
                for row, cp in zip(symbols, (2, 1, 2))
            ]
        )[:, None]

        grid, info = demodulate_full(waveform, params, ndlrb=1)

        self.assertEqual(grid.shape, (16, 3, 1))
        np.testing.assert_allclose(grid[:, :, 0], np.fft.fft(symbols, axis=1).T / np.sqrt(16))
        np.testing.assert_array_equal(info.active_indices, np.array([10, 11, 12, 13, 14, 15, 1, 2, 3, 4, 5, 6]))
        self.assertEqual(info.dc_index, 0)
        np.testing.assert_array_equal(info.symbol_map, np.array([0, 1, 0]))

    def test_phase_slope_estimator_supports_trailing_dimensions(self):
        n_samples = 48
        frequency_bin = 5.25 / n_samples
        n = np.arange(n_samples)
        signal = np.exp(2j * np.pi * frequency_bin * n)[:, None, None]

        estimate = _estimate_phase_slope_fft(signal)

        self.assertEqual(estimate.shape, (1, 1, 1))
        self.assertAlmostEqual(float(estimate[0, 0, 0]), 5.25, places=2)


if __name__ == "__main__":
    unittest.main()
