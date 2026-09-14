import unittest

import numpy as np

from ltesen.ltephy import lte_ofdm_demodulate, lte_ofdm_info


def make_resource_waveform(ndlrb: int = 6) -> tuple[np.ndarray, np.ndarray]:
    info = lte_ofdm_info({"NDLRB": ndlrb, "CyclicPrefix": "Normal"})
    active = np.concatenate(
        (
            np.arange(info.nfft - ndlrb * 6, info.nfft),
            np.arange(1, ndlrb * 6 + 1),
        )
    )
    rng = np.random.default_rng(172)
    resource_grid = (
        rng.standard_normal((ndlrb * 12, len(info.cyclic_prefix_lengths)))
        + 1j * rng.standard_normal((ndlrb * 12, len(info.cyclic_prefix_lengths)))
    )
    waveform_parts = []
    for symbol_index, cp_length in enumerate(info.cyclic_prefix_lengths):
        spectrum = np.zeros(info.nfft, dtype=np.complex128)
        spectrum[active] = resource_grid[:, symbol_index]
        useful = np.fft.ifft(spectrum)
        waveform_parts.append(np.concatenate((useful[-cp_length:], useful)))
    return np.concatenate(waveform_parts), resource_grid


class OfdmDemodulateTests(unittest.TestCase):
    def test_demodulate_returns_active_grid_with_matlab_fft_scaling(self):
        waveform, expected = make_resource_waveform()

        grid = lte_ofdm_demodulate(
            {"NDLRB": 6, "CyclicPrefix": "Normal"},
            waveform[:, None],
            cp_fraction=0.55,
        )

        self.assertEqual(grid.shape, (72, 14, 1))
        np.testing.assert_allclose(grid[:, :, 0], expected, atol=1e-11, rtol=1e-11)

    def test_demodulate_accepts_vector_and_explicit_fft_size(self):
        waveform, expected = make_resource_waveform()

        grid = lte_ofdm_demodulate(
            {"NDLRB": 6, "CyclicPrefix": "Normal"},
            waveform,
            cp_fraction=1.0,
            nfft=128,
        )

        self.assertEqual(grid.shape, (72, 14, 1))
        np.testing.assert_allclose(grid[:, :, 0], expected, atol=1e-11, rtol=1e-11)


if __name__ == "__main__":
    unittest.main()
