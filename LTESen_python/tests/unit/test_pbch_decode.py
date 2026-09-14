import unittest

import numpy as np

from ltesen.ltephy import (
    lte_bch,
    lte_cell_rs,
    lte_cell_rs_indices,
    lte_dl_channel_estimate,
    lte_extract_resources,
    lte_mib,
    lte_pbch,
    lte_pbch_decode,
    lte_pbch_indices,
)


class PbchDecodeTests(unittest.TestCase):
    def test_pbch_symbols_match_matlab_port_mapping(self):
        transport = np.arange(24, dtype=np.uint8) % 2
        enb = {"NCellID": 10, "CellRefP": 1, "CyclicPrefix": "Normal"}
        coded = lte_bch(enb, transport)
        symbols = lte_pbch(enb, coded[:480])
        expected = np.asarray(
            [
                -0.7071067811865475 + 0.7071067811865475j,
                0.7071067811865475 - 0.7071067811865475j,
                0.7071067811865475 - 0.7071067811865475j,
                -0.7071067811865475 - 0.7071067811865475j,
                0.7071067811865475 + 0.7071067811865475j,
                0.7071067811865475 + 0.7071067811865475j,
                0.7071067811865475 + 0.7071067811865475j,
                -0.7071067811865475 + 0.7071067811865475j,
            ]
        )
        np.testing.assert_allclose(symbols[:8, 0], expected)

    def test_flat_channel_recovers_mib_for_all_transmit_port_modes(self):
        mib = lte_mib(
            {"NDLRB": 25, "Ng": "One", "NFrame": 828, "PHICHDuration": "Normal"}
        )
        for prefix in ("Normal", "Extended"):
            for ports in (1, 2, 4):
                enb = {
                    "NCellID": 10,
                    "CellRefP": ports,
                    "CyclicPrefix": prefix,
                }
                coded = lte_bch(enb, mib)
                quarter = 480 if prefix == "Normal" else 432
                received = lte_pbch(enb, coded, frame_mod4=0)
                received = np.sum(received, axis=1, keepdims=True)
                hest = np.ones((quarter // 2, 1, ports), dtype=np.complex128)
                _, _, nfmod4, decoded, detected_ports = lte_pbch_decode(
                    enb, received, hest, noise_estimate=0.0
                )
                np.testing.assert_array_equal(decoded, mib)
                self.assertEqual(nfmod4, 0)
                self.assertEqual(detected_ports, ports)

    def test_extended_cp_frame_phase_and_mib_decode(self):
        mib = lte_mib(
            {"NDLRB": 50, "Ng": "Two", "NFrame": 1000, "PHICHDuration": "Extended"}
        )
        enb = {"NCellID": 172, "CellRefP": 4, "CyclicPrefix": "Extended"}
        coded = lte_bch(enb, mib)
        quarter = 432
        received = lte_pbch(enb, coded, frame_mod4=3)
        received = np.sum(received, axis=1, keepdims=True)
        hest = np.ones((quarter // 2, 1, 4), dtype=np.complex128)
        _, _, nfmod4, decoded, detected_ports = lte_pbch_decode(
            enb, received, hest, noise_estimate=0.0
        )
        np.testing.assert_array_equal(decoded, mib)
        self.assertEqual(nfmod4, 3)
        self.assertEqual(detected_ports, 4)

    def test_crs_estimator_output_is_sufficient_for_mib_decode(self):
        enb = {
            "NDLRB": 6,
            "NCellID": 10,
            "CellRefP": 4,
            "NSubframe": 0,
            "CyclicPrefix": "Normal",
            "DuplexMode": "FDD",
        }
        mib = lte_mib(
            {"NDLRB": 6, "Ng": "Sixth", "NFrame": 100, "PHICHDuration": "Extended"}
        )
        coded = lte_bch(enb, mib)
        pbch = lte_pbch(enb, coded[:480])
        grid = np.zeros((72, 14, 1), dtype=np.complex128)

        pbch_subscripts = lte_pbch_indices(enb)
        for port in range(4):
            for index, (subcarrier, symbol, _) in enumerate(
                pbch_subscripts.reshape(4, 240, 3)[port]
            ):
                grid[subcarrier, symbol, 0] += pbch[index, port]

        for port in range(4):
            rs_indices = lte_cell_rs_indices(enb, port, ["sub", "0based"])
            rs_symbols = lte_cell_rs(enb, port)
            for index, (subcarrier, symbol, _) in enumerate(rs_indices):
                grid[subcarrier, symbol, 0] += rs_symbols[index]

        hest, _ = lte_dl_channel_estimate(
            enb,
            grid,
            {
                "PilotAverage": "UserDefined",
                "FreqWindow": 13,
                "TimeWindow": 9,
                "InterpType": "cubic",
            },
        )
        rx = lte_extract_resources(pbch_subscripts, grid)
        channel = lte_extract_resources(pbch_subscripts, hest)
        _, _, nfmod4, decoded, detected_ports = lte_pbch_decode(
            enb, rx, channel, noise_estimate=0.0
        )
        np.testing.assert_array_equal(decoded, mib)
        self.assertEqual(nfmod4, 0)
        self.assertEqual(detected_ports, 4)


if __name__ == "__main__":
    unittest.main()
