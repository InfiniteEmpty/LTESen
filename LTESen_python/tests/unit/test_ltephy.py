import unittest

import numpy as np

from ltesen.ltephy import (
    CrsReferenceCache,
    cell_search,
    lte_cell_rs,
    lte_cell_rs_indices,
    lte_crs_csi,
    lte_dl_frame_offset,
    lte_ofdm_info,
)
from ltesen.ltephy.cell_search import _pss_sequence, _sss_sequences


def make_reference_subframe(ndlrb: int, cell_id: int) -> tuple[np.ndarray, object]:
    enb = {
        "ndlrb": ndlrb,
        "ncellid": cell_id,
        "cell_ref_p": 1,
        "nsubframe": 0,
        "cyclic_prefix": "Normal",
        "duplex_mode": "FDD",
    }
    info = lte_ofdm_info(enb)
    n_id_1, n_id_2 = divmod(cell_id, 3)
    sequence0 = _sss_sequences(n_id_1, n_id_2)[0]
    pss = _pss_sequence(n_id_2)
    subframe = np.zeros(
        sum(info.nfft + cp for cp in info.cyclic_prefix_lengths), dtype=np.complex128
    )
    position = 0
    for symbol_index, cp_length in enumerate(info.cyclic_prefix_lengths):
        spectrum = np.zeros(info.nfft, dtype=np.complex128)
        if symbol_index == 5:
            spectrum[-31:] = sequence0[:31]
            spectrum[1:32] = sequence0[31:]
        elif symbol_index == 6:
            spectrum[-31:] = pss[:31]
            spectrum[1:32] = pss[31:]
        active_bins = np.concatenate(
            (
                np.arange(info.nfft - ndlrb * 6, info.nfft),
                np.arange(1, ndlrb * 6 + 1),
            )
        )
        crs_locations = lte_cell_rs_indices(enb, 0, ["sub", "0based"])
        crs_symbols = lte_cell_rs(enb, 0)
        for index, (subcarrier, crs_symbol, _port) in enumerate(crs_locations):
            if crs_symbol == symbol_index:
                spectrum[active_bins[subcarrier]] = crs_symbols[index]
        useful = np.fft.ifft(spectrum) * np.sqrt(info.nfft)
        subframe[position : position + cp_length] = useful[-cp_length:]
        subframe[position + cp_length : position + cp_length + info.nfft] = useful
        position += cp_length + info.nfft
    return subframe, info


class LtePhyTests(unittest.TestCase):
    def test_ofdm_info_matches_matlab_reference_table(self):
        expected = {
            6: (128, 1.92e6, 4),
            15: (256, 3.84e6, 6),
            25: (512, 7.68e6, 4),
            50: (1024, 15.36e6, 6),
            75: (2048, 30.72e6, 8),
            100: (2048, 30.72e6, 8),
        }
        for ndlrb, values in expected.items():
            info = lte_ofdm_info({"NDLRB": ndlrb, "CyclicPrefix": "Normal"})
            self.assertEqual((info.nfft, info.sampling_rate_hz, info.windowing), values)
            self.assertEqual(len(info.cyclic_prefix_lengths), 14)
            self.assertEqual(info.cyclic_prefix_lengths[0], info.cyclic_prefix_lengths[7])

        extended = lte_ofdm_info({"ndlrb": 6, "cyclic_prefix": "Extended"})
        self.assertEqual(extended.cyclic_prefix_lengths, (32,) * 12)

    def test_ofdm_info_scales_explicit_fft_size_and_validates_cp(self):
        info = lte_ofdm_info({"ndlrb": 6}, nfft=256)
        self.assertEqual(info.sampling_rate_hz, 3.84e6)
        self.assertEqual(info.cyclic_prefix_lengths[0], 20)
        with self.assertRaises(ValueError):
            lte_ofdm_info({"ndlrb": 50}, nfft=512)
        with self.assertRaises(ValueError):
            lte_ofdm_info({"ndlrb": 6}, nfft=1000)

    def test_cell_search_recovers_pss_sss_identity_and_frame_offset(self):
        subframe, info = make_reference_subframe(6, cell_id=172)
        prefix = 23
        waveform = np.concatenate((np.zeros(prefix), subframe))[:, None]

        cell_ids, offsets, peaks = cell_search(
            {"ndlrb": 6, "cyclic_prefix": "Normal", "duplex_mode": "FDD"},
            waveform,
            {"sss_detection": "PostFFT", "max_cell_count": 1},
        )

        self.assertEqual(cell_ids.tolist(), [172])
        self.assertEqual(offsets.tolist(), [prefix])
        self.assertGreater(peaks[0], 1.5)
        self.assertEqual(info.pss_symbol_index, 6)

    def test_dl_frame_offset_uses_known_cell_id(self):
        subframe, _ = make_reference_subframe(6, cell_id=172)
        prefix = 23
        waveform = np.concatenate((np.zeros(prefix), subframe))[:, None]

        offset, correlation = lte_dl_frame_offset(
            {"NDLRB": 6, "NCellID": 172, "DuplexMode": "FDD"},
            waveform,
            {"PSS": "On", "SSS": "On", "CellRS": "Off"},
            return_correlation=True,
        )

        self.assertEqual(offset, prefix)
        self.assertEqual(correlation.shape, waveform.shape)
        self.assertGreater(np.max(np.abs(correlation)), 0.9)

    def test_dl_frame_offset_can_refine_with_cell_rs(self):
        subframe, _ = make_reference_subframe(6, cell_id=172)
        prefix = 23
        waveform = np.concatenate((np.zeros(prefix), subframe))[:, None]

        offset = lte_dl_frame_offset(
            {
                "NDLRB": 6,
                "NCellID": 172,
                "CellRefP": 1,
                "DuplexMode": "FDD",
            },
            waveform,
            {
                "PSS": "On",
                "SSS": "On",
                "CellRS": "On",
                "CellRSSearchRadius": 8,
            },
        )

        self.assertEqual(offset, prefix)

    def test_dl_frame_offset_supports_cell_rs_only(self):
        enb = {
            "NDLRB": 6,
            "NCellID": 172,
            "CellRefP": 1,
            "DuplexMode": "FDD",
        }
        subframe, _ = make_reference_subframe(6, cell_id=172)
        prefix = 23
        waveform = np.concatenate((np.zeros(prefix), subframe))[:, None]

        offset = lte_dl_frame_offset(
            enb,
            waveform,
            {"PSS": "Off", "SSS": "Off", "CellRS": "On"},
        )

        self.assertEqual(offset, prefix)

    def test_direct_crs_csi_extracts_both_groups_and_ports(self):
        enb = {
            "NDLRB": 6,
            "NCellID": 10,
            "CellRefP": 2,
            "NSubframe": 0,
            "CyclicPrefix": "Normal",
            "DuplexMode": "FDD",
        }
        grid = np.zeros((72, 14, 1), dtype=np.complex128)

        def channel(subcarrier, symbol, port):
            return 1 + 0.01 * subcarrier + (0.02 + 0.001j) * symbol + 0.1j * port

        expected = {}
        for port in range(2):
            locations = lte_cell_rs_indices(enb, port, ["sub", "0based"])
            references = lte_cell_rs(enb, port)
            for index, (subcarrier, symbol, _port) in enumerate(locations):
                value = channel(subcarrier, symbol, port)
                grid[subcarrier, symbol, 0] = value * references[index]
                expected[(port, int(subcarrier), int(symbol))] = value

        cache = CrsReferenceCache(enb)
        g1, g2, index_g1, index_g2 = lte_crs_csi(
            enb, grid, reference_cache=cache
        )
        self.assertEqual(g1.shape, (12, 2, 1, 2))
        self.assertEqual(g2.shape, (12, 2, 1, 2))
        for port in range(2):
            locations = lte_cell_rs_indices(enb, port, ["sub", "0based"])
            symbols = np.unique(locations[:, 1])
            for group, symbol in enumerate((symbols[0], symbols[2])):
                mask = locations[:, 1] == symbol
                for index, subcarrier in enumerate(locations[mask, 0]):
                    np.testing.assert_allclose(
                        g1[index, group, 0, port],
                        expected[(port, int(subcarrier), int(symbol))],
                    )
            self.assertTrue(np.all(index_g1[:, port] >= 0))
            self.assertTrue(np.all(index_g2[:, port] >= 0))

    def test_crs_reference_cache_reuses_locations_and_caches_ten_subframes(self):
        enb = {
            "NDLRB": 6,
            "NCellID": 10,
            "CellRefP": 2,
            "CyclicPrefix": "Normal",
            "DuplexMode": "FDD",
        }
        cache = CrsReferenceCache(enb)

        self.assertEqual(len(cache.locations), 2)
        self.assertEqual(len(cache.references), 10)
        self.assertIs(cache.for_subframe(0), cache.references[0])
        self.assertFalse(np.array_equal(cache.references[0][0], cache.references[1][0]))


if __name__ == "__main__":
    unittest.main()
