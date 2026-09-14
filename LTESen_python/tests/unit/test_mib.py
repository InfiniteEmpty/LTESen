import unittest

import numpy as np

from ltesen.ltephy import lte_mib


class MibTests(unittest.TestCase):
    def test_encode_matches_matlab_reference_bits(self):
        config = {
            "NDLRB": 6,
            "Ng": "Sixth",
            "NFrame": 100,
            "PHICHDuration": "Extended",
        }
        # MATLAB R2025b: lteMIB(config) -> 000100000110010000000000
        expected = np.asarray([int(bit) for bit in "000100000110010000000000"], dtype=np.uint8)
        np.testing.assert_array_equal(lte_mib(config), expected)

    def test_decode_and_merge_preserve_existing_configuration_fields(self):
        # MATLAB example input from help lteMIB; it decodes to NFrame=828.
        bits = np.asarray([int(bit) for bit in "010010110011110000000000"], dtype=np.uint8)
        decoded = lte_mib(bits)
        self.assertEqual(decoded, {
            "ndlrb": 25,
            "phich_duration": "Normal",
            "ng": "One",
            "nframe": 828,
        })

        merged = lte_mib(bits, {"NCellID": 172, "DuplexMode": "FDD"})
        self.assertEqual(merged.get("NDLRB", merged.get("ndlrb")), 25)
        self.assertEqual(merged["NCellID"], 172)

    def test_unsupported_bandwidth_decodes_as_zero(self):
        bits = lte_mib({"NDLRB": 110})
        self.assertEqual("".join(str(bit) for bit in bits[:3]), "111")
        self.assertEqual(lte_mib(bits)["ndlrb"], 0)


if __name__ == "__main__":
    unittest.main()
