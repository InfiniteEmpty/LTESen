import unittest

import numpy as np

from ltesen.ltephy import (
    lte_cell_rs,
    lte_cell_rs_indices,
    lte_resource_grid_size,
)


class CellRsTests(unittest.TestCase):
    def setUp(self):
        self.enb = {
            "NDLRB": 6,
            "NCellID": 10,
            "CellRefP": 4,
            "NSubframe": 0,
            "CyclicPrefix": "Normal",
            "DuplexMode": "FDD",
        }

    def test_resource_grid_size_matches_lte_grid_contract(self):
        self.assertEqual(lte_resource_grid_size(self.enb), (72, 14, 4))
        self.assertEqual(
            lte_resource_grid_size(
                {"NDLRB": 6, "CellRefP": 2, "CyclicPrefix": "Extended"}
            ),
            (72, 12, 2),
        )
        self.assertEqual(
            lte_resource_grid_size(
                {"NULRB": 6, "NTxAnts": 2, "CyclicPrefixUL": "Normal"}
            ),
            (72, 14, 2),
        )
        self.assertEqual(lte_resource_grid_size({"NULRB": 6}, antenna_planes=3), (72, 14, 3))

    def test_indices_match_matlab_zero_based_subscript_examples(self):
        port0 = lte_cell_rs_indices(self.enb, 0, ["0based", "sub"])
        np.testing.assert_array_equal(
            port0[:4],
            np.asarray([[4, 0, 0], [10, 0, 0], [16, 0, 0], [22, 0, 0]]),
        )

        port2 = lte_cell_rs_indices(self.enb, 2, ["0based", "sub"])
        self.assertEqual(port2.shape, (24, 3))
        np.testing.assert_array_equal(port2[0], [4, 1, 2])
        np.testing.assert_array_equal(port2[-1], [67, 8, 2])

    def test_linear_indices_support_matlab_one_based_mapping(self):
        indices = lte_cell_rs_indices(self.enb, 0, ["1based", "ind"])
        np.testing.assert_array_equal(indices[:4], [5, 11, 17, 23])

    def test_symbols_match_matlab_crs_reference_vectors(self):
        # MATLAB R2025b reference command:
        #   lteCellRS(struct('NDLRB',6,'NCellID',10,'CellRefP',4,
        #   'NSubframe',0,'CyclicPrefix','Normal','DuplexMode','FDD'), 0)
        expected_port0 = np.asarray(
            [
                0.7071067811865475 - 0.7071067811865475j,
                0.7071067811865475 + 0.7071067811865475j,
                -0.7071067811865475 - 0.7071067811865475j,
                0.7071067811865475 - 0.7071067811865475j,
                0.7071067811865475 + 0.7071067811865475j,
            ]
        )
        np.testing.assert_allclose(lte_cell_rs(self.enb, 0)[:5], expected_port0)

        expected_port2 = np.asarray(
            [
                0.7071067811865475 - 0.7071067811865475j,
                -0.7071067811865475 - 0.7071067811865475j,
                -0.7071067811865475 + 0.7071067811865475j,
            ]
        )
        np.testing.assert_allclose(lte_cell_rs(self.enb, 2)[:3], expected_port2)

    def test_extended_cp_port_layout(self):
        enb = dict(self.enb, CyclicPrefix="Extended", NSubframe=1)
        port3 = lte_cell_rs_indices(enb, 3, ["0based", "sub"])
        np.testing.assert_array_equal(port3[0], [1, 1, 3])
        np.testing.assert_array_equal(port3[-1], [70, 7, 3])
        self.assertEqual(lte_cell_rs(enb, 3).shape, (24,))


if __name__ == "__main__":
    unittest.main()
