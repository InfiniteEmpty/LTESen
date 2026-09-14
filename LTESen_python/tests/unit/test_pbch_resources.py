import unittest

import numpy as np

from ltesen.ltephy import lte_extract_resources, lte_pbch_indices


class PbchResourceTests(unittest.TestCase):
    def setUp(self):
        self.enb = {
            "NDLRB": 6,
            "NCellID": 10,
            "CellRefP": 4,
            "NSubframe": 0,
            "CyclicPrefix": "Normal",
            "DuplexMode": "FDD",
        }

    def test_pbch_subscripts_match_matlab_layout(self):
        indices = lte_pbch_indices(self.enb)
        self.assertEqual(indices.shape, (960, 3))
        np.testing.assert_array_equal(indices[0], [0, 7, 0])
        np.testing.assert_array_equal(indices[239], [71, 10, 0])
        np.testing.assert_array_equal(indices[240], [0, 7, 1])

        # MATLAB R2025b ltePBCHIndices(enb,{'0based'}) returns 240 rows
        # per port and the same time-frequency locations in each column.
        linear = lte_pbch_indices(self.enb, ["ind", "1based"])
        self.assertEqual(linear.shape, (240, 4))
        np.testing.assert_array_equal(linear[0], [505, 1513, 2521, 3529])

    def test_pbch_is_empty_outside_subframe_zero(self):
        indices = lte_pbch_indices(dict(self.enb, NSubframe=1))
        self.assertEqual(indices.shape, (0, 3))

    def test_extract_resources_projects_received_and_channel_planes(self):
        indices = lte_pbch_indices(self.enb, ["ind", "1based"])
        rxgrid = np.zeros((72, 14, 2), dtype=np.complex128)
        hest = np.zeros((72, 14, 2, 4), dtype=np.complex128)
        for k in range(72):
            for symbol in range(14):
                for rx in range(2):
                    rxgrid[k, symbol, rx] = 100 * symbol + k + 1000 * rx
                    for port in range(4):
                        hest[k, symbol, rx, port] = (
                            100 * symbol + k + 1000 * rx + 10000 * port
                        )

        rx = lte_extract_resources(indices, rxgrid, options=["ind", "1based"])
        channel = lte_extract_resources(indices, hest, options=["ind", "1based"])
        self.assertEqual(rx.shape, (240, 2))
        self.assertEqual(channel.shape, (240, 2, 4))
        np.testing.assert_array_equal(rx[0], [700, 1700])
        np.testing.assert_array_equal(channel[0, 0], [700, 10700, 20700, 30700])


if __name__ == "__main__":
    unittest.main()
