import unittest

import numpy as np

from ltesen.ltephy import lte_pbch_prbs


class PbchHelperTests(unittest.TestCase):
    def test_pbch_prbs_matches_matlab_reference(self):
        enb = {"NCellID": 10}
        expected = np.asarray([int(bit) for bit in "0110001000101111"], dtype=np.uint8)
        np.testing.assert_array_equal(lte_pbch_prbs(enb, 16), expected)
        np.testing.assert_array_equal(
            lte_pbch_prbs(enb, [4, 8]), expected[4:12]
        )
        np.testing.assert_array_equal(
            lte_pbch_prbs(enb, 8, "signed"), 1 - 2 * expected[:8].astype(np.int8)
        )


if __name__ == "__main__":
    unittest.main()
