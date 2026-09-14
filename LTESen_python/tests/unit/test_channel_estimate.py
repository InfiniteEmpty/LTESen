import unittest

import numpy as np

from ltesen.ltephy import (
    lte_cell_rs,
    lte_cell_rs_indices,
    lte_dl_channel_estimate,
)


class ChannelEstimateTests(unittest.TestCase):
    def setUp(self):
        self.enb = {
            "NDLRB": 6,
            "NCellID": 10,
            "CellRefP": 4,
            "NSubframe": 0,
            "CyclicPrefix": "Normal",
            "DuplexMode": "FDD",
        }

    def _crs_only_grid(self, gains):
        grid = np.zeros((72, 14, 1), dtype=np.complex128)
        for port, gain in enumerate(gains):
            locations = lte_cell_rs_indices(self.enb, port, ["sub", "0based"])
            symbols = lte_cell_rs(self.enb, port)
            for index, (subcarrier, symbol, _port) in enumerate(locations):
                grid[subcarrier, symbol, 0] = gain * symbols[index]
        return grid

    def test_ls_estimate_populates_only_crs_locations_without_interpolation(self):
        gains = np.asarray([1, 2 + 0.5j, -0.25j, -1 + 0.25j])
        grid = self._crs_only_grid(gains)
        hest, noise = lte_dl_channel_estimate(
            self.enb,
            grid,
            {
                "PilotAverage": "UserDefined",
                "FreqWindow": 1,
                "TimeWindow": 1,
                "InterpType": "none",
            },
        )

        self.assertEqual(hest.shape, (72, 14, 1, 4))
        self.assertEqual(noise, 0.0)
        for port, gain in enumerate(gains):
            locations = lte_cell_rs_indices(self.enb, port, ["sub", "0based"])
            estimates = hest[locations[:, 0], locations[:, 1], 0, port]
            np.testing.assert_allclose(estimates, gain)

    def test_flat_channel_survives_linear_interpolation(self):
        gains = np.asarray([1, 2 + 0.5j, -0.25j, -1 + 0.25j])
        hest, noise = lte_dl_channel_estimate(
            self.enb,
            self._crs_only_grid(gains),
            {"InterpType": "linear"},
        )

        self.assertEqual(noise, 0.0)
        for port, gain in enumerate(gains):
            np.testing.assert_allclose(hest[:, :, 0, port], gain)

    def test_srsran_interpolation_handles_frequency_edges_and_time(self):
        enb = dict(self.enb)
        enb["CellRefP"] = 1
        grid = np.zeros((72, 14, 1), dtype=np.complex128)

        def channel(subcarrier, symbol):
            return 1.0 + 0.01 * subcarrier + (0.02 + 0.003j) * symbol

        locations = lte_cell_rs_indices(enb, 0, ["sub", "0based"])
        symbols = lte_cell_rs(enb, 0)
        for index, (subcarrier, symbol, _port) in enumerate(locations):
            grid[subcarrier, symbol, 0] = (
                channel(subcarrier, symbol) * symbols[index]
            )

        hest, noise = lte_dl_channel_estimate(
            enb,
            grid,
            {"FreqWindow": 1, "TimeWindow": 1, "InterpType": "linear"},
        )

        self.assertEqual(noise, 0.0)
        expected = np.empty((72, 14), dtype=np.complex128)
        for symbol in range(14):
            for subcarrier in range(72):
                expected[subcarrier, symbol] = channel(subcarrier, symbol)
        np.testing.assert_allclose(hest[:, :, 0, 0], expected)


if __name__ == "__main__":
    unittest.main()
