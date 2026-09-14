import unittest

import numpy as np

from ltesen.ltephy import lte_frequency_correct, lte_frequency_offset, lte_ofdm_info


class FrequencyTests(unittest.TestCase):
    def test_frequency_correct_removes_positive_offset(self):
        sample_rate = 1.92e6
        offset_hz = 1250.0
        n = np.arange(4096)
        waveform = np.exp(2j * np.pi * offset_hz * n / sample_rate)

        corrected = lte_frequency_correct(
            {"sampling_rate_hz": sample_rate}, waveform, offset_hz
        )

        np.testing.assert_allclose(corrected, np.ones_like(waveform), atol=1e-12)
        self.assertEqual(corrected.ndim, 1)

    def test_frequency_offset_estimates_cp_phase_rotation(self):
        info = lte_ofdm_info({"ndlrb": 6})
        rng = np.random.default_rng(7)
        symbols = []
        for cp_length in info.cyclic_prefix_lengths:
            useful = rng.normal(size=info.nfft) + 1j * rng.normal(size=info.nfft)
            symbols.append(np.concatenate((useful[-cp_length:], useful)))
        clean = np.concatenate(symbols)
        expected_hz = -2400.0
        sample_index = np.arange(clean.size)
        impaired = clean * np.exp(2j * np.pi * expected_hz * sample_index / info.sampling_rate_hz)

        estimated, correlation = lte_frequency_offset(
            {"ndlrb": 6}, impaired[:, None], toffset=0, return_correlation=True
        )

        self.assertAlmostEqual(estimated, expected_hz, places=6)
        self.assertEqual(correlation.shape[1], 1)
        self.assertGreater(correlation.shape[0], 0)

    def test_frequency_offset_accepts_explicit_matlab_style_ofdm_info(self):
        waveform = np.ones((256, 1), dtype=np.complex128)
        config = {
            "OfdmInfo": {
                "Nfft": 64,
                "CyclicPrefixLengths": [8],
                "SamplingRate": 960_000.0,
            }
        }

        estimate = lte_frequency_offset(config, waveform, toffset=0)

        self.assertEqual(estimate, 0.0)


if __name__ == "__main__":
    unittest.main()
